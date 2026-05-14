# Auto-sync transparente del lado del cliente

`engram` cloud es la capa de SINCRONIZACIÓN entre múltiples PCs, pero
los tools MCP de Claude (`mem_search`, `mem_save`, `mem_context`) leen
y escriben SIEMPRE en el SQLite local. NO existe modo "cliente cloud
puro" — toda query MCP toca el local.

Consecuencia: si en otro PC alguien guardó una memoria con `mem_save` +
`sync` push, este PC NO la ve hasta que corra:

```bash
engram sync --cloud --project <proyecto> --import
```

Si el operador olvida ese comando antes de iniciar sesión, el agente
Claude trabaja con un local desactualizado.

## Solución — hook SessionStart automático

`scripts/setup-isolated-project.sh` configura automáticamente este hook
en `.claude/settings.local.json` del repo. Se ejecuta al arrancar
cualquier sesión Claude en ese repo.

### Patrón aplicado

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "ENGRAM_DATA_DIR=\"$HOME/.engram-<slug>\" \"$HOME/.local/bin/engram\" sync --cloud --project <slug> 2>/dev/null; ENGRAM_DATA_DIR=\"$HOME/.engram-<slug>\" \"$HOME/.local/bin/engram\" sync --cloud --project <slug> --import 2>/dev/null; printf '\\n=========================================\\nPROJECT SCOPE: <slug>\\n=========================================\\n'; true"
          }
        ]
      }
    ]
  }
}
```

Notas:

- **Primer sync sin `--import`** hace PUSH: si la sesión anterior crasheó
  sin sincronizar mutations pendientes, este flush las sube antes del pull.
- **Segundo sync con `--import`** hace PULL: trae al local todo lo
  nuevo del cloud (mutations de otros PCs).
- **`2>/dev/null`** suprime ruido si cloud no está accesible.
- **`; true`** final garantiza exit code 0 — el hook NO bloquea el
  inicio de sesión si el sync falla. Trade-off consciente: prefieres
  arrancar con local viejo a no arrancar.

## Pre-requisitos (una vez por PC)

1. `engram` CLI instalado (`~/.local/bin/engram`, v1.15.10+).
2. `~/.engram/cloud.json` poblado con `server_url` + `token`.
3. `export ENGRAM_CLOUD_TOKEN=...` en `~/.bashrc` (algunos subcomandos
   lo leen solo desde env var).
4. Proyecto enrolado: `engram cloud enroll <slug>`.
5. Proyecto en allowlist del server (`ENGRAM_CLOUD_ALLOWED_PROJECTS`).

## Verificación

Después de configurar el hook (vía `setup-isolated-project.sh`), abrir
una nueva sesión Claude en el repo:

```bash
cd /path/to/myproject
claude
```

Y dentro de la sesión, en el primer mensaje al agente:

> buscá en engram el contexto del proyecto

El agente va a llamar `mem_search` y debería encontrar las memorias que
viven en cloud, incluso si en este PC nunca se hizo `mem_save` de ellas.

Para validar que el hook corrió:

```bash
ENGRAM_DATA_DIR=~/.engram-<slug> engram sync --status
```

## Hook complementario (opcional)

Si querés también hacer un push automático al cerrar sesión (en lugar
de esperar al próximo SessionStart), usar un cron user:

```bash
# Cada 15 min como respaldo
*/15 * * * * ENGRAM_DATA_DIR=$HOME/.engram-<slug> $HOME/.local/bin/engram sync --cloud --project <slug> 2>/dev/null
```

No es estrictamente necesario porque el SessionStart de la próxima
sesión hace el push antes del pull. Pero ayuda si tenés varias sesiones
paralelas en distintos PCs y querés convergencia rápida.

## Limitaciones conocidas

- `engram` v1.15.10 NO tiene autosync nativo (no hay daemon que escuche
  cambios del local y empuje al cloud sin comando explícito).
- El hook SessionStart agrega ~200-500ms al arranque de cada sesión.
  Aceptable para sesiones interactivas; evitar en scripts batch.
- Si el cloud server cae, el hook silencia el error (`true` al final).
  El operador NO se entera salvo que el agente reporte queries vacías.
  Para alertar, reemplazar `; true` por `; notify-send 'engram sync failed'`.
