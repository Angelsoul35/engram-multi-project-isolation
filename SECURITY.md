# Postura de seguridad

## Resumen

Este toolkit no introduce código nuevo de runtime — son scripts shell, Python
helpers, configuración Docker y documentación. La superficie de ataque viene
mayormente del binario `engram` upstream y de la stack del cloud server
(Docker, Postgres, Tailscale).

## Versiones soportadas

Solo la **última versión** del toolkit recibe fixes de seguridad. Para el
binario `engram`, ver la política upstream:
https://github.com/gentleman-programming/engram/blob/main/SECURITY.md

## Reportar vulnerabilidades

- **Vulnerabilidad en este toolkit** (scripts, docs, configuración):
  abrir un GitHub Security Advisory en este repositorio:
  `https://github.com/<this-repo>/security/advisories/new`
- **Vulnerabilidad en el binario `engram`**: reportar upstream:
  https://github.com/gentleman-programming/engram/security/advisories/new
- **Vulnerabilidad en Postgres**: pgsql-security@postgresql.org
- **Vulnerabilidad en Tailscale**: security@tailscale.com

NO publicar CVEs en issues abiertos hasta que el fix esté disponible.

## Garantías que SÍ provee este toolkit

1. **Aislamiento físico cross-project**: cada proyecto tiene su propio
   SQLite (`~/.engram-<slug>/`). Verificable con
   `scripts/validate-isolation.sh` (16 checks, incluye runtime probe).

2. **Cero secretos en el repo**: el `.env` real está en `.gitignore`. Solo
   se versiona `.env.example` con placeholders. El token del cloud vive en
   `~/.engram-<slug>/cloud.json` (perms 600), nunca en el repo del proyecto.

3. **Backups verificables**: `scripts/backup.sh` + retención + offsite
   cifrado opcional con `age`. Restore drill documentado.

4. **CI gates anti-regresión**: workflow valida cada push/PR. Detecta
   regresiones de portabilidad (paths hardcoded), syntax errors, shellcheck
   warnings.

5. **Pre-commit hook**: bloquea regresiones antes de llegar a CI.

## Lo que este toolkit NO garantiza

1. **Acceso root al PC del dev** → cualquier modelo de aislamiento se
   rompe. Mitigación: hardening del PC, perms 700 sobre data dirs.

2. **Compromiso del cloud server** → si un atacante toma control del
   server cloud, puede leer todas las observations sincronizadas.
   Mitigación: hardening del server (PRODUCTION-DEPLOY.md sección 10),
   exposición solo via Tailscale o tunnel autenticado.

3. **Bug zero-day en `engram`** que viole el contrato de
   `ENGRAM_DATA_DIR`. Mitigación: pin de versión defensivo en
   `setup-isolated-project.sh`, monitoreo via `validate-isolation.sh`.

4. **Bug zero-day en Postgres / Docker / Tailscale**. Mitigación: pin de
   versiones + chequeo periódico via `scripts/check-updates.sh`.

## Rotación de credenciales

Recomendado cada 90 días:

- `ENGRAM_CLOUD_TOKEN` (bearer compartido del cloud)
- `ENGRAM_CLOUD_ADMIN` (token del dashboard admin)
- SSH keys de devs hacia el server

Procedimiento detallado en `docs/PRODUCTION-DEPLOY.md` sección 8.

## Defensa en profundidad

Ver `docs/ARCHITECTURE.md` sección "DEFENSE IN DEPTH" para las 8 capas
documentadas y qué pasa si cada una falla individualmente.
