# Troubleshooting — síntomas comunes y fix

Si algo no funciona como esperabas, buscá el síntoma acá. Si no está, abrí issue.

---

## Síntoma: el agente Claude sigue viendo memorias de OTROS proyectos

### Causa más común: marker file faltante o malformado

```bash
# Verificar marker:
cat $REPO/.engram-isolation
# Debe contener una línea: slug: <tu-slug>
# Si está vacío o el slug es distinto al esperado, regenerar:

~/engram-multi-project-isolation/scripts/setup-isolated-project.sh \
  --slug <tu-slug> --repo $REPO
```

### Causa: wrapper no instalado

```bash
ls -la ~/.local/bin/engram
# Debe ser: lrwxrwxrwx ... engram -> /home/<vos>/.local/bin/engram-wrapper.sh
# Si NO es symlink, instalar wrapper:
~/engram-multi-project-isolation/scripts/install-engram-wrapper.sh
```

### Causa: PATH ordering (otro engram interceptando)

```bash
which engram
# Debe ser: /home/<vos>/.local/bin/engram
# Si es otro path (ej: /usr/local/bin/engram), tu PATH tiene otro engram antes:
echo $PATH
# Agregar ~/.local/bin al PRINCIPIO:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Causa: Claude session anterior aún corriendo MCP viejo

```bash
# Listar MCP processes activos:
pgrep -af "engram mcp"

# Verificar env del MCP de tu sesión:
PID=<el-pid-de-tu-sesión>
cat /proc/$PID/environ | tr '\0' '\n' | grep ENGRAM_DATA_DIR
# Si NO aparece ENGRAM_DATA_DIR, el MCP fue spawneado SIN wrapper.
# Solución: cerrar Y reabrir la sesión Claude completamente.
```

---

## Síntoma: `validate-isolation.sh` dice 19/20 con check 12 FAIL

**Síntoma exacto**:
```
[12] [funcional] engram projects list global SÍ lista 'XXX' (control) ... FAIL
```

**Causa**: estás corriendo validate desde dentro del repo del proyecto. El wrapper detecta el marker, setea `ENGRAM_DATA_DIR=isolated`, y el check 12 (que necesita query al GLOBAL como control) ve el aislado.

**Fix**: correr validate desde un cwd FUERA del repo:

```bash
cd ~/
~/engram-multi-project-isolation/scripts/validate-isolation.sh \
  --slug <tu-slug> --repo /ruta/al/repo
```

---

## Síntoma: `engram-wrapper: marker malformado`

**Síntoma exacto**:
```
ERROR engram-wrapper: marker /path/.engram-isolation malformado (no encuentro 'slug: <name>')
```

**Causa**: el archivo marker tiene formato incorrecto.

**Fix**: regenerar:

```bash
echo "slug: <tu-slug>" > $REPO/.engram-isolation
# Slug debe ser lowercase con guiones (ej: mi-app, no Mi_App)
```

---

## Síntoma: `engram-wrapper: slug=X pero ~/.engram-X no existe`

**Causa**: marker dice un slug pero el data dir aislado nunca fue creado.

**Fix**:

```bash
# Opción A: crear el data dir (preserva el marker):
~/engram-multi-project-isolation/scripts/setup-isolated-project.sh \
  --slug <slug-del-marker> --repo $REPO

# Opción B: cambiar el marker a un slug que SÍ tenga data dir:
ls ~/.engram-*  # listar data dirs existentes
echo "slug: <slug-existente>" > $REPO/.engram-isolation

# Opción C: borrar el marker (vuelve a usar global):
rm $REPO/.engram-isolation
```

---

## Síntoma: cloud sync falla con `blocked_unenrolled`

**Síntoma exacto**:
```
engram: cloud sync blocked_unenrolled: project "X" is not enrolled for cloud sync
```

**Causa**: el slug NO está en `ENGRAM_CLOUD_ALLOWED_PROJECTS` del server cloud.

**Fix**: enrolar:

```bash
# Cliente:
ENGRAM_DATA_DIR=~/.engram-<slug> engram cloud enroll <slug>

# Server (si el slug NO está en allowlist):
ssh <admin-del-cloud-server>
sudo nano /home/engram/engram-cloud/.env
# Editar ENGRAM_CLOUD_ALLOWED_PROJECTS=existente,<slug>
sudo systemctl restart engram-cloud.service
```

---

## Síntoma: cloud sync falla con `upgrade_blocked_legacy_mutation_manual`

**Síntoma exacto**:
```
legacy mutation payloads require manual action ... session payload directory is required
```

**Causa**: importaste un .db de una versión más vieja de engram que tiene sessions sin campo `directory`.

**Fix** (script Python):

```python
import sqlite3, json
c = sqlite3.connect('/home/<vos>/.engram-<slug>/engram.db')

# Fix sessions
c.execute("UPDATE sessions SET directory='/imported/<slug>', project='<slug>' WHERE directory='' OR project != '<slug>'")

# Fix mutation payloads
for row in c.execute("SELECT seq, payload FROM sync_mutations WHERE entity='session'").fetchall():
    seq, payload_str = row
    if not payload_str: continue
    p = json.loads(payload_str)
    if p.get('directory', '') == '':
        p['directory'] = '/imported/<slug>'
    if p.get('project') != '<slug>':
        p['project'] = '<slug>'
    c.execute("UPDATE sync_mutations SET payload=? WHERE seq=?", (json.dumps(p), seq))

c.commit()
```

Después retry: `engram sync --cloud --project <slug>`.

---

## Síntoma: hook SessionStart no imprime banner al abrir Claude

**Causa**: hook config en `.claude/settings.local.json` malformado o Claude Code no soporta hooks per-project.

**Fix**: regenerar settings.local.json + reabrir sesión:

```bash
~/engram-multi-project-isolation/scripts/setup-isolated-project.sh \
  --slug <slug> --repo $REPO
# Cerrar Y reabrir Claude completamente
```

---

## Síntoma: el agente perdió memoria al reabrir Claude

**Causa**: probablemente reabrió en otro cwd (ej: `~/` en lugar de el repo).

**Fix**:

```bash
cd /ruta/correcta/al/repo
claude
```

---

## Si nada de lo anterior funciona

1. Correr `validate-isolation.sh` y leer cada FAIL con detalle:
   ```bash
   cd ~/
   ~/engram-multi-project-isolation/scripts/validate-isolation.sh \
     --slug <slug> --repo /ruta/repo 2>&1 | tee /tmp/validate.log
   ```
2. Inspeccionar processes engram activos:
   ```bash
   for pid in $(pgrep -f "engram mcp"); do
     echo "PID $pid:"
     cat /proc/$pid/environ | tr '\0' '\n' | grep -E "ENGRAM|HOME|PWD" | head -10
   done
   ```
3. Abrir issue en el repo del toolkit con:
   - Output de validate-isolation.sh
   - Output del inspect de processes
   - Versión engram (`engram version`)
   - Versión Claude Code (`claude --version` si disponible)

---

## Disaster recovery

Si el aislado se corrompió o perdiste datos, ver `docs/CONTINGENCY-PLAN.md`
(6 escenarios + RTO 30min / RPO 24h + procedimientos de restore).
