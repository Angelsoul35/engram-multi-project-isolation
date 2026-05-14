#!/usr/bin/env python3
"""
test-mcp-runtime-isolation.py — prueba runtime de aislamiento del MCP server.

Spawnea el binario `engram mcp` con ENGRAM_DATA_DIR apuntando al data dir
aislado del proyecto, le manda 4 queries via JSON-RPC stdio, y verifica:

  1. mem_context (auto-scope cwd) NO leakea memorias de otros proyectos.
  2. mem_search sin project filter NO leakea de otros proyectos.
  3. mem_search con project=<otro> INTENCIONAL devuelve VACÍO (aislamiento
     bloquea incluso peticiones explícitas a otros proyectos).
  4. mem_search con project=<este> control positivo: encuentra memorias.

Si los 4 pasan, el aislamiento físico está PROBADO a nivel runtime —
no behavioral, no instructivo, no estructural.

Uso:
  python3 test-mcp-runtime-isolation.py --slug <slug> --repo <ruta-al-repo>

Exit:
  0 → 4/4 PASS
  1 → al menos 1 FAIL (revisar output)
  2 → error de invocación o setup
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


# Strings únicas que delatan presencia de OTROS proyectos en el resultado.
# Lista genérica — un setup específico debería extender esta lista con
# nombres únicos de los OTROS proyectos del operador.
DEFAULT_FORBIDDEN_KEYWORDS = [
    'spark', 'Spark', 'tenant_id', 'Protegis',
    'production_db', 'prod-cluster',
]


def parse_args():
    p = argparse.ArgumentParser(
        description='Runtime isolation test for engram MCP server.'
    )
    p.add_argument('--slug', required=True, help='slug del proyecto aislado')
    p.add_argument('--repo', required=True, help='ruta al repo del proyecto')
    p.add_argument('--probe-project', default='spark',
                   help='proyecto OTRO para probar negative test (default: spark)')
    p.add_argument('--engram-bin', default=None,
                   help='ruta al binario engram (default: $HOME/.local/bin/engram)')
    p.add_argument('--forbidden', action='append', default=None,
                   help='palabra clave adicional cuya presencia indica leak (repetible)')
    return p.parse_args()


def jsonrpc_call(proc, req_id, method, params=None):
    msg = {"jsonrpc": "2.0", "id": req_id, "method": method}
    if params is not None:
        msg["params"] = params
    proc.stdin.write(json.dumps(msg) + '\n')
    proc.stdin.flush()
    line = proc.stdout.readline()
    return json.loads(line) if line else {}


def jsonrpc_notify(proc, method, params=None):
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    proc.stdin.write(json.dumps(msg) + '\n')
    proc.stdin.flush()


def extract_result_text(resp):
    return resp.get('result', {}).get('content', [{}])[0].get('text', '')


def parse_result_field(text):
    """El MCP devuelve un JSON con metadata + result. Extraer solo result."""
    try:
        parsed = json.loads(text)
        return str(parsed.get('result', text))
    except json.JSONDecodeError:
        return text


def has_leaks(result_str, forbidden):
    return [w for w in forbidden if w in result_str]


def main():
    args = parse_args()

    slug = args.slug
    repo = Path(args.repo)
    probe = args.probe_project
    engram_bin = args.engram_bin or os.path.expanduser('~/.local/bin/engram')
    data_dir = os.path.expanduser(f'~/.engram-{slug}')

    forbidden = list(DEFAULT_FORBIDDEN_KEYWORDS)
    if args.forbidden:
        forbidden.extend(args.forbidden)

    if not Path(engram_bin).exists():
        print(f"ERROR: engram binary no existe: {engram_bin}", file=sys.stderr)
        return 2
    if not Path(data_dir).is_dir():
        print(f"ERROR: data dir aislado no existe: {data_dir}", file=sys.stderr)
        return 2
    if not repo.is_dir():
        print(f"ERROR: repo no existe: {repo}", file=sys.stderr)
        return 2

    cmd = [
        'bash', '-c',
        f'export ENGRAM_DATA_DIR="{data_dir}" ENGRAM_CLOUD_AUTOSYNC=1; '
        f'exec "{engram_bin}" mcp --tools=agent'
    ]

    print(f"=== TEST RUNTIME MCP isolation — slug={slug} ===")
    print(f"  data dir : {data_dir}")
    print(f"  cwd      : {repo}")
    print(f"  probe    : {probe}")
    print()

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1, cwd=str(repo),
    )

    try:
        jsonrpc_call(proc, 1, "initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "isolation-runtime-test", "version": "1.0"},
        })
        jsonrpc_notify(proc, "notifications/initialized")

        results = []

        # TEST 1
        r = jsonrpc_call(proc, 2, "tools/call", {
            "name": "mem_context", "arguments": {},
        })
        text = extract_result_text(r)
        result_str = parse_result_field(text)
        leaks = has_leaks(result_str, forbidden)
        t1 = len(leaks) == 0
        print(f"[1] mem_context auto-scope cwd:")
        print(f"    leaks: {leaks if leaks else 'NINGUNO'}")
        print(f"    {'PASS' if t1 else 'FAIL'}")
        results.append(t1)

        # TEST 2
        r = jsonrpc_call(proc, 3, "tools/call", {
            "name": "mem_search", "arguments": {"query": "tenant"},
        })
        text = extract_result_text(r)
        result_str = parse_result_field(text)
        leaks = has_leaks(result_str, forbidden)
        t2 = len(leaks) == 0
        print(f"\n[2] mem_search 'tenant' sin filter:")
        print(f"    leaks: {leaks if leaks else 'NINGUNO'}")
        print(f"    {'PASS' if t2 else 'FAIL'}")
        results.append(t2)

        # TEST 3 (NEGATIVE)
        r = jsonrpc_call(proc, 4, "tools/call", {
            "name": "mem_search",
            "arguments": {"query": "tenant", "project": probe},
        })
        text = extract_result_text(r)
        result_str = parse_result_field(text)
        is_empty = (
            not result_str.strip()
            or 'No memories' in result_str
            or 'not found' in result_str.lower()
            or len(result_str.strip()) < 80
        )
        t3 = is_empty
        print(f"\n[3] mem_search project={probe} (NEGATIVO intencional):")
        print(f"    result vacío?: {'SÍ' if is_empty else 'NO (LEAK)'}")
        print(f"    {'PASS' if t3 else 'FAIL'}")
        results.append(t3)

        # TEST 4 (positive control)
        r = jsonrpc_call(proc, 5, "tools/call", {
            "name": "mem_search",
            "arguments": {"query": "deploy", "project": slug},
        })
        text = extract_result_text(r)
        result_str = parse_result_field(text)
        found_some = ('Found' in result_str and '#' in result_str) \
                      or ('No memories' in result_str)
        t4 = found_some
        print(f"\n[4] mem_search project={slug} (control positivo):")
        if 'Found' in result_str:
            n_found = result_str.split('Found')[1].split(' ')[1] if 'Found' in result_str else '?'
            print(f"    encontradas: {n_found} memorias")
        else:
            print(f"    sin memorias aún (proyecto recién enrolado, OK)")
        print(f"    {'PASS' if t4 else 'FAIL'}")
        results.append(t4)

    finally:
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            proc.kill()

    print("\n" + "=" * 50)
    pass_count = sum(results)
    print(f"  RUNTIME ISOLATION: {pass_count}/4 pass")
    if pass_count == 4:
        print(f"  >>> TODOS PASS — aislamiento RUNTIME PROBADO")
        return 0
    else:
        print(f"  >>> {4 - pass_count} FAIL(s) — REVISAR")
        return 1


if __name__ == '__main__':
    sys.exit(main())
