#!/usr/bin/env bash
# test-multi-session-isolation.sh — verifica que MCPs concurrentes en
# proyectos distintos NO se confunden de data dir.
#
# Spawna 2 MCP servers en paralelo (cada uno con cwd distinto, distintos
# .engram-isolation markers) y manda JSON-RPC stdio a cada uno. Verifica:
#   - MCP A solo ve project A
#   - MCP B solo ve project B
#   - Concurrencia no causa cross-contamination

set -euo pipefail

SLUG_A="multitest-a"
SLUG_B="multitest-b"
REPO_A="/tmp/multi-iso-a-$$"
REPO_B="/tmp/multi-iso-b-$$"
ENGRAM_BIN="${ENGRAM_BIN:-$HOME/.local/bin/engram}"

# shellcheck disable=SC2064
# (Intencional: expandir las vars AHORA al definir el trap, no en EXIT,
# para que el cleanup conozca los paths aunque las vars se desreferencien.)
trap "rm -rf '$REPO_A' '$REPO_B' '$HOME/.engram-$SLUG_A' '$HOME/.engram-$SLUG_B'" EXIT

echo "=== TEST MULTI-SESSION ISOLATION ==="

# Setup 2 isolated projects
for slug_repo in "$SLUG_A:$REPO_A" "$SLUG_B:$REPO_B"; do
  slug="${slug_repo%:*}"
  repo="${slug_repo##*:}"
  mkdir -p "$repo"
  (cd "$repo" && git init -q)
  cat > "$repo/.engram-isolation" <<EOF
slug: $slug
EOF
  mkdir -p "$HOME/.engram-$slug"
  chmod 700 "$HOME/.engram-$slug"
  # init DB
  ENGRAM_DATA_DIR="$HOME/.engram-$slug" "${ENGRAM_BIN}-real" stats >/dev/null 2>&1 || \
    ENGRAM_DATA_DIR="$HOME/.engram-$slug" "$ENGRAM_BIN" stats >/dev/null 2>&1 || true
  chmod 600 "$HOME/.engram-$slug/engram.db" 2>/dev/null || true
  # save unique obs to each isolated DB
  ENGRAM_DATA_DIR="$HOME/.engram-$slug" "${ENGRAM_BIN}-real" save \
    "marker for $slug" "UNIQUE-CONTENT-FOR-$slug-PROJECT-UNICORN" \
    --type manual --project "$slug" >/dev/null 2>&1 || \
    ENGRAM_DATA_DIR="$HOME/.engram-$slug" "$ENGRAM_BIN" save \
      "marker for $slug" "UNIQUE-CONTENT-FOR-$slug-PROJECT-UNICORN" \
      --type manual --project "$slug" >/dev/null 2>&1
done

# Spawn MCPs CONCURRENTLY and send queries
python3 - "$SLUG_A" "$REPO_A" "$SLUG_B" "$REPO_B" "$ENGRAM_BIN" <<'PYEOF'
import json, subprocess, sys, threading, time

slug_a, repo_a, slug_b, repo_b, engram_bin = sys.argv[1:]

def spawn_and_query(slug, repo, engram_bin, results):
    """Spawn MCP from cwd=repo (wrapper detects marker), query, return results."""
    proc = subprocess.Popen(
        [engram_bin, 'mcp', '--tools=agent'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, cwd=repo,
    )
    def send(req_id, method, params=None):
        msg = {"jsonrpc": "2.0", "id": req_id, "method": method}
        if params: msg["params"] = params
        proc.stdin.write(json.dumps(msg) + '\n')
        proc.stdin.flush()
        return json.loads(proc.stdout.readline())

    def notify(method):
        proc.stdin.write(json.dumps({"jsonrpc":"2.0","method":method}) + '\n')
        proc.stdin.flush()

    try:
        send(1, "initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": f"multi-iso-test-{slug}", "version": "1.0"},
        })
        notify("notifications/initialized")
        # Search for content unique to this slug
        r = send(2, "tools/call", {
            "name": "mem_search",
            "arguments": {"query": "UNICORN", "project": slug}
        })
        text = r.get('result', {}).get('content', [{}])[0].get('text', '')
        try:
            parsed = json.loads(text)
            result_str = str(parsed.get('result', text))
        except:
            result_str = text
        # Search for the OTHER slug's unique content (should be empty)
        other = slug_b if slug == slug_a else slug_a
        r2 = send(3, "tools/call", {
            "name": "mem_search",
            "arguments": {"query": "UNICORN", "project": other}
        })
        text2 = r2.get('result', {}).get('content', [{}])[0].get('text', '')
        try:
            parsed2 = json.loads(text2)
            result_str2 = str(parsed2.get('result', text2))
        except:
            result_str2 = text2

        # Acepta como isolated-correct cualquiera de:
        #   - "No memories" string (engram older returns)
        #   - "unknown_project" error (engram 1.15.10+ returns — más fuerte:
        #     significa que el data dir LITERALMENTE no sabe que el project
        #     existe, ni siquiera como concepto)
        #   - texto corto (<100 chars wrapper metadata)
        cross_empty_or_unknown = (
            'unknown_project' in text2 or
            'No memories' in result_str2 or
            'not found in store' in text2 or
            len(result_str2.strip()) < 100
        )
        results[slug] = {
            'self_finds_unique': f"UNIQUE-CONTENT-FOR-{slug}-PROJECT-UNICORN" in result_str,
            'self_leaks_other': f"UNIQUE-CONTENT-FOR-{other}-PROJECT-UNICORN" in result_str,
            'cross_query_isolated': cross_empty_or_unknown,
        }
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except:
            proc.kill()

results = {}
threads = [
    threading.Thread(target=spawn_and_query, args=(slug_a, repo_a, engram_bin, results)),
    threading.Thread(target=spawn_and_query, args=(slug_b, repo_b, engram_bin, results)),
]
for t in threads: t.start()
for t in threads: t.join()

print(f"=== Concurrent MCP isolation test ===")
all_pass = True
for slug, r in results.items():
    print(f"  [{slug}]")
    print(f"    finds own unique content       : {'PASS' if r['self_finds_unique'] else 'FAIL'}")
    print(f"    NO leak from other project      : {'PASS' if not r['self_leaks_other'] else 'FAIL'}")
    print(f"    cross-project query → isolated : {'PASS' if r['cross_query_isolated'] else 'FAIL'}")
    if not r['self_finds_unique'] or r['self_leaks_other'] or not r['cross_query_isolated']:
        all_pass = False
print(f">>> {'PASS' if all_pass else 'FAIL'}")
sys.exit(0 if all_pass else 1)
PYEOF
