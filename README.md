# TravelX 슬롯 예약 동시성 부하테스트

TravelX(환전 예약 플랫폼) 백엔드의 슬롯 예약 동시성 설계를
[vietnam-internship/server Discussion #13](https://github.com/vietnam-internship/server/discussions/13)에서
비관적 락(방안 A)으로 제안했다. 이 저장소는 그 제안이 실제 배포 환경
([vietnam-internship/infra](https://github.com/vietnam-internship/infra)로 띄운 단일 인스턴스,
`https://api.knu80th.shop`)에서도 유효한지 k6로 직접 검증한 기록이다. 별도 staging 환경이
없어 이 인스턴스가 사실상 유일한 실서버이고, **모든 실행은 처음부터 이 실서버를 직접
대상으로 했다** — 로컬 복제 환경은 쓰지 않았다. 그만큼 안전장치가 전제조건이므로, 실행 전
반드시 [안전 수칙](#안전-수칙-필수)을 먼저 읽을 것.

---

## 무엇을 확인하려 했고, 무엇을 알아냈나 (요약)

**원래 물음(discussion#13)**: 슬롯 정원(6명) 경합 상황에서, `BranchTimeSlot` 행의 비관적
락 자체가 병목인가, 아니면 `HIKARI_MAX_POOL_SIZE=8`인 커넥션 풀이 먼저 병목이 되는가?

이 물음에 답하려고 A(정합성 검증)/B0(풀 이내+락 경합)/B1(풀 초과+락 경합)/C(풀 초과+무경합)
4개 시나리오를 k6로 짜서 실제 서버에 대고 5차례 실행했다. 결과부터 말하면:

- **정합성은 항상 통과했다** — 슬롯 정원 6명을 넘는 예약이 확정된 적은 한 번도 없다.
- **최종 결론: 병목은 락이 아니라 커넥션 풀이다.** 락 경합이 전혀 없는 대조군(C)이 락 경합이
  있는 시나리오(A)보다 오히려 `HIKARI_MAX_POOL_SIZE=8` 고갈로 인한 500 에러를 더 많이
  겪었다 — 락이 요청을 순서대로 줄 세워서 동시 DB 커넥션 수요를 오히려 분산시키는 반면,
  경합이 없는 시나리오는 모든 요청이 한꺼번에 DB로 몰려서 풀을 더 확실하게 고갈시켰기
  때문이다 ([`docs/round5-findings.md`](docs/round5-findings.md)).
- **가는 길에 실제 버그를 3개 찾아 고쳤다** — 이게 이 테스트가 존재하는 이유를 가장 잘
  보여준다. 순차적인 수동 QA로는 절대 안 드러나고, 실제 동시 요청이 몰려야만 나타나는
  문제들이었다:
  1. **서버 버그**: `branch_time_slots` 테이블에 있어야 할 UNIQUE 제약이 실제 운영 DB엔
     없는 스키마 드리프트 상태였다. 고동시성 상황에서 중복 행이 쌓이면서 500 에러를
     대량으로 냈다 (`server` 레포 커밋 `ca4867f`로 수정됨, [`docs/round2-findings.md`](docs/round2-findings.md)).
  2. **테스트 설계 버그**: 시나리오마다 겹치는 유저를 재사용해서, 한 시나리오에서 성공한
     유저가 다음 시나리오에서 `CONCURRENT_PENDING_PAYMENT_LIMIT`에 걸려 결과가 오염됐다
     ([`docs/round1-findings.md`](docs/round1-findings.md)). 라운드가 바뀌어도 같은 이메일을
     재사용해서 라운드 간에도 같은 문제가 새는 것도 나중에 추가로 발견했다
     ([`docs/round3-findings.md`](docs/round3-findings.md)).
  3. **k6 스크립트 버그**: k6의 `__VU`가 시나리오마다 1부터 새로 시작한다고 잘못 가정하고
     토큰 인덱스를 계산했다. 실제로는 테스트 전체에서 전역으로 유일한 번호라서, 일부
     시나리오의 토큰 배열 인덱스가 범위를 벗어나 `undefined` 토큰(`Bearer undefined`)으로
     요청이 나가 401이 대량으로 났다 ([`docs/round4-findings.md`](docs/round4-findings.md)).

각 라운드의 세부 실행 로그·분석·스크린샷은 [라운드별 결과](#라운드별-결과)에 정리했다.

---

## 테스트 목표

이 테스트로 확인하고 싶은 것은 딱 두 가지, 우선순위 순으로:

1. **오버부킹이 실제로 일어났는가**: `BranchTimeSlot` 행에 비관적 락을 걸어뒀지만, 그게
   "설계상 그렇다"는 것과 "동시 요청 앞에서 실제로 그렇게 동작한다"는 건 다른 문제다.
   슬롯 정원(6명)을 초과하는 예약이 단 한 건이라도 확정되면 이 테스트는 실패다 — 다른
   모든 결과보다 이게 최우선이다. (실측: 지금까지 5차 모두 통과, 초과 예약 0건.)
2. **병목이 락인가, HikariCP 커넥션 풀인가 — 풀 튜닝이 필요한가**: 정원 경합 상황에서 실제로
   느려지거나 에러(500)가 나는 지점이 락 대기인지 `HIKARI_MAX_POOL_SIZE=8` 풀 고갈인지
   구분한다(`B1 − C` 비교). 병목이 풀로 확인되면, 이 값을 실제 기대 동시 부하에 맞게 올려야
   하는지 판단하는 근거로 삼는다. (실측: 5차 결과 `B1 − C`가 음수 — 병목은 락이 아니라
   커넥션 풀. `docs/round5-findings.md` 참고.)

**성공 기준**은 "임계치 통과"가 아니라 "이 두 가지에 대해 명확한 답을 얻는 것"이다. 임계치가
깨져도 왜 깨졌는지 설명할 수 있으면 그 자체로 유의미한 결과다.

이 둘을 검증하는 과정에서 원래 목표는 아니었지만 실제 버그를 여러 개 찾았다(스키마 드리프트,
테스트 설계 버그, k6 스크립트 버그 — [위 요약](#무엇을-확인하려-했고-무엇을-알아냈나-요약) 참고).
그 경험을 살려서, discussion#13 범위 밖이지만 고동시성에서만 드러나는 다른 엣지케이스도
`k6/edge-case-*.js`로 별도 탐색하고 있다. **첫 번째로 확인한 예약 취소 동시 요청 레이스는
버그로 확정됐다** — 동시 취소 10건 중 5건이 각각 "성공" 처리되며 재고가 정상보다 400
(4회분) 더 복원됐다. 즉 목표 1번(오버부킹 방지)과 거울처럼 반대되는 방향의 문제로, 취소
경로에서 재고/슬롯이 실제보다 부풀려질 수 있다는 뜻이다. 자세한 내용은
[`docs/edge-cases.md`](docs/edge-cases.md) 참고.

---

## 테스트 대상 환경

- [vietnam-internship/infra](https://github.com/vietnam-internship/infra)로 띄운 **단일 k3s
  VM**. `travelx-server`는 이 VM의 nginx가 `https://api.knu80th.shop → localhost:8080`으로
  리버스 프록시한다(hostPort 8080, 인증서 certbot 관리).
- MySQL은 RDS 같은 관리형 DB가 아니라 **같은 클러스터의 자체 파드**(`mysql-data` PVC)다.
- 단일 replica, HPA 없음 — 부하테스트 트래픽이 실사용자 트래픽과 완전히 같은
  CPU(500m)/메모리(768Mi)/HikariCP 풀(8)을 공유한다.
- `BASE_URL=https://api.knu80th.shop`으로 모든 스크립트를 실행한다.

---

## 안전 수칙 (필수)

- **단일 VM, 단일 replica, HPA 없음** — 테스트 시간 동안 실사용자 응답이 느려질 수 있다.
- **MySQL도 자체 파드** — DB 부하도 실사용자와 그대로 공유된다.
- **`DEV_AUTH_ENABLED`는 prod configmap에 `false`로 고정, 명시적 경고 있음**
  (`k8s/configmap.env`: "운영에서 켜두면 인증 우회 엔드포인트가 그대로 열려버리므로
  절대 true로 바꾸지 말 것"). 테스트를 위해 이 값을 켜는 것은 **의도적인 예외**이지
  기본값이 아니다 — 최소 시간만 켜고 즉시 되돌린다.
- **`travelx-server` Deployment는 `Recreate` 전략** (hostPort 8080을 쓰기 때문에
  RollingUpdate 불가). `DEV_AUTH_ENABLED`를 켜고 끌 때마다 파드가 재기동되며 **매번 수십
  초~최대 수 분의 실다운타임**이 발생한다 — on/off 두 번이면 다운타임도 두 번이다.
- **재시드 없이 재실행 금지**: k6를 한 번이라도 돌렸다면(중단됐더라도) 슬롯 정원/유저의
  `PENDING_PAYMENT` 상태가 이미 소비돼 있다. 재시드 없이 재실행하면 재현이 아니라 오염된
  결과가 나온다([`docs/round4-findings.md`](docs/round4-findings.md)에서 실제로 겪은 실수).
- **문제가 생긴 순간의 로그는 몇 분 안에 확보해야 한다**: 로그 aggregator가 없는 MVP
  구성이라, k6 실행이 끝나는 즉시 서버 로그부터 파일로 받아두지 않으면 컨테이너 로그
  로테이션으로 영영 사라진다([`docs/round3-findings.md`](docs/round3-findings.md)에서 실제로
  놓친 사례).

### 체크리스트

1. **트래픽이 가장 적은 시간대**에 진행한다.
2. `DEV_AUTH_ENABLED`를 켠다 (VM에서 직접, infra 레포의 커밋된 `configmap.env`는 건드리지
   않고 배포 스펙만 일시적으로 오버라이드 — 되돌리기 쉽게):
   ```bash
   kubectl set env deployment/travelx-server DEV_AUTH_ENABLED=true
   kubectl rollout status deployment/travelx-server --timeout=180s
   curl -sf https://api.knu80th.shop/actuator/health
   ```
3. `scripts/seed.sh` 실행 → `k6 run` 실행(끝까지, 중단하지 말 것) → 결과 확인.
4. k6가 끝나면 **바로** 서버 로그부터 파일로 받아둔다 (분석은 그다음에 해도 됨):
   ```bash
   kubectl logs -l app=travelx-server -c travelx-server --tail=1000 > /tmp/roundN-server.log
   ```
5. **테스트 결과와 무관하게 즉시** `DEV_AUTH_ENABLED`를 되돌린다:
   ```bash
   kubectl set env deployment/travelx-server DEV_AUTH_ENABLED=false
   kubectl rollout status deployment/travelx-server --timeout=180s
   ```
6. `scripts/cleanup.sh`로 테스트 지점 재고/행 정리 (VM에서, [클린업](#클린업) 참고).
7. 테스트 중 `kubectl top pod`와 실사용자向 에러율을 병행 관찰하다가, 이상 징후가 보이면
   즉시 k6를 중단(`Ctrl+C`)하고 4~5번을 먼저 실행한다.

---

## 저장소 구성

```
.
├── README.md              # 이 문서 — 설계 배경, 목표/결과 요약, 실행 방법
├── docs/
│   ├── round1~5-findings.md   # 라운드별 실행 기록 — 변경사항/결과/원인 분석/TODO
│   ├── edge-cases.md          # discussion#13 범위 밖 동시성 엣지케이스 탐색 기록
│   └── images/                 # 라운드별 k6 결과 스크린샷
├── scripts/
│   ├── seed.sh             # 지점/재고/슬롯/테스트 유저 토큰(66명) 생성
│   └── cleanup.sh          # 테스트 지점 재고 정리 + kubectl exec로 실제 행 삭제(확인 프롬프트)
└── k6/
    ├── scenario.js         # 부하테스트 시나리오 (A/B0/B1/C) — discussion#13 핵심 질문용
    └── edge-case-*.js      # 개별 엣지케이스 검증 스크립트 (docs/edge-cases.md 참고)
```

---

## 검증 대상 지표

가장 최근 정상 완료된 실행(5차, 2026-07-30, `branchId=24`)의 실측값을 같이 적는다. 자세한
원본 수치는 [`docs/round5-findings.md`](docs/round5-findings.md)와
[`docs/images/round5-total-results.png`](docs/images/round5-total-results.png) 참고.

| 지표 | 정의 | 측정 방법 | 5차 실측값 |
|---|---|---|---|
| 정합성(Correctness) | 슬롯 정원 초과 예약이 확정되지 않는가 | 성공 건수 카운트 (정확히 6건이어야 함) | **통과** — A: 20건 중 정확히 6건 성공(`201`), 14건 정원초과(`409 C206`) |
| 락 대기시간 | `BranchTimeSlot` 행 락 획득까지 걸린 시간 | `SHOW ENGINE INNODB STATUS` / `sys.innodb_lock_waits` | **직접 측정 안 함** (INNODB STATUS 미조회). 간접 추정: B0(VU=6, 풀 이내라 풀 대기 없음)의 응답시간이 곧 "락 대기 + Stripe 외부 호출 시간"이다 — avg 1.53s, p95 2.67s |
| p95 / p99 응답지연 | 전체 요청의 95/99번째 백분위 응답 시간 | k6 `http_req_duration` | p95만 계산됨(p99는 옵션 미설정): B0 2.67s / B1 3.41s / C 5.55s |
| 데드락 발생 여부 | 락 순서 충돌로 인한 트랜잭션 강제 종료 | `SHOW ENGINE INNODB STATUS`의 LATEST DETECTED DEADLOCK | **미확인** (조회 안 함). 서버 로그(`Unhandled exception`)에 데드락 관련 예외는 없었음 |
| TPS | 초당 처리 가능한 예약 요청 수 | k6 `http_reqs` | 전체 66건/약 66초 ≈ **0.998 req/s** (k6 계산치) — 시나리오가 0/20/40/60초로 단계적으로 시작되므로 순간 최대 처리량은 아니고 전체 평균일 뿐 |
| 커넥션 풀 대기시간 | HikariCP에서 커넥션을 못 받아 대기한 시간 | HikariCP DEBUG 로그, `CannotCreateTransactionException` 발생 여부 | 정확한 대기시간(ms)은 미측정(DEBUG 로그 미확인). 대신 **풀 고갈로 인한 `CannotCreateTransactionException` 8건 확인**(B1 2건, C 6건) — `HIKARI_CONNECTION_TIMEOUT=3000ms` 초과로 판단(`docs/round5-findings.md`) |
| CPU 쓰로틀링 | cgroup CPU 제한(500m)에 걸려 강제 대기한 시간 | `/sys/fs/cgroup/cpu.stat`의 `nr_throttled` | **미확인** (조회 안 함) |

---

## 실행 방법

### 1. 사전 준비 — 시드

```bash
BASE_URL=https://api.knu80th.shop ./scripts/seed.sh
```

- 지점 1개(정원 6명, `timeSlotCapacity=6`) — A/B0/B1이 각각 같은 날짜의 다른 시간대
  (10:00/10:30/11:00)를 써서 서로 슬롯 정원을 침범하지 않음. 분산용 슬롯 20개(C용) 추가,
  통화 USD 재고는 100만으로 시드. 생성 직후 `active=false`로 비활성화해 실사용자 대상
  공개 지점 목록(`GET /branches`)에서 숨김(예약 생성은 `branchId`를 직접 지정하므로 영향 없음).
- 시나리오별로 **겹치지 않는** 유저 토큰 66명 발급(A 20 / B0 6 / B1 20 / C 20). 같은 유저를
  여러 시나리오에서 재사용하면 `CONCURRENT_PENDING_PAYMENT_LIMIT`에 걸려 결과가 오염되므로
  구간을 분리한다. 이메일에는 실행마다 고유한 `RUN_ID`(타임스탬프)를 섞어서, 라운드가
  바뀌어도 이전 라운드의 유저 상태(아직 안 풀린 `PENDING_PAYMENT` 등)와 섞이지 않게 한다.
- `k6/tokens.json`, `k6/token-counts.json`, `k6/spread-slots.json`, `k6/hot-slot.json` 생성
  (git에는 커밋 안 함, 매번 새로 생성됨).

### 2. 시나리오 구성 — 락 vs 커넥션 풀 분리

|                        | 풀 크기 이내(VU=6)      | 풀 초과(VU=20)                    |
|------------------------|--------------------------|-----------------------------------|
| **같은 슬롯**(경합 O) | B0 — 순수 락 대기        | B1 — 실제 배포 조건(락+풀 대기 합산) |
| **다른 슬롯**(경합 X) | 대조군(즉시 응답 확인용) | C — 풀 대기만(락 없음)             |

`k6/scenario.js`는 A(정합성, 0초) → B0(20초 뒤) → B1(40초 뒤) → C(60초 뒤) 순서로
`startTime`을 분리해서 한 번 실행으로 네 시나리오가 순차 진행된다. `B1 − C`가 크면 "락이
실제 병목", 작으면 "커넥션 풀이 더 큰 병목"이라는 뜻 — 실제로는 후자로 나왔다(위 요약 참고).

### 3. 실행

```bash
k6 run -e BASE_URL=https://api.knu80th.shop k6/scenario.js \
  --summary-export=results/summary.json 2>&1 | tee results/roundN-raw.log
```

- `branchId`/슬롯 날짜·시간/유저 토큰/구간 오프셋은 전부 `seed.sh`가 만든 json 파일을
  스크립트가 직접 읽으므로 별도 `-e` 플래그가 필요 없다.
- `reserve()`가 매 요청마다 `RESULT scenario=... status=... code=...` 로그를 남긴다 —
  `tee`로 파일에 받아두면 아래처럼 시나리오별 성공/실패 분포를 바로 집계할 수 있다:
  ```bash
  grep 'msg="RESULT' results/roundN-raw.log | \
    sed -E 's/.*msg="RESULT scenario=([^ ]+) vu=([0-9]+) iter=([0-9]+) tokenIndex=([0-9]+) status=([0-9]+) code=([^"]*)".*/\1 \5 \6/' | \
    sort | uniq -c
  ```
- **k6 콘솔에서 시나리오 A의 성공 건수부터 확인한다** — 정확히 6건이 아니면 뒤의 B0/B1/C
  숫자는 의미가 없다.
- **절대 중단(Ctrl+C)하지 말 것** — 중단하면 일부 시나리오만 실행된 채로 슬롯/유저 상태가
  소비되고, 안전 수칙에 있듯 재시드 없이는 재실행도 못 한다.

### 4. 실행 중/후 관측 (kubectl 기준)

```bash
# 실시간 리소스
kubectl top pod -l app=travelx-server

# CPU 쓰로틀링 여부
kubectl exec deployment/travelx-server -- cat /sys/fs/cgroup/cpu.stat

# 데드락 여부
kubectl exec deployment/mysql -- \
  mysql -uroot -p$DB_PASSWORD -e "SHOW ENGINE INNODB STATUS\G" \
  | grep -A 30 "LATEST DETECTED DEADLOCK"

# k6 종료 직후 바로 (분석은 나중에 해도 되니 일단 확보부터)
kubectl logs -l app=travelx-server -c travelx-server --tail=1000 > /tmp/roundN-server.log
# 500(Unhandled exception)의 실제 스택트레이스
grep -A 30 "Unhandled exception" /tmp/roundN-server.log
```

---

## 클린업

**VM에서 실행할 것** — 행 삭제에 `kubectl exec`로 mysql 파드 접근이 필요하다.

```bash
# 이번 라운드(k6/hot-slot.json)의 branchId만 정리
BASE_URL=https://api.knu80th.shop ./scripts/cleanup.sh

# 여러 라운드를 한 번에 정리하려면 BRANCH_IDS에 공백으로 나열
BRANCH_IDS="40 41 21 22 23 24" BASE_URL=https://api.knu80th.shop ./scripts/cleanup.sh
```

- 테스트 지점(들)의 USD 재고를 API로 0으로 되돌린다(active=false는 seed.sh가 이미 처리).
- 지점/예약/슬롯/재고 행과 `loadtest-%@travelx.dev` 유저를 **`kubectl exec`로 실제로
  삭제**한다 — 되돌릴 수 없는 작업이라 실행 전 SQL과 대상 `branch_id`를 그대로 보여주고
  `y` 확인을 받는다(비대화형으로 쓰려면 `CONFIRM=yes` 지정). `DB_USERNAME`/`DB_PASSWORD`
  환경변수가 VM 셸에 미리 있어야 한다.
- 테스트 예약이 아직 `PENDING_PAYMENT`인 채로 삭제돼도 문제없다 — 서버의 기존
  `ReservationExpirySweeper`는 그냥 못 찾는 행을 건너뛸 뿐이다.

---

## 성공/실패 판정 기준

가장 최근 정상 완료된 실행(5차, 2026-07-30) 기준.

| 항목 | 통과 기준 | 5차 결과 |
|---|---|---|
| 정합성 | 정확히 6건 성공, 나머지는 4xx (500 없음) | ✅ **통과** — A: 6건 성공(`201`) + 14건 정원초과(`409 C206`), 500 없음 |
| 데드락 | 0건 | ⚠️ **미확인** — `SHOW ENGINE INNODB STATUS` 조회를 안 해서 판정 불가. 다음 라운드 TODO |
| B0 p95 | 락 대기만 있는 상태에서 목표치(예: 200ms대) 근접 | ❌ **2.67s로 목표치 크게 초과**. 다만 이건 순수 락 대기가 아니라, `createReservation()`이 락을 잡은 채로 같은 트랜잭션 안에서 Stripe PaymentIntent 생성(외부 API 호출)까지 순차 실행하는 구조 때문일 가능성이 높다 — 서버 레포 쪽 코드 확인 필요(아직 안 함) |
| B1 − C | 값이 크면 "락이 실제 병목", 작으면 "커넥션 풀이 더 큰 병목" | avg 기준 2.82s − 3.41s = **−0.59s**, p95 기준 3.41s − 5.55s = **−2.14s** — 둘 다 음수, 즉 락으로 인한 추가 지연은 관측되지 않았다. C가 오히려 더 높은 건 C의 500(6건, 각각 `HIKARI_CONNECTION_TIMEOUT` 3초를 다 기다리다 실패)이 평균/p95를 끌어올렸기 때문. **결론: 병목은 락이 아니라 커넥션 풀** |

---

## 라운드별 결과

각 라운드의 세부 실행 로그·원인 분석·다음 단계 TODO는 `docs/round*-findings.md`에 있다.

- **1차** ([`docs/round1-findings.md`](docs/round1-findings.md)): 정합성 기준(전체 66건 중
  성공 3건뿐, 500 34건) 미충족 — 원인 미확인 상태로 로그 확인 후 재테스트 예정.
- **2차** ([`docs/round2-findings.md`](docs/round2-findings.md)): 1차의 500(34건) 원인 확인 —
  `branch_time_slots`의 UNIQUE 제약 누락(스키마 드리프트)으로 `ensureExists()`의 동시성 방어가
  깨져 있었던 것(`server` 레포 `ca4867f`로 수정, 재현 안 됨). 대신 기대 성공 건수(38건)보다 훨씬
  적은 18건만 성공 — 관리자 API로는 `PENDING_PAYMENT` 상태를 조회할 수 없어 사후 재구성 불가
  확인, `k6/scenario.js`에 시나리오별 결과 로그(`RESULT scenario=... status=... code=...`) 추가.
- **3차** ([`docs/round3-findings.md`](docs/round3-findings.md)): 정합성 계속 통과(A 정확히
  6/20). 결과 로그로 새 문제 2개 발견 — (1) `seed.sh`가 라운드마다 같은 이메일을 써서 이전
  라운드의 `PENDING_PAYMENT`가 남은 유저가 재사용되며 C304 오염 → `RUN_ID`로 라운드별 유저
  분리해 수정 완료. (2) B1/C에서 401(A001) 다수 발생 — 재배포 충돌은 타이밍상 기각, 로그
  aggregator가 없어 그 순간 로그가 유실돼 원인 미해결로 다음 라운드로 이월.
- **4차** ([`docs/round4-findings.md`](docs/round4-findings.md)): 401(A001)의 진짜 원인
  확정 — `k6`의 `__VU`는 시나리오마다 1부터 리셋되는 게 아니라 테스트 실행 전체에서 전역으로
  유일한 번호였다. `(__VU - 1)`로 토큰 인덱스를 계산하던 게 이 가정 위에 있어서 시나리오별
  토큰 배열 범위를 벗어났고, 범위 밖 접근이 `undefined` 토큰 → `Bearer undefined` → 401로
  이어졌던 것(서버 버그 아님). `exec.scenario.iterationInInstance`로 교체해 수정, 범위 이탈 시
  조용히 새지 않도록 `BUG` 로그도 추가. 이 과정에서 "중단된 실행 후 재시드 없이 재실행하면
  안 된다"는 것도 확인(슬롯/유저 상태가 이미 소비돼 있어 재현이 아니라 오염된 결과가 나옴).
- **5차** ([`docs/round5-findings.md`](docs/round5-findings.md)): `__VU` 픽스 후 처음
  끝까지 정상 완료(정합성 계속 통과, 32/38 성공). 실행 직후 곧바로 확보한 서버 로그로 잔여
  500의 정체를 확정 — `CannotCreateTransactionException`(HikariCP 커넥션 풀 고갈,
  `HIKARI_MAX_POOL_SIZE=8` 초과 시 3초 타임아웃). **핵심 질문("락 vs 풀")에 대한 답**:
  락 경합이 없는 대조군(C)이 락 경합이 있는 A보다 오히려 이 에러를 더 많이 겪었다 — 락이
  요청을 순차적으로 줄 세워 동시 커넥션 수요를 분산시키는 반면, 무경합 시나리오는 다 같이
  DB로 몰려 풀을 더 확실하게 고갈시킨다. 즉 **병목은 락이 아니라 커넥션 풀**.
