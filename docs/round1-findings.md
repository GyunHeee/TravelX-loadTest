### 배경

[vietnam-internship/server Discussion #13](https://github.com/vietnam-internship/server/discussions/13)에서
슬롯 예약 동시성 설계를 비관적 락(방안 A)으로 제안했고, 이 저장소에서 k6로 검증해왔다.
이번 라운드부터는 로컬 Docker 복제 대신
[vietnam-internship/infra](https://github.com/vietnam-internship/infra)로 배포된
**실제 단일 인스턴스**(k3s 단일 VM, `https://api.knu80th.shop`)를 직접 대상으로 실행했다 —
별도 staging 환경이 없어 사실상 유일한 실서버다.

이 문서는 1차 실행까지의 변경 사항과 결과, 그리고 원인 미확인 상태로 남은 문제를 기록한다.
(재테스트 예정 — 결과 나오면 이어서 업데이트할 것)

---

### 이번 라운드에서 바꾼 것 (커밋 `6c26c73`, `5d9fbf6`)

1. **유저 풀 오염 버그 수정**: 기존엔 A(VU=20)/B0(VU=6)/B1(VU=20) 시나리오가 20명의 유저 토큰을
   `(__VU-1) % 20`으로 재사용했다. A에서 성공한 유저는 결제 웹훅을 안 태워 `PENDING_PAYMENT`
   예약을 쥔 채 남는데, 이 유저가 B0/B1에서 다시 뽑히면 락/풀 대기가 아니라
   `CONCURRENT_PENDING_PAYMENT_LIMIT`(C304)로 막혀 순수 락 대기 측정이 오염될 수 있었다.
   → 시나리오별로 겹치지 않는 유저 구간(총 66명: A 20 / B0 6 / B1 20 / C 20)을 쓰도록 수정
   (`scripts/seed.sh`, `k6/scenario.js`).
2. **실사용자 노출 차단**: 테스트 지점을 생성 직후 `active=false`로 비활성화해 공개
   `GET /branches`에서 숨김 (예약 생성은 `branchId` 직접 지정이라 영향 없음).
3. **안전 수칙 문서화**: 실배포 특성(단일 VM·단일 replica·HPA 없음·자체 MySQL 파드·
   `Recreate` 전략으로 인한 토글마다의 실다운타임) 확인 후 `DEV_AUTH_ENABLED` on/off
   체크리스트, `kubectl` 기반 관측 명령으로 README 전면 개정.
4. **클린업 스크립트 추가**(`scripts/cleanup.sh`): 삭제 API가 없어 재고 정리만 자동화하고,
   행 삭제 SQL은 검토 후 수동 실행하도록 출력만 함.
5. **버그 픽스**: `seed.sh`에서 `$VAR` 뒤에 공백 없이 한글이 바로 붙는 패턴(`$C_COUNT개` 등)이
   맥 로케일에서 변수명에 한글 바이트까지 삼켜 `set -u`로 죽는 문제 발견 → `${VAR}`로 브레이싱해
   수정 (커밋 `5d9fbf6`).

---

### 1차 실행 절차

1. VM에서 `kubectl set env deployment/travelx-server DEV_AUTH_ENABLED=true` → rollout 확인 →
   `/dev/auth/token` 실제 토큰 발급 확인(`200`, `loadtest-verify@travelx.dev` 생성 확인).
2. `BASE_URL=https://api.knu80th.shop ./scripts/seed.sh` 실행
   - 1차 시도: 로케일 버그로 `branchId=40` 생성 후 6단계에서 중단 (재고/우대율/비활성화까지는
     완료된 상태로 남음 — 정리 필요)
   - 버그 수정 후 재시도: `branchId=41`로 정상 완료, 유저 66명 토큰 발급 완료
3. `k6 run -e BASE_URL=https://api.knu80th.shop k6/scenario.js --summary-export=results/summary.json` 실행

---

### 1차 실행 결과 — 정합성 기준 미충족, 원인 미확인

```
checks_total: 132, checks_succeeded: 74.24%(98), checks_failed: 25.75%(34)
  - "not a 500": 32/66 통과, 34/66 실패 (즉 66건 중 34건이 그대로 HTTP 500)
  - "not a connection timeout": 66/66 통과 (네트워크 레벨 타임아웃은 없음)
http_req_failed (2xx/3xx가 아닌 응답 비율): 95.45% (63/66)

http_req_duration:
  - b0_pool_safe_contended (VU=6, 풀 이내):  avg 804ms  p95 825ms  → 임계치(p95<300ms) 실패
  - b1_pool_exceed_contended (VU=20, 풀 초과): avg 494ms  p95 881ms  → 임계치(p95<3500ms) 통과
  - c_pool_exceed_spread (VU=20, 분산 슬롯):  avg 69ms   p95 125ms  → 임계치(p95<3500ms) 통과
```

**계산상 도출되는 사실**: `http_req_failed` 63건 = 500(34건) + 정상 4xx 거절(29건)이므로,
**전체 66건(A+B0+B1+C) 중 실제 성공(2xx)은 3건뿐**이다. 시나리오 A 하나만으로도 "정원 6인
슬롯에 20명 동시 요청 → 정확히 6건 성공"이 핵심 정합성 기준인데, A/B0/B1/C를 다 합쳐도 성공이
3건이라는 것은 **A 자체가 6건을 채우지 못했을 가능성이 매우 높다** — 이번 라운드의 핵심
질문(락 vs 커넥션 풀 병목)을 판단하기 이전에, 정합성 전제부터 깨진 상태다.

또한 정상적인 정원초과/중복결제 거절은 서버의 `GlobalExceptionHandler.handleBusinessException`을
거쳐 깔끔한 4xx로 나가야 하는데, 500이 34건이나 나온 것도 비정상이다 — 처리되지 않은
예외(제네릭 `Exception` 캐치, 코드 `C009`)가 상당수 발생하고 있다는 뜻이다.

**b0(풀 이내, VU=6)의 p95 825ms도 그 자체로 눈여겨볼 지점**이다: 서버의 `createReservation()`은
`@Transactional` 메서드 하나로 묶여 있고, `BranchTimeSlot` 행 락(`PESSIMISTIC_WRITE`)을 획득한
뒤에도 트랜잭션이 끝나지 않은 채로 Stripe PaymentIntent 생성(외부 API 호출)이 이어지는 구조로
보인다. 즉 슬롯 락이 **Stripe 왕복 시간까지 포함해서** 잡혀 있을 가능성이 있고, 이게 사실이면
6-way 직렬화 시 각 요청이 앞사람의 "DB 락 + 외부 API 호출" 전체를 기다리게 되어 순수 DB 락
대기보다 훨씬 느려진다. 이번 500 원인과 별개로 서버 레포 쪽에서 확인이 필요한 지점.

**원인 미확인**: 서버 로그를 확인하려 했으나 이번 세션에서는 로그를 못 띄웠다
(`kubectl logs -l app=travelx-server -c travelx-server --tail=500`). 34건의 500이 정확히
어느 시나리오에 몰려있는지, 실제 예외가 무엇인지(Stripe 키 문제/DB 커넥션 타임아웃/다른
버그)는 다음 세션에서 로그 확보 후 확인 예정.

---

### 남은 것 (다음 세션)

- [ ] 서버 로그에서 500의 실제 스택트레이스 확인 (`kubectl logs -l app=travelx-server -c travelx-server --tail=500 | grep -B2 -A40 ERROR`)
- [ ] 시나리오 A의 실제 성공 건수 확인 (6건 미달 원인 규명)
- [ ] 서버 레포에서 `createReservation()`의 Stripe 호출이 슬롯 락 보유 구간 안에 있는지 코드 재확인
- [ ] 원인 조치 후 재테스트
- [ ] 정리 필요: 테스트 지점 `branchId=40`(중단된 1차 시도, 방치됨), `branchId=41`(1차 실행분) —
      최종 테스트 종료 후 `scripts/cleanup.sh` + 수동 SQL로 둘 다 정리
- [ ] 테스트 종료 후 `DEV_AUTH_ENABLED=false`로 원복 확인 (현재 `true`로 켜져 있는 상태)
