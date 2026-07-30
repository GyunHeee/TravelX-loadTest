// TravelX 슬롯 예약 동시성 부하테스트
//
// 시나리오:
//   A  — 정합성 검증: 정원 6인 슬롯에 20명 동시 요청 → 정확히 6건만 성공해야 함
//   B0 — 같은 슬롯 + 풀 크기 이내(VU=6)  → 순수 락 대기
//   B1 — 같은 슬롯 + 풀 초과(VU=20)      → 락 대기 + 커넥션 풀 대기 (실제 배포 조건)
//   C  — 다른 슬롯(분산) + 풀 초과(VU=20) → 커넥션 풀 대기만 (락 없음, B1과의 대조군)
// B1 - C ≈ 슬롯 락 자체로 인한 순수 지연.
//
// A/B0/B1은 서로 다른 슬롯(시간대)을 쓴다 — 같은 슬롯을 재사용하면 앞 시나리오가
// 정원 6을 다 소진해버려서 뒤 시나리오가 처음부터 "슬롯 꽉 참"으로만 나오기 때문이다.
//
// 유저 풀: A/B0/B1/C는 서로 겹치지 않는 전용 유저 구간을 쓴다(tokens.json 안에서
// token-counts.json 순서대로 연속 슬라이스). 예전엔 20명을 4개 시나리오에서 모듈러로
// 재사용했는데, A에서 성공한 유저는 PENDING_PAYMENT 예약을 쥔 채 남아있어 뒤이은
// 시나리오에서 CONCURRENT_PENDING_PAYMENT_LIMIT(C304)에 걸릴 수 있었다 — 어떤 토큰이
// A에서 이길지는 레이스라 재현성도 없이 락/풀 대기 측정이 오염됐다. 겹치지 않는 구간을
// 쓰면 이 오염 자체가 구조적으로 불가능해진다.
//
// 실행 전 scripts/seed.sh로 tokens.json / token-counts.json / hot-slot.json /
// spread-slots.json을 먼저 생성할 것.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8090';

const TOKENS = JSON.parse(open('./tokens.json'));
const COUNTS = JSON.parse(open('./token-counts.json')); // { a, b0, b1, c } — seed.sh와 반드시 동일해야 함
const SPREAD_SLOTS = JSON.parse(open('./spread-slots.json'));
const HOT = JSON.parse(open('./hot-slot.json')); // { branchId, date, aTime, b0Time, b1Time }

// seed.sh가 만든 순서(A → B0 → B1 → C) 그대로 누적 오프셋을 계산한다 — 카운트를 바꿔도
// 두 파일이 같은 token-counts.json을 보는 한 항상 서로 다른 구간을 가리킨다.
const OFFSET_A = 0;
const OFFSET_B0 = OFFSET_A + COUNTS.a;
const OFFSET_B1 = OFFSET_B0 + COUNTS.b0;
const OFFSET_C = OFFSET_B1 + COUNTS.b1;

const SLOT_BY_SCENARIO = {
  a_correctness: { date: HOT.date, time: HOT.aTime },
  b0_pool_safe_contended: { date: HOT.date, time: HOT.b0Time },
  b1_pool_exceed_contended: { date: HOT.date, time: HOT.b1Time },
};

const TOKEN_OFFSET_BY_SCENARIO = {
  a_correctness: OFFSET_A,
  b0_pool_safe_contended: OFFSET_B0,
  b1_pool_exceed_contended: OFFSET_B1,
  c_pool_exceed_spread: OFFSET_C,
};

export const options = {
  scenarios: {
    a_correctness: {
      executor: 'per-vu-iterations',
      vus: COUNTS.a,
      iterations: 1,
      exec: 'reserve',
      startTime: '0s',
    },
    b0_pool_safe_contended: {
      executor: 'per-vu-iterations',
      vus: COUNTS.b0,
      iterations: 1,
      exec: 'reserve',
      startTime: '20s',
    },
    b1_pool_exceed_contended: {
      executor: 'per-vu-iterations',
      vus: COUNTS.b1,
      iterations: 1,
      exec: 'reserve',
      startTime: '40s',
    },
    c_pool_exceed_spread: {
      executor: 'per-vu-iterations',
      vus: COUNTS.c,
      iterations: 1,
      exec: 'reserve',
      startTime: '60s',
    },
  },
  thresholds: {
    // 실배포 대상은 nginx 리버스 프록시 + TLS를 거치므로 로컬 Docker 직결보다 기본 RTT가
    // 더 크다. 최초 실행에서는 이 임계치를 하드 실패가 아니라 관찰 기준으로 보고, 실측
    // 후 재조정할 것.
    'http_req_duration{scenario:b0_pool_safe_contended}': ['p(95)<300'],
    // HIKARI_CONNECTION_TIMEOUT=3000ms이므로 풀 초과 시나리오는 이보다 커도 실패로 보지 않는다 —
    // 임계치는 "타임아웃으로 전부 죽지는 않는다"를 확인하는 정도로 느슨하게 잡는다.
    'http_req_duration{scenario:b1_pool_exceed_contended}': ['p(95)<3500'],
    'http_req_duration{scenario:c_pool_exceed_spread}': ['p(95)<3500'],
  },
};

export function reserve() {
  const scenarioName = exec.scenario.name;
  // __VU는 시나리오마다 1부터 다시 시작하는 게 아니라 이 테스트 실행 전체에서 유일한
  // 전역 번호다(예: b0_pool_safe_contended가 VU=6개뿐인데도 실제 __VU 값은 24 같은 식으로
  // 찍힘). __VU로 오프셋을 계산하면 시나리오별 토큰 범위를 벗어나 tokens.json 배열 밖을
  // 가리키게 되고, 그 결과 token이 undefined가 되어 "Bearer undefined"로 요청 → 401만
  // 잔뜩 나는 버그가 있었다(3~4차 라운드). exec.scenario.iterationInInstance는 "이
  // 시나리오 안에서 몇 번째 이터레이션인가"를 0부터 세므로, 시나리오 내 순번이 정확히 필요하다.
  const iterationIndex = exec.scenario.iterationInInstance;
  const tokenIndex = TOKEN_OFFSET_BY_SCENARIO[scenarioName] + iterationIndex;
  const token = TOKENS[tokenIndex];
  if (token === undefined) {
    console.log(`BUG scenario=${scenarioName} vu=${__VU} iter=${iterationIndex} tokenIndex=${tokenIndex} out of range (tokens.length=${TOKENS.length})`);
  }

  const slot =
    scenarioName === 'c_pool_exceed_spread'
      ? SPREAD_SLOTS[iterationIndex % SPREAD_SLOTS.length]
      : SLOT_BY_SCENARIO[scenarioName];

  const res = http.post(
    `${BASE_URL}/reservations`,
    JSON.stringify({
      currencyCode: 'USD',
      branchId: Number(HOT.branchId),
      amount: 100,
      pickupDate: slot.date,
      pickupTime: slot.time,
    }),
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } },
  );

  check(res, {
    'not a 500': (r) => r.status !== 500,
    'not a connection timeout': (r) => r.status !== 0,
  });

  // 서버 상태(PENDING_PAYMENT 5분 TTL로 재고/예약 상태가 계속 바뀜)에 의존하지 않고, 시나리오별
  // 성공/실패 분포를 그 자리에서 바로 확인하기 위한 로그. 실패 응답의 code 필드(BusinessErrorCode)도
  // 같이 찍어서 "정원초과라 정상 거절"인지 "처리 안 된 예외"인지 바로 구분한다.
  let errorCode = '';
  if (res.status !== 200 && res.status !== 201) {
    try {
      errorCode = JSON.parse(res.body).code || '';
    } catch (e) {
      errorCode = 'unparseable-body';
    }
  }
  console.log(`RESULT scenario=${scenarioName} vu=${__VU} iter=${iterationIndex} tokenIndex=${tokenIndex} status=${res.status} code=${errorCode}`);
}
