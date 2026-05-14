#!/usr/bin/env bash
# migrate-to-isolated.sh — migra observations de un proyecto desde el global
# ~/.engram/engram.db al data dir aislado ~/.engram-<slug>/.
#
# SAFE: el global NO se modifica. Solo se filtra el contenido del DB
# aislado para dejar SOLO el proyecto target. Verifica MD5 del global
# pre/post para garantizar integridad.
#
# Uso:
#   ./migrate-to-isolated.sh --slug <slug>

set -euo pipefail

SLUG=""

usage() {
  cat <<EOF
Usage: $0 --slug <slug>

Migra observations del proyecto <slug> desde el global engram (~/.engram/)
al data dir aislado (~/.engram-<slug>/). El global queda INTACTO (verificado
por MD5 pre/post).

Pre-requisitos:
  - setup-isolated-project.sh ya ejecutado para este slug.
  - El proyecto tiene observations en el global (sino, no hay nada que
    migrar — el script avisa y continúa).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: argumento desconocido: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -z "$SLUG" ]] && { usage; exit 2; }
echo "$SLUG" | grep -qE '^[a-z][a-z0-9-]{1,63}$' || { echo "ERROR: slug inválido" >&2; exit 1; }

GLOBAL_DB="$HOME/.engram/engram.db"
DATA_DIR="$HOME/.engram-$SLUG"
ISOLATED_DB="$DATA_DIR/engram.db"
BACKUP_DIR="$HOME/.engram/.backups"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${SLUG}-pre-migration-${STAMP}.db"

[[ -f "$GLOBAL_DB" ]] || { echo "ERROR: global DB no existe: $GLOBAL_DB" >&2; exit 1; }
[[ -d "$DATA_DIR" ]] || { echo "ERROR: data dir aislado no existe: $DATA_DIR. Correr setup-isolated-project.sh primero." >&2; exit 1; }

# ---- 1. Backup atómico del global ----
echo "[1/5] Backup atómico del global..."
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
python3 - "$GLOBAL_DB" "$BACKUP_FILE" <<'PYEOF'
import sqlite3, sys
src, dst = sys.argv[1:]
s = sqlite3.connect(src)
d = sqlite3.connect(dst)
s.backup(d)
s.close()
d.close()
PYEOF
echo "      OK: backup en $BACKUP_FILE"

GLOBAL_MD5_BEFORE=$(md5sum "$GLOBAL_DB" | cut -d' ' -f1)

# ---- 2. Verificar obs del slug en el global ----
echo "[2/5] Verificando observations de $SLUG en global..."
COUNT_GLOBAL=$(python3 -c "
import sqlite3
c = sqlite3.connect('$GLOBAL_DB')
print(c.execute(\"SELECT COUNT(*) FROM observations WHERE project='$SLUG'\").fetchone()[0])
")
echo "      Observations en global con project='$SLUG': $COUNT_GLOBAL"

if [[ "$COUNT_GLOBAL" == "0" ]]; then
  echo "WARNING: 0 observations para '$SLUG' en global. Nada que migrar."
  echo "         Esto puede ser correcto si el proyecto es nuevo. Continuando."
fi

# ---- 3. Reemplazar el aislado con backup completo + filtrar al slug ----
echo "[3/5] Migrando data al aislado (backup + filtrar)..."

if [[ -f "$ISOLATED_DB" ]]; then
  ISO_BACKUP="$BACKUP_DIR/${SLUG}-isolated-pre-overwrite-${STAMP}.db"
  cp "$ISOLATED_DB" "$ISO_BACKUP"
  echo "      Backup del aislado existente: $ISO_BACKUP"
fi

python3 - "$GLOBAL_DB" "$ISOLATED_DB" "$SLUG" <<'PYEOF'
import sqlite3, sys

global_db, isolated_db, slug = sys.argv[1:]

src = sqlite3.connect(global_db)
dst = sqlite3.connect(isolated_db)
src.backup(dst)
src.close()

TABLES = ['observations', 'sessions', 'sync_mutations', 'sync_enrolled_projects']
for t in TABLES:
    cur = dst.execute(f"DELETE FROM {t} WHERE project IS NULL OR project != ?", (slug,))
    print(f"      {t}: borradas {cur.rowcount} filas (no eran del slug)")

dst.commit()
dst.execute("VACUUM")

print()
print("      Estado final del DB aislado:")
for r in dst.execute("SELECT project, COUNT(*) FROM observations GROUP BY project"):
    print(f"        {r[0]}: {r[1]}")
total_obs = dst.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
total_sess = dst.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
total_mut = dst.execute("SELECT COUNT(*) FROM sync_mutations").fetchone()[0]
print(f"        TOTAL: obs={total_obs} sessions={total_sess} mutations={total_mut}")

projects = [r[0] for r in dst.execute("SELECT DISTINCT project FROM observations")]
assert all(p == slug for p in projects), f"FALLO ISOLATION: projects detectados {projects}"
dst.close()
print()
print(f"      ASSERT OK: aislado contiene SOLO project='{slug}'")
PYEOF

# ---- 4. Validar integridad del global ----
echo "[4/5] Validando integridad del global (NO modificado)..."
GLOBAL_MD5_AFTER=$(md5sum "$GLOBAL_DB" | cut -d' ' -f1)

if [[ "$GLOBAL_MD5_BEFORE" != "$GLOBAL_MD5_AFTER" ]]; then
  echo "ERROR: el global ~/.engram/engram.db cambió durante la migración!" >&2
  echo "       MD5 antes: $GLOBAL_MD5_BEFORE" >&2
  echo "       MD5 después: $GLOBAL_MD5_AFTER" >&2
  echo "       Restaurar manualmente desde: $BACKUP_FILE" >&2
  exit 2
fi
echo "      OK: global intacto (md5 $GLOBAL_MD5_BEFORE)"

# ---- 5. Sync push al cloud ----
echo "[5/5] Push al cloud (sync)..."
ENGRAM_BIN="${ENGRAM_BIN:-$HOME/.local/bin/engram}"
ENGRAM_DATA_DIR="$DATA_DIR" "$ENGRAM_BIN" sync --cloud --project "$SLUG" 2>&1 | sed 's/^/      /'

echo
echo "==========================================="
echo "  MIGRACIÓN A AISLADO — DONE"
echo "==========================================="
echo "  slug          : $SLUG"
echo "  data dir      : $DATA_DIR"
echo "  global DB     : $GLOBAL_DB (intacto, md5 verificado)"
echo "  backup pre    : $BACKUP_FILE"
echo
echo "  Validar end-to-end:"
echo "     ./scripts/validate-isolation.sh --slug $SLUG --repo /ruta/repo"
echo
echo "  Rollback (si algo salió mal):"
echo "     ./scripts/rollback-isolated.sh --slug $SLUG"
echo "==========================================="
