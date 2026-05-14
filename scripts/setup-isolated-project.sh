#!/usr/bin/env bash
# setup-isolated-project.sh — onboarda un proyecto NUEVO con engram aislado.
#
# Crea un data dir aislado por proyecto (~/.engram-<slug>/) y configura el
# repo del proyecto para que su MCP server use ese data dir vía
# ENGRAM_DATA_DIR. Resultado: el agente IA trabajando en ese repo NO
# PUEDE ver memorias de otros proyectos del operador. Aislamiento físico,
# no behavioral.
#
# Uso:
#   ./setup-isolated-project.sh --slug <slug> --repo <ruta-al-repo> \
#     [--client <cliente-mcp>] [--config-path <ruta>]
#
# Clientes MCP soportados (--client):
#   claude-code  (default)  — escribe a $REPO/.claude/settings.local.json
#   cursor                  — escribe a $REPO/.cursor/mcp.json
#   custom                  — requiere --config-path explícito
#
# Ejemplos:
#   # Default (Claude Code)
#   ./setup-isolated-project.sh --slug myproject --repo ~/projects/myproject
#
#   # Cursor IDE
#   ./setup-isolated-project.sh --slug myproject --repo ~/projects/myproject \
#     --client cursor
#
#   # Custom path para cualquier MCP client compatible
#   ./setup-isolated-project.sh --slug myproject --repo ~/projects/myproject \
#     --client custom --config-path /ruta/al/config.json
#
# Pre-requisitos:
#   - engram CLI v1.15.10+ (https://github.com/gentleman-programming/engram)
#   - ~/.engram/cloud.json poblado (server_url + token)
#   - El slug debe estar en ENGRAM_CLOUD_ALLOWED_PROJECTS del cloud server

set -euo pipefail

# ---- Argumentos ----
SLUG=""
REPO=""
CLIENT="claude-code"
CONFIG_PATH=""

usage() {
  cat <<EOF
Usage: $0 --slug <slug> --repo <ruta> [--client <c>] [--config-path <p>]

Onboarda un proyecto con engram local aislado por ENGRAM_DATA_DIR.

Opciones:
  --slug          nombre del proyecto en engram (lowercase, guiones, 2-64 chars)
  --repo          ruta absoluta al working tree del repo del proyecto
  --client        cliente MCP (default: claude-code).
                  Soportados: claude-code, cursor, custom
  --config-path   solo con --client custom: ruta absoluta al archivo JSON
                  de config MCP a escribir (debe ser relativo al repo)
  -h              este help

Convenciones de paths por cliente:
  claude-code  → \$REPO/.claude/settings.local.json
  cursor       → \$REPO/.cursor/mcp.json
  custom       → \$CONFIG_PATH (provisto)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --client) CLIENT="$2"; shift 2 ;;
    --config-path) CONFIG_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: argumento desconocido: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -z "$SLUG" || -z "$REPO" ]] && { usage; exit 2; }

# ---- Validaciones ----
echo "$SLUG" | grep -qE '^[a-z][a-z0-9-]{1,63}$' || {
  echo "ERROR: slug inválido. Debe matchear ^[a-z][a-z0-9-]{1,63}$" >&2
  exit 1
}

[[ -d "$REPO" ]] || { echo "ERROR: repo no existe: $REPO" >&2; exit 1; }

# Validar cliente + resolver SETTINGS_FILE
case "$CLIENT" in
  claude-code)
    SETTINGS_FILE="$REPO/.claude/settings.local.json"
    SETTINGS_DIR="$REPO/.claude"
    ;;
  cursor)
    SETTINGS_FILE="$REPO/.cursor/mcp.json"
    SETTINGS_DIR="$REPO/.cursor"
    ;;
  custom)
    [[ -z "$CONFIG_PATH" ]] && {
      echo "ERROR: --client custom requiere --config-path <ruta>" >&2
      exit 2
    }
    SETTINGS_FILE="$CONFIG_PATH"
    SETTINGS_DIR="$(dirname "$CONFIG_PATH")"
    ;;
  *)
    echo "ERROR: --client desconocido: $CLIENT (soportados: claude-code, cursor, custom)" >&2
    exit 2
    ;;
esac

# Engram binary
ENGRAM_BIN="${ENGRAM_BIN:-$HOME/.local/bin/engram}"
[[ -x "$ENGRAM_BIN" ]] || { echo "ERROR: engram CLI no encontrado: $ENGRAM_BIN" >&2; exit 1; }

# Versión mínima requerida
MIN_VERSION="1.15.10"
ACTUAL_VERSION=$("$ENGRAM_BIN" version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [[ -z "$ACTUAL_VERSION" ]]; then
  echo "WARNING: no pude detectar versión de engram. Verificá manualmente que sea >= $MIN_VERSION" >&2
else
  IFS=. read -r min_a min_b min_c <<< "$MIN_VERSION"
  IFS=. read -r act_a act_b act_c <<< "$ACTUAL_VERSION"
  if (( act_a < min_a )) || \
     (( act_a == min_a && act_b < min_b )) || \
     (( act_a == min_a && act_b == min_b && act_c < min_c )); then
    echo "ERROR: engram versión $ACTUAL_VERSION es menor a $MIN_VERSION requerida." >&2
    echo "       Actualizá: https://github.com/gentleman-programming/engram/releases" >&2
    exit 1
  fi
fi

# Global cloud config
GLOBAL_CLOUD_JSON="$HOME/.engram/cloud.json"
[[ -f "$GLOBAL_CLOUD_JSON" ]] || {
  echo "ERROR: cloud.json global no existe: $GLOBAL_CLOUD_JSON. Configurá engram cloud primero." >&2
  exit 1
}

# Targets
DATA_DIR="$HOME/.engram-$SLUG"

# ---- Estado previo ----
echo "[setup-isolated-project] slug=$SLUG repo=$REPO client=$CLIENT"
echo "[setup-isolated-project] data_dir=$DATA_DIR"
echo "[setup-isolated-project] settings_file=$SETTINGS_FILE"
echo

if [[ -d "$DATA_DIR" ]]; then
  echo "WARNING: data dir ya existe: $DATA_DIR"
  echo "         Si querés re-inicializar, borralo o usá rollback-isolated.sh primero."
  echo "         Continuando con verificación + re-aplicación de override settings..."
fi

# ---- 1. Crear data dir aislado con perms estrictas ----
echo "[1/6] Creando data dir aislado..."
mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

# ---- 2. Copiar cloud.json al data dir ----
echo "[2/6] Copiando cloud.json + ajustando perms..."
cp "$GLOBAL_CLOUD_JSON" "$DATA_DIR/cloud.json"
chmod 600 "$DATA_DIR/cloud.json"

# ---- 3. Inicializar SQLite del data dir ----
echo "[3/6] Inicializando SQLite vacío..."
ENGRAM_DATA_DIR="$DATA_DIR" "$ENGRAM_BIN" stats >/dev/null 2>&1 || true
[[ -f "$DATA_DIR/engram.db" ]] || { echo "ERROR: engram no creó el DB en $DATA_DIR/engram.db" >&2; exit 1; }
chmod 600 "$DATA_DIR/engram.db"
[[ -f "$DATA_DIR/engram.db-wal" ]] && chmod 600 "$DATA_DIR/engram.db-wal" || true
[[ -f "$DATA_DIR/engram.db-shm" ]] && chmod 600 "$DATA_DIR/engram.db-shm" || true
echo "      OK: $DATA_DIR/engram.db creado (perms 600)"

# ---- 4. Enrolar proyecto en cloud ----
echo "[4/6] Enrolando proyecto en engram cloud..."
ENGRAM_DATA_DIR="$DATA_DIR" "$ENGRAM_BIN" cloud enroll "$SLUG" 2>&1 | head -3 || {
  echo "WARNING: enroll falló. Verificá que '$SLUG' esté en ENGRAM_CLOUD_ALLOWED_PROJECTS del cloud server." >&2
}

# ---- 5. Configurar override mcpServers en el config del cliente MCP ----
echo "[5/6] Configurando override mcpServers ($CLIENT) en $SETTINGS_FILE..."
mkdir -p "$SETTINGS_DIR"

python3 - "$SETTINGS_FILE" "$SLUG" "$CLIENT" <<'PYEOF'
import json, os, sys, pathlib

settings_path, slug, client = sys.argv[1:]

if os.path.exists(settings_path):
    with open(settings_path) as f:
        try:
            cfg = json.load(f)
        except json.JSONDecodeError as e:
            print(f"ERROR: {settings_path} no es JSON válido: {e}", file=sys.stderr)
            sys.exit(1)
else:
    cfg = {}

# permissions.deny mem_stats — defense in depth (mem_stats es global by design).
# Soportado por Claude Code; otros clientes pueden ignorarlo (no rompe).
if client == "claude-code":
    cfg.setdefault("permissions", {})
    cfg["permissions"].setdefault("deny", [])
    deny_target = "mcp__plugin_engram_engram__mem_stats"
    if deny_target not in cfg["permissions"]["deny"]:
        cfg["permissions"]["deny"].append(deny_target)

# mcpServers override — bash -c con $HOME para portabilidad per-PC.
# Schema common entre Claude Code y Cursor (ambos usan mcpServers JSON).
cfg.setdefault("mcpServers", {})
cfg["mcpServers"]["engram"] = {
    "command": "bash",
    "args": [
        "-c",
        f'export ENGRAM_DATA_DIR="$HOME/.engram-{slug}" ENGRAM_CLOUD_AUTOSYNC=1; '
        f'exec "$HOME/.local/bin/engram" mcp --tools=agent'
    ]
}

# Hook SessionStart con sync push+pull + banner de scope.
# Claude Code soporta hooks. Cursor / otros clientes no, así que solo agregar
# para claude-code.
if client == "claude-code":
    cfg.setdefault("hooks", {})
    cfg["hooks"]["SessionStart"] = [{
        "matcher": "startup|resume",
        "hooks": [{
            "type": "command",
            "command": (
                f'ENGRAM_DATA_DIR="$HOME/.engram-{slug}" "$HOME/.local/bin/engram" sync --cloud --project {slug} 2>/dev/null; '
                f'ENGRAM_DATA_DIR="$HOME/.engram-{slug}" "$HOME/.local/bin/engram" sync --cloud --project {slug} --import 2>/dev/null; '
                "printf '\\n==========================================\\n"
                f"PROJECT SCOPE: {slug}\\n"
                "==========================================\\n"
                f"Isolated engram DB: $HOME/.engram-{slug}/\\n"
                "MCP server uses ENGRAM_DATA_DIR override.\\n"
                f"This session can ONLY see {slug}.\\n"
                "==========================================\\n'; true"
            )
        }]
    }]

pathlib.Path(settings_path).write_text(json.dumps(cfg, indent=2) + "\n")
print(f"      OK: {settings_path} actualizado para client={client}")
PYEOF

# ---- 6. Reporte + checklist final ----
echo "[6/6] Reporte final"
echo
echo "==========================================="
echo "  ENGRAM ISOLATED PROJECT — SETUP DONE"
echo "==========================================="
echo "  slug       : $SLUG"
echo "  client MCP : $CLIENT"
echo "  data dir   : $DATA_DIR"
echo "  settings   : $SETTINGS_FILE"
echo
echo "  Verificación:"
ENGRAM_DATA_DIR="$DATA_DIR" "$ENGRAM_BIN" stats 2>&1 | sed 's/^/    /'
echo
echo "  Próximos pasos:"
echo "  1. Si el repo ya tiene memorias en global engram, correr:"
echo "       ./scripts/migrate-to-isolated.sh --slug $SLUG"
echo "  2. Validar 16 checks E2E:"
echo "       ./scripts/validate-isolation.sh --slug $SLUG --repo $REPO --client $CLIENT"
echo "  3. Reabrir tu IDE / cliente MCP en el repo y validar que el server"
echo "     engram arranca con ENGRAM_DATA_DIR=$DATA_DIR."
echo "==========================================="
