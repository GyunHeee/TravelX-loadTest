#!/usr/bin/env bash
# 부하테스트 종료 후 정리. VM에서 실행할 것 (행 삭제에 kubectl exec로 mysql 파드 접근이 필요).
#
# 하는 일:
#   1. 테스트 지점(들) USD 재고를 0으로 되돌림 (API, active=false는 seed.sh에서 이미 처리됨)
#   2. 지점/예약/유저 행을 실제로 DB에서 삭제 (kubectl exec, 확인 프롬프트 통과 후)
#
# BRANCH_IDS에 지금까지 쌓인 모든 테스트 branchId를 공백으로 나열하면 한 번에 정리된다.
# 지정 안 하면 이번 라운드(k6/hot-slot.json)의 branchId만 정리한다.
#   예: BRANCH_IDS="40 41 21 22 23 24" ./scripts/cleanup.sh
#
# PENDING_PAYMENT로 남은 테스트 예약은 서버의 기존 스케줄러
# (ReservationExpirySweeper.expireOverduePendingPayments, 5분 TTL)가 자동으로 EXPIRED
# 처리하며 슬롯/재고를 복원하지만, 이 스크립트의 행 삭제는 그 상태와 무관하게 바로 지운다.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8090}"
K6_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../k6" && pwd)"

if [ ! -f "$K6_DIR/hot-slot.json" ]; then
  echo "hot-slot.json이 없습니다 — seed.sh를 먼저 실행했는지 확인하세요." >&2
  exit 1
fi
CURRENT_BRANCH_ID=$(jq -r .branchId "$K6_DIR/hot-slot.json")
BRANCH_IDS="${BRANCH_IDS:-$CURRENT_BRANCH_ID}"

echo "== admin 토큰 발급 =="
ADMIN_TOKEN=$(curl -sf -X POST "$BASE_URL/dev/auth/token" \
  -H "Content-Type: application/json" \
  -d '{"email":"loadtest-admin@travelx.dev","role":"ADMIN"}' | jq -r .accessToken)

for BID in $BRANCH_IDS; do
  echo "== 지점 $BID USD 재고 0으로 되돌림 =="
  curl -sf -X PATCH "$BASE_URL/admin/branches/$BID/inventory" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $ADMIN_TOKEN" \
    -d '{"items":[{"currencyCode":"USD","stock":0}]}' > /dev/null \
    || echo "  (지점 $BID 재고 정리 실패 — 이미 지워졌거나 존재하지 않을 수 있음, 계속 진행)"
done

BRANCH_IDS_CSV=$(echo "$BRANCH_IDS" | tr -s ' ' ',')

SQL=$(cat <<EOSQL
DELETE FROM reservations WHERE branch_id IN ($BRANCH_IDS_CSV);
DELETE FROM branch_time_slots WHERE branch_id IN ($BRANCH_IDS_CSV);
DELETE FROM branch_currency_rates WHERE branch_id IN ($BRANCH_IDS_CSV);
DELETE FROM branches WHERE id IN ($BRANCH_IDS_CSV);
DELETE FROM users WHERE email LIKE 'loadtest-%@travelx.dev';
EOSQL
)

echo ""
echo "-------------------------------------------------------------------"
echo "아래 SQL을 실제 DB에 실행합니다 (branch_id: $BRANCH_IDS_CSV) — 되돌릴 수 없습니다:"
echo ""
echo "$SQL"
echo "-------------------------------------------------------------------"

if [ "${CONFIRM:-}" != "yes" ]; then
  read -r -p "정말 실행할까요? branch_id 목록이 테스트 데이터만 가리키는지 확인했다면 y 입력: " ans
  if [ "$ans" != "y" ] && [ "$ans" != "Y" ]; then
    echo "취소됨. 재고 정리(위 단계)만 반영되고 행 삭제는 안 했습니다."
    exit 0
  fi
fi

echo "== kubectl exec로 실제 삭제 실행 (mysql 파드) =="
echo "$SQL" | kubectl exec -i deployment/mysql -- mysql -u"$DB_USERNAME" -p"$DB_PASSWORD" travelx

echo ""
echo "완료: branch_id($BRANCH_IDS_CSV) 테스트 지점/예약/슬롯/재고와 loadtest-% 유저를 삭제했습니다."
