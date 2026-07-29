# TravelX 슬롯 예약 동시성 부하테스트

TravelX(환전 예약 플랫폼) 백엔드의 슬롯 예약 동시성 설계를
[vietnam-internship/server Discussion #13](https://github.com/vietnam-internship/server/discussions/13)에서
비관적 락(방안 A)으로 제안했다. 이 저장소는 그 제안이 실제 배포 스펙
([vietnam-internship/infra](https://github.com/vietnam-internship/infra))에서도 유효한지
k6로 직접 검증한 기록이다.

라이브 서버는 건드리지 않고, 로컬에 **동일한 리소스 제약(CPU 0.5, 메모리 768Mi,
HikariCP 풀 8개)을 Docker로 복제**해 테스트한다.

---

## 핵심 질문

슬롯 정원(6명) 경합 상황에서, **락 자체가 병목인가 아니면 커넥션 풀
(`HIKARI_MAX_POOL_SIZE=8`)이 먼저 병목이 되는가?**

기존 논의(#13)는 이 4개 지표에 임계치를 정의했다: 락 대기시간, p95/p99 응답지연,
데드락 발생 여부, TPS. 여기에 인프라 스펙을 직접 확인하는 과정에서 **커넥션 풀 대기**와
**CPU 쓰로틀링**을 추가 관측 대상으로 넣었다 — 둘 다 락보다 먼저 병목이 될 수 있는
요인이기 때문이다.

---

## 저장소 구성

```
.
├── README.md              # 이 문서 — 설계 배경과 실행 방법
├── env/
│   └── configmap.env.example   # infra 레포에서 가져와야 하는 값 목록(값 자체는 포함 안 함)
├── scripts/
│   └── seed.sh             # 지점/재고/슬롯/테스트 유저 토큰 생성
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

## 테스트 환경 — 실제 배포 스펙 재현

### 1. 앱 컨테이너

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
  `k8s/secret.env`를 합쳐서 로컬에 직접 만든다 (이 저장소엔 실제 값을 커밋하지 않음 —
  `env/configmap.env.example` 참고).
- `--cpus=0.5 --memory=768m`은 [infra 레포 `deployment.yaml`](https://github.com/vietnam-internship/infra/blob/main/k8s/deployment.yaml)의
  `resources.limits`와 동일하다.
- `DEV_AUTH_ENABLED=true`만 실제 prod 값(`false`)과 다르게 오버라이드한다 — 테스트 유저
  20명을 매번 실제 Google OAuth로 만들 수 없어서, 이 값만 테스트 편의를 위해 켠다. 그 외
  `HIKARI_MAX_POOL_SIZE=8`, `TOMCAT_MAX_THREADS=600`, `VIRTUAL_THREADS_ENABLED=true` 등은
  전부 실제 prod 값 그대로 사용한다.

### 2. 상태 확인

```bash
curl http://localhost:8090/actuator/health
```

---

## 테스트 시나리오

### 사전 준비

```bash
BASE_URL=http://localhost:8090 ./scripts/seed.sh
```

- 지점 1개(정원 6명, timeSlotCapacity=6) — A/B0/B1이 각각 같은 날짜의 다른 시간대(10:00/10:30/11:00)를
  써서 서로 슬롯 정원을 침범하지 않음. 여기에 분산용 슬롯 20개 추가, 통화 USD 재고는 100만으로 시드
- 서로 다른 유저 20명의 dev-auth 토큰 발급 (같은 유저로 동시 요청하면
  `CONCURRENT_PENDING_PAYMENT_LIMIT`에 걸려 결과가 오염되므로 반드시 유저를 분리한다)
- `k6/tokens.json`, `k6/spread-slots.json`, `k6/hot-slot.json` 생성 (git에는 커밋 안 함)

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
k6 run -e BASE_URL=http://localhost:8090 scenario.js --summary-export=../results/summary.json
```

`branchId`/슬롯 날짜·시간/유저 토큰은 전부 `seed.sh`가 만든 `hot-slot.json` /
`spread-slots.json` / `tokens.json`을 스크립트가 직접 읽으므로 별도 `-e` 플래그가 필요 없다.

`k6/scenario.js`는 A(정합성, 0초) → B0(VU=6, 20초 뒤) → B1(VU=20, 40초 뒤) →
C(VU=20, 60초 뒤) 순서로 `startTime`을 분리해뒀기 때문에 한 번 실행으로 네 시나리오가
순차 진행된다. **A/B0/B1은 서로 다른 슬롯(같은 날짜, 다른 시간대)을 쓴다** — 같은 슬롯을
재사용하면 앞 시나리오가 정원 6을 다 소진해버려서 뒤 시나리오가 처음부터
"슬롯 꽉 참"으로만 나오기 때문이다.

### 실행 중/후 관측

```bash
# 실시간 리소스
docker stats travelx-loadtest

# CPU 쓰로틀링 여부
docker exec travelx-loadtest cat /sys/fs/cgroup/cpu.stat

# 데드락 여부
docker exec travelx-mysql mysql -uroot -p$DB_PASSWORD -e "SHOW ENGINE INNODB STATUS\G" \
  | grep -A 30 "LATEST DETECTED DEADLOCK"
```

---

## 성공/실패 판정 기준

| 항목 | 통과 기준 |
|---|---|
| 정합성 | 정확히 6건 성공, 나머지는 4xx (500 없음) |
| 데드락 | 0건 |
| B0 p95 | 락 대기만 있는 상태에서 목표치(예: 200ms대) 근접 |
| B1 − C | 값이 크면 "락이 실제 병목"이라는 원래 결론을 지지, 작으면 "커넥션 풀이 더 큰 병목"이라는 새로운 발견 |

---

## 결과

_실행 후 `results/`에 요약을 채우고, 이 섹션에 표/그래프로 정리 예정._
