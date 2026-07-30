# TravelX 슬롯 예약 동시성 부하테스트

TravelX(환전 예약 플랫폼) 백엔드의 슬롯 예약 동시성 설계를
[vietnam-internship/server Discussion #13](https://github.com/vietnam-internship/server/discussions/13)에서
비관적 락(방안 A)으로 제안했다. 이 저장소는 그 제안이 실제 배포 환경
([vietnam-internship/infra](https://github.com/vietnam-internship/infra))에서도 유효한지
k6로 직접 검증한 기록이다.

**이번 라운드부터는 로컬 복제가 아니라 실제 배포된 단일 인스턴스를 대상으로 직접
실행한다** (별도 staging 환경이 없어 사실상 유일한 실서버). 그만큼 안전장치가
전제조건이므로, 실행 전 반드시 [안전 수칙](#안전-수칙--실배포-대상-필수)을 먼저 읽을 것.

---

## 핵심 질문

슬롯 정원(6명) 경합 상황에서, **락 자체가 병목인가 아니면 커넥션 풀
(`HIKARI_MAX_POOL_SIZE=8`)이 먼저 병목이 되는가?**

기존 논의(#13)는 이 4개 지표에 임계치를 정의했다: 락 대기시간, p95/p99 응답지연,
데드락 발생 여부, TPS. 여기에 인프라 스펙을 직접 확인하는 과정에서 **커넥션 풀 대기**와
**CPU 쓰로틀링**을 추가 관측 대상으로 넣었다 — 둘 다 락보다 먼저 병목이 될 수 있는
요인이기 때문이다.

---

## 이번 라운드에서 바뀐 것

- **대상**: 로컬 Docker 복제 → [vietnam-internship/infra](https://github.com/vietnam-internship/infra)로
  배포된 실제 단일 인스턴스. 별도 staging 클러스터/DB는 없다(서버 코드에
  `application-staging.yml`이 있지만 실제로 배포되는 곳은 `SPRING_PROFILES_ACTIVE=prod` 하나뿐).
- **유저 풀 오염 버그 수정**: 예전엔 A(VU=20)/B0(VU=6)/B1(VU=20)이 같은 20명의 토큰을
  `(__VU-1) % 20`으로 재사용했다. A에서 성공한 6명은 결제 웹훅을 안 태워 `PENDING_PAYMENT`
  예약을 쥔 채 남는데, 이 유저가 B0/B1에서 다시 뽑히면 락/풀 대기가 아니라
  `CONCURRENT_PENDING_PAYMENT_LIMIT`(C304)로 막혀 **순수 락 대기 측정이 오염**된다. 게다가
  어떤 토큰이 A에서 이길지는 레이스라 재현성도 없었다. → **시나리오별로 겹치지 않는 유저
  구간**(총 66명: A 20 / B0 6 / B1 20 / C 20)을 쓰도록 `seed.sh`/`scenario.js`를 고쳤다.
- **실사용자 노출 차단**: 테스트 지점을 생성 직후 `active=false`로 비활성화해 공개
  `GET /branches` 목록에서 숨긴다(예약 생성은 `branchId`를 직접 지정하므로 영향 없음).
- **클린업 스크립트 추가**(`scripts/cleanup.sh`): 실배포 DB에 테스트 데이터가 남으므로,
  종료 후 되돌릴 수 있는 것(재고)은 자동으로 되돌리고, 나머지는 검토용 SQL만 출력한다.
- **관측 명령**: `docker exec`/`docker stats` → `kubectl exec`/`kubectl top pod`
  (infra의 [`redeploy.sh`](https://github.com/vietnam-internship/infra/blob/main/redeploy.sh) 관례에 맞춰
  `sudo kubectl`, `KUBECONFIG=/etc/rancher/k3s/k3s.yaml` 사용).

---

## 안전 수칙 (실배포 대상 — 필수)

실배포 인프라의 실제 특성(모두 [vietnam-internship/infra](https://github.com/vietnam-internship/infra) 확인):

- **단일 VM, 단일 replica, HPA 없음** — 부하테스트 트래픽이 실사용자 트래픽과 완전히
  같은 CPU(500m)/메모리(768Mi)/HikariCP 풀(8)을 공유한다. 테스트 시간 동안 실사용자
  응답이 느려질 수 있다.
- **MySQL도 자체 파드(PVC)** — RDS 같은 관리형 DB가 아니라 같은 클러스터의 파드다.
  DB 부하도 실사용자와 그대로 공유된다.
- **`DEV_AUTH_ENABLED`는 prod configmap에 `false`로 고정, 명시적 경고 있음**
  (`k8s/configmap.env`: "운영에서 켜두면 인증 우회 엔드포인트가 그대로 열려버리므로
  절대 true로 바꾸지 말 것"). 테스트를 위해 이 값을 켜는 것은 **의도적인 예외**이지
  기본값이 아니다 — 아래처럼 최소 시간만 켜고 즉시 되돌린다.
- **`travelx-server` Deployment는 `Recreate` 전략** (hostPort 8080을 쓰기 때문에
  RollingUpdate 불가). 즉 `DEV_AUTH_ENABLED`를 켜고 끌 때마다 파드가 재기동되며
  **매번 수십 초~최대 수 분(startupProbe `failureThreshold: 30 × periodSeconds: 5`)의
  실다운타임**이 발생한다 — on/off 두 번이면 다운타임도 두 번이다.

### 체크리스트

1. **트래픽이 가장 적은 시간대**에 진행한다.
2. `DEV_AUTH_ENABLED`를 켠다 (VM에서 직접, infra 레포의 커밋된 `configmap.env`는 건드리지
   않고 배포 스펙만 일시적으로 오버라이드 — 되돌리기 쉽게):
   ```bash
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl set env deployment/travelx-server DEV_AUTH_ENABLED=true
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl rollout status deployment/travelx-server --timeout=180s
   curl -sf https://api.knu80th.shop/actuator/health
   ```
3. `scripts/seed.sh` 실행 → `k6 run` 실행 → 결과 확인.
4. **테스트 결과와 무관하게 즉시** `DEV_AUTH_ENABLED`를 되돌린다:
   ```bash
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl set env deployment/travelx-server DEV_AUTH_ENABLED=false
   sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl rollout status deployment/travelx-server --timeout=180s
   ```
5. `scripts/cleanup.sh`로 테스트 지점 재고 정리 (테스트 예약 자체는 서버의 기존
   `ReservationExpirySweeper`가 5분 TTL로 자동 정리 — 결제 웹훅을 안 태우므로 전부
   `PENDING_PAYMENT → EXPIRED` 경로를 탄다).
6. 테스트 중 `kubectl top pod`와 실사용자向 에러율을 병행 관찰하다가, 이상 징후가 보이면
   즉시 k6를 중단(`Ctrl+C`)하고 3~4번을 먼저 실행한다.

---

## 저장소 구성

```
.
├── README.md              # 이 문서 — 설계 배경과 실행 방법
├── docs/
│   └── round1-findings.md # 라운드별 실행 기록 — 변경사항/결과/원인 분석/TODO
├── env/
│   └── configmap.env.example   # (선택) 로컬 리허설용 — infra 레포 값 목록, 값 자체는 포함 안 함
├── scripts/
│   ├── seed.sh             # 지점/재고/슬롯/테스트 유저 토큰(66명) 생성
│   └── cleanup.sh          # 테스트 지점 재고 정리 + 행 삭제용 SQL 출력(수동 실행)
└── k6/
    └── scenario.js         # 부하테스트 시나리오 (A/B0/B1/C)
```

---

## 검증 대상 지표

| 지표 | 정의 | 측정 방법 |
|---|---|---|
| 정합성(Correctness) | 슬롯 정원 초과 예약이 확정되지 않는가 | 성공 건수 카운트 (정확히 6건이어야 함) |
| 락 대기시간 | `BranchTimeSlot` 행 락 획득까지 걸린 시간 | `SHOW ENGINE INNODB STATUS` / `sys.innodb_lock_waits` |
| p95 / p99 응답지연 | 전체 요청의 95/99번째 백분위 응답 시간 | k6 `http_req_duration` |
| 데드락 발생 여부 | 락 순서 충돌로 인한 트랜잭션 강제 종료 | `SHOW ENGINE INNODB STATUS`의 LATEST DETECTED DEADLOCK |
| TPS | 초당 처리 가능한 예약 요청 수 | k6 `http_reqs` |
| 커넥션 풀 대기시간 | HikariCP에서 커넥션을 못 받아 대기한 시간 | HikariCP DEBUG 로그 |
| CPU 쓰로틀링 | cgroup CPU 제한(500m)에 걸려 강제 대기한 시간 | `/sys/fs/cgroup/cpu.stat`의 `nr_throttled` |

---

## A. (선택) 로컬 리허설 — 실배포 실행 전 먼저 검증 권장

실배포에 영향을 주지 않고 스크립트/시나리오 자체가 의도대로 도는지 먼저 확인하고
싶다면, 동일 리소스 제약을 Docker로 복제해 리허설한다.

```bash
docker network create travelx-net

docker run -d --name travelx-mysql \
  --network travelx-net \
  -e MYSQL_DATABASE=travelx \
  -e MYSQL_USER=$DB_USERNAME \
  -e MYSQL_PASSWORD=$DB_PASSWORD \
  -e MYSQL_ROOT_PASSWORD=$DB_PASSWORD \
  mysql:8.4

docker run -d --name travelx-loadtest \
  --network travelx-net \
  --cpus=0.5 --memory=768m \
  --env-file env/configmap.env \
  -e DEV_AUTH_ENABLED=true \
  -e JAVA_TOOL_OPTIONS="-Xlog:gc*:file=/app/logs/gc.log" \
  -p 8090:8080 \
  ghcr.io/vietnam-internship/server:latest
```

- `env/configmap.env`는 [infra 레포의 `k8s/configmap.env`](https://github.com/vietnam-internship/infra/blob/main/k8s/configmap.env)와
  `k8s/secret.env`를 합쳐서 로컬에 직접 만든다 (`env/configmap.env.example` 참고, 실제
  값은 커밋 안 함).
- `--cpus=0.5 --memory=768m`은 실배포 `deployment.yaml`의 `resources.limits`와 동일하다.
- `DEV_AUTH_ENABLED=true`만 실배포 값(`false`)과 다르게 오버라이드한다. 그 외
  `HIKARI_MAX_POOL_SIZE=8`, `TOMCAT_MAX_THREADS=600`, `VIRTUAL_THREADS_ENABLED=true` 등은
  전부 실배포 값 그대로 사용한다.

리허설 상태 확인: `curl http://localhost:8090/actuator/health`

리허설에서는 `BASE_URL=http://localhost:8090`을 쓰고, 아래 B 섹션의 안전 수칙(트래픽
시간대, 되돌리기 등)은 적용할 필요 없다 — 실사용자가 없는 로컬 컨테이너이기 때문이다.

## B. 실제 배포 환경에서 실행

- 대상: [vietnam-internship/infra](https://github.com/vietnam-internship/infra)로 띄운 단일
  k3s VM. `travelx-server`는 해당 VM의 nginx가 `https://api.knu80th.shop → localhost:8080`으로
  리버스 프록시한다(hostPort 8080, 인증서 certbot 관리).
- MySQL은 RDS가 아니라 **같은 클러스터의 자체 파드**(`mysql-data` PVC)다.
- `BASE_URL=https://api.knu80th.shop`으로 아래 사전 준비/실행 단계를 그대로 쓴다.
- **반드시 [안전 수칙](#안전-수칙--실배포-대상-필수) 체크리스트 순서대로 진행할 것**
  (`DEV_AUTH_ENABLED` on → seed → k6 → off → cleanup).

---

## 테스트 시나리오

### 사전 준비

```bash
BASE_URL=https://api.knu80th.shop ./scripts/seed.sh
```

- 지점 1개(정원 6명, timeSlotCapacity=6) — A/B0/B1이 각각 같은 날짜의 다른 시간대(10:00/10:30/11:00)를
  써서 서로 슬롯 정원을 침범하지 않음. 여기에 분산용 슬롯 20개 추가, 통화 USD 재고는 100만으로 시드.
  생성 직후 `active=false`로 비활성화해 실사용자 대상 지점 목록에서 숨김.
- 시나리오별로 **겹치지 않는** 유저 토큰 66명 발급(A 20 / B0 6 / B1 20 / C 20) —
  같은 유저를 여러 시나리오에서 재사용하면 `CONCURRENT_PENDING_PAYMENT_LIMIT`에 걸려
  결과가 오염되므로 반드시 구간을 분리한다.
- `k6/tokens.json`, `k6/token-counts.json`, `k6/spread-slots.json`, `k6/hot-slot.json` 생성
  (git에는 커밋 안 함)

### 시나리오 A — 정합성 검증 (제일 먼저 실행됨)

정원 6인 슬롯에 서로 다른 유저 20명이 동시에 `POST /reservations` →
**정확히 6건만 성공**, 나머지는 정원초과 에러(500 아님)인지 확인한다.
`k6/scenario.js`에서 항상 첫 번째(0초)로 실행되도록 고정해뒀다 — 이게 실패하면
뒤이은 B0/B1/C의 성능 숫자는 의미가 없으므로, k6 실행 후 콘솔에서 A의 성공 건수부터
확인한다.

### 시나리오 매트릭스 — 락 vs 커넥션 풀 분리

|                        | 풀 크기 이내(VU=6)      | 풀 초과(VU=20)                    |
|------------------------|--------------------------|-----------------------------------|
| **같은 슬롯**(경합 O) | B0 — 순수 락 대기        | B1 — 실제 배포 조건(락+풀 대기 합산) |
| **다른 슬롯**(경합 X) | 대조군(즉시 응답 확인용) | C — 풀 대기만(락 없음)             |

**`B1 − C ≈ 슬롯 락 자체로 인한 순수 지연`** — 이 차감이 이 테스트 설계의 핵심이다.

### 실행

```bash
cd k6
k6 run -e BASE_URL=https://api.knu80th.shop scenario.js --summary-export=../results/summary.json
```

`branchId`/슬롯 날짜·시간/유저 토큰/구간 오프셋은 전부 `seed.sh`가 만든 json 파일을
스크립트가 직접 읽으므로 별도 `-e` 플래그가 필요 없다.

`k6/scenario.js`는 A(정합성, 0초) → B0(VU=6, 20초 뒤) → B1(VU=20, 40초 뒤) →
C(VU=20, 60초 뒤) 순서로 `startTime`을 분리해뒀기 때문에 한 번 실행으로 네 시나리오가
순차 진행된다. **A/B0/B1은 서로 다른 슬롯(같은 날짜, 다른 시간대)을 쓴다** — 같은 슬롯을
재사용하면 앞 시나리오가 정원 6을 다 소진해버려서 뒤 시나리오가 처음부터
"슬롯 꽉 참"으로만 나오기 때문이다. **A/B0/B1/C는 서로 다른 유저 구간을 쓴다** — 같은
유저를 재사용하면 앞 시나리오에서 성공한 유저가 `PENDING_PAYMENT`를 쥔 채 뒤 시나리오에서
C304로 막혀 결과가 오염되기 때문이다.

### 실행 중/후 관측 (실배포 — kubectl 기준)

```bash
# 실시간 리소스
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl top pod -l app=travelx-server

# CPU 쓰로틀링 여부
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec deployment/travelx-server -- cat /sys/fs/cgroup/cpu.stat

# 데드락 여부 (자체 MySQL 파드, RDS 아님)
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec deployment/mysql -- \
  mysql -uroot -p$DB_PASSWORD -e "SHOW ENGINE INNODB STATUS\G" \
  | grep -A 30 "LATEST DETECTED DEADLOCK"
```

로컬 리허설(A 섹션)에서는 위 명령을 그대로 `docker stats travelx-loadtest` /
`docker exec travelx-loadtest cat /sys/fs/cgroup/cpu.stat` / `docker exec travelx-mysql mysql ...`로
바꿔 쓰면 된다.

---

## 클린업

```bash
BASE_URL=https://api.knu80th.shop ./scripts/cleanup.sh
```

- 테스트 지점의 USD 재고를 0으로 되돌린다(active=false는 seed.sh가 이미 처리).
- 테스트 예약(`PENDING_PAYMENT`)은 결제 웹훅을 안 태웠으므로 서버의 기존
  `ReservationExpirySweeper`가 5분 TTL 후 자동으로 `EXPIRED` 처리하며 슬롯/재고를 복원한다
  — 별도 조치 불필요.
- 지점/예약/유저 행 자체를 DB에서 완전히 지우고 싶다면 스크립트가 출력하는 SQL을
  검토 후 직접 실행할 것(삭제 API가 없어 자동화하지 않았고, 실배포 DB에 대한 되돌릴 수
  없는 작업이라 의도적으로 사람 손을 거치게 했다).

---

## 성공/실패 판정 기준

| 항목 | 통과 기준 |
|---|---|
| 정합성 | 정확히 6건 성공, 나머지는 4xx (500 없음) |
| 데드락 | 0건 |
| B0 p95 | 락 대기만 있는 상태에서 목표치(예: 200ms대) 근접 — 단, 실배포는 nginx+TLS 경유라 로컬 리허설보다 기본 RTT가 크므로 최초 실행은 관찰 기준으로 삼는다 |
| B1 − C | 값이 크면 "락이 실제 병목"이라는 원래 결론을 지지, 작으면 "커넥션 풀이 더 큰 병목"이라는 새로운 발견 |

---

## 결과

라운드별 실행 기록(변경사항/결과/원인 분석/TODO)은 [`docs/round1-findings.md`](docs/round1-findings.md)에 정리한다.

- **1차 실행** ([`docs/round1-findings.md`](docs/round1-findings.md)): 정합성 기준(전체 66건 중
  성공 3건뿐, 500 34건) 미충족 — 원인 미확인 상태로 로그 확인 후 재테스트 예정.
