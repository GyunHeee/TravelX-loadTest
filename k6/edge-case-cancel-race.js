// 엣지케이스 부하테스트 — 예약 취소 동시 요청 레이스 (docs/discussion-reservation-cancel-expire-race.md)
//
// 배경: ReservationService.cancelReservation()은 Reservation 행에 락을 걸지 않고
// findById()로만 읽는다. Reservation.cancel()도 인메모리 status 필드만 검사한다
// (BusinessException은 status가 이미 CANCELLED/COMPLETED/EXPIRED일 때만 던져짐).
// 두 트랜잭션이 서로 커밋하기 전에 각자 findById로 같은 예약을 읽으면(MySQL REPEATABLE READ +
// JPA 1차 캐시), 둘 다 "아직 취소 안 됨"으로 판단하고 재고(BranchCurrencyRate)/슬롯
// (BranchTimeSlot)을 각자 한 번씩 복원한다 — 이중 복원 버그가 이론상 가능하다.
//
// 검증 방법: 재고를 알려진 값(baselineStock)으로 시드 → 예약 1건 생성(재고 -amount) →
// 같은 예약 ID에 DELETE(취소)를 N번 동시에 쏨 → 최종 재고를 확인.
//   - 정상(버그 없음): 정확히 1번만 복원 → finalStock === baselineStock
//   - 버그 있음: 여러 번 복원 → finalStock > baselineStock (초과분 / amount = 이중 복원 횟수)
//
// 실행: k6 run -e BASE_URL=https://api.knu80th.shop k6/edge-case-cancel-race.js
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8090';
const N_CONCURRENT_CANCELS = Number(__ENV.N_CONCURRENT_CANCELS || 10);
const AMOUNT = 100;
const BASELINE_STOCK = 10000;

export const options = {
  scenarios: {
    cancel_race: {
      executor: 'per-vu-iterations',
      vus: N_CONCURRENT_CANCELS,
      iterations: 1,
      exec: 'cancelRace',
    },
  },
};

function tomorrow() {
  const d = new Date();
  d.setDate(d.getDate() + 1);
  return d.toISOString().slice(0, 10);
}

function jsonHeaders(token) {
  return { headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` } };
}

export function setup() {
  const runId = Date.now();

  const adminRes = http.post(
    `${BASE_URL}/dev/auth/token`,
    JSON.stringify({ email: `loadtest-cancelrace-admin-${runId}@travelx.dev`, role: 'ADMIN' }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  const adminToken = adminRes.json('accessToken');
  if (!adminToken) {
    throw new Error(`admin 토큰 발급 실패: ${adminRes.status} ${adminRes.body}`);
  }

  const branchRes = http.post(
    `${BASE_URL}/admin/branches`,
    JSON.stringify({
      name: 'CancelRace Branch',
      address: '123 Cancel Race Ave',
      latitude: 37.5665,
      longitude: 126.978,
      phone: '02-0000-0000',
      businessHours: 'Weekday 00:00-23:30, Weekend 00:00-23:30',
      pickupLocationDetail: 'Edge case test only',
      timeSlotCapacity: 6,
      supportedCurrencies: ['USD'],
    }),
    jsonHeaders(adminToken),
  );
  const branchId = branchRes.json('data.id');
  if (!branchId) {
    throw new Error(`지점 생성 실패: ${branchRes.status} ${branchRes.body}`);
  }

  http.patch(
    `${BASE_URL}/admin/branches/${branchId}/rate`,
    JSON.stringify({ currencyCode: 'USD', preferentialRate: 1.0, reservationOnlyStock: BASELINE_STOCK }),
    jsonHeaders(adminToken),
  );
  http.patch(`${BASE_URL}/admin/branches/${branchId}`, JSON.stringify({ active: false }), jsonHeaders(adminToken));

  const userRes = http.post(
    `${BASE_URL}/dev/auth/token`,
    JSON.stringify({ email: `loadtest-cancelrace-user-${runId}@travelx.dev` }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  const userToken = userRes.json('accessToken');
  if (!userToken) {
    throw new Error(`유저 토큰 발급 실패: ${userRes.status} ${userRes.body}`);
  }

  const pickupDate = tomorrow();
  const pickupTime = '15:00';

  const resvRes = http.post(
    `${BASE_URL}/reservations`,
    JSON.stringify({ currencyCode: 'USD', branchId: Number(branchId), amount: AMOUNT, pickupDate, pickupTime }),
    jsonHeaders(userToken),
  );
  const reservationId = resvRes.json('data.id');
  if (!reservationId) {
    throw new Error(`사전 예약 생성 실패: ${resvRes.status} ${resvRes.body}`);
  }

  console.log(
    `SETUP branchId=${branchId} reservationId=${reservationId} baselineStock=${BASELINE_STOCK} afterReservation=${BASELINE_STOCK - AMOUNT}`,
  );

  return { adminToken, branchId, userToken, reservationId };
}

export function cancelRace(data) {
  const res = http.del(`${BASE_URL}/reservations/${data.reservationId}`, null, {
    headers: { Authorization: `Bearer ${data.userToken}` },
  });
  console.log(`CANCEL_RESULT vu=${__VU} status=${res.status} body=${res.body}`);
  check(res, { 'not a 500': (r) => r.status !== 500 });
}

export function teardown(data) {
  const invRes = http.get(`${BASE_URL}/admin/branches/${data.branchId}/inventory`, {
    headers: { Authorization: `Bearer ${data.adminToken}` },
  });
  const items = invRes.json('data') || [];
  const usd = items.find((i) => i.currencyCode === 'USD');
  const finalStock = usd ? usd.stock : null;
  const expected = BASELINE_STOCK;

  console.log(`VERIFY baselineStock=${BASELINE_STOCK} expectedAfterOneCancel=${expected} finalStock=${finalStock}`);

  if (finalStock === null) {
    console.log('VERIFY_RESULT: UNKNOWN — 재고 조회 실패');
  } else if (finalStock > expected) {
    const extra = (finalStock - expected) / AMOUNT;
    console.log(
      `VERIFY_RESULT: BUG_CONFIRMED — finalStock(${finalStock}) > baseline(${expected}), 약 ${extra}회 이중 복원됨`,
    );
  } else if (finalStock === expected) {
    console.log('VERIFY_RESULT: OK — 정확히 1번만 복원됨 (버그 재현 안 됨)');
  } else {
    console.log(
      `VERIFY_RESULT: UNEXPECTED — finalStock(${finalStock}) < baseline(${expected}), 취소가 하나도 반영 안 됐거나 다른 문제`,
    );
  }
}
