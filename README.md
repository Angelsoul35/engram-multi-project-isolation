# engram-multi-project-isolation

> Toolkit production-ready para garantizar aislamiento ARQUITECTÓNICO entre
> múltiples proyectos cuando se usa `engram` (memoria persistente para
> agentes de IA) en un equipo de developers, con un único cloud server
> compartido pero **cero contaminación cross-project**.

Construido sobre [`engram`](https://github.com/gentleman-programming/engram)
de **Gentleman Programming**. Ver [ATTRIBUTION.md](ATTRIBUTION.md) para la
separación de responsabilidades upstream vs. este toolkit.

---

## ¿Qué problema resuelve?

`engram` por default opera sobre **un único** SQLite local
(`~/.engram/engram.db`) que contiene observations de **todos los proyectos**
del operador. Esto es razonable para uso individual, pero genera tres
problemas en un equipo o cuando se trabaja en múltiples proyectos
sensibles:

1. **`mem_stats`** es global por diseño — un agente que llama esta tool
   ve la lista completa de proyectos del operador, incluyendo nombres
   de clientes confidenciales.
2. **`mem_context` sin filtro** devuelve recientes cross-project,
   contaminando el contexto del agente con decisiones, patrones y reglas
   de OTROS proyectos no compatibles.
3. **`mem_search` con `project=<otro>` intencional** sí accede al data
   compartido — un agente "creativo" o malicioso puede extraer
   información de proyectos a los que no debería tener acceso.

Este toolkit elimina los 3 problemas vía **8 capas de defensa en
profundidad**, siendo la principal el aislamiento físico del SQLite
por proyecto usando la variable de entorno `ENGRAM_DATA_DIR`.

## ¿Para quién es?

- Equipos de 2-N developers que usan `engram` con un cloud server
  compartido.
- Operadores que trabajan en múltiples proyectos sensibles (clientes
  distintos, NDAs distintos, contextos no intercambiables).
- Cualquiera que quiera **garantizar empíricamente** que un agente IA
  trabajando en el repo del proyecto X **NO PUEDE** ver memorias del
  proyecto Y, ni siquiera intentándolo.

## Quick start (3 fases)

### Fase 1 — Server cloud (admin, una vez)

Si todavía no tenés un `engram` cloud server, levantalo siguiendo
[`docs/PRODUCTION-DEPLOY.md`](docs/PRODUCTION-DEPLOY.md).
Si ya tenés uno funcionando, podés saltar a la fase 2.

### Fase 2 — Por dev (una vez por PC)

```bash
# Pre-requisitos:
#   - engram CLI instalado (>= 1.15.10): https://github.com/gentleman-programming/engram/releases
#   - ~/.engram/cloud.json poblado con server_url + token del cloud
#   - export ENGRAM_CLOUD_TOKEN=... en ~/.bashrc

# Cloná este toolkit
git clone https://github.com/<tu-org>/engram-multi-project-isolation.git ~/engram-multi-project-isolation
```

### Fase 3 — Por proyecto (5 minutos)

```bash
# 1. Setup data dir aislado + override MCP en el repo del proyecto.
#    --client soportados: claude-code (default), cursor, custom
~/engram-multi-project-isolation/scripts/setup-isolated-project.sh \
  --slug myproject \
  --repo /path/to/myproject \
  --client claude-code

# 2. (Opcional) Migrar memorias existentes del global
~/engram-multi-project-isolation/scripts/migrate-to-isolated.sh \
  --slug myproject

# 3. Validar 16 checks E2E (incluye runtime test via JSON-RPC)
~/engram-multi-project-isolation/scripts/validate-isolation.sh \
  --slug myproject \
  --repo /path/to/myproject \
  --client claude-code
# Esperado: "16 pass, 0 fail", exit 0

# 4. (Recomendado) Pre-commit hook anti-regresión en el repo del proyecto
cd /path/to/myproject
~/engram-multi-project-isolation/scripts/install-pre-commit.sh

# Rollback si algo sale mal
~/engram-multi-project-isolation/scripts/rollback-isolated.sh \
  --slug myproject --repo /path/to/myproject --client claude-code
```

## Clientes MCP soportados

| Cliente | Path del config | Notas |
|---|---|---|
| **claude-code** (default) | `<repo>/.claude/settings.local.json` | Soporta `mcpServers` + `permissions.deny` + `hooks.SessionStart`. Configuración completa. |
| **cursor** | `<repo>/.cursor/mcp.json` | Solo `mcpServers` (Cursor no soporta `permissions.deny` ni `hooks.SessionStart`). Aislamiento físico funciona igual. |
| **custom** | `--config-path /ruta/al/config.json` | Para cualquier cliente MCP compatible con schema `mcpServers` JSON. |

El aislamiento ARQUITECTÓNICO (data dir físicamente separado vía `ENGRAM_DATA_DIR`) es INDEPENDIENTE del cliente MCP — funciona en TODOS por diseño. Lo que cambia por cliente son las capas extras (permission deny, hook banner) que solo aplican donde el cliente las soporta.

## Documentación

| Documento | Contenido |
|---|---|
| [`docs/PROJECT-ISOLATION.md`](docs/PROJECT-ISOLATION.md) | Patrón arquitectónico de aislamiento por `ENGRAM_DATA_DIR`. **Empezar acá.** |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Arquitectura completa, 8 capas defense in depth, threat model, version compat matrix |
| [`docs/OPERATIONAL-CHECKLIST.md`](docs/OPERATIONAL-CHECKLIST.md) | Checklist paso-a-paso de despliegue (4 fases con checkboxes imprimibles) |
| [`docs/CONTINGENCY-PLAN.md`](docs/CONTINGENCY-PLAN.md) | Recovery procedures: 6 escenarios + RTO 30min / RPO 24h + inventario de backups |
| [`docs/CLIENT-AUTO-SYNC.md`](docs/CLIENT-AUTO-SYNC.md) | Patrón cliente: hook SessionStart auto-pull/push del cloud |
| [`docs/PRODUCTION-DEPLOY.md`](docs/PRODUCTION-DEPLOY.md) | Guía integral de deploy del cloud server |
| [`SECURITY.md`](SECURITY.md) | Postura de seguridad, política de updates, cómo reportar vulnerabilidades |
| [`ATTRIBUTION.md`](ATTRIBUTION.md) | Atribución upstream + separación de responsabilidades |

## Defensas activas (8 capas)

Detalle completo en [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Resumen:

1. **DATA**: SQLite físicamente separado por proyecto (`~/.engram-<slug>/`)
2. **PERMISSION**: `permissions.deny` bloquea `mem_stats` harness-side
3. **INSTRUCCIÓN**: bloque "AISLAMIENTO ESTRICTO" al inicio de `CLAUDE.md` del repo
4. **BANNER**: hook SessionStart imprime `PROJECT SCOPE: <slug>` al arrancar
5. **VALIDATE SCRIPT**: 16 checks reproducibles (incluye runtime probe JSON-RPC)
6. **VERSION PIN**: el setup script exige `engram >= 1.15.10`
7. **CI/CD**: workflow valida cada push/PR
8. **PRE-COMMIT**: hook local bloquea regresiones antes de commit

## CI/CD

Cada push o PR a `main` dispara `.github/workflows/validate.yml` con 4 jobs:

| Job | Verifica |
|---|---|
| `syntax-check` | `bash -n` sobre `.sh`, `py_compile` sobre `.py`, `json.load` sobre `.json` |
| `shellcheck` | warnings sobre todos los scripts bash |
| `docs-no-hardcoded-paths` | Detecta regresiones de portabilidad |
| `scripts-have-shebang-and-set-euo` | Verifica `#!/usr/bin/env bash` + `set -euo pipefail` |

Configurando branch protection requiriendo este check, ningún PR puede
mergearse sin los 4 verde.

## Estructura del repo

```
.
├── README.md
├── LICENSE                              # MIT
├── ATTRIBUTION.md                       # crédito a Gentleman Programming (engram upstream)
├── SECURITY.md
├── .gitignore
├── .env.example                         # template para el server cloud
├── docker-compose.yml                   # stack del server cloud
├── docs/
│   ├── PROJECT-ISOLATION.md
│   ├── ARCHITECTURE.md
│   ├── OPERATIONAL-CHECKLIST.md
│   ├── CONTINGENCY-PLAN.md
│   ├── CLIENT-AUTO-SYNC.md
│   └── PRODUCTION-DEPLOY.md
├── scripts/
│   ├── setup-isolated-project.sh        # CLIENT: onboarda proyecto aislado ⭐
│   ├── migrate-to-isolated.sh           # CLIENT: migra desde global
│   ├── validate-isolation.sh            # CLIENT: 16 checks E2E
│   ├── test-mcp-runtime-isolation.py    # CLIENT: probe runtime JSON-RPC
│   ├── rollback-isolated.sh             # CLIENT: revierte setup
│   ├── install-pre-commit.sh            # MAINT: hook anti-regresión
│   ├── backup.sh                        # SERVER: dump postgres
│   ├── offsite.sh                       # SERVER: cifra age + rclone
│   ├── restore.sh                       # SERVER: restore dump
│   ├── smoke.sh                         # SERVER: check /health + auth
│   └── check-updates.sh                 # SERVER: avisa engram/postgres nuevo
├── systemd/
│   └── engram-cloud.service
└── .github/
    └── workflows/
        └── validate.yml                 # CI: 4 jobs de calidad
```

## Garantías

| Garantía | Evidencia objetiva |
|---|---|
| Aislamiento cross-project blindado | Check 16 sub-test 3: `mem_search project="<otro>"` con override devuelve VACÍO |
| Migración no toca el global | MD5 verificado bit-a-bit pre/post |
| Setup/migrate/validate/rollback funcionan | E2E tested en cualquier slug pristine |
| Cero hardcoded paths | grep recursivo + CI job + pre-commit hook |
| Pre-commit bloquea regresiones | Test positivo PASS + test negativo BLOQUEADO |
| Replicable a cualquier PC | `bash -c "$HOME/..."` resuelve por dev/PC |

## Versiones soportadas

| Componente | Min | Recomendado |
|---|---|---|
| `engram` CLI / server | 1.15.10 | última estable |
| Postgres (server) | 16.x | 16.13-alpine |
| Docker Engine | 24.x | 27+ |
| Docker Compose | v2 | v2.20+ |
| Python (scripts) | 3.10 | 3.12 |
| Bash (scripts) | 5.0 | 5.2 |

El pin defensivo en `setup-isolated-project.sh` enforza el `Min` de
`engram`. Versiones anteriores podrían no honrar `ENGRAM_DATA_DIR` o
tener schema incompatible.

## Contribuir

Este es un toolkit open source MIT. Issues y PRs bienvenidos en GitHub.
Convenciones:

- Scripts bash: `set -euo pipefail`, `#!/usr/bin/env bash`, idempotentes.
- Cero paths hardcoded del operador (CI lo enforce).
- Cada cambio funcional debe pasar los 16 checks de
  `validate-isolation.sh` sobre un slug de prueba.
- Commits firmados (recomendado).

Para un setup local de desarrollo:

```bash
git clone https://github.com/<tu-org>/engram-multi-project-isolation.git
cd engram-multi-project-isolation
./scripts/install-pre-commit.sh   # gate local pre-commit
```

## Licencia

MIT — ver [LICENSE](LICENSE). El binario `engram` upstream tiene su propia
licencia MIT (ver [ATTRIBUTION.md](ATTRIBUTION.md)).
