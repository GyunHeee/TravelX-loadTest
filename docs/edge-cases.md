### 배경

5차까지 discussion#13의 핵심 질문(락 vs 커넥션 풀)에 답이 나왔고, 지금 실배포 서버
스펙(단일 replica, CPU 500m)으로는 더 파고들어도 성능 튜닝 관점에서 얻을 게 많지 않다.
대신 이 부하테스트 인프라(66명 유저, 실서버 대상, 안전 수칙 등)를 재활용해서 **discussion#13
범위 밖의, 고동시성에서만 드러나는 다른 동시성 버그**를 찾는 쪽으로 방향을 틀었다 — 정확히
1차에서 `branch_time_slots` 스키마 드리프트를 찾아낸 것과 같은 방식이다.

---

### 코드 조사 — 후보 5개

`server` 레포를 다시 훑어서 "동시 요청이 몰려야만 드러나는" 취약 지점 후보를 찾았다.

1. **`BranchCurrencyRateRepository`의 upsert/락**: 안전해 보임. `BranchTimeSlot`과 달리
   upsert 패턴을 안 쓰고, `findForUpdate()`가 `PESSIMISTIC_WRITE`로 보호되며, UNIQUE
   제약(`uk_branch_currency_rates_branch_currency`, V6)도 실제로 존재한다 — 스키마
   드리프트 없음.
2. **예약 취소/환불(redeem)/거절 동시 요청**: **취약함**. `cancelReservation()`,
   `rejectByBranch()`, `redeem()` 전부 `Reservation` 행에 락을 안 걸고 `findById()`로만
   읽는다. `Reservation.cancel()`도 인메모리 `status` 필드만 검사한다 — 아래 상세.
3. **취소 ↔ 만료 스윕 레이스**: [`docs/discussion-reservation-cancel-expire-race.md`](discussion-reservation-cancel-expire-race.md)
   (server 레포)로 이미 논의됐지만 **실제로 고쳐지지 않았다** — `@Version` 컬럼 미도입.
   2번과 같은 근본 원인(예약 행 락 없음)의 다른 발현이다.
4. **User 행 락(노쇼 제한)**: 안전해 보임. `assertNoShowLimitNotExceeded()`가 유저 락을
   먼저 잡고 재고 → 슬롯 순으로 일관되게 락을 잡아 데드락 위험이 없다.
5. **관리자 재고/우대율 변경 vs 고객 예약 생성**: **취약함**. `BranchAdminService
   .updateInventory()`/`updateRates()`가 `findRate()`(락 없음)로 읽고 절대값을 그대로
   저장한다(`rate.update(null, item.stock())`). 고객 쪽은 `findForUpdate()`로 락을 걸고
   차감하므로, "관리자가 재고를 읽은 직후 고객이 차감·커밋 → 관리자가 그 예전 값을 그대로
   저장"하면 고객의 차감이 사라지는 lost update가 가능하다.

**우선순위**: 2/3(예약 취소 계열)과 5(관리자 lost update) 둘 다 검증 가치가 있다고 판단.
취소↔만료 레이스(2/3)부터 먼저 스크립트로 만든다.

---

### 예약 취소 동시 요청 레이스 — 검증 스크립트

`k6/edge-case-cancel-race.js` 작성 완료 (아직 실행 안 함).

**메커니즘**: `cancelReservation()`은 `findById()`로 예약을 읽고, `Reservation.cancel()`은
인메모리 `status` 필드만 검사해서 이미 `CANCELLED`/`COMPLETED`/`EXPIRED`일 때만 예외를
던진다. MySQL REPEATABLE READ + JPA 1차 캐시 특성상, 두 트랜잭션이 서로 커밋하기 전에 각자
`findById`로 같은 예약을 읽으면 둘 다 "아직 취소 안 됨"으로 판단하고, 이후 각자
`restoreStock()`/`restoreTimeSlot()`(재고/슬롯에 `PESSIMISTIC_WRITE`)을 순서대로(먼저 커밋한
쪽이 락을 풀면 다음 트랜잭션이 이어받아) 실행한다 — **재검증 없이** 무조건 복원하므로 이중
복원이 이론상 가능하다.

**검증 방법** (재고 값으로 이중 복원 여부를 직접 증명):
1. 전용 지점 + USD 재고를 알려진 값(`baselineStock=10000`)으로 시드
2. 예약 1건 생성(재고 100 차감 → 9900)
3. 그 예약 ID에 `DELETE /reservations/{id}`를 동시에 N번(기본 10) 쏨
4. 최종 재고 확인:
   - `finalStock === 10000` (baseline) → 정확히 1번만 복원됨, 버그 재현 안 됨
   - `finalStock > 10000` → 이중(다중) 복원됨, 버그 확인. 초과분 ÷ 100 = 복원된 횟수

```bash
k6 run -e BASE_URL=https://api.knu80th.shop k6/edge-case-cancel-race.js
```

`N_CONCURRENT_CANCELS` 환경변수로 동시 취소 요청 수 조절 가능(기본 10).

---

### 실행 결과 — 버그 확정 (2026-07-30, `branchId=25`, `reservationId=102`)

```
CANCEL_RESULT: 204(성공) 5건, 409 C207(이미 취소됨) 5건 — 10건 중 5건이나 "성공" 처리됨
VERIFY: baselineStock=10000 expectedAfterOneCancel=10000 finalStock=10400
VERIFY_RESULT: BUG_CONFIRMED — finalStock(10400) > baseline(10000), 약 4회 이중 복원됨
```

10개의 동시 `DELETE /reservations/{id}` 요청 중 **5건이 각각 `204 No Content`(정상 취소
처리)를 받았다** — 하나의 예약을 5번 "성공적으로" 취소한 셈이다. 재고는 예약 생성으로
9900까지 내려간 뒤 **10400으로 끝났다**: 정상적인 복원 1회(9900→10000) 위에 **4회의
초과 복원**(각 +100)이 더해진 값과 정확히 일치한다 — 즉 실제로는 5번의 `restoreStock()`
호출이 전부 실행됐다는 뜻이다(성공 응답 5건과 정확히 일치).

**의미**: 이건 discussion#13이 막으려던 "오버부킹"과 **거울처럼 반대되는 방향의 정합성
버그**다 — 정원 초과 예약을 막는 락은 잘 작동하지만(README 목표 1번, 계속 통과), 취소 경로엔
같은 보호가 전혀 없어서 **재고/슬롯이 실제보다 많이 남아있는 것처럼 부풀려질 수 있다.** 이러면
나중에 진짜로 재고가 없는데도 "있다"고 잘못 판단해 예약을 더 받아버리는 2차 문제로 이어질 수
있다. 이번 테스트는 `BranchCurrencyRate`(재고) 복원만 직접 측정했지만, `BranchTimeSlot`
(슬롯 `remaining`)의 `restoreTimeSlot()`도 정확히 같은 코드 패턴(락 없는 상태 체크 후
무조건 복원)이라 동일한 버그가 있을 가능성이 매우 높다 — 다음에 확인.

---

### 남은 것

- [x] `k6/edge-case-cancel-race.js` 실제 실행 → **버그 재현 확인** (위 결과 참고)
- [ ] `BranchTimeSlot.remaining`도 같이 이중 복원되는지 확인(DB 직접 조회 필요 — API로는
      정확한 잔여 슬롯 수를 노출하지 않음)
- [ ] 관리자 재고 변경 vs 고객 예약(lost update) 검증 스크립트도 작성
      (`k6/edge-case-admin-inventory-race.js` 예정) — 재고를 알려진 값으로 시드 → 서로 다른
      슬롯에 예약 N건(재고만 차감, 슬롯 경합 없음) + 관리자가 같은 "오래된" 값으로 재고를
      계속 덮어쓰는 요청을 동시에 쏨 → `기대 재고(baseline − amount×성공건수)`와 실제 재고 비교
- [ ] 서버 레포 쪽에 버그로 보고할지 여부 결정 — 이 레포 스코프 밖이라 수정은 안 함. 제안:
      `cancelReservation()`/`rejectByBranch()`/`redeem()`에서도 `Reservation` 조회를
      `findById` 대신 `PESSIMISTIC_WRITE` 락으로 바꾸거나, `@Version`(낙관적 락) 도입
      (server 레포 `docs/discussion-reservation-cancel-expire-race.md`의 "방안 2"와 동일한
      해법이 여기(동시 취소)에도 그대로 적용됨)
- [ ] 정리 필요: 이번 테스트로 생성된 `branchId=25` 정리 (`cleanup.sh`에 추가)
