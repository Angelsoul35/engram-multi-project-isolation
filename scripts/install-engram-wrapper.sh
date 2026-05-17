#!/usr/bin/env bash
# install-engram-wrapper.sh — instala wrapper de engram con hardening completo.
#
# Garantías:
#   1. Wrapper en POSIX sh (funciona en bash/zsh/fish/dash)
#   2. ~/.local/bin DEBE estar primero en PATH para engram (verifica + warnea)
#   3. NO existen otros binaries `engram` en PATH (verifica + falla si los hay)
#   4. Multi-marker detection: usa el marker MAS CERCANO al cwd (más específico)
#   5. Marker malformado → error claro, no fallback silencioso
#   6. Idempotente, re-correr no rompe nada

set -euo pipefail

BIN_DIR="$HOME/.local/bin"
ENGRAM_BIN="$BIN_DIR/engram"
ENGRAM_REAL="$BIN_DIR/engram-real"
WRAPPER="$BIN_DIR/engram-wrapper.sh"

echo "[install-engram-wrapper] target dir: $BIN_DIR"

mkdir -p "$BIN_DIR"

# ---- Pre-check 1: NO debe haber otros binaries `engram` en PATH ----
echo "[install-engram-wrapper] verificando PATH..."
all_engrams=$(command -v -a engram 2>/dev/null | grep -v "^$BIN_DIR/engram$" || true)
if [[ -n "$all_engrams" ]]; then
  # Permitir si los otros son symlinks que apuntan al wrapper/real conocidos
  # (ej: brew install puso engram en /opt/homebrew/bin pero apunta acá)
  for path in $all_engrams; do
    real=$(readlink -f "$path")
    if [[ "$real" != "$WRAPPER" && "$real" != "$ENGRAM_REAL" ]]; then
      echo "ERROR: otro engram binary detectado en PATH:" >&2
      echo "  $path → $real" >&2
      echo "  Removelo o ajustá PATH para que $BIN_DIR vaya primero." >&2
      exit 1
    fi
  done
fi

# ---- Pre-check 2: ~/.local/bin debe ser PATH-prefix para engram ----
which_engram=$(command -v engram 2>/dev/null || echo "")
if [[ -n "$which_engram" ]] && [[ "$which_engram" != "$ENGRAM_BIN" ]]; then
  echo "WARNING: `engram` actualmente resuelve a $which_engram NO a $ENGRAM_BIN" >&2
  echo "         Agregá '$BIN_DIR' antes en tu PATH:" >&2
  echo "         export PATH=\"$BIN_DIR:\$PATH\"" >&2
  echo "         Continuando, pero verificá después de instalar." >&2
fi

# ---- Detect / migrate existing binary ----
if [[ -L "$ENGRAM_BIN" ]] && [[ "$(readlink "$ENGRAM_BIN")" == "$WRAPPER" ]] && [[ -x "$ENGRAM_REAL" ]] && [[ -x "$WRAPPER" ]]; then
  echo "[install-engram-wrapper] wrapper ya instalado — re-escribiendo (idempotent)"
elif [[ -f "$ENGRAM_BIN" ]] && [[ ! -L "$ENGRAM_BIN" ]]; then
  echo "[install-engram-wrapper] migrando binary existente a engram-real..."
  mv "$ENGRAM_BIN" "$ENGRAM_REAL"
  chmod +x "$ENGRAM_REAL"
elif [[ ! -f "$ENGRAM_REAL" ]]; then
  echo "ERROR: no encontré ni $ENGRAM_BIN ni $ENGRAM_REAL." >&2
  echo "       Instalá engram primero: https://github.com/gentleman-programming/engram/releases" >&2
  exit 1
fi

# ---- Escribir el wrapper (POSIX sh para máxima compat) ----
cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/bin/sh
# engram wrapper — POSIX sh para portabilidad shells (bash/zsh/fish/dash/ash).
# Auto-sets ENGRAM_DATA_DIR desde .engram-isolation marker walking up cwd.
# Si marker existe + data dir existe: setea env y exec engram-real.
# Si marker malformado: error claro, exit !=0.
# Si no hay marker: pasa-through al engram-real sin tocar env (default global).
# Multi-marker: usa el MAS CERCANO (más específico) al cwd actual.

set -eu

REAL_ENGRAM="$HOME/.local/bin/engram-real"

if [ ! -x "$REAL_ENGRAM" ]; then
    echo "ERROR engram-wrapper: $REAL_ENGRAM no existe o no es ejecutable" >&2
    exit 127
fi

# Respeta ENGRAM_DATA_DIR si caller lo seteó explícitamente
if [ -z "${ENGRAM_DATA_DIR:-}" ]; then
    dir="$PWD"
    while [ "$dir" != "/" ] && [ -n "$dir" ]; do
        if [ -f "$dir/.engram-isolation" ]; then
            slug=$(grep -E '^slug:[[:space:]]+[a-z][a-z0-9-]+' "$dir/.engram-isolation" 2>/dev/null | head -1 | awk '{print $2}')
            if [ -z "$slug" ]; then
                echo "ERROR engram-wrapper: marker $dir/.engram-isolation malformado (no encuentro 'slug: <name>')" >&2
                exit 2
            fi
            data_dir="$HOME/.engram-$slug"
            if [ ! -d "$data_dir" ]; then
                echo "ERROR engram-wrapper: marker dice slug=$slug pero $data_dir no existe" >&2
                echo "       Correr setup-isolated-project.sh para crearlo." >&2
                exit 3
            fi
            ENGRAM_DATA_DIR="$data_dir"
            export ENGRAM_DATA_DIR
            break
        fi
        dir=$(dirname "$dir")
    done
fi

exec "$REAL_ENGRAM" "$@"
WRAPPER_EOF
chmod +x "$WRAPPER"

# ---- Symlink engram → wrapper ----
if [[ -L "$ENGRAM_BIN" ]]; then
  rm -f "$ENGRAM_BIN"
fi
ln -sf "$WRAPPER" "$ENGRAM_BIN"

# ---- Smoke test ----
echo
echo "[install-engram-wrapper] smoke test:"
"$ENGRAM_BIN" version 2>&1 | head -1 | sed 's/^/  /'

# ---- Verificar PATH resolution post-install ----
resolved=$(command -v engram 2>/dev/null || echo "")
if [[ "$resolved" != "$ENGRAM_BIN" ]]; then
  echo "::error::PATH resolution post-install incorrecta: $resolved (esperado: $ENGRAM_BIN)" >&2
  echo "  Agregá '$BIN_DIR' al PRINCIPIO de tu PATH." >&2
  exit 1
fi

echo
echo "==========================================="
echo "  ENGRAM WRAPPER INSTALLED + VERIFIED"
echo "==========================================="
echo "  binary real : $ENGRAM_REAL"
echo "  wrapper     : $WRAPPER  (POSIX sh)"
echo "  symlink     : $ENGRAM_BIN → $WRAPPER"
echo "  PATH check  : engram resuelve a $resolved ✓"
echo "==========================================="
