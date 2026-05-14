# Aislamiento arquitectónico estricto por proyecto

Estándar operacional para todo proyecto enrolado en `engram` cloud cuando
un operador trabaja en múltiples proyectos sensibles. Cada proyecto vive
en su propio SQLite local, físicamente separado. Cero contaminación
cross-project — no behavioral, sino arquitectónico.

## Problema que resuelve

El plugin MCP de `engram` (`mem_search`, `mem_context`, `mem_stats`)
opera por default sobre UN ÚNICO SQLite local (`~/.engram/engram.db`)
que contiene observations de TODOS los proyectos del operador.
Comportamiento por tool:

| Tool | Default | Riesgo |
|---|---|---|
| `mem_search` | auto-scope al cwd (git_child / dir_basename) | Bajo en uso normal — sin filter explícito devuelve solo el proyecto actual |
| `mem_context` | sin `project` devuelve recientes GLOBAL | **Alto** — leak cross-project si el agente lo llama sin filter para "orientarse" |
| `mem_stats` | siempre GLOBAL, no acepta filter | **Alto** — expone lista de TODOS los proyectos del operador |

Aunque `mem_search` sea seguro por default, `mem_stats` y
`mem_context` sin filter son llamadas comunes cuando un agente arranca
y trata de "orientarse en el contexto". Esto produce filtración
cross-proyecto que el agente luego mezcla en sus decisiones.

Consecuencias operacionales documentadas:

- Recomendar patrones de un repo en otro donde NO aplican.
- Filtrar info comercial sensible entre clientes.
- Citar decisiones internas que pertenecen a otro proyecto.
- Romper modelos multi-tenant.
- Producir respuestas técnicamente correctas pero del proyecto
  equivocado — peor que no responder.

## Solución arquitectónica — `ENGRAM_DATA_DIR` por proyecto

`engram` v1.15.10+ acepta una variable de entorno que redirige el SQLite
local a un directorio arbitrario:

```
ENGRAM_DATA_DIR    Override data directory (default: ~/.engram)
```

Patrón:

Cada proyecto X se enrola con su propio data dir aislado:

```
~/.engram-X/engram.db          (solo observations de proyecto X)
~/.engram-X/cloud.json         (config sync engram cloud)
```

El plugin MCP, lanzado con `ENGRAM_DATA_DIR=~/.engram-X`, **NO PUEDE**
ver memorias de otros proyectos — están físicamente en otros archivos
inaccesibles para ese proceso. Aislamiento ferro, no behavioral.

El cloud server (Postgres) sigue siendo común para todos los proyectos —
el aislamiento es del CLIENTE local. La separación en cloud se hace por
nombre de proyecto en el allowlist (`ENGRAM_CLOUD_ALLOWED_PROJECTS`).

### Beneficios vs. solución behavioral

| Aspecto | Behavioral (instrucciones + denylist) | `ENGRAM_DATA_DIR` (físico) |
|---|---|---|
| Aislamiento real | Soft (depende del agente) | Físico (otro DB) |
| Resistente a agente "creativo" | NO | SÍ |
| Resistente a `mem_stats` | Solo deny | SÍ (DB no tiene la data) |
| Cross-project visibility | Posible | Imposible |
| Setup por proyecto | 3 capas | 1 ENV var + DB |
| Auditable | Difícil | Trivial (`ls ~/.engram-*`) |

## Estándar de implementación

### Pre-condiciones (una vez por PC)

- `engram` CLI v1.15.10+ instalado en `~/.local/bin/engram`.
- `~/.engram/cloud.json` poblado con `server_url` + `token` del cloud.
- `export ENGRAM_CLOUD_TOKEN=...` en `~/.bashrc` (algunos subcomandos lo
  leen solo de env var).

### Setup del proyecto (1 comando)

```bash
./scripts/setup-isolated-project.sh \
  --slug myproject \
  --repo /path/to/myproject
```

El script:

1. Valida slug (lowercase, sin espacios, sin caracteres ilegales).
2. Verifica versión engram >= 1.15.10 (pin defensivo).
3. Crea `~/.engram-myproject/` con perms 700.
4. Inicializa el DB con schema engram.
5. Copia `cloud.json` al data dir aislado.
6. Enrola en cloud server (`engram cloud enroll myproject`).
7. Crea `.claude/settings.local.json` en el repo con `mcpServers`
   override apuntando al data dir aislado vía `bash -c "$HOME/..."`
   (portable per-PC).
8. Configura hook SessionStart con sync push+pull + banner de scope.

### Migración de proyecto existente (opcional)

Si el proyecto ya tiene memorias en `~/.engram/engram.db` (caso típico
de migración cross-PC desde un setup legacy):

```bash
./scripts/migrate-to-isolated.sh --slug myproject
```

El script:

1. Backup atómico del global a `~/.engram/.backups/<slug>-pre-migration-<timestamp>.db`.
2. Crea `~/.engram-myproject/` vía `sqlite3.backup()` del global (incluye WAL pendiente).
3. `DELETE WHERE project IS NULL OR project != 'myproject'` en el nuevo DB.
4. `VACUUM` para reclamar espacio.
5. Validación: aislado contiene SOLO el slug.
6. Validación: global SIN MODIFICAR (md5 igual al inicio).
7. Push al cloud: `engram sync --cloud --project myproject`.

### Validación E2E

```bash
./scripts/validate-isolation.sh \
  --slug myproject \
  --repo /path/to/myproject
```

Verifica 16 checks:

- 8 estructurales (perms, JSON config, schema SQLite)
- 7 funcionales (engram CLI con/sin override)
- 1 runtime (spawn MCP server real + JSON-RPC stdio probe — el más
  importante: prueba que el binario corriendo NO PUEDE ver otros
  proyectos NI cuando se le piden intencionalmente)

Exit 0 si 16/16 pass, exit !=0 si algún FAIL.

## Garantías de diseño (no limitaciones — features intencionales)

Las siguientes propiedades son CONSECUENCIAS DIRECTAS Y DESEADAS del
aislamiento. NO son trade-offs ni deuda — son la garantía operacional.

- **Cross-project visibility imposible desde sesión con override.** Un
  agente trabajando en proyecto X no puede listar, leer ni inferir la
  existencia de proyectos Y, Z. Esta es LA GARANTÍA. Si el operador
  necesita query cross-proyecto (uso excepcional, ej: auditoría
  comparativa), ejecuta `engram <comando>` en shell directo SIN
  `ENGRAM_DATA_DIR` override.

- **`mem_stats` reporta solo el proyecto activo.** Stats globales
  requieren shell directo sin override — fuera del scope del agente.
  Esto evita filtración accidental de inventario de proyectos a un
  agente que solo debería conocer el suyo.

- **Backups gestionados por proyecto.** Cada data dir aislado se
  backupea independiente. Permite restore granular sin tocar proyectos
  no afectados.

## Referencias

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — 8 capas defense in depth + threat model
- [`OPERATIONAL-CHECKLIST.md`](OPERATIONAL-CHECKLIST.md) — checklist paso-a-paso
- [`CONTINGENCY-PLAN.md`](CONTINGENCY-PLAN.md) — recovery procedures
- [`CLIENT-AUTO-SYNC.md`](CLIENT-AUTO-SYNC.md) — patrón cliente sync transparente
- [`PRODUCTION-DEPLOY.md`](PRODUCTION-DEPLOY.md) — deploy del server cloud
