#!/usr/bin/env bash
# validate-isolation.sh — verifica E2E que un proyecto está aislado
# correctamente en su propio engram local con MCP override.
#
# Devuelve exit 0 si los 16 checks pasan. Exit != 0 si algún FAIL.
#
# Uso:
#   ./validate-isolation.sh --slug <slug> --repo <ruta> [--client <c>] [--config-path <p>]

set -euo pipefail

SLUG=""
REPO=""
CLIENT="claude-code"
CONFIG_PATH=""

usage() {
  cat <<EOF
Usage: $0 --slug <slug> --repo <ruta> [--client <c>] [--config-path <p>]

Verifica E2E (16 checks) que el proyecto <slug> está correctamente aislado:
  - 8 checks estructurales (perms, JSON, schema)
  - 7 checks funcionales (engram CLI con/sin override)
  - 1 check runtime (spawn MCP server real + JSON-RPC stdio)

--client soportados: claude-code (default), cursor, custom (con --config-path)
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

# CRITICAL: computar SCRIPT_DIR al principio, ANTES de cualquier cd
# (algunos checks hacen 'cd $REPO' que cambia el cwd del script).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolver SETTINGS_FILE según client
case "$CLIENT" in
  claude-code) SETTINGS_FILE="$REPO/.claude/settings.local.json" ;;
  cursor)      SETTINGS_FILE="$REPO/.cursor/mcp.json" ;;
  custom)
    [[ -z "$CONFIG_PATH" ]] && { echo "ERROR: --client custom requiere --config-path" >&2; exit 2; }
    SETTINGS_FILE="$CONFIG_PATH"
    ;;
  *) echo "ERROR: --client desconocido: $CLIENT" >&2; exit 2 ;;
esac

DATA_DIR="$HOME/.engram-$SLUG"
ENGRAM_BIN="${ENGRAM_BIN:-$HOME/.local/bin/engram}"
# Para tests "control" (que necesitan el GLOBAL engram, no el isolated),
# preferir engram-real bypassing el wrapper. Si no existe (toolkit corre
# en PC sin wrapper instalado todavía), fallback al wrapper.
if [[ -x "$HOME/.local/bin/engram-real" ]]; then
  ENGRAM_BIN_GLOBAL="$HOME/.local/bin/engram-real"
else
  ENGRAM_BIN_GLOBAL="$ENGRAM_BIN"
fi

PASS=0
FAIL=0

check() {
  local name="$1"
  local cmd="$2"
  printf "  [%s] %s ... " "$((PASS+FAIL+1))" "$name"
  set +e
  eval "$cmd" >/dev/null 2>&1
  local rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    printf "\e[32mOK\e[0m\n"
    PASS=$((PASS+1))
  else
    printf "\e[31mFAIL\e[0m\n"
    FAIL=$((FAIL+1))
    set +e
    local diag
    diag=$(eval "$cmd" 2>&1)
    set -e
    if [[ -n "$diag" ]]; then
      printf '%s\n' "$diag" | sed 's/^/         /'
    fi
  fi
  return 0
}

echo "===================================="
echo "  VALIDATE ISOLATION — slug=$SLUG client=$CLIENT"
echo "===================================="

# ---- Estructurales (1-8) ----

check "data dir existe con perms 700" "
  test -d '$DATA_DIR' && test \$(stat -c '%a' '$DATA_DIR') = '700'
"

check "cloud.json existe con perms 600" "
  test -f '$DATA_DIR/cloud.json' && test \$(stat -c '%a' '$DATA_DIR/cloud.json') = '600'
"

check "SQLite contiene SOLO project='$SLUG'" "
  python3 -c \"
import sqlite3, sys
c = sqlite3.connect('$DATA_DIR/engram.db')
projs = [r[0] for r in c.execute('SELECT DISTINCT project FROM observations')]
sys.exit(0 if all(p == '$SLUG' for p in projs) else 1)
\"
"

check "settings file ($CLIENT) tiene mcpServers.engram apuntando al data dir" "
  python3 -c \"
import json, sys
with open('$SETTINGS_FILE') as f: cfg = json.load(f)
mcp = cfg.get('mcpServers', {}).get('engram', {})
slug = '$SLUG'
data_dir = '$DATA_DIR'
home_form = '\\\$HOME/.engram-' + slug
env_ds = mcp.get('env', {}).get('ENGRAM_DATA_DIR', '')
if env_ds == data_dir:
    sys.exit(0)
joined = ' '.join([mcp.get('command','')] + mcp.get('args', []))
if 'ENGRAM_DATA_DIR' in joined and (data_dir in joined or home_form in joined):
    sys.exit(0)
print(f'mcpServers.engram no apunta al data dir. mcp={mcp}', file=sys.stderr)
sys.exit(1)
\"
"

check "engram stats con ENGRAM_DATA_DIR aislado reporta solo $SLUG" "
  ENGRAM_DATA_DIR='$DATA_DIR' '$ENGRAM_BIN' stats 2>&1 | grep -qE 'Projects:\s+$SLUG\$'
"

check "cloud sync --status no falla" "
  ENGRAM_DATA_DIR='$DATA_DIR' '$ENGRAM_BIN' sync --status 2>&1 | head -10 >/dev/null
"

check "permissions.deny mem_stats (claude-code) o ausente (otros clientes)" "
  python3 -c \"
import json, sys
with open('$SETTINGS_FILE') as f: cfg = json.load(f)
deny = cfg.get('permissions', {}).get('deny', [])
client = '$CLIENT'
if client == 'claude-code':
    sys.exit(0 if 'mcp__plugin_engram_engram__mem_stats' in deny else 1)
else:
    sys.exit(0)
\"
"

check "hook SessionStart (claude-code) o ausente (otros)" "
  python3 -c \"
import json, sys
with open('$SETTINGS_FILE') as f: cfg = json.load(f)
hooks = cfg.get('hooks', {}).get('SessionStart', [])
slug = '$SLUG'
data_dir = '$DATA_DIR'
home_form = '\\\$HOME/.engram-' + slug
client = '$CLIENT'
if client == 'claude-code':
    ok = any(
      (data_dir in h.get('command', '') or home_form in h.get('command', '')) and slug in h.get('command', '')
      for entry in hooks for h in entry.get('hooks', [])
    )
    sys.exit(0 if ok else 1)
else:
    sys.exit(0)
\"
"

# ---- Funcionales (9-15) ----
echo
echo "  --- Functional checks (read-only) ---"

GLOBAL_DB="$HOME/.engram/engram.db"
OTHER_PROJECT=""
if [[ -f "$GLOBAL_DB" ]]; then
  OTHER_PROJECT=$(python3 -c "
import sqlite3
c = sqlite3.connect('$GLOBAL_DB')
for r in c.execute(\"\"\"
    SELECT project, COUNT(*) FROM observations
    WHERE project != '$SLUG' AND project IS NOT NULL
      AND project = LOWER(project) AND project NOT IN ('/', '$SLUG')
    GROUP BY project ORDER BY COUNT(*) DESC LIMIT 1
\"\"\"):
    print(r[0]); break
else:
    for r in c.execute(\"\"\"
        SELECT project, COUNT(*) FROM observations
        WHERE project != '$SLUG' AND project IS NOT NULL
        GROUP BY project ORDER BY COUNT(*) DESC LIMIT 1
    \"\"\"):
        print(r[0])
" 2>/dev/null || echo "")
fi

if [[ -z "$OTHER_PROJECT" ]]; then
  echo "  [skip] no hay otro proyecto en global para validar negative test"
else
  echo "  [info] Otro proyecto detectado en global para prueba negativa: '$OTHER_PROJECT'"

  check "[funcional] '$OTHER_PROJECT' SÍ existe en global engram (sanity)" "
    python3 -c \"
import sqlite3, sys
c = sqlite3.connect('$GLOBAL_DB')
n = c.execute(\\\"SELECT COUNT(*) FROM observations WHERE project='$OTHER_PROJECT'\\\").fetchone()[0]
sys.exit(0 if n > 0 else 1)
\"
  "

  check "[funcional] '$OTHER_PROJECT' NO existe en isolated DB" "
    python3 -c \"
import sqlite3, sys
c = sqlite3.connect('$DATA_DIR/engram.db')
n = c.execute(\\\"SELECT COUNT(*) FROM observations WHERE project='$OTHER_PROJECT'\\\").fetchone()[0]
sys.exit(0 if n == 0 else 1)
\"
  "

  check "[funcional] engram projects list aislado NO lista '$OTHER_PROJECT'" "
    out=\$(ENGRAM_DATA_DIR='$DATA_DIR' '$ENGRAM_BIN' projects list 2>&1 || true)
    ! echo \"\$out\" | grep -qE '(^| )$OTHER_PROJECT( |\$)'
  "

  check "[funcional] engram projects list global SÍ lista '$OTHER_PROJECT' (control)" "
    out=\$(ENGRAM_DATA_DIR='$HOME/.engram' '$ENGRAM_BIN_GLOBAL' projects list 2>&1 || true)
    echo \"\$out\" | grep -qE '(^| )$OTHER_PROJECT( |\$)'
  "

  check "[funcional] engram projects list aislado solo muestra '$SLUG'" "
    out=\$(ENGRAM_DATA_DIR='$DATA_DIR' '$ENGRAM_BIN' projects list 2>&1 || true)
    projects=\$(echo \"\$out\" | awk '/^[[:space:]]+[a-zA-Z0-9_-]+[[:space:]]+[0-9]+ obs/ {print \$1}' | sort -u)
    n=\$(echo \"\$projects\" | grep -c . || echo 0)
    test \"\$n\" -eq 1 && test \"\$projects\" = '$SLUG'
  "
fi

check "[funcional] engram stats aislado lista únicamente '$SLUG'" "
  proj=\$(ENGRAM_DATA_DIR='$DATA_DIR' '$ENGRAM_BIN' stats 2>&1 | grep -oE 'Projects:.*' | sed 's/Projects:[ ]*//')
  test \"\$proj\" = '$SLUG'
"

check "[funcional] cloud.json del data dir tiene token (no vacío)" "
  python3 -c \"
import json, sys
with open('$DATA_DIR/cloud.json') as f: cfg = json.load(f)
sys.exit(0 if cfg.get('token') and len(cfg['token']) >= 16 else 1)
\"
"

# ---- Wrapper checks (necesarios cuando hay plugin Claude Code engram) ----
echo
echo "  --- Wrapper checks (defense vs plugin precedence) ---"

check "[wrapper] engram wrapper instalado en ~/.local/bin/engram" "
  test -L '$HOME/.local/bin/engram' && \
  test \"\$(readlink '$HOME/.local/bin/engram')\" = '$HOME/.local/bin/engram-wrapper.sh' && \
  test -x '$HOME/.local/bin/engram-real'
"

check "[wrapper] marker file '.engram-isolation' existe en repo con slug correcto" "
  test -f '$REPO/.engram-isolation' && \
  grep -qE '^slug:[[:space:]]+$SLUG\$' '$REPO/.engram-isolation'
"

check "[wrapper] invocar engram sin env desde cwd=repo apunta al isolated DB" "
  db=\$( ( cd '$REPO' && unset ENGRAM_DATA_DIR && '$HOME/.local/bin/engram' stats 2>&1 ) | grep -oE 'Database:.*' | awk '{print \$2}')
  test \"\$db\" = '$DATA_DIR/engram.db'
"

# ---- Runtime check (spawn MCP + JSON-RPC) ----
echo
echo "  --- Runtime check (spawn MCP + JSON-RPC test) ---"
RUNTIME_TEST="$SCRIPT_DIR/test-mcp-runtime-isolation.py"
if [[ -f "$RUNTIME_TEST" ]]; then
  # Pasar --probe-project con el OTHER_PROJECT auto-detectado si existe,
  # asegurando que probe ≠ slug (sino el test 3 sería inválido).
  PROBE="$OTHER_PROJECT"
  if [[ -z "$PROBE" || "$PROBE" == "$SLUG" ]]; then
    PROBE="nonexistent-leak-probe-xyz123"
  fi
  check "[runtime] MCP server con override no leakea cross-project (probe=$PROBE)" "
    python3 '$RUNTIME_TEST' --slug '$SLUG' --repo '$REPO' --probe-project '$PROBE' >/dev/null 2>&1
  "
else
  echo "  [skip] $RUNTIME_TEST no existe — runtime test omitido"
fi

# ---- CRITICAL — Plugin path check ----
# Spawn engram mcp SIN env vars (como hace el plugin), via wrapper.
# Verifica que el wrapper intercepta y aísla aunque el invocador no pase env.
echo
echo "  --- Plugin path check (simula plugin Claude Code engram) ---"
if [[ -f "$RUNTIME_TEST" ]]; then
  check "[plugin-path] engram mcp SIN env vars desde repo cwd → isolated DB" "
    unset ENGRAM_DATA_DIR
    python3 '$RUNTIME_TEST' --slug '$SLUG' --repo '$REPO' --probe-project '${PROBE:-nonexistent-leak-probe-xyz123}' --engram-bin '$HOME/.local/bin/engram' >/dev/null 2>&1
  "
fi

echo
echo "===================================="
echo "  RESULT: $PASS pass, $FAIL fail"
echo "===================================="

if [[ "$FAIL" -gt 0 ]]; then
  echo "FAIL — aislamiento NO verificado. Revisar los checks fallidos." >&2
  exit 1
fi

echo "OK — aislamiento verificado."
exit 0
