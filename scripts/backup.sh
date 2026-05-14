#!/usr/bin/env bash
# backup.sh — dump comprimido del Postgres del cloud server.
# Cron sugerido (03:00 diario):
#   0 3 * * * /path/to/scripts/backup.sh >> /path/to/backups/cron.log 2>&1

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${REPO_DIR}/backups"
ENV_FILE="${REPO_DIR}/.env"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
STAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT="${BACKUP_DIR}/engram-cloud-${STAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "ERROR: $ENV_FILE no existe" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx 'engram-cloud-postgres'; then
  echo "ERROR: container engram-cloud-postgres no está corriendo" >&2
  exit 1
fi

docker exec engram-cloud-postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --no-owner --clean --if-exists \
  | gzip > "$OUTPUT"

if [[ ! -s "$OUTPUT" ]]; then
  echo "ERROR: backup vacío, abortando" >&2
  rm -f "$OUTPUT"
  exit 1
fi

find "$BACKUP_DIR" -name 'engram-cloud-*.sql.gz' -mtime +"$RETENTION_DAYS" -delete

SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "OK $(date '+%F %T') → engram-cloud-${STAMP}.sql.gz ($SIZE)"
