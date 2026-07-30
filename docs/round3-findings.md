### 배경

[2차 실행](round2-findings.md)에서 기대 성공 건수(38건)보다 훨씬 적은 18건만 성공한 이유를
서버 상태로는 재구성할 수 없어서, `k6/scenario.js`에 시나리오별 결과 로그(`RESULT scenario=...
status=... code=...`)를 추가했다. 이번 라운드는 그 로그를 켠 채로 재실행한 기록이다.

실행 전에 로컬 `server` 레포 클론을 `origin/develop`으로 갱신했다 — `git fetch`로
16개 커밋이 뒤처져 있던 걸 발견해서 `git pull --ff-only`로 반영(`7313fcd` → `ca4867f`).
여기엔 1차 500의 원인이었던 V16 마이그레이션과 예외 처리 리팩터(`338f517`)가 포함된다.

---

### 실행

`branchId=22`로 재시드 후 결과 로그를 파일로 받으며 실행:

```bash
BASE_URL=https://api.knu80th.shop ./scripts/seed.sh
k6 run -e BASE_URL=https://api.knu80th.shop k6/scenario.js \
  --summary-export=results/summary.json 2>&1 | tee results/round3-raw.log
```

---

### 결과 — 정합성 통과, 그런데 새로운 문제 두 가지 발견

로그 포맷이 k6의 구조화 로거(`time="..." level=info msg="RESULT ..." source=console`)로
감싸져 있어서 처음 시도한 `awk` 파싱이 안 맞았다. 아래로 교정:

```bash
grep 'msg="RESULT' results/round3-raw.log | \
  sed -E 's/.*msg="RESULT scenario=([^ ]+) vu=([^ ]+) status=([^ ]+) code=([^"]*)".*/\1 \3 \4/' | \
  sort | uniq -c
```

```
  20 c_pool_exceed_spread 401 A001
  12 a_correctness 409 C206
   6 b1_pool_exceed_contended 409 C206
   6 b1_pool_exceed_contended 401 A001
   6 b1_pool_exceed_contended 201
   6 b0_pool_safe_contended 201
   6 a_correctness 201
   2 b1_pool_exceed_contended 403 C304
   2 a_correctness 500 C009
```

**정합성(핵심 목표 1번) 통과**: A가 정확히 6/20 성공. B0도 6/6 전부 성공(VU=6=정원과 정확히
일치하니 당연). 6(A)+6(B0)+6(B1)=18은 정원 로직 자체는 여전히 올바르게 동작한다는 뜻이다.

**새로 발견된 문제 1 — B1의 403 C304 (`CONCURRENT_PENDING_PAYMENT_LIMIT`), 원인 확인·수정 완료**:
`seed.sh`가 매 라운드 **같은 이메일**(`loadtest-user-N@travelx.dev`)로 토큰을 발급해왔다.
`DevAuthController.issueToken()`은 이메일이 이미 있으면 기존 유저를 그대로 재사용하는데, 그
유저가 이전 라운드(1차/2차)에서 만든 예약이 아직 `PENDING_PAYMENT`로 남아있으면 이번 라운드
첫 예약 시도에서 바로 C304에 걸린다 — **테스트 설계상 시나리오 간 유저 분리는 해뒀지만, 라운드
간 분리는 안 해뒀던 것**. `RUN_ID`(유닉스 타임스탬프)를 이메일에 섞어 라운드마다 완전히 새
유저를 만들도록 `scripts/seed.sh`를 수정했다 (커밋에 포함).

**새로 발견된 문제 2 — B1(6건)/C(20건 전부) 401 UNAUTHORIZED(A001), 원인 미해결**:
- 저장된 토큰을 그대로 재생해보니(사후) 멀쩡히 인증됨 → 토큰 자체 결함 아님
- 그 시각(UTC 06:52경) 파드 재시작 이벤트가 있었으나, 재시작 시각(06:41:44Z)이 테스트
  시작보다 10분 이상 앞서 있어 **타이밍이 안 맞음 — 재배포 충돌 가설은 기각**
- 서버 로그로 그 순간을 직접 보려 했으나, `--since=25m`으로도 테스트 시각대의 로그가 전혀
  안 잡힘 — 파드는 재시작 안 했는데도(`startTime` 동일) 로그가 없는 걸 보면, 로그 aggregator가
  없는 MVP 구성이라 컨테이너 로그가 순수 로테이션/유실된 것으로 보인다. **사후 재구성 불가.**

**남은 500(2건, A에서)**: V16 픽스 이후에도 완전히 사라지지 않았다. 1차(34건)보다는 훨씬
적지만, 여전히 뭔가 남아있다는 뜻 — 다음 라운드에서 재현되면 바로 로그를 확인해야 한다.

---

### 교훈 — 실배포 대상 테스트에서 "그 순간 로그"는 사라지기 전에 잡아야 한다

이번 라운드에서 가장 크게 배운 것: 로그 aggregator가 없는 이 환경에서는 **문제가 생긴 바로
그 순간의 로그를 몇 분 안에 확보하지 못하면 영영 사후 분석이 불가능**하다. 다음 라운드부턴
k6 실행이 끝나는 즉시(같은 세션에서) 로그부터 받아두는 순서로 진행할 것.

---

### 남은 것 (다음 세션)

- [x] `seed.sh` 라운드 간 유저 재사용 문제 수정 (`RUN_ID` 추가)
- [ ] 재실행 → k6가 끝나자마자 바로 (`kubectl logs ... > 파일` 먼저, 분석은 나중에) 로그부터
      확보 — 401(A001) 재현 시 원인 규명, 잔여 500(C009) 재현 여부 확인
- [ ] 정리 필요: 테스트 지점 `branchId=40`(1차, 중단됨), `41`(1차), `21`(2차), `22`(3차) 총 4개
- [ ] `DEV_AUTH_ENABLED=false`로 원복 (1차부터 지금까지 계속 `true`로 켜진 채 방치됨)
