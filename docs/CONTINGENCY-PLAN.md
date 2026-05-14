# Plan de contingencia

Procedimientos de recuperación ante fallas operativas. Numerados por
escenario. Cada uno con: síntoma, causa raíz, acción inmediata,
recuperación, prevención.

## Escenario 1 — Migración a aislado interrumpida

**Síntoma**: `~/.engram-<slug>/` existe pero `engram stats` falla, o el
conteo de obs no cuadra con el global.

**Causa raíz**: el script `migrate-to-isolated.sh` fue interrumpido
(Ctrl+C, terminal cerrada, OS reboot) antes del `VACUUM` final.

**Acción inmediata**: NO ejecutar nada más. Verificar estado del backup:

```bash
ls -la ~/.engram/.backups/<slug>-pre-migration-*.db
```

Si existe, el global está garantizadamente intacto (el script no toca
global, solo lee). Si no existe, ver Escenario 4.

**Recuperación**:

```bash
rm -rf ~/.engram-<slug>/
./scripts/setup-isolated-project.sh --slug <slug> --repo /path
./scripts/migrate-to-isolated.sh --slug <slug>
./scripts/validate-isolation.sh --slug <slug> --repo /path
```

**Prevención**: correr scripts dentro de tmux/screen para sobrevivir
disconnects de SSH. Espacio en disco mínimo 200 MB libre.

## Escenario 2 — DB aislado corrompido

**Síntoma**: `ENGRAM_DATA_DIR=~/.engram-<slug> engram stats` devuelve
error "database disk image is malformed" o similar.

**Causa raíz**: power loss durante write, filesystem error, OS bug.

**Acción inmediata**: NO escribir más al DB corrompido. Hacer copia del
estado dañado por si auditoría lo requiere:

```bash
cp -a ~/.engram-<slug>/ ~/.engram-<slug>.corrupt-$(date +%Y%m%d)
```

**Recuperación opción A — desde backup pre-migración**:

```bash
ls -t ~/.engram/.backups/<slug>-pre-migration-*.db | head -1
rm -rf ~/.engram-<slug>/
./scripts/setup-isolated-project.sh --slug <slug> --repo /path
./scripts/migrate-to-isolated.sh --slug <slug>
```

**Recuperación opción B — desde engram cloud**:

```bash
rm -rf ~/.engram-<slug>/
./scripts/setup-isolated-project.sh --slug <slug> --repo /path
ENGRAM_DATA_DIR=~/.engram-<slug>/ engram sync --cloud --project <slug> --import
ssh engram@<your-cloud-host> \
  "docker exec engram-cloud-postgres psql -U engram -d engram \
   -c \"SELECT COUNT(*) FROM observations WHERE project='<slug>'\""
```

**Prevención**: correr `backup.sh` diario en cron. El backup off-site
cifrado con `age` es la garantía final.

## Escenario 3 — Cloud server inaccesible

**Síntoma**: `engram sync --cloud` devuelve "connection refused" o
"tls handshake failed" o "401 unauthorized".

**Causa raíz por orden de probabilidad**:

a. Tailscale del HOST caído.
b. Container `engram-cloud` o `engram-cloud-postgres` parado.
c. Token rotado en server, cliente con valor viejo.
d. Token rotado/perdido en cliente, server con valor viejo.
e. Allowlist no incluye el slug.

**Acción inmediata**: trabajar local solamente. El SQLite aislado sigue
operativo independientemente del cloud — el agente puede leer/escribir
memorias del proyecto sin sync.

**Diagnóstico**:

```bash
# 1. ¿El cliente puede pingear el server?
curl -sf https://<your-cloud-host>/health

# 2. ¿Tailscale activa?
tailscale status | head -5

# 3. ¿Cloud y postgres healthy?
ssh engram@<your-cloud-host> \
  "docker ps --filter name=engram --format 'table {{.Names}}\t{{.Status}}'"

# 4. ¿Token correcto?
grep ENGRAM_CLOUD_TOKEN ~/.engram-<slug>/cloud.json
ssh engram@<your-cloud-host> \
  "grep ^ENGRAM_CLOUD_TOKEN= /home/engram/engram-cloud/.env"

# 5. ¿Slug en allowlist?
ssh engram@<your-cloud-host> \
  "grep ^ENGRAM_CLOUD_ALLOWED_PROJECTS= /home/engram/engram-cloud/.env"
```

**Recuperación según diagnóstico**:

- **a (server unreachable)**: chequear `tailscale serve status` del HOST.
  Reset: `sudo systemctl restart tailscaled` (en HOST).

- **b (containers down)**: SSH al HOST y
  `sudo systemctl restart engram-cloud.service`.

- **c (token mismatch cliente)**: editar `~/.engram-<slug>/cloud.json`
  con el token correcto. Reiniciar el agente para que el MCP server
  rearranque con la nueva config.

- **e (slug no allowlisted)**: editar `/home/engram/engram-cloud/.env`
  en HOST, agregar slug a `ENGRAM_CLOUD_ALLOWED_PROJECTS`,
  `sudo systemctl restart engram-cloud.service`.

**Prevención**: monitor uptime con healthchecks.io o equivalente sobre
el endpoint `/health`. Backup off-site cifrado garantiza que un fallo
de cloud server prolongado no pierde data.

## Escenario 4 — Global engram corrompido / borrado

**Síntoma**: `~/.engram/engram.db` no abre, o se perdió en un wipe del PC.

**Causa raíz**: filesystem error, `rm` accidental, OS reinstall.

**Acción inmediata**: NO ejecutar ningún script de `engram` que escriba al
global hasta restaurar. Si el aislado de cada proyecto sigue OK, NO hay
urgencia — los proyectos funcionan via su propio data dir.

**Recuperación**:

```bash
mkdir -p ~/.engram
chmod 700 ~/.engram

# Copiar cloud.json desde algún data dir aislado (todos tienen el mismo)
cp ~/.engram-<algun-slug>/cloud.json ~/.engram/cloud.json
chmod 600 ~/.engram/cloud.json

engram stats >/dev/null 2>&1

# (Opcional) Pull cada proyecto desde cloud al global, si querés
# que el global tenga visibilidad cross-proyecto a futuro
for slug in $(ls -d ~/.engram-* | sed 's|.*/.engram-||'); do
  engram cloud enroll "$slug"
  engram sync --cloud --project "$slug" --import
done
```

**Prevención**: los data dirs aislados son el "primary" — el global ya
no es críticamente importante con el patrón aislado. Backup del global
puede ser semanal en lugar de diario.

## Escenario 5 — Override `mcpServers` no se aplica

**Síntoma**: en una sesión del agente IA abierta en el repo, el agente llama
`mem_search` y devuelve memorias de proyectos OTROS, indicando que el
MCP server está leyendo del global `~/.engram/`.

**Causa raíz por orden de probabilidad**:

a. Versión del IDE / cliente MCP no soporta `mcpServers` en `.claude/settings.local.json`.
b. JSON de `settings.local.json` mal formado.
c. `ENGRAM_DATA_DIR` del config apunta a path inexistente.
d. Cache del IDE requiere restart.

**Diagnóstico**:

```bash
# 1. Validar JSON
python3 -c "import json; json.load(open('$REPO/.claude/settings.local.json'))"

# 2. Validar data dir existe
ls -la $(python3 -c "import json; print(json.load(open('$REPO/.claude/settings.local.json'))['mcpServers']['engram']['args'][1])" | grep -oE '\$HOME/[^ ]+' | sed "s|\$HOME|$HOME|")

# 3. Versión del IDE / cliente MCP
<your-agent-cli> --version  # comando version de tu IDE / cliente MCP
```

**Recuperación**: re-correr setup (es idempotente):

```bash
./scripts/setup-isolated-project.sh --slug <slug> --repo /path
./scripts/validate-isolation.sh --slug <slug> --repo /path
```

Cerrar TODAS las sesiones del agente IA del proyecto, reabrir nueva.

## Escenario 6 — Conflicto de ID entre data dirs

**Síntoma**: al hacer `engram sync --import`, error
"UNIQUE constraint failed: observations.id".

**Causa raíz**: dos data dirs aislados generan IDs autoincrement
independientes. Cuando el cloud unifica via project name, puede haber
colisión si un mismo ID se asignó en dos data dirs distintos.

**Acción inmediata**: NO forzar el sync. Detectar la colisión primero.

**Diagnóstico**:

```bash
ssh engram@<your-cloud-host> \
  "docker exec engram-cloud-postgres psql -U engram -d engram \
   -c \"SELECT id, project, COUNT(*) FROM observations \
        WHERE project='<slug>' GROUP BY id, project HAVING COUNT(*)>1\""
```

**Recuperación**: contactar al mantainer de `engram` para resolución
limpia. Como workaround, exportar a JSON y reimportar con re-IDs:

```bash
engram export ~/engram-<slug>-export.json --project <slug>
# Editar JSON para limpiar conflictos manualmente
rm -rf ~/.engram-<slug>/
engram import ~/engram-<slug>-export.json
```

**Prevención**: NO compartir data dirs entre PCs (cada PC genera el
suyo via `setup-isolated-project.sh`). El cloud es el punto de
sincronización single-source-of-truth.

## Inventario de backups

Capas de defensa contra pérdida de data:

1. **WAL del SQLite** (`~/.engram-<slug>/engram.db-wal`): write-ahead
   log, recovery automática hasta el último commit fsync'd. Always-on.

2. **Backups pre-migración**: `~/.engram/.backups/<slug>-pre-migration-<timestamp>.db`
   Generados automáticamente por `migrate-to-isolated.sh`. Retener 30+ días.

3. **Backups del cloud server**: `/home/engram/engram-cloud/backups/engram-cloud-<timestamp>.sql.gz`
   Cron diario 03:00. Retener 14 días.

4. **Backups off-site cifrados con age**: `<bucket>/engram-cloud-prod/engram-cloud-*.sql.gz.age`
   Cron 04:00 sube el último. Retener indefinido.

5. **Repo git de cada proyecto**: el dump engram_export.db de cada
   proyecto puede commitearse al repo (en `memory/engram_export/`)
   como backup VCS-trackeable + DR.

**RTO objetivo**: 30 min (restore desde backup local pre-migración).
**RPO objetivo**: 24 h (último backup off-site exitoso).

## Contacto de escalación

- **Falla crítica del cloud server**: contactar admin del HOST del
  cloud. Ver runbook personal del operador para credenciales SSH y
  acceso físico.
- **Bug del binario `engram`**: reportar a
  https://github.com/gentleman-programming/engram/issues con repro
  mínimo + versión (`engram --version`).
- **Bug en este toolkit**: reportar issue en este repo de GitHub.
