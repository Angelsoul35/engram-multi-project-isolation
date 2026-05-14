#!/usr/bin/env bash
# check-updates.sh — chequea si hay versión nueva de engram o postgres.
# NO actualiza nada — solo informa, para revisión humana.
#
# Cron sugerido (lunes 09:00):
#   0 9 * * 1 /path/to/scripts/check-updates.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${REPO_DIR}/docker-compose.yml"

CURRENT_ENGRAM=$(grep -oE 'engram:[0-9]+\.[0-9]+\.[0-9]+' "$COMPOSE_FILE" | head -1 | cut -d: -f2 || echo "?")
CURRENT_PG=$(grep -oE 'postgres:[0-9]+\.[0-9]+-alpine' "$COMPOSE_FILE" | head -1 | cut -d: -f2 || echo "?")

LATEST_ENGRAM=$(curl -fsS https://api.github.com/repos/gentleman-programming/engram/releases/latest 2>/dev/null \
  | grep -oE '"tag_name":\s*"v[^"]+"' | cut -d'"' -f4 | sed 's/^v//' || echo "?")

LATEST_PG=$(curl -fsS https://endoflife.date/api/postgresql.json 2>/dev/null \
  | grep -oE '"latest":\s*"16\.[0-9]+"' | head -1 | cut -d'"' -f4 || echo "?")

echo "═══════════════════════════════════════════"
echo "  Engram Cloud — Update Check $(date '+%F %T')"
echo "═══════════════════════════════════════════"
echo
printf "  %-12s pinneado: %-12s última: %-12s " "engram"   "$CURRENT_ENGRAM"   "$LATEST_ENGRAM"
[[ "$CURRENT_ENGRAM" == "$LATEST_ENGRAM" ]] && echo "✓ al día" || echo "⚠ ACTUALIZAR"

printf "  %-12s pinneado: %-12s última: %-12s " "postgres" "$CURRENT_PG"       "${LATEST_PG}-alpine"
[[ "$CURRENT_PG" == "${LATEST_PG}-alpine" ]] && echo "✓ al día" || echo "⚠ ACTUALIZAR"

echo
echo "Si hay update:"
echo "  1. Leer release notes:"
echo "       https://github.com/gentleman-programming/engram/releases"
echo "       https://www.postgresql.org/about/news/"
echo "  2. Editar tag en docker-compose.yml"
echo "  3. Validar en staging (COMPOSE_PROJECT_NAME=staging docker compose up -d)"
echo "  4. ./scripts/backup.sh"
echo "  5. docker compose pull && docker compose up -d"
echo "  6. ENGRAM_CLOUD_TOKEN=... ./scripts/smoke.sh"
