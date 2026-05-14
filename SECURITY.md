# Postura de seguridad

## Política CVE — ZERO CVE ABSOLUTE (con escalación documentada)

**Objetivo**: 0 CVEs en TODAS las severidades (LOW + MEDIUM + HIGH + CRITICAL)
sobre las imágenes Docker pinneadas en `docker-compose.yml`.

**Estado actual al 2026-05-14** (verificado con Trivy v0.5x):

| Componente | Imagen | CVEs (todas severidades) | Estado |
|---|---|---|---|
| Postgres | `cgr.dev/chainguard/postgres:latest@sha256:42865a...` | **0** | ✅ ZERO CVE absolute |
| engram cloud server | `ghcr.io/gentleman-programming/engram:1.15.11@sha256:987a2f...` | **3** (1 CRITICAL + 1 HIGH + 1 LOW) | ⚠️ ACEPTADAS con mitigación + escalación upstream |

**Las 3 CVEs en engram NO son fixeables desde este toolkit** (son
dependencias del binario Go). Cada una está documentada explícitamente
en `.github/cve-acceptance.yml` con:

- Severidad
- Versión fixeada disponible upstream
- Mitigación aplicada en nuestra arquitectura
- Riesgo residual evaluado
- Link al issue upstream
- Fecha de re-evaluación obligatoria (cada 90 días)

El job de CI `trivy-gate` falla si aparece UNA CVE que no esté en el
acceptance file. Esto previene regresiones silenciosas.

## CVEs conocidas en engram (upstream)

### CVE-2026-33816 — CRITICAL — pgx/v5 5.7.6 → 5.9.0

**Descripción**: Memory-safety vulnerability en `github.com/jackc/pgx/v5`.

**Impacto en este toolkit**: bajo. La vulnerabilidad ocurre en el cliente pgx
consumiendo data del server Postgres. En nuestra arquitectura:

- El server Postgres está aislado en el bridge interno de Docker (no expuesto)
- engram es el único cliente de esa Postgres
- No hay multi-tenant Postgres con clientes untrusted

Para que esta CVE se explote acá, un atacante tendría que comprometer el
container Postgres primero, lo cual ya implicaría compromiso total del stack.

**Mitigación**: arquitectura de aislamiento (bridge interno, no exposición
externa de Postgres).

**Fix permanente**: esperar release de engram que bumpee pgx/v5 a >= 5.9.0.

### CVE-2026-32285 — HIGH — buger/jsonparser → 1.1.2

**Descripción**: DoS via malformed JSON input.

**Impacto**: bajo a medio. engram parsea JSON de requests autenticados.
Worst case: atacante autenticado puede crashear el proceso engram con un
JSON crafted.

**Mitigación**:

- Auth obligatoria por bearer token (filtra atacantes anónimos)
- Acceso solo via Tailscale (capa de red autenticada antes de llegar a engram)
- Docker restart policy `unless-stopped` recupera el proceso si crashea
- Rate limiting opcional via reverse proxy (Cloudflare/nginx) si se necesita

**Fix permanente**: esperar release de engram con jsonparser 1.1.2+.

### CVE-2026-41889 — LOW — pgx/v5 → 5.9.2

Severity LOW. Misma mitigación arquitectónica que CVE-2026-33816.

## Verificación continua (CI gate)

`.github/workflows/validate.yml` corre el job `trivy-scan` en cada
push/PR a `main`. Output esperado:

```
postgres :latest@sha256:42865a... CVEs found: 0   → PASS
engram :1.15.11@sha256:987a2f... CVEs found: 3 (en acceptance) → PASS
```

Si Trivy detecta una CVE NO listada en `.github/cve-acceptance.yml`,
el job FAIL y el merge se bloquea. Esto impide regresiones.

## Bumpear versiones

Cuando upstream libere una versión que fixea una de las CVEs aceptadas:

1. Bumpear el digest en `docker-compose.yml`
2. Re-correr Trivy local: `./scripts/check-updates.sh`
3. Si la CVE desapareció: remover su entrada de `.github/cve-acceptance.yml`
4. Commit + PR + verificar que CI pasa

Para postgres (que está en 0 CVE): `./scripts/check-updates.sh` también
detecta nuevos digests del Chainguard image. Bumpear cuando aparezca uno
nuevo (Chainguard rebuild diario).

## Reportar vulnerabilidades

- **En este toolkit** (scripts, docs, configuración): GitHub Security Advisory
  en este repositorio: `https://github.com/<org>/<repo>/security/advisories/new`
- **En el binario `engram`**: upstream
  https://github.com/gentleman-programming/engram/security/advisories/new
- **En Postgres**: pgsql-security@postgresql.org
- **En Chainguard images**: security@chainguard.dev
- **En Tailscale**: security@tailscale.com

NO publicar CVEs en issues abiertos hasta que el fix esté disponible.

## Lo que este toolkit garantiza

1. **Aislamiento físico cross-project**: cada proyecto tiene su propio
   SQLite (`~/.engram-<slug>/`). Verificable con
   `scripts/validate-isolation.sh` (16 checks reproducibles, incluye
   runtime probe via JSON-RPC stdio).

2. **Cero secretos en el repo**: el `.env` real está en `.gitignore`. Solo
   se versiona `.env.example` con placeholders. El token del cloud vive
   en `~/.engram-<slug>/cloud.json` (perms 600), nunca en el repo.

3. **Backups verificables**: `scripts/backup.sh` + retención + offsite
   cifrado opcional con `age`. Restore drill documentado.

4. **CI gates anti-regresión**: workflow valida cada push/PR. Detecta
   CVEs nuevas, regresiones de portabilidad, syntax errors, shellcheck
   warnings.

5. **Pre-commit hook**: bloquea regresiones antes de llegar a CI.

6. **Pin de versión defensivo**: `setup-isolated-project.sh` exige
   engram CLI >= 1.15.10. Si una versión futura rompe `ENGRAM_DATA_DIR`,
   el setup falla con mensaje claro antes de configurar mal.

## Lo que este toolkit NO garantiza (límites físicos)

1. **Acceso root al PC del dev** rompe cualquier modelo de aislamiento.
   Mitigación: hardening del PC, perms 700 sobre data dirs.

2. **Compromiso del cloud server**: si un atacante toma control del
   server cloud, puede leer todas las observations sincronizadas.
   Mitigación: hardening del server (PRODUCTION-DEPLOY.md sección 12),
   exposición solo via Tailscale o tunnel autenticado.

3. **Bug zero-day en engram** que viole `ENGRAM_DATA_DIR`. Mitigación:
   pin de versión defensivo + monitoreo via `validate-isolation.sh`.

4. **Bug zero-day en Postgres / Docker / Tailscale**. Mitigación: pin
   de versiones + Trivy CI gate + `scripts/check-updates.sh` semanal.

## Rotación de credenciales

Recomendado cada 90 días:

- `ENGRAM_CLOUD_TOKEN` (bearer compartido del cloud)
- `ENGRAM_CLOUD_ADMIN` (token del dashboard admin)
- SSH keys de devs hacia el server

Procedimiento detallado en `docs/PRODUCTION-DEPLOY.md`.

## Defensa en profundidad

Ver `docs/ARCHITECTURE.md` sección "DEFENSE IN DEPTH" para las 8 capas
documentadas y qué pasa si cada una falla individualmente.
