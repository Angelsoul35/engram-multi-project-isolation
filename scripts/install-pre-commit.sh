#!/usr/bin/env bash
# install-pre-commit.sh — instala un pre-commit hook en este repo que
# corre los mismos gates que la CI antes de permitir un commit.
#
# Después de esto, cada `git commit` corre automáticamente:
#   - bash -n sobre todos los scripts/*.sh modificados
#   - python3 -m py_compile sobre scripts/*.py modificados
#   - validación de JSON modificados
#   - check de paths personales hardcodeados
#   - shellcheck si está instalado

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: no estás dentro de un repo git" >&2
  exit 1
}

HOOK_FILE="$REPO_ROOT/.git/hooks/pre-commit"

cat > "$HOOK_FILE" << 'EOF'
#!/usr/bin/env bash
# Pre-commit hook generado por install-pre-commit.sh
# NO EDITAR DIRECTAMENTE — re-correr el script de install para regenerar.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

CHANGED=$(git diff --cached --name-only --diff-filter=ACM)
[[ -z "$CHANGED" ]] && exit 0

fail=0

# 1. bash -n sobre .sh modificados
for f in $(echo "$CHANGED" | grep -E '\.sh$' || true); do
  [[ -f "$f" ]] || continue
  bash -n "$f" || { echo "FAIL bash -n: $f" >&2; fail=1; }
done

# 2. py_compile sobre .py modificados
for f in $(echo "$CHANGED" | grep -E '\.py$' || true); do
  [[ -f "$f" ]] || continue
  python3 -m py_compile "$f" || { echo "FAIL py_compile: $f" >&2; fail=1; }
done

# 3. JSON validate
for f in $(echo "$CHANGED" | grep -E '\.json$' || true); do
  [[ -f "$f" ]] || continue
  python3 -c "import json,sys; json.load(open('$f'))" 2>&1 || {
    echo "FAIL json validate: $f" >&2; fail=1
  }
done

# 4. Hardcoded paths personales (skip self-referential meta-scripts).
# Patrón configurable via env HARDCODED_PATTERNS (default detecta /home/<user>
# absolutos no genéricos). Por default solo warnea — los proyectos que
# adopten este toolkit pueden customizar.
PATTERN="${HARDCODED_PATTERNS:-}"
SELF_FILES_REGEX='(install-pre-commit\.sh|\.github/workflows/validate\.yml)$'
if [[ -n "$PATTERN" ]]; then
  for f in $CHANGED; do
    [[ -f "$f" ]] || continue
    echo "$f" | grep -qE "$SELF_FILES_REGEX" && continue
    if grep -qE "$PATTERN" "$f" 2>/dev/null; then
      echo "FAIL paths personales encontrados en: $f" >&2
      grep -nE "$PATTERN" "$f" | sed 's/^/    /' >&2
      fail=1
    fi
  done
fi

# 5. shellcheck si disponible
if command -v shellcheck >/dev/null 2>&1; then
  for f in $(echo "$CHANGED" | grep -E '\.sh$' || true); do
    [[ -f "$f" ]] || continue
    shellcheck -s bash -S warning "$f" || { fail=1; }
  done
fi

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "Pre-commit failed. Fix errores arriba o usa --no-verify para skipear (NO recomendado)." >&2
  exit 1
fi
EOF

chmod +x "$HOOK_FILE"
echo "OK: pre-commit hook instalado en $HOOK_FILE"
echo "    Para detectar paths personales hardcodeados (opcional):"
echo "      export HARDCODED_PATTERNS='/home/yourusername|your-internal-host'"
echo "    Para skipear en una emergencia: git commit --no-verify"
