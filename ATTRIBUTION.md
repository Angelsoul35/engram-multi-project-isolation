# Attribution / Atribuciones

Este toolkit (`engram-multi-project-isolation`) es un conjunto de scripts,
documentación y patrones operativos construido **encima** de proyectos
upstream que pertenecen a otros autores. Este documento clarifica qué es
de este repo vs. qué es upstream.

## Upstream — `engram` (Gentleman Programming)

- **Proyecto**: engram — Persistent memory for AI coding agents.
- **Autor / mantenedor**: Gentleman Programming.
- **Repositorio oficial**: https://github.com/gentleman-programming/engram
- **Licencia**: MIT.
- **Qué provee**:
  - Binario CLI `engram` (Go).
  - Servidor MCP (Model Context Protocol) sobre stdio.
  - Servidor cloud HTTP (Go) para sincronización remota.
  - Schema SQLite + Postgres.
  - Tools MCP (`mem_save`, `mem_search`, `mem_context`, `mem_stats`, etc.).
  - Variable de entorno `ENGRAM_DATA_DIR` que este toolkit aprovecha como
    primitiva fundamental para el aislamiento físico por proyecto.

**Este toolkit NO incluye, modifica ni redistribuye el binario `engram`.**
Cada usuario debe instalar `engram` desde la fuente oficial siguiendo
las instrucciones del repo upstream.

## Lo que provee ESTE repo (toolkit, MIT)

Construye sobre la primitiva `ENGRAM_DATA_DIR` un patrón operativo
completo de aislamiento multi-proyecto:

- **Scripts**:
  - `setup-isolated-project.sh` — onboarda un proyecto con su data dir aislado.
  - `migrate-to-isolated.sh` — migra observations desde `~/.engram/` (global)
    al data dir aislado, preservando el global intacto.
  - `validate-isolation.sh` — 16 checks (estructura + funcional + runtime
    via JSON-RPC) que prueban empíricamente el aislamiento.
  - `rollback-isolated.sh` — revierte el setup aislado.
  - `install-pre-commit.sh` — instala un git hook anti-regresión.
  - `test-mcp-runtime-isolation.py` — probe de stdio JSON-RPC contra el
    MCP server con override.
  - Scripts de servidor (`backup.sh`, `offsite.sh`, `restore.sh`, `smoke.sh`,
    `check-updates.sh`) para operar el `engram` cloud server.

- **Documentación**:
  - `docs/PROJECT-ISOLATION.md` — patrón arquitectónico de aislamiento.
  - `docs/ARCHITECTURE.md` — 8 capas defense in depth + threat model.
  - `docs/OPERATIONAL-CHECKLIST.md` — checklist paso-a-paso de despliegue.
  - `docs/CONTINGENCY-PLAN.md` — recovery procedures (6 escenarios).
  - `docs/CLIENT-AUTO-SYNC.md` — patrón de auto-sync transparente cliente.
  - `docs/PRODUCTION-DEPLOY.md` — guía de deploy del server cloud.

- **Configuración**:
  - `docker-compose.yml` para el server cloud.
  - `systemd/engram-cloud.service` para auto-start.
  - `.github/workflows/validate.yml` con 4 jobs de CI (gates de calidad).

## Resumen de responsabilidades

| Componente | Owner | Licencia | Modificable por este toolkit |
|---|---|---|---|
| binario `engram` | Gentleman Programming | MIT (upstream) | NO (consumido tal cual) |
| protocolo MCP | Anthropic + comunidad | open spec | NO |
| schema SQLite/Postgres engram | Gentleman Programming | MIT (upstream) | NO |
| `ENGRAM_DATA_DIR` env var | Gentleman Programming | MIT (upstream) | NO (usado como primitiva) |
| scripts de este toolkit | engram-multi-project-isolation contributors | MIT | SÍ |
| documentación de este toolkit | engram-multi-project-isolation contributors | MIT | SÍ |
| docker-compose del server | engram-multi-project-isolation contributors | MIT | SÍ |
| CI workflow | engram-multi-project-isolation contributors | MIT | SÍ |

## Reportar issues

- **Bug del binario `engram`**: reportar al upstream:
  https://github.com/gentleman-programming/engram/issues
- **Bug en este toolkit (scripts, docs, CI)**: reportar acá:
  (ver `README.md` de este repo).

## Agradecimientos

A **Gentleman Programming** y a los contribuidores de `engram` por construir
una base sólida con la flexibilidad arquitectónica (vía `ENGRAM_DATA_DIR`)
que permite el patrón de aislamiento que este toolkit formaliza.

A la comunidad MCP / Anthropic por la especificación abierta del protocolo
sobre la cual se construye `engram` y, por extensión, este toolkit.
