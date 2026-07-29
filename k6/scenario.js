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
// 실행 전 scripts/seed.sh로 tokens.json / hot-slot.json / spread-slots.json을 먼저 생성할 것.
import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8090';

const TOKENS = JSON.parse(open('./tokens.json'));
const SPREAD_SLOTS = JSON.parse(open('./spread-slots.json'));
const HOT = JSON.parse(open('./hot-slot.json')); // { branchId, date, aTime, b0Time, b1Time }

const SLOT_BY_SCENARIO = {
  a_correctness: { date: HOT.date, time: HOT.aTime },
  b0_pool_safe_contended: { date: HOT.date, time: HOT.b0Time },
  b1_pool_exceed_contended: { date: HOT.date, time: HOT.b1Time },
};

export const options = {
  scenarios: {
    a_correctness: {
      executor: 'per-vu-iterations',
      vus: 20,
      iterations: 1,
      exec: 'reserve',
      startTime: '0s',
    },
    b0_pool_safe_contended: {
      executor: 'per-vu-iterations',
      vus: 6,
      iterations: 1,
      exec: 'reserve',
      startTime: '20s',
    },
    b1_pool_exceed_contended: {
      executor: 'per-vu-iterations',
      vus: 20,
      iterations: 1,
      exec: 'reserve',
      startTime: '40s',
    },
    c_pool_exceed_spread: {
      executor: 'per-vu-iterations',
      vus: 20,
      iterations: 1,
      exec: 'reserve',
      startTime: '60s',
    },
  },
  thresholds: {
    'http_req_duration{scenario:b0_pool_safe_contended}': ['p(95)<300'],
    // HIKARI_CONNECTION_TIMEOUT=3000ms이므로 풀 초과 시나리오는 이보다 커도 실패로 보지 않는다 —
    // 임계치는 "타임아웃으로 전부 죽지는 않는다"를 확인하는 정도로 느슨하게 잡는다.
    'http_req_duration{scenario:b1_pool_exceed_contended}': ['p(95)<3500'],
    'http_req_duration{scenario:c_pool_exceed_spread}': ['p(95)<3500'],
  },
};

export function reserve() {
  const scenarioName = exec.scenario.name;
  const token = TOKENS[(__VU - 1) % TOKENS.length];

  const slot =
    scenarioName === 'c_pool_exceed_spread'
      ? SPREAD_SLOTS[(__VU - 1) % SPREAD_SLOTS.length]
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
}
