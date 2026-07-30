### 배경

[4차](round4-findings.md)에서 `k6`의 `__VU` 전역 넘버링 버그를 고쳤다. 이번 라운드는 그 수정
후 처음으로 제대로(끝까지 중단 없이, 재시드 후) 돌린 실행이고, 여기서 **원래 discussion#13이
검증하려던 질문("락이 병목인가, 커넥션 풀이 병목인가")에 대한 실제 답**을 얻었다.

---

### 실행 및 결과 — `__VU` 픽스 확인, 정합성 통과

```bash
BASE_URL=https://api.knu80th.shop ./scripts/seed.sh
k6 run -e BASE_URL=https://api.knu80th.shop k6/scenario.js \
  --summary-export=results/summary.json 2>&1 | tee results/round5-raw.log
```

`BUG scenario=... out of range` 로그 0건 — 4차의 `__VU` 픽스가 정상 동작함을 확인.

![thresholds](images/round5-thresholds.png)
![total results](images/round5-total-results.png)

```
A:  6×201(성공) + 14×409 C206(정원초과)                  = 20  ✅ 정확히 6건 성공(정합성 통과)
B0: 6×201(성공)                                          = 6   ✅ 6/6 전부 성공
B1: 6×201(성공) + 12×409 C206 + 2×500 C009               = 20  ✅ 정원 로직 정상, 500 2건
C:  14×201(성공) + 6×500 C009                            = 20  ⚠️ 경합 없는 대조군인데 500 6건
```

총 성공 32/38(이론값) — `__VU` 버그로 가려져 있던 예전 라운드들보다 훨씬 이론값에 가까워졌다.

---

### 잔여 500(C009)의 정체 — HikariCP 커넥션 풀 고갈

이번엔 처음으로 실행 직후 곧바로 서버 로그를 확보했다. 새로 pull한
`GlobalExceptionHandler`(커밋 `338f517`)가 제네릭 예외를 `"Unhandled exception"`으로
ERROR 로깅하도록 바뀐 덕분에 바로 스택트레이스를 찾을 수 있었다:

```
org.springframework.transaction.CannotCreateTransactionException: Could not open JPA EntityManager for transaction
    at org.springframework.orm.jpa.JpaTransactionManager.doBegin(...)
    ...
    at com.fptis.intern.server.application.reservation.ReservationService$$SpringCGLIB$$0.createReservation(<generated>)
    at com.fptis.intern.server.presentation.reservation.ReservationController.createReservation(...)
```

`HIKARI_CONNECTION_TIMEOUT=3000ms` 안에 풀(`HIKARI_MAX_POOL_SIZE=8`)에서 커넥션을 못 받으면
나는 예외 그대로다. **B1(2건)/C(6건) 둘 다 VU=20으로 풀 크기(8)를 초과하는 시나리오**에서만
발생했고, 풀 이내인 B0(VU=6)에서는 0건이었다 — 커넥션 풀이 원인이라는 가설과 정확히 들어맞는다.

**흥미로운 비대칭**: 락 경합이 있는 A(정원 6, VU=20)는 이 에러가 0건인데, 락 경합이 전혀
없는 C(분산 슬롯, VU=20)는 오히려 6건(30%)으로 더 많다. 슬롯 락이 요청들을 순차적으로 줄
세우는 효과가 있어서 동시 DB 커넥션 수요를 오히려 분산시키는 반면, C는 경합이 없으니 20개
요청이 그대로 동시에 DB로 몰려 풀이 더 확실하게 고갈되는 것으로 보인다 — **락이 병목이
아니라 오히려 완충 역할을 하고, 진짜 병목은 커넥션 풀**이라는 걸 시사한다.

---

### 핵심 질문(discussion#13)에 대한 잠정 답

> 슬롯 정원 경합 상황에서, 락 자체가 병목인가 아니면 커넥션 풀이 먼저 병목이 되는가?

**이번 라운드 데이터로는 커넥션 풀 쪽이다.** 락 자체는(A/B0/B1 모두) 정합성을 정확히
지켰고, 락으로 인한 추가 500은 관측되지 않았다. 반면 VU가 풀 크기(8)를 초과하는 모든
시나리오(B1, C)에서 `CannotCreateTransactionException`이 발생했고, 락 경합이 없는 C가
오히려 더 많이 겪었다. `HIKARI_MAX_POOL_SIZE=8`이 실제 동시 부하 앞에서 raw 500을 내는
지점이라는 것이 이번 라운드의 결론이다.

**서버 레포 쪽에 제안할 만한 개선 방향** (이 레포의 스코프 밖이라 실행은 안 함):
- `CannotCreateTransactionException`/`SQLTransientConnectionException`을 500 대신
  503(Service Unavailable) 등 명확한 재시도 유도 응답으로 처리
- `HIKARI_MAX_POOL_SIZE`를 실제 기대 동시 부하에 맞게 재산정할지 검토

---

### 지표별 실측값 정리

| 지표 | 5차 실측값 |
|---|---|
| 정합성 | **통과** — A: 20건 중 정확히 6건 성공(`201`), 14건 정원초과(`409 C206`), 500 없음 |
| 락 대기시간 | 직접 측정 안 함(`SHOW ENGINE INNODB STATUS` 미조회). 간접 추정: B0(VU=6, 풀 이내라 풀 대기 없음)의 응답시간이 곧 "락 대기 + Stripe 외부 호출 시간" — avg 1.53s, p95 2.67s |
| p95 응답지연 | B0 2.67s / B1 3.41s / C 5.55s (p99는 k6 옵션 미설정이라 미계산) |
| 데드락 | **미확인** — 조회 안 함. 서버 로그(`Unhandled exception`)에 데드락 관련 예외는 없었음 |
| TPS | 전체 66건/약 66초 ≈ 0.998 req/s (k6 계산치) — 시나리오가 0/20/40/60초로 단계적으로 시작되므로 순간 최대 처리량이 아니라 전체 평균일 뿐 |
| 커넥션 풀 대기시간 | 정확한 값(ms)은 미측정(HikariCP DEBUG 로그 미확인). 대신 풀 고갈로 인한 `CannotCreateTransactionException` 8건 확인(B1 2건, C 6건) |
| CPU 쓰로틀링 | **미확인** — `cpu.stat` 조회 안 함 |
| B0 p95 판정 | ❌ 목표치(200ms대) 크게 초과. 순수 락 대기가 아니라 락을 잡은 채로 같은 트랜잭션에서 Stripe PaymentIntent 생성까지 순차 실행하는 구조 때문일 가능성이 높음 — 서버 레포 코드 확인 필요(아직 안 함) |
| B1 − C 판정 | avg 기준 2.82s − 3.41s = **−0.59s**, p95 기준 3.41s − 5.55s = **−2.14s** — 둘 다 음수. 락으로 인한 추가 지연은 관측 안 됨. C가 오히려 높은 건 C의 500(6건, 각각 3초 타임아웃까지 대기하다 실패)이 평균/p95를 끌어올렸기 때문 |

---

### 미측정 항목 — 다음 라운드 측정 계획

데드락/CPU 쓰로틀링/정확한 커넥션 대기시간은 이번 라운드에서 안 봤다. 다음 라운드에서
아래처럼 측정한다:

- **데드락**: 서버 변경 필요 없음. k6 실행 직후 바로 조회.
  ```bash
  kubectl exec deployment/mysql -- mysql -uroot -p$DB_PASSWORD \
    -e "SHOW ENGINE INNODB STATUS\G" | grep -A 30 "LATEST DETECTED DEADLOCK"
  ```
- **CPU 쓰로틀링**: `cpu.stat`의 `nr_throttled`/`throttled_time`은 컨테이너 시작 이후
  누적값이라, **테스트 전/후 두 번 찍어서 차이(delta)를 봐야** 의미가 있다(한 번만 찍으면
  이전 테스트나 실트래픽의 누적치와 섞여 무의미함).
  ```bash
  kubectl exec deployment/travelx-server -- cat /sys/fs/cgroup/cpu.stat > /tmp/cpu-before.txt
  # ... k6 실행 ...
  kubectl exec deployment/travelx-server -- cat /sys/fs/cgroup/cpu.stat > /tmp/cpu-after.txt
  diff /tmp/cpu-before.txt /tmp/cpu-after.txt
  ```
- **HikariCP 정확한 대기시간**: `LOGGING_LEVEL_COM_ZAXXER_HIKARI=DEBUG`를 `DEV_AUTH_ENABLED=true`와
  **같은 `kubectl set env` 호출에 같이 넣어서** 재기동을 한 번만 겪도록 한다:
  ```bash
  kubectl set env deployment/travelx-server DEV_AUTH_ENABLED=true LOGGING_LEVEL_COM_ZAXXER_HIKARI=DEBUG
  ```

---

### JVM 워밍업(JIT) 고려사항

이 테스트는 전체 66건뿐이라 HotSpot의 C2 컴파일 임계치(보통 수천~1만 회 호출)에 한참 못
미친다 — `createReservation()` 경로가 인터프리터/C1 단계에 머물러 있었을 가능성이 높고,
그러면 측정된 절대 지연시간(B0 p95 2.67s 등)이 실제 정상 운영 중인(충분히 워밍업된) 서버보다
더 느리게 나왔을 수 있다.

다만:
- A/B0/B1/C가 전부 **같은 워밍업 상태에서 순차 실행**되므로, `B1 − C` 같은 **상대 비교(락 vs
  풀 결론)는 이 영향을 크게 받지 않는다** — 다 같이 느려진 거면 상쇄된다.
- 지금 보이는 수 초 단위 지연은 Stripe 외부 API 호출/락 대기/DB 커넥션 타임아웃(3초) 같은
  **I/O 대기가 지배적**이라, CPU 바운드인 JIT 워밍업 효과는 상대적으로 작을 가능성이 높다.

절대 수치를 더 신뢰성 있게 보고 싶다면, 본 측정 전에 별도의 버려질 웜업 지점에 30~50건
정도 예약 요청을 먼저 흘려보내는 웜업 단계를 추가하는 걸 고려할 수 있다(실서버에 진짜
예약이 더 생기는 비용은 있음) — 다음 라운드에서 필요 여부 결정.

---

### 남은 것

- [ ] 정리 필요: 테스트 지점 `branchId=40,41`(1차), `21`(2차), `22`(3차), `23`(중단된 4차 시도),
      `24`(5차) 총 6개 — `scripts/cleanup.sh`(이제 `kubectl exec`로 실제 삭제까지 함)로 정리
- [ ] `DEV_AUTH_ENABLED=false`로 원복 (계속 `true`로 켜진 채 방치됨 — 테스트 마무리되면 필수)
- [ ] 다음 라운드: 데드락(`SHOW ENGINE INNODB STATUS`)/CPU 쓰로틀링(`cpu.stat` 전후 diff)/
      HikariCP 정확한 대기시간(`LOGGING_LEVEL_COM_ZAXXER_HIKARI=DEBUG`) 측정
- [ ] 다음 라운드: JVM 워밍업 단계를 넣을지 결정 (넣으면 절대 지연시간이 더 현실적으로 나옴,
      단 실서버에 웜업용 예약이 추가로 생김)
- [ ] (선택) 위 서버 개선 제안을 실제로 반영할지는 서버 팀과 별도 논의
