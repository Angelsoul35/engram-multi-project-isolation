#!/usr/bin/env bash
# install-engram-wrapper.sh — instala un wrapper de `engram` en ~/.local/bin
# que detecta `.engram-isolation` marker files y setea ENGRAM_DATA_DIR
# automáticamente. Esto es NECESARIO cuando se usa el plugin Claude Code
# engram (o cualquier client MCP) que ignora mcpServers override per-project.
#
# Mecanismo:
#   ~/.local/bin/engram (symlink) → engram-wrapper.sh
#   ~/.local/bin/engram-real     → binario engram original
#   engram-wrapper.sh detecta cwd → busca `.engram-isolation` walking up
#       → si marker existe + data dir aislado existe: setea ENGRAM_DATA_DIR
#       → exec engram-real con env actualizado
#
# Idempotente: re-correr no rompe nada, solo verifica que esté en lugar.

set -euo pipefail

BIN_DIR="$HOME/.local/bin"
ENGRAM_BIN="$BIN_DIR/engram"
ENGRAM_REAL="$BIN_DIR/engram-real"
WRAPPER="$BIN_DIR/engram-wrapper.sh"

echo "[install-engram-wrapper] target dir: $BIN_DIR"

mkdir -p "$BIN_DIR"

# ---- Detectar estado actual ----
if [[ -L "$ENGRAM_BIN" ]] && [[ "$(readlink "$ENGRAM_BIN")" == "$WRAPPER" ]] && [[ -x "$ENGRAM_REAL" ]] && [[ -x "$WRAPPER" ]]; then
  echo "[install-engram-wrapper] wrapper ya instalado — verificando integridad..."
elif [[ -f "$ENGRAM_BIN" ]] && [[ ! -L "$ENGRAM_BIN" ]]; then
  echo "[install-engram-wrapper] migrando binary existente a engram-real..."
  mv "$ENGRAM_BIN" "$ENGRAM_REAL"
  chmod +x "$ENGRAM_REAL"
elif [[ ! -f "$ENGRAM_REAL" ]]; then
  echo "ERROR: no encontré ni $ENGRAM_BIN ni $ENGRAM_REAL." >&2
  echo "       Instalá engram primero: https://github.com/gentleman-programming/engram/releases" >&2
  exit 1
fi

# ---- Escribir el wrapper ----
cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# engram wrapper — auto-sets ENGRAM_DATA_DIR from .engram-isolation marker.
#
# Walks up from $PWD looking for `.engram-isolation` marker. If found,
# extracts slug and sets ENGRAM_DATA_DIR=$HOME/.engram-$slug (only if data
# dir exists). Respects ENGRAM_DATA_DIR if already set by caller.
#
# If no marker: ENGRAM_DATA_DIR stays unset → engram uses ~/.engram/ default.
#
# This wrapper is critical because Claude Code engram plugin defines its
# own MCP server config that ignores per-project .claude/settings.local.json
# mcpServers override. The wrapper intercepts ALL invocations regardless
# of source (plugin/CLI/MCP/scripts).

set -euo pipefail

REAL_ENGRAM="$HOME/.local/bin/engram-real"

if [[ -z "${ENGRAM_DATA_DIR:-}" ]]; then
  dir="$PWD"
  while [[ "$dir" != "/" && "$dir" != "" ]]; do
    if [[ -f "$dir/.engram-isolation" ]]; then
      slug=$(grep -oE '^slug:[[:space:]]+[a-z][a-z0-9-]+' "$dir/.engram-isolation" 2>/dev/null | awk '{print $2}')
      if [[ -n "$slug" && -d "$HOME/.engram-$slug" ]]; then
        export ENGRAM_DATA_DIR="$HOME/.engram-$slug"
      fi
      break
    fi
    dir="$(dirname "$dir")"
  done
fi

exec "$REAL_ENGRAM" "$@"
WRAPPER_EOF
chmod +x "$WRAPPER"

# ---- Crear symlink engram → wrapper ----
if [[ -L "$ENGRAM_BIN" ]]; then
  rm -f "$ENGRAM_BIN"
fi
ln -sf "$WRAPPER" "$ENGRAM_BIN"

# ---- Verificar ----
echo
echo "[install-engram-wrapper] estado final:"
ls -la "$ENGRAM_BIN" "$ENGRAM_REAL" "$WRAPPER" 2>&1 | sed 's/^/  /'

echo
echo "[install-engram-wrapper] smoke test (engram version):"
"$ENGRAM_BIN" version 2>&1 | grep -E '^engram' | head -1 | sed 's/^/  /'

echo
echo "==========================================="
echo "  ENGRAM WRAPPER INSTALLED"
echo "==========================================="
echo "  binary real : $ENGRAM_REAL"
echo "  wrapper     : $WRAPPER"
echo "  symlink     : $ENGRAM_BIN → $WRAPPER"
echo
echo "  El wrapper intercepta TODAS las invocaciones de engram (incluyendo"
echo "  el plugin Claude Code MCP) y detecta automáticamente .engram-isolation"
echo "  markers en el cwd."
echo
echo "  Para uninstall:"
echo "    rm $ENGRAM_BIN $WRAPPER"
echo "    mv $ENGRAM_REAL $ENGRAM_BIN"
echo "==========================================="
