#!/usr/bin/env bash
# smoke.sh — smoke test end-to-end del cloud server: /health + auth ping.
# Uso:
#   ENGRAM_CLOUD_TOKEN=... ./smoke.sh                                # localhost
#   ENGRAM_CLOUD_TOKEN=... ./smoke.sh https://engram.your-tld.ts.net # remoto

set -euo pipefail

URL="${1:-http://127.0.0.1:18080}"
TOKEN="${ENGRAM_CLOUD_TOKEN:?ENGRAM_CLOUD_TOKEN no exportado}"

URL="${URL%/}"

pass() { printf "  \e[32m✓\e[0m %s\n" "$1"; }
fail() { printf "  \e[31m✗\e[0m %s\n" "$1"; exit 1; }

echo "Smoke test contra: $URL"

echo
echo "[1/3] /health (sin auth)"
HTTP_CODE=$(curl -fsS -o /tmp/smoke-health -w '%{http_code}' "$URL/health" || true)
[[ "$HTTP_CODE" == "200" ]] && pass "200 OK" || fail "esperaba 200, vino $HTTP_CODE"

echo
echo "[2/3] /api/v1/projects sin token (debe rechazar)"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/v1/projects")
[[ "$HTTP_CODE" =~ ^(401|403)$ ]] && pass "rechazó con $HTTP_CODE (auth obligatoria)" \
  || fail "esperaba 401/403 sin token, vino $HTTP_CODE — REVISAR auth!"

echo
echo "[3/3] /api/v1/projects con token"
HTTP_CODE=$(curl -fsS -o /tmp/smoke-projects -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" "$URL/api/v1/projects" || true)
[[ "$HTTP_CODE" == "200" ]] && pass "200 OK con token" || fail "esperaba 200, vino $HTTP_CODE"

echo
echo "✓ Smoke test PASS"
