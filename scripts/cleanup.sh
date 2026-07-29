#!/usr/bin/env bash
# 부하테스트 종료 후 정리:
# - 이 스크립트만으로 DB 행 자체가 삭제되지는 않는다(서버에 지점/유저 삭제 API가 없음).
#   대신 API로 안전하게 되돌릴 수 있는 것만 되돌리고, 나머지(행 삭제)는 사람이 검토 후
#   수동으로 실행할 SQL을 출력만 한다 — 실배포 DB에 자동으로 DELETE를 날리지 않는다.
#
# 자동으로 되는 것:
#   1. 테스트 지점 재고를 0으로 되돌림 (이미 seed.sh에서 active=false 처리는 해둔 상태)
# 자동으로 안 되는 것 (해당 서버에 삭제 API가 없어서):
#   - PENDING_PAYMENT로 남은 테스트 예약들은 서버의 기존 스케줄러
#     (ReservationExpirySweeper.expireOverduePendingPayments, 5분 TTL)가 자동으로 EXPIRED
#     처리하며 슬롯/재고를 알아서 복원한다 — 결제 웹훅을 안 태웠으므로 전부 이 경로를 탄다.
#     별도 조치 불필요, 5분만 기다리면 됨.
#   - 지점/예약/유저 행 자체를 DB에서 완전히 지우고 싶다면 아래 출력되는 SQL을
#     검토한 뒤 직접 kubectl exec로 실행할 것 (되돌릴 수 없음).
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8090}"
K6_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../k6" && pwd)"

if [ ! -f "$K6_DIR/hot-slot.json" ]; then
  echo "hot-slot.json이 없습니다 — seed.sh를 먼저 실행했는지 확인하세요." >&2
  exit 1
fi
BRANCH_ID=$(jq -r .branchId "$K6_DIR/hot-slot.json")

echo "== admin 토큰 발급 =="
ADMIN_TOKEN=$(curl -sf -X POST "$BASE_URL/dev/auth/token" \
  -H "Content-Type: application/json" \
  -d '{"email":"loadtest-admin@travelx.dev","role":"ADMIN"}' | jq -r .accessToken)

echo "== 테스트 지점(branchId=$BRANCH_ID) USD 재고 0으로 되돌림 =="
curl -sf -X PATCH "$BASE_URL/admin/branches/$BRANCH_ID/inventory" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"items":[{"currencyCode":"USD","stock":0}]}' > /dev/null

echo "== 지점 활성 상태 재확인 (active: false 여야 함) =="
curl -sf "$BASE_URL/branches/$BRANCH_ID" | jq '.data.active'

echo ""
echo "완료: 지점 재고 0 처리. active=false는 seed.sh에서 이미 처리됨."
echo "PENDING_PAYMENT 테스트 예약은 5분 내 스케줄러가 자동으로 EXPIRED 처리한다 — 대기만 하면 됨."
echo ""
echo "-------------------------------------------------------------------"
echo "[선택] 지점/예약/유저 행 자체를 DB에서 완전히 지우려면 (되돌릴 수 없음, 검토 후 직접 실행):"
echo ""
cat <<SQL
-- FK 순서 주의: reservation → branch_time_slot/branch_currency_rate/branch/users 순으로 지운다.
DELETE FROM reservation WHERE branch_id = $BRANCH_ID;
DELETE FROM branch_time_slot WHERE branch_id = $BRANCH_ID;
DELETE FROM branch_currency_rate WHERE branch_id = $BRANCH_ID;
DELETE FROM branch WHERE id = $BRANCH_ID;
DELETE FROM users WHERE email LIKE 'loadtest-%@travelx.dev';
SQL
echo "-------------------------------------------------------------------"
echo "실배포(vietnam-internship/infra) 기준 실행 위치 (셀프호스팅 MySQL 파드, RDS 아님):"
echo "  sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl exec -it deployment/mysql -- \\"
echo "    mysql -u\$DB_USERNAME -p\$DB_PASSWORD travelx"
echo "  (위 SQL을 붙여넣기 전에 반드시 branchId/이메일 패턴이 테스트 데이터만 가리키는지 확인할 것)"
