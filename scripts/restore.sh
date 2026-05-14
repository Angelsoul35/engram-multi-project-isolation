#!/usr/bin/env bash
# restore.sh — restaura un dump en un compose paralelo (NO toca el stack
# productivo). Pensado para el "restore drill" mensual.
#
# Uso:
#   ./restore.sh /path/to/engram-cloud-YYYYMMDD-HHMMSS.sql.gz
#   ./restore.sh /path/to/engram-cloud-YYYYMMDD-HHMMSS.sql.gz.age   # cifrado

set -euo pipefail

DUMP="${1:?Uso: $0 <ruta-al-dump.sql.gz[.age]>}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_NAME="engram-restore"

if [[ ! -f "$DUMP" ]]; then
  echo "ERROR: no existe $DUMP" >&2
  exit 1
fi

WORK="$DUMP"
TMP_DECRYPTED=""
if [[ "$DUMP" == *.age ]]; then
  command -v age >/dev/null || { echo "age no instalado" >&2; exit 1; }
  TMP_DECRYPTED=$(mktemp --suffix=.sql.gz)
  echo "→ Descifrando con age (te va a pedir la KEY privada)..."
  age -d -o "$TMP_DECRYPTED" "$DUMP"
  WORK="$TMP_DECRYPTED"
fi

cleanup() {
  [[ -n "$TMP_DECRYPTED" && -f "$TMP_DECRYPTED" ]] && rm -f "$TMP_DECRYPTED"
}
trap cleanup EXIT

ENV_FILE="${REPO_DIR}/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE no existe" >&2; exit 1; }

cd "$REPO_DIR"

echo "→ Levantando stack paralelo ($PROJECT_NAME)..."
COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose up -d postgres

echo "→ Esperando Postgres healthy..."
for i in {1..30}; do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "${PROJECT_NAME}-postgres-1" 2>/dev/null || echo "starting")
  [[ "$STATUS" == "healthy" ]] && break
  sleep 2
done
[[ "$STATUS" == "healthy" ]] || { echo "ERROR: postgres no llegó a healthy" >&2; exit 1; }

set -a; source "$ENV_FILE"; set +a

echo "→ Cargando dump..."
gunzip -c "$WORK" | \
  docker exec -i "${PROJECT_NAME}-postgres-1" \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1

echo "→ Levantando engram cloud sobre la restore DB..."
COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose up -d cloud

echo
echo "✓ Restore completo en stack '$PROJECT_NAME'."
echo "  Container engram cloud: ${PROJECT_NAME}-cloud-1"
echo "  Validá con:"
echo "    docker logs ${PROJECT_NAME}-cloud-1"
echo "    docker exec ${PROJECT_NAME}-postgres-1 psql -U $POSTGRES_USER -d $POSTGRES_DB -c 'SELECT count(*) FROM observations;'"
echo
echo "Cuando termines el drill, tear down:"
echo "    cd $REPO_DIR && COMPOSE_PROJECT_NAME=$PROJECT_NAME docker compose down -v"
