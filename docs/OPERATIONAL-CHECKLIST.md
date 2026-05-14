# Checklist operacional de despliegue

Checklist paso-a-paso para desplegar `engram` cloud + isolation
arquitectónico en un servidor con equipo de 2-5 developers. Imprimible
y marcable item por item. NO declarar production-ready hasta TODOS
los checkboxes verde.

## Fase 1 — Server cloud (admin único, ~2 horas)

### Pre-flight

- [ ] Server con Ubuntu 24.04 LTS, mín. 4 vCPU + 8 GB RAM + 50 GB SSD
- [ ] SSH solo por clave pública (`PasswordAuthentication no` en sshd)
- [ ] Usuario dedicado `engram` creado (sudo opcional, docker grupo sí)
- [ ] Docker Engine >= 27 + Docker Compose v2.20+ instalados
- [ ] Tailscale instalado y logueado con cuenta corp
- [ ] Tag corp creado en admin Tailscale: `tag:engram-prod`
- [ ] Password manager corp con al menos 4 secretos generados
      (`ENGRAM_CLOUD_TOKEN`, `ENGRAM_CLOUD_ADMIN`, `ENGRAM_JWT_SECRET`,
      `POSTGRES_PASSWORD`), todos 48 chars random alfanum

### Deploy del stack

- [ ] Clonar este repo en `/home/engram/engram-cloud`
- [ ] Copiar `.env.example` → `.env` y popular con secretos
- [ ] `chmod 600 .env`
- [ ] `docker compose pull`
- [ ] `docker compose up -d`
- [ ] `docker compose ps` muestra ambos containers Up + healthy
- [ ] `curl -fsS http://127.0.0.1:18080/health` responde 200
- [ ] `sudo cp systemd/engram-cloud.service /etc/systemd/system/`
- [ ] `sudo systemctl daemon-reload`
- [ ] `sudo systemctl enable --now engram-cloud.service`
- [ ] `sudo systemctl status engram-cloud.service`: active

### Exposición via Tailscale

- [ ] `sudo tailscale up --advertise-tags=tag:engram-prod --ssh`
- [ ] `tailscale status`: nodo aparece con tag correcto
- [ ] `sudo tailscale serve --bg --https=443 http://127.0.0.1:18080`
- [ ] `tailscale serve status`: muestra https expuesto
- [ ] `curl -fsS https://<host>.<tailnet>.ts.net/health` responde 200
      (desde otro PC en la tailnet)

### Allowlist inicial

- [ ] Editar `.env` y agregar slugs de los proyectos del equipo a
      `ENGRAM_CLOUD_ALLOWED_PROJECTS` (separados por coma)
- [ ] `sudo systemctl restart engram-cloud.service`
- [ ] `docker compose logs cloud | grep allowlist` (verificar carga OK)

### Backups

- [ ] `scripts/backup.sh` ejecutado manualmente — genera dump comprimido
- [ ] crontab: `0 3 * * * /path/scripts/backup.sh ...` activo
- [ ] (recomendado) age key generada para offsite, vault corp
- [ ] (recomendado) `scripts/offsite.sh` configurado con `AGE_RECIPIENT` real
- [ ] (recomendado) crontab para offsite también
- [ ] Restore drill ejecutado en server staging — verificado data OK

### Monitoreo

- [ ] Healthcheck externo configurado (uptimekuma / healthchecks.io /
      Datadog) sobre el endpoint `/health`
- [ ] Alertas a oncall configuradas
- [ ] Logs de Docker rotando (max 10MB × 5 archivos por container,
      ya configurado en `docker-compose.yml`)

## Fase 2 — Por cada dev del equipo (~30 min por persona)

### Pre-reqs del dev

- [ ] Tailscale corp activo en su PC
- [ ] `engram` CLI >= 1.15.10 instalado en `~/.local/bin/engram`
      (https://github.com/gentleman-programming/engram/releases)
- [ ] `engram --version` reporta >= 1.15.10
- [ ] `~/.engram/cloud.json` poblado con URL del server cloud + token
      compartido del `.env` del server
- [ ] `export ENGRAM_CLOUD_TOKEN=...` agregado a `~/.bashrc`
- [ ] `source ~/.bashrc`

### Validar acceso al cloud

- [ ] `engram cloud status`: "Auth status: ready"
- [ ] `curl -fsS https://<host>.<tailnet>.ts.net/health`: 200

### Clonar el repo de tools

- [ ] `git clone <url-de-este-repo> ~/engram-multi-project-isolation`
- [ ] (recomendado) `cd ~/engram-multi-project-isolation && ./scripts/install-pre-commit.sh`

## Fase 3 — Por cada proyecto que el dev va a trabajar (~10 min)

### Clone + setup

- [ ] `git clone <url-del-repo-del-proyecto> ~/projects/<slug>`
- [ ] `cd ~/projects/<slug>`
- [ ] `~/engram-multi-project-isolation/scripts/setup-isolated-project.sh \`
      `   --slug <slug> --repo $(pwd)`
- [ ] Output muestra "ENGRAM ISOLATED PROJECT — SETUP DONE"
- [ ] `ls ~/.engram-<slug>/` muestra: `cloud.json` + `engram.db`

### Migración (solo si el proyecto tenía memorias en global)

- [ ] Verificar conteo del slug en global:
      `python3 -c "import sqlite3; print(sqlite3.connect('$HOME/.engram/engram.db').execute(\"SELECT COUNT(*) FROM observations WHERE project='<slug>'\").fetchone()[0])"`
- [ ] Si > 0: `~/engram-multi-project-isolation/scripts/migrate-to-isolated.sh --slug <slug>`
- [ ] Output muestra "MIGRACIÓN A AISLADO — DONE"
- [ ] Backup pre-migración existe en `~/.engram/.backups/`

### Validación E2E

- [ ] `~/engram-multi-project-isolation/scripts/validate-isolation.sh \`
      `   --slug <slug> --repo $(pwd)`
- [ ] Output: "16 pass, 0 fail" exit 0
- [ ] Si algún check falla: NO continuar. Investigar el FAIL específico
      antes de declarar production-ready para este proyecto

### Pre-commit hook del proyecto (opcional, defense in depth)

- [ ] `cd ~/projects/<slug>`
- [ ] `~/engram-multi-project-isolation/scripts/install-pre-commit.sh`

### Prueba con sesión Claude

- [ ] `cd ~/projects/<slug>`
- [ ] `claude` (abrir nueva sesión)
- [ ] Verificar banner "PROJECT SCOPE: <slug>" aparece al arranque
- [ ] Pedir al agente: "buscá en engram el contexto del proyecto"
- [ ] Verificar respuesta menciona SOLO `<slug>`, NO otros proyectos

## Fase 4 — Post-deploy (responsabilidad del admin)

### Gobernanza

- [ ] Documentar `<slug>` → owner del proyecto (quién es el dev primario)
- [ ] Comunicar al equipo el procedimiento para sumar nuevos proyectos
      (Fase 3 → setup + migrate + validate)
- [ ] Comunicar el procedimiento de rotación del cloud token
      (cada 90 días sugerido, ver `PROJECT-ISOLATION.md`)
- [ ] Comunicar el procedimiento de update de `engram` CLI
      (ver `SECURITY.md`)

### Branch protection del repo de tools

- [ ] GitHub Settings → Branches → Add rule para `main`
- [ ] Require pull request before merging (mín 1 reviewer)
- [ ] Require status checks: "Validate scripts + docs" debe pasar
- [ ] Require linear history
- [ ] Allow force pushes: OFF
- [ ] Allow deletions: OFF
- [ ] Include administrators

### Auditoría periódica (mensual)

- [ ] Cada dev corre `validate-isolation.sh` sobre cada proyecto.
      Reporta resultados al admin
- [ ] Restore drill del server cloud (ver `PRODUCTION-DEPLOY.md` sec 7.3)
- [ ] Revisar logs del cloud por accesos sospechosos
- [ ] `check-updates.sh` — `engram` + Postgres última versión?
- [ ] Auditar quiénes tienen `ENGRAM_CLOUD_TOKEN`. Rotar si alguien dejó
      el equipo

## Criterios de go-live

Declarar production-ready cuando:

- [ ] Server cloud: 2/2 containers healthy continuamente por 24h+
- [ ] Backup automático ejecutándose diario sin fallos por 7 días
- [ ] Monitoring envió al menos 1 alerta de prueba (verificada)
- [ ] Restore drill ejecutado en staging — datos restaurados OK
- [ ] Al menos 1 dev del equipo completó Fase 2 + Fase 3 para 1 proyecto
- [ ] `validate-isolation.sh` devuelve 16/16 sobre ese proyecto
- [ ] Branch protection del repo de tools activa
- [ ] CI `.github/workflows/validate.yml` verde en `main`

## Criterios de rollback

Si después de declarar production-ready aparece falla crítica:

- [ ] Server cloud caído > 1 hora: comunicar al equipo, ejecutar
      escenarios 1-3 de `CONTINGENCY-PLAN.md`
- [ ] `validate-isolation.sh` falla en cualquier proyecto: ejecutar
      `rollback-isolated.sh` para ese proyecto + investigar causa raíz
- [ ] Backup falla 2 días consecutivos: investigar disk space + perms
- [ ] Sospecha de leak cross-project: PARAR todo trabajo en proyectos
      involucrados, ejecutar `validate-isolation.sh`, levantar incidente

## Referencias rápidas

```bash
# Setup nuevo proyecto isolated
./scripts/setup-isolated-project.sh --slug X --repo /path

# Validar isolated
./scripts/validate-isolation.sh --slug X --repo /path

# Rollback isolated
./scripts/rollback-isolated.sh --slug X --repo /path

# Backup server
./scripts/backup.sh

# Restore server
./scripts/restore.sh /path/al/dump.sql.gz

# Smoke server
ENGRAM_CLOUD_TOKEN=... ./scripts/smoke.sh https://<url>

# Update check
./scripts/check-updates.sh
```
