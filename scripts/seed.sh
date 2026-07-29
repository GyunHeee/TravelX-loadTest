#!/usr/bin/env bash
# 부하테스트용 시드 데이터 생성:
# - 지점 1개 (정원 6명 슬롯 테스트용 timeSlotCapacity=6), USD 재고 넉넉히 시드
# - 서로 다른 유저 20명의 dev-auth 토큰 발급 (같은 유저로 동시 요청하면
#   CONCURRENT_PENDING_PAYMENT_LIMIT에 걸려 결과가 오염되므로 유저를 반드시 분리한다)
# - k6가 바로 읽을 수 있게 hot-slot.json / spread-slots.json / tokens.json 생성
#
# 전제: DEV_AUTH_ENABLED=true인 서버(로컬 부하테스트 컨테이너)를 대상으로만 실행할 것.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8090}"
VU_COUNT="${VU_COUNT:-20}"
K6_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../k6" && pwd)"

echo "== 1. admin 토큰 발급 =="
ADMIN_TOKEN=$(curl -sf -X POST "$BASE_URL/dev/auth/token" \
  -H "Content-Type: application/json" \
  -d '{"email":"loadtest-admin@travelx.dev","role":"ADMIN"}' | jq -r .accessToken)

echo "== 2. 지점 생성 (timeSlotCapacity=6) =="
BRANCH_ID=$(curl -sf -X POST "$BASE_URL/admin/branches" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{
    "name": "LoadTest Branch",
    "address": "123 Load Test Ave, Seoul",
    "latitude": 37.5665,
    "longitude": 126.9780,
    "phone": "02-0000-0000",
    "businessHours": "Weekday 00:00-23:30, Weekend 00:00-23:30",
    "pickupLocationDetail": "Load test only",
    "timeSlotCapacity": 6,
    "supportedCurrencies": ["USD"]
  }' | jq -r .data.id)
echo "branchId=$BRANCH_ID"

echo "== 3. USD 재고/우대율 시드 (넉넉하게, 재고 부족이 결과에 안 섞이게) =="
curl -sf -X PATCH "$BASE_URL/admin/branches/$BRANCH_ID/rate" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"currencyCode":"USD","preferentialRate":1.0,"reservationOnlyStock":1000000}' > /dev/null

echo "== 4. 시나리오별 핫 슬롯 날짜/시간 고정 (A/B0/B1이 같은 슬롯을 쓰면 A가 정원 6을 다 =="
echo "==    소진해서 B0/B1이 처음부터 '슬롯 꽉 참'으로만 나오므로, 반드시 서로 다른   =="
echo "==    슬롯을 쓴다 — 슬롯당 정원은 항상 새로 6명분이 생긴다)                     =="
HOT_DATE=$(date -v+1d +%Y-%m-%d 2>/dev/null || date -d "+1 day" +%Y-%m-%d)
jq -n --arg branchId "$BRANCH_ID" --arg date "$HOT_DATE" \
  --arg aTime "10:00" --arg b0Time "10:30" --arg b1Time "11:00" \
  '{branchId: ($branchId|tonumber), date: $date, aTime: $aTime, b0Time: $b0Time, b1Time: $b1Time}' \
  > "$K6_DIR/hot-slot.json"
echo "hot slots on $HOT_DATE: A=10:00 B0=10:30 B1=11:00"

echo "== 5. 분산 슬롯(C용) $VU_COUNT개 — 서로 다른 날짜/시간이라 경합이 안 생김 =="
SPREAD_JSON="["
for i in $(seq 0 $((VU_COUNT - 1))); do
  DAY_OFFSET=$((2 + i / 4))          # 30분 슬롯 4개씩 하루에 배분
  SLOT_INDEX=$((i % 4))
  SLOT_DATE=$(date -v+"${DAY_OFFSET}"d +%Y-%m-%d 2>/dev/null || date -d "+${DAY_OFFSET} day" +%Y-%m-%d)
  SLOT_HOUR=$((11 + SLOT_INDEX / 2))
  SLOT_MIN=$((SLOT_INDEX % 2 * 30))
  SLOT_TIME=$(printf "%02d:%02d" "$SLOT_HOUR" "$SLOT_MIN")
  SPREAD_JSON+="{\"date\":\"$SLOT_DATE\",\"time\":\"$SLOT_TIME\"}"
  [ "$i" -lt $((VU_COUNT - 1)) ] && SPREAD_JSON+=","
done
SPREAD_JSON+="]"
echo "$SPREAD_JSON" | jq '.' > "$K6_DIR/spread-slots.json"

echo "== 6. 테스트 유저 $VU_COUNT명 토큰 발급 (유저별로 반드시 달라야 함) =="
TOKENS_JSON="["
for i in $(seq 1 "$VU_COUNT"); do
  TOKEN=$(curl -sf -X POST "$BASE_URL/dev/auth/token" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"loadtest-user-$i@travelx.dev\"}" | jq -r .accessToken)
  TOKENS_JSON+="\"$TOKEN\""
  [ "$i" -lt "$VU_COUNT" ] && TOKENS_JSON+=","
done
TOKENS_JSON+="]"
echo "$TOKENS_JSON" | jq '.' > "$K6_DIR/tokens.json"

echo ""
echo "완료. k6 실행 예시 (branchId/슬롯/토큰은 전부 hot-slot.json 등에서 자동으로 읽음):"
echo "  k6 run -e BASE_URL=$BASE_URL k6/scenario.js --summary-export=results/summary.json"
