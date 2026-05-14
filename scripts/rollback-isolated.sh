#!/usr/bin/env bash
# rollback-isolated.sh — revierte el setup aislado de un proyecto.
#
# - Mata procesos engram mcp con ENGRAM_DATA_DIR del slug.
# - Borra ~/.engram-<slug>/.
# - Quita el override mcpServers.engram del .claude/settings.local.json.
# - Opcionalmente restaura el global desde un backup específico.
#
# Uso:
#   ./rollback-isolated.sh --slug <slug> [--repo <ruta>] [--backup <archivo>]

set -euo pipefail

SLUG=""
REPO=""
BACKUP=""

usage() {
  cat <<EOF
Usage: $0 --slug <slug> [--repo <ruta-al-repo>] [--backup <archivo.db>]

Revierte el setup aislado del proyecto <slug>.

Opciones:
  --slug    nombre del proyecto a revertir
  --repo    ruta al repo (para limpiar settings.local.json). Opcional.
  --backup  ruta a un backup específico para restaurar el global. Opcional.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --backup) BACKUP="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: argumento desconocido: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -z "$SLUG" ]] && { usage; exit 2; }
echo "$SLUG" | grep -qE '^[a-z][a-z0-9-]{1,63}$' || { echo "ERROR: slug inválido" >&2; exit 1; }

DATA_DIR="$HOME/.engram-$SLUG"
GLOBAL_DB="$HOME/.engram/engram.db"

echo "[rollback-isolated] slug=$SLUG"
echo

read -r -p "ATENCIÓN: esto borrará $DATA_DIR. ¿Continuar? [y/N] " resp
[[ "$resp" =~ ^[Yy]$ ]] || { echo "Abortado."; exit 0; }

# 1. Matar procesos engram mcp con ENGRAM_DATA_DIR=DATA_DIR
echo "[1/4] Matando procesos engram mcp con ENGRAM_DATA_DIR=$DATA_DIR..."
pgrep -af "engram mcp" | grep -F "$DATA_DIR" | awk '{print $1}' | xargs -r kill 2>/dev/null || true

# 2. Borrar data dir
echo "[2/4] Borrando $DATA_DIR..."
if [[ -d "$DATA_DIR" ]]; then
  rm -rf "$DATA_DIR"
  echo "      OK"
else
  echo "      WARNING: $DATA_DIR no existe (ya borrado?)"
fi

# 3. Limpiar override del repo si --repo
if [[ -n "$REPO" ]]; then
  SETTINGS_FILE="$REPO/.claude/settings.local.json"
  if [[ -f "$SETTINGS_FILE" ]]; then
    echo "[3/4] Limpiando mcpServers.engram override de $SETTINGS_FILE..."
    python3 - "$SETTINGS_FILE" <<'PYEOF'
import json, sys, pathlib
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

changed = False
if "mcpServers" in cfg and "engram" in cfg["mcpServers"]:
    del cfg["mcpServers"]["engram"]
    if not cfg["mcpServers"]:
        del cfg["mcpServers"]
    changed = True

if "hooks" in cfg and "SessionStart" in cfg["hooks"]:
    cfg["hooks"]["SessionStart"] = [
        e for e in cfg["hooks"]["SessionStart"]
        if not any("engram" in h.get("command", "") for h in e.get("hooks", []))
    ]
    if not cfg["hooks"]["SessionStart"]:
        del cfg["hooks"]["SessionStart"]
    if not cfg["hooks"]:
        del cfg["hooks"]
    changed = True

if changed:
    pathlib.Path(path).write_text(json.dumps(cfg, indent=2) + "\n")
    print(f"      OK: limpiado")
else:
    print(f"      WARNING: nada que limpiar en {path}")
PYEOF
  else
    echo "[3/4] $SETTINGS_FILE no existe — skip"
  fi
else
  echo "[3/4] --repo no especificado — skip cleanup settings.local.json"
fi

# 4. Restaurar global desde backup (opcional)
if [[ -n "$BACKUP" ]]; then
  [[ -f "$BACKUP" ]] || { echo "ERROR: backup no existe: $BACKUP" >&2; exit 1; }
  echo "[4/4] Restaurando global desde backup..."
  read -r -p "  Reemplazar $GLOBAL_DB con $BACKUP? [y/N] " resp2
  if [[ "$resp2" =~ ^[Yy]$ ]]; then
    cp "$GLOBAL_DB" "${GLOBAL_DB}.pre-rollback-$(date +%Y%m%d-%H%M%S)"
    cp "$BACKUP" "$GLOBAL_DB"
    rm -f "${GLOBAL_DB}-shm" "${GLOBAL_DB}-wal"
    echo "      OK: restaurado"
  else
    echo "      Abortado restore"
  fi
else
  echo "[4/4] --backup no especificado — global queda como está"
fi

echo
echo "==========================================="
echo "  ROLLBACK ISOLATED — DONE"
echo "==========================================="
echo "  slug: $SLUG"
echo "  El proyecto vuelve a usar engram global ~/.engram/."
echo "==========================================="
