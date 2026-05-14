# Arquitectura completa

Documento de referencia técnica. Para guía operativa práctica ver
[`OPERATIONAL-CHECKLIST.md`](OPERATIONAL-CHECKLIST.md).

## Vista 30,000 pies

```
┌───────────────────────────────────────────────────────────────────┐
│  SERVIDOR CLOUD — engram cloud (Ubuntu + Docker)                  │
│                                                                   │
│   ┌────────────────┐  bridge interno  ┌──────────────────────┐   │
│   │  Postgres 16   │◄─────────────────│  engram cloud (Go)   │   │
│   │  (volumen)     │                  │  bind 127.0.0.1:18080│   │
│   └────────────────┘                  └──────────┬───────────┘   │
│                                                  │               │
│   ┌────────────────────────────────────┐         │               │
│   │  Tailscale serve (HTTPS, *.ts.net) │◄────────┘               │
│   └────────────────┬───────────────────┘                         │
└─────────────────────┼─────────────────────────────────────────────┘
                      │  tailnet (cifrado WireGuard, zero-trust)
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│  CADA PC DE DEV — N data dirs aislados                          │
│                                                                 │
│    sesión del agente IA abierta en /repo/myproject/              │
│              │                                                  │
│              │ spawn MCP via .claude/settings.local.json:       │
│              │   "command":"bash" "args":["-c",                 │
│              │    "ENGRAM_DATA_DIR=$HOME/.engram-myproject      │
│              │     engram mcp"]                                 │
│              ▼                                                  │
│    engram MCP server (per-session)                              │
│      reads/writes ~/.engram-myproject/engram.db                 │
│      syncs via cloud.json en el mismo data dir                  │
│              │                                                  │
│              ▼                                                  │
│    ~/.engram-myproject/        ~/.engram-anotherproject/        │
│    (proyecto X, AISLADO)       (proyecto Y, AISLADO)            │
└─────────────────────────────────────────────────────────────────┘
```

## Tres piezas, tres responsabilidades

### 1. Cloud server (`engram` + Postgres + Tailscale serve)

- Almacena observations de TODOS los proyectos en una BD Postgres.
- Expone API HTTPS via Tailscale (no público, no LAN).
- Allowlist de proyectos (`ENGRAM_CLOUD_ALLOWED_PROJECTS`) controla
  qué slugs pueden sincronizar.
- Auth: bearer token compartido para 2-5 devs (escalar a multi-token o
  reverse proxy con SSO si pasa de 5 — ver `PRODUCTION-DEPLOY.md`).

### 2. Cliente local por proyecto (`~/.engram-<slug>/`)

- SQLite local que contiene SOLO observations del slug.
- `cloud.json` con `server_url` + `token` para sincronizar a cloud.
- Aislado físicamente de otros `~/.engram-<otroslug>/`.
- Schema 100% compatible con `engram` CLI v1.15.10+.

### 3. El IDE / cliente MCP en el repo del proyecto

- Lee `.claude/settings.local.json` del repo al arrancar.
- Spawn MCP server con `command:"bash"` + `args:["-c","ENGRAM_DATA_DIR=$HOME/.engram-<slug> ..."]`.
- El bash expande `$HOME` a runtime → portable per-PC.
- Hook SessionStart ejecuta sync push+pull antes del primer mensaje.

## Defense in depth — 8 capas

Para que un agente NO pueda ver memorias de proyectos no-suyos:

1. **DATA**: SQLite físicamente separado por slug. Si esta capa fallara
   sola (ej: bug en `engram` que ignore `ENGRAM_DATA_DIR`),
   tendríamos las capas 2-8 abajo.

2. **PERMISSION**: `.claude/settings.local.json` deny lista
   `mcp__plugin_engram_engram__mem_stats` (que es global by design del
   binario). Bloqueado a nivel harness del IDE.

3. **INSTRUCCIÓN**: bloque "AISLAMIENTO ESTRICTO" al principio de
   `CLAUDE.md` del repo con reglas no-negociables. El agente lo lee al
   arrancar.

4. **BANNER**: hook SessionStart imprime `PROJECT SCOPE: <slug>` con
   las reglas, refuerza al agente justo antes del primer mensaje.

5. **VALIDATE SCRIPT**: `scripts/validate-isolation.sh` con 16 checks
   (estructura + funcional + runtime via JSON-RPC). Reproducible.

6. **VERSION PIN**: `setup-isolated-project.sh` exige `engram` CLI
   >= 1.15.10. Si una versión futura rompe `ENGRAM_DATA_DIR`, el setup
   falla con mensaje claro antes de configurar mal.

7. **CI/CD**: `.github/workflows/validate.yml` gatea cada push/PR con
   4 jobs (syntax, shellcheck, no-personal-paths, shebang-set-euo).

8. **PRE-COMMIT**: `scripts/install-pre-commit.sh` instala un hook
   local que replica los gates de CI antes de cada commit local.
   Bloquea regresiones antes de llegar a CI.

## Threat model

### Defendidos (probados empíricamente)

- Agente CASUAL que llama `mem_search`/`mem_context` sin filter →
  auto-scope cwd o data físicamente vacío → solo ve su slug.
- Agente que llama `mem_stats` GLOBAL → bloqueado por permission deny.
- Agente que pide INTENCIONALMENTE memorias de `project=<otro>` → data
  dir aislado simplemente no contiene esa data → vacío (verificado
  runtime con JSON-RPC, sub-test 3 de Check 16).
- Operador que clona el repo en otro PC → JSON portable via `$HOME`,
  MCP override resuelve a paths del nuevo PC.
- Dev que regresa hardcoded paths en un commit → pre-commit hook bloquea
  local + CI bloquea PR.
- Dev que actualiza `engram` a versión vieja → setup script aborta.
- Migración desde global → backup atómico pre-migration + verificación
  MD5 que el global no se tocó.

### NO defendidos (fuera de scope)

- Operador con root SSH al PC del dev (puede leer cualquier
  `~/.engram-*` directamente). Mitigación: perms 700 + sudo audit.
- Atacante con malware en el PC del dev. Mitigación: hardening del PC.
- Memorias clasificadas/tóxicas en el cloud server compartido entre
  devs autorizados con el mismo token. Mitigación: split en
  tokens-por-dev (ver `PRODUCTION-DEPLOY.md`).
- Bug zero-day en `engram` que viole `ENGRAM_DATA_DIR`. Mitigación:
  pin de versión + monitoreo + auditorías.

## Versión compat matrix

| Componente | Min | Tested | Recomendado |
|---|---|---|---|
| `engram` CLI / server | 1.15.10 | 1.15.10 | última estable |
| Postgres (server cloud) | 16.x | 16.13-alpine | 16.13-alpine |
| Docker engine | 24.x | 27.x | 27+ |
| Docker Compose | v2 | v2.20+ | v2.20+ |
| Python (scripts) | 3.10 | 3.12 | 3.12 |
| Bash (scripts) | 5.0 | 5.2 | 5.2 |
| Tailscale | última | última | plan corp |

El pin defensivo en `setup-isolated-project.sh` enforza el "Min" de
`engram`. Si algo más cambia y rompe, doc de regresión + bump de Min en
compat matrix.
