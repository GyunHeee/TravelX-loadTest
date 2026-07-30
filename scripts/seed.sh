#!/usr/bin/env bash
# 부하테스트용 시드 데이터 생성:
# - 지점 1개 (정원 6명 슬롯 테스트용 timeSlotCapacity=6), USD 재고 넉넉히 시드 →
#   생성 직후 active=false로 비활성화해 공개 GET /branches(실사용자 노출)에서 숨긴다
#   (예약 생성은 branchId를 직접 지정하므로 비활성 지점이어도 정상 동작한다)
# - A/B0/B1/C 시나리오별로 서로 겹치지 않는 유저 토큰을 발급한다. 예전엔 20명을 4개
#   시나리오에서 모듈러로 재사용했는데, A에서 성공한 유저는 PENDING_PAYMENT 예약을 든 채
#   남아있어 뒤이은 시나리오에서 CONCURRENT_PENDING_PAYMENT_LIMIT(C304)에 걸려 락/풀
#   대기 측정이 오염될 수 있었다. 그래서 이번엔 시나리오마다 전용 유저 구간을 쓴다.
#
# 전제: DEV_AUTH_ENABLED=true인 서버를 대상으로만 실행할 것.
#   실배포(vietnam-internship/infra) 대상이라면 테스트 직전에만
#     kubectl set env deployment/travelx-server DEV_AUTH_ENABLED=true
#   로 켜고, 테스트가 끝나면 반드시 --overwrite로 되돌린다(README "안전 수칙" 참고).
#   이 토글은 Recreate 전략 때문에 파드가 재기동되며 매번 수십 초의 실다운타임이 생긴다.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8090}"

# 시나리오별 유저 수 — scenario.js의 시나리오 vus와 반드시 일치해야 한다(수정 시 양쪽 다 변경).
A_COUNT="${A_COUNT:-20}"
B0_COUNT="${B0_COUNT:-6}"
B1_COUNT="${B1_COUNT:-20}"
C_COUNT="${C_COUNT:-20}"
TOTAL_COUNT=$((A_COUNT + B0_COUNT + B1_COUNT + C_COUNT))

K6_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../k6" && pwd)"

# 라운드마다 고유한 유저를 새로 만들기 위한 구분자. 이메일이 이전 라운드와 같으면
# DevAuthController가 기존 유저를 그대로 재사용하는데, 그 유저가 이전 라운드에서 만든
# 예약이 아직 PENDING_PAYMENT로 남아있으면(5분 TTL 전이거나 뭔가 안 풀렸으면) 이번 라운드에서
# CONCURRENT_PENDING_PAYMENT_LIMIT(C304)에 바로 걸려 락/풀 대기 측정이 오염된다.
RUN_ID="${RUN_ID:-$(date +%s)}"
echo "== 0. 이번 라운드 RUN_ID=$RUN_ID (유저 이메일에 반영, 라운드 간 상태 오염 방지) =="

echo "== 1. admin 토큰 발급 =="
ADMIN_TOKEN=$(curl -sf -X POST "$BASE_URL/dev/auth/token" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"loadtest-admin-$RUN_ID@travelx.dev\",\"role\":\"ADMIN\"}" | jq -r .accessToken)

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

echo "== 4. 지점 비활성화 (실사용자 대상 공개 GET /branches에서 숨김) =="
curl -sf -X PATCH "$BASE_URL/admin/branches/$BRANCH_ID" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"active": false}' > /dev/null

echo "== 5. 시나리오별 핫 슬롯 날짜/시간 고정 (A/B0/B1이 같은 슬롯을 쓰면 A가 정원 6을 다 =="
echo "==    소진해서 B0/B1이 처음부터 '슬롯 꽉 참'으로만 나오므로, 반드시 서로 다른   =="
echo "==    슬롯을 쓴다 — 슬롯당 정원은 항상 새로 6명분이 생긴다)                     =="
HOT_DATE=$(date -v+1d +%Y-%m-%d 2>/dev/null || date -d "+1 day" +%Y-%m-%d)
jq -n --arg branchId "$BRANCH_ID" --arg date "$HOT_DATE" \
  --arg aTime "10:00" --arg b0Time "10:30" --arg b1Time "11:00" \
  '{branchId: ($branchId|tonumber), date: $date, aTime: $aTime, b0Time: $b0Time, b1Time: $b1Time}' \
  > "$K6_DIR/hot-slot.json"
echo "hot slots on $HOT_DATE: A=10:00 B0=10:30 B1=11:00"

echo "== 6. 분산 슬롯(C용) ${C_COUNT}개 — 서로 다른 날짜/시간이라 경합이 안 생김 =="
SPREAD_JSON="["
for i in $(seq 0 $((C_COUNT - 1))); do
  DAY_OFFSET=$((2 + i / 4))          # 30분 슬롯 4개씩 하루에 배분
  SLOT_INDEX=$((i % 4))
  SLOT_DATE=$(date -v+"${DAY_OFFSET}"d +%Y-%m-%d 2>/dev/null || date -d "+${DAY_OFFSET} day" +%Y-%m-%d)
  SLOT_HOUR=$((11 + SLOT_INDEX / 2))
  SLOT_MIN=$((SLOT_INDEX % 2 * 30))
  SLOT_TIME=$(printf "%02d:%02d" "$SLOT_HOUR" "$SLOT_MIN")
  SPREAD_JSON+="{\"date\":\"$SLOT_DATE\",\"time\":\"$SLOT_TIME\"}"
  [ "$i" -lt $((C_COUNT - 1)) ] && SPREAD_JSON+=","
done
SPREAD_JSON+="]"
echo "$SPREAD_JSON" | jq '.' > "$K6_DIR/spread-slots.json"

echo "== 7. 테스트 유저 ${TOTAL_COUNT}명 토큰 발급 =="
echo "==    순서 고정: A[0:$A_COUNT) B0[$A_COUNT:$((A_COUNT + B0_COUNT))) "
echo "==    B1[$((A_COUNT + B0_COUNT)):$((A_COUNT + B0_COUNT + B1_COUNT))) C[$((A_COUNT + B0_COUNT + B1_COUNT)):$TOTAL_COUNT)"
echo "==    scenario.js가 이 순서를 그대로 슬라이스해서 쓰므로 순서를 바꾸면 안 된다."
TOKENS_JSON="["
for i in $(seq 1 "$TOTAL_COUNT"); do
  TOKEN=$(curl -sf -X POST "$BASE_URL/dev/auth/token" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"loadtest-user-$i-$RUN_ID@travelx.dev\"}" | jq -r .accessToken)
  TOKENS_JSON+="\"$TOKEN\""
  [ "$i" -lt "$TOTAL_COUNT" ] && TOKENS_JSON+=","
done
TOKENS_JSON+="]"
echo "$TOKENS_JSON" | jq '.' > "$K6_DIR/tokens.json"

# scenario.js가 하드코딩된 카운트 대신 이 파일에서 직접 offset을 읽게 해서, 두 스크립트가
# 서로 다른 카운트로 어긋나는 사고를 구조적으로 막는다.
jq -n --argjson a "$A_COUNT" --argjson b0 "$B0_COUNT" --argjson b1 "$B1_COUNT" --argjson c "$C_COUNT" \
  '{a: $a, b0: $b0, b1: $b1, c: $c}' > "$K6_DIR/token-counts.json"

echo ""
echo "완료 (총 ${TOTAL_COUNT}명 유저, branchId=$BRANCH_ID, 비활성화 처리됨)."
echo "k6 실행 예시 (branchId/슬롯/토큰/카운트는 전부 위에서 만든 json에서 자동으로 읽음):"
echo "  k6 run -e BASE_URL=$BASE_URL k6/scenario.js --summary-export=results/summary.json"
echo ""
echo "테스트 종료 후 scripts/cleanup.sh 로 지점/토큰 파일을 정리할 것."
