### 배경

[3차 실행](round3-findings.md)에서 B1(6건)/C(20건)의 401(A001) 원인을 못 찾고 넘어갔다.
이번 라운드는 그 원인을 마저 찾으려던 재실행 기록인데, 과정에서 **진짜 원인은 서버가 아니라
`k6/scenario.js` 자체의 버그**였다는 게 드러났다.

---

### 시행착오 1 — 재시드 없이 재실행하면 안 된다

첫 시도에서 k6 실행을 Ctrl+C로 중단했다(A/B0만 끝나고 B1/C는 시작도 못함). 이어서 "토큰이
30분 안 지났으면 재시드 없이 k6만 다시 돌려도 된다"고 판단하고 그대로 재실행했는데, 완전히
잘못된 판단이었다 — **중단된 실행에서도 A/B0의 예약은 이미 실제로 성공해서 슬롯 정원(6명)을
채웠고, 그 유저들은 `PENDING_PAYMENT`를 이미 쥔 상태**였다. 그래서 재실행에서 A/B0가 전부
정원초과(409 C206)/중복결제(403 C304)로 막혔다 — 서버 버그가 아니라 **재시드를 생략한
판단 자체가 오류**였다. 토큰 TTL만 보고 "재시드 필요 없음"을 판단하면 안 되고, k6를 한 번이라도
돌렸다면(중단됐더라도) 슬롯/유저 상태가 이미 오염됐다고 보고 항상 재시드해야 한다.

---

### 시행착오 2가 드러낸 진짜 버그 — `__VU`는 시나리오별로 리셋되지 않는다

같은 로그에서 결정적 단서가 나왔다:

```
RESULT scenario=b0_pool_safe_contended vu=24 status=201 code=
```

`b0_pool_safe_contended`는 `vus: 6`인 시나리오인데 `vu=24`가 찍혔다. **k6의 `__VU`는
시나리오마다 1부터 다시 시작하는 게 아니라, 이 테스트 실행 전체에서 유일한 전역 번호**였다
(A가 VU 1~20을 먼저 가져가면, B0/B1/C는 이미 다음 번호부터 이어받는 식). `scenario.js`는
`TOKEN_OFFSET_BY_SCENARIO[scenarioName] + (__VU - 1)`로 토큰 인덱스를 계산했는데, 이게
시나리오별로 `__VU`가 1부터 시작한다는 잘못된 가정 위에 있었다.

**결과**: B0/B1/C의 실제 `__VU` 값을 오프셋 공식에 넣으면 `tokens.json`(길이 66) 범위를
벗어난 인덱스가 나왔다. JS에서 배열 범위 밖 접근은 예외 없이 `undefined`를 반환하고,
`Authorization: Bearer undefined`로 요청이 나가니 서버가 **깔끔하게 401을 리턴**한 것이었다
— 서버 쪽엔 아무 문제가 없었다. B1은 일부 VU만 범위를 벗어나 6건만 401, C는 전 구간이
범위를 벗어나 20건 전부 401이 났던 것도 이걸로 설명된다.

**3차 결과도 이 렌즈로 다시 보면**: 3차의 B1/C 401도 필시 같은 버그였을 가능성이 높다
(재배포 충돌설은 이미 기각했었고, 이게 훨씬 더 근본적이고 일관된 설명이다).

---

### 수정

`__VU` 대신 `exec.scenario.iterationInInstance`(그 시나리오 안에서 몇 번째 이터레이션인지,
0부터 시작, 시나리오별로 독립적으로 셈)를 쓰도록 `k6/scenario.js`를 고쳤다. 토큰 인덱스가
범위를 벗어나면 조용히 `undefined`로 새지 않도록 `BUG ...` 로그도 방어적으로 추가했다.

```js
const iterationIndex = exec.scenario.iterationInInstance;
const tokenIndex = TOKEN_OFFSET_BY_SCENARIO[scenarioName] + iterationIndex;
const token = TOKENS[tokenIndex];
if (token === undefined) {
  console.log(`BUG scenario=${scenarioName} vu=${__VU} iter=${iterationIndex} tokenIndex=${tokenIndex} out of range (tokens.length=${TOKENS.length})`);
}
```

C의 분산 슬롯 선택(`SPREAD_SLOTS[...]`)도 같은 이유로 `__VU` 대신 `iterationIndex`를 쓰도록
같이 고쳤다.

---

### 남은 것 (다음 세션)

- [ ] **반드시 재시드 후** 재실행 (이전 라운드의 슬롯/유저 상태를 재사용하지 말 것)
- [ ] 이번엔 중단하지 말고 끝까지 실행 → `RESULT`/`BUG` 로그로 정상적인 6(A)+6(B0)+6(B1)+20(C)=38건
      성공이 나오는지 확인 (드디어 이론값과 일치할 것으로 기대)
- [ ] 3차에서 남아있던 잔여 500(C009, A에서 2~4건)이 이번에도 재현되는지 확인 — k6 종료 직후
      바로 서버 로그부터 확보할 것
- [ ] 정리 필요: 테스트 지점 `branchId=40,41`(1차), `21`(2차), `22`(3차), `23`(중단된 4차 시도) 총 5개
- [ ] `DEV_AUTH_ENABLED=false`로 원복 (계속 `true`로 켜진 채 방치됨)
