# Quickstart para neófito — desde cero hasta aislamiento total

> Para alguien que NO tiene experiencia con engram, MCP, ni Claude Code plugins.
> Lectura: 10 min · ejecución: 15 min · resultado: aislamiento garantizado.

---

## ¿Qué es engram y por qué necesitás aislamiento?

**engram** es una "memoria persistente para agentes de IA". Cuando trabajás con
Claude Code (o cualquier cliente compatible con MCP), engram guarda
observaciones, decisiones, snippets de código, etc. para que el agente las
recuerde en sesiones futuras.

**El problema**: engram guarda TODO en un único archivo (`~/.engram/engram.db`)
con todos tus proyectos mezclados. Si trabajás en múltiples clientes/repos:

- Tu agente en proyecto **CocaCola** ve memorias de **Pepsi** ❌
- Tu agente en repo **cliente-A** ve datos sensibles de **cliente-B** ❌
- `mem_stats` revela TODOS los nombres de proyectos sin filtro ❌

Este toolkit resuelve eso forzando **un archivo SQLite por proyecto**,
físicamente separado, sin posibilidad de mezcla.

---

## Conceptos básicos (glosario)

| Término | Significa |
|---|---|
| **MCP** | Model Context Protocol — el "lenguaje" estándar para que agentes de IA hablen con tools externos (engram es uno) |
| **MCP server** | Proceso que expone tools (como `mem_save`, `mem_search`) via stdio. engram es un MCP server |
| **Plugin Claude Code** | Extensión que agrega tools a Claude Code. El plugin engram (de Gentleman Programming) instala engram MCP en Claude Code automáticamente |
| **slug** | Nombre único del proyecto en engram (lowercase, con guiones). Ej: `mi-proyecto`, `cliente-acme`. **Debe matchear el nombre del repo GitHub** para evitar confusiones |
| **Data dir aislado** | Carpeta `~/.engram-<slug>/` con su propio SQLite. Solo contiene memorias del proyecto X |
| **Marker file** | Archivo `.engram-isolation` en el repo del proyecto que le dice al wrapper: "estoy en proyecto X, usá `~/.engram-<slug>/`" |
| **Wrapper** | Script en `~/.local/bin/engram` que intercepta TODAS las invocaciones de engram y lee el marker para setear `ENGRAM_DATA_DIR` automáticamente |
| **`ENGRAM_DATA_DIR`** | Variable de entorno que le dice a engram qué carpeta de datos usar |

---

## Antes de empezar (pre-requisitos)

Verificá que tenés instalado:

```bash
# Engram CLI (>= 1.15.10)
~/.local/bin/engram version
# debe mostrar: engram v1.15.10 o superior
# Si no: https://github.com/gentleman-programming/engram/releases

# Cloud config (si vas a sincronizar entre PCs)
cat ~/.engram/cloud.json
# debe tener: {"server_url":"https://...", "token":"..."}
# Si no, configurá engram cloud o pasá este paso

# Git en el repo del proyecto que querés aislar
cd /ruta/a/tu/proyecto
git remote -v
# debe mostrar el remote a GitHub (o cualquier git host)
```

---

## Paso 1: clonar este toolkit (una sola vez por PC)

```bash
git clone https://github.com/<tu-org>/engram-multi-project-isolation.git ~/engram-multi-project-isolation
cd ~/engram-multi-project-isolation
```

---

## Paso 2: aislar tu primer proyecto (5 min)

Supongamos que tu proyecto vive en `~/proyectos/mi-app` y se llama `mi-app` en GitHub.

```bash
~/engram-multi-project-isolation/scripts/setup-isolated-project.sh \
  --slug mi-app \
  --repo ~/proyectos/mi-app \
  --client claude-code
```

Esto hace **7 pasos automáticamente**:

| Paso | Qué hace |
|---|---|
| **0/7 Instalar wrapper** | Reemplaza `~/.local/bin/engram` con un script wrapper que detecta el marker `.engram-isolation` y setea `ENGRAM_DATA_DIR` automáticamente |
| **1/7 Crear data dir** | `mkdir ~/.engram-mi-app/` con perms 700 |
| **2/7 Copiar cloud.json** | Copia tu config de cloud al data dir aislado |
| **3/7 Inicializar SQLite** | Crea el archivo `engram.db` vacío con schema engram |
| **4/7 Enrolar en cloud** | `engram cloud enroll mi-app` (si tenés cloud configurado) |
| **5/7 Crear marker** | Escribe `~/proyectos/mi-app/.engram-isolation` con `slug: mi-app` |
| **6/7 Override MCP** | Escribe `~/proyectos/mi-app/.claude/settings.local.json` con `mcpServers.engram` apuntando al data dir aislado (capa extra) |
| **7/7 Reporte** | Imprime resumen y próximos pasos |

**Salida esperada al final**:
```
===========================================
  ENGRAM ISOLATED PROJECT — SETUP DONE
===========================================
  slug       : mi-app
  client MCP : claude-code
  data dir   : /home/<vos>/.engram-mi-app
  settings   : /home/<vos>/proyectos/mi-app/.claude/settings.local.json
===========================================
```

---

## Paso 3: validar que funcionó (1 min)

```bash
~/engram-multi-project-isolation/scripts/validate-isolation.sh \
  --slug mi-app \
  --repo ~/proyectos/mi-app \
  --client claude-code
```

Debe mostrar:
```
====================================
  RESULT: 20 pass, 0 fail
====================================
OK — aislamiento verificado.
```

Si algún check falla, ver `docs/TROUBLESHOOTING.md`.

---

## Paso 4: probarlo con Claude Code real

1. Cerrá cualquier sesión Claude Code abierta en ese repo
2. Abrí una sesión nueva:
   ```bash
   cd ~/proyectos/mi-app
   claude
   ```
3. Preguntale al agente: `"buscá en engram el contexto del proyecto"`
4. **Resultado esperado**: el agente solo te muestra memorias de `mi-app`, NO menciona otros proyectos tuyos

---

## Paso 5 (opcional): migrar memorias existentes del global

Si ya tenías memorias del proyecto `mi-app` en el engram global (`~/.engram/`), migralas:

```bash
~/engram-multi-project-isolation/scripts/migrate-to-isolated.sh --slug mi-app
```

Esto:
- Hace backup del global (safety)
- Copia las memorias `project=mi-app` al data dir aislado
- Verifica que el global NO cambió (md5 check)
- Push al cloud para que esté disponible en otros PCs

---

## Paso 6: repetir para otros proyectos

Por cada proyecto adicional:

```bash
~/engram-multi-project-isolation/scripts/setup-isolated-project.sh \
  --slug otro-proyecto \
  --repo ~/proyectos/otro-proyecto
~/engram-multi-project-isolation/scripts/validate-isolation.sh \
  --slug otro-proyecto \
  --repo ~/proyectos/otro-proyecto
```

Cada proyecto queda en su propio `~/.engram-<slug>/` aislado.

---

## Cómo verifico que el aislamiento es REAL?

3 pruebas que podés hacer manualmente:

```bash
# 1. Desde cwd del proyecto mi-app, engram solo ve mi-app:
cd ~/proyectos/mi-app
engram stats
# Database debe decir: /home/<vos>/.engram-mi-app/engram.db
# Projects debe decir: mi-app

# 2. Desde cwd sin marker, engram usa el global (default):
cd ~/
engram stats
# Database: /home/<vos>/.engram/engram.db (global)

# 3. Multi-session concurrente (avanzado):
~/engram-multi-project-isolation/scripts/test-multi-session-isolation.sh
# Spawna 2 MCPs en proyectos distintos, verifica aislamiento bajo concurrencia
```

---

## Problemas comunes (y solución rápida)

### "El agente sigue viendo otros proyectos"

```bash
# 1. Verificá que el marker existe:
cat ~/proyectos/mi-app/.engram-isolation
# Debe decir: slug: mi-app

# 2. Verificá que el wrapper está instalado:
ls -la ~/.local/bin/engram
# Debe ser symlink a engram-wrapper.sh

# 3. Verificá que engram resuelve al wrapper:
which engram
# Debe ser: /home/<vos>/.local/bin/engram

# 4. Reabrí la sesión Claude (cerrar Y volver a abrir)
```

### "engram no se encuentra después de instalar wrapper"

Tu PATH no incluye `~/.local/bin` primero. Agregalo:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### "validate-isolation.sh dice 19/20 con check 12 FAIL"

Ejecutalo desde un cwd FUERA del proyecto (ej: `cd ~/` antes de correr). El test de control (check 12) necesita query al engram global, no al aislado.

---

## Cómo desinstalar

```bash
# Quitar aislamiento de UN proyecto:
~/engram-multi-project-isolation/scripts/rollback-isolated.sh \
  --slug mi-app \
  --repo ~/proyectos/mi-app

# Quitar el wrapper global (vuelve al engram original):
rm ~/.local/bin/engram
mv ~/.local/bin/engram-real ~/.local/bin/engram
rm ~/.local/bin/engram-wrapper.sh
```

---

## Cuándo NO usar este toolkit

- Solo tenés 1 proyecto → el global de engram alcanza
- No usás engram para nada sensible → la mezcla no importa
- Querés cross-project queries intencionales (auditoría comparativa entre clientes) → el aislamiento físico bloquea esto

---

## Siguientes lecturas

- `docs/PROJECT-ISOLATION.md` — patrón arquitectónico detallado
- `docs/ARCHITECTURE.md` — 8 capas defense in depth
- `docs/OPERATIONAL-CHECKLIST.md` — deploy en equipo de empresa
- `docs/CONTINGENCY-PLAN.md` — qué hacer si algo se rompe
- `docs/TROUBLESHOOTING.md` — síntomas comunes y fixes
- `SECURITY.md` — postura de seguridad y CVE policy
