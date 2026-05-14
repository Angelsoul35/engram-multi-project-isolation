#!/usr/bin/env bash
# offsite.sh — sube el último backup a destino remoto, cifrado con `age`.
# Cron sugerido (04:00 diario, después de backup.sh):
#   0 4 * * * /path/to/scripts/offsite.sh >> /path/to/backups/cron.log 2>&1
#
# Pre-requisitos:
#   sudo apt install age rclone
#   age-keygen → guardar la KEY privada en password manager corp
#   rclone config → crear remote (S3, GCS, B2, etc.)

set -euo pipefail

# === CONFIG (editar) ===
AGE_RECIPIENT="${AGE_RECIPIENT:-age1examplereplacemewithyourrealrecipient}"
RCLONE_REMOTE="${RCLONE_REMOTE:-engram-backups:engram-cloud-prod}"
# === FIN CONFIG ===

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${REPO_DIR}/backups"

command -v age >/dev/null    || { echo "age no instalado: sudo apt install age"  >&2; exit 1; }
command -v rclone >/dev/null || { echo "rclone no instalado: sudo apt install rclone" >&2; exit 1; }

if [[ "$AGE_RECIPIENT" == age1example* ]]; then
  echo "ERROR: editá AGE_RECIPIENT en el script con tu clave pública real" >&2
  exit 1
fi

LATEST=$(ls -1t "${BACKUP_DIR}"/engram-cloud-*.sql.gz 2>/dev/null | head -1)
if [[ -z "$LATEST" ]]; then
  echo "ERROR: no hay backups en $BACKUP_DIR — corré backup.sh primero" >&2
  exit 1
fi

ENCRYPTED="${LATEST}.age"
BASENAME=$(basename "$ENCRYPTED")

age -r "$AGE_RECIPIENT" -o "$ENCRYPTED" "$LATEST"
rclone copy "$ENCRYPTED" "$RCLONE_REMOTE/" --progress
rm -f "$ENCRYPTED"

echo "OK $(date '+%F %T') → off-site $BASENAME ($RCLONE_REMOTE)"
