# Deploy del cloud server productivo

Guía integral para desplegar `engram` cloud server en un servidor de
empresa para un equipo de 2-N developers. Pensado para Linux + Docker
+ Tailscale.

> Si todavía no leíste [`PROJECT-ISOLATION.md`](PROJECT-ISOLATION.md)
> y [`ARCHITECTURE.md`](ARCHITECTURE.md), empezá por ahí. Este doc es
> el "cómo levantar el server", no el "qué problema resuelve".

## 1. Resumen ejecutivo

| Tema | Decisión |
|---|---|
| **Backend** | `engram` server + Postgres 16, Docker Compose |
| **Exposición** | Tailscale `serve` (zero-trust) |
| **Plan B exposición** | Cloudflare Tunnel (sección 9) |
| **Auth** | Bearer token compartido (`ENGRAM_CLOUD_TOKEN`) |
| **Multi-tenancy** | Por nombre de proyecto via `ENGRAM_CLOUD_ALLOWED_PROJECTS` |
| **Persistencia** | Volumen Docker `engram-cloud-pg` |
| **Backups** | Cron diario + replicación off-site cifrada con `age` |
| **Auto-start** | systemd unit |

## 2. Pre-requisitos del server

| Recurso | Mínimo | Recomendado |
|---|---|---|
| OS | Ubuntu 22.04+ / Debian 12 | Ubuntu 24.04 LTS |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Disco | 20 GB SSD | 50 GB SSD |
| Docker Engine | 24.x | 27+ |
| Docker Compose | v2 plugin | v2.20+ |
| Acceso | SSH solo por clave | + sudo + 2FA |

```bash
sudo apt update && sudo apt install -y docker.io docker-compose-v2 curl
sudo usermod -aG docker $USER
```

## 3. Layout

```bash
sudo useradd -m -s /bin/bash engram
sudo usermod -aG docker engram
sudo -iu engram

git clone <url-de-este-repo> ~/engram-cloud
cd ~/engram-cloud
mkdir -p backups
```

## 4. Generar secretos

```bash
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48; echo; }
echo "ENGRAM_CLOUD_TOKEN=$(gen)"
echo "ENGRAM_CLOUD_ADMIN=$(gen)"
echo "ENGRAM_JWT_SECRET=$(gen)"
echo "POSTGRES_PASSWORD=$(gen)"
```

Anotalos en el password manager corp ANTES de seguir.

## 5. `.env`

```bash
cp .env.example .env
chmod 600 .env
# editar con los secretos generados
```

Ver `.env.example` en la raíz del repo para todos los campos.

## 6. Levantar el stack

```bash
docker compose pull
docker compose up -d
docker compose ps          # ambos containers Up + healthy
docker compose logs -f cloud   # ver arranque
```

## 7. systemd para auto-start

`/etc/systemd/system/engram-cloud.service` — copiar desde `systemd/engram-cloud.service`
y ajustar `User`, `Group`, `WorkingDirectory` al setup real.

```bash
sudo cp systemd/engram-cloud.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now engram-cloud.service
sudo systemctl status engram-cloud.service
```

## 8. Tailscale serve (exposición a la tailnet)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --authkey=<tskey-...> --advertise-tags=tag:engram-prod --ssh
tailscale status
sudo tailscale serve --bg --https=443 http://127.0.0.1:18080
tailscale serve status
# URL: https://<host>.<your-tailnet>.ts.net
```

## 9. Plan B — Cloudflare Tunnel (si IT bloquea Tailscale)

```bash
curl -L --output cloudflared.deb \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i cloudflared.deb
cloudflared tunnel login
cloudflared tunnel create engram-prod

cat > ~/.cloudflared/config.yml << EOF
tunnel: engram-prod
credentials-file: /home/engram/.cloudflared/<UUID>.json
ingress:
  - hostname: engram.<your-domain>
    service: http://127.0.0.1:18080
  - service: http_status:404
EOF

cloudflared tunnel route dns engram-prod engram.<your-domain>
sudo cloudflared service install
```

**Auth extra recomendada**: Cloudflare Access encima del tunnel
(SSO con Google/Okta), gratis hasta 50 usuarios.

## 10. Backups

Ver `scripts/backup.sh` y `scripts/offsite.sh`. Configurar cron:

```bash
crontab -e
0 3 * * * /home/engram/engram-cloud/scripts/backup.sh >> /home/engram/engram-cloud/backups/cron.log 2>&1
0 4 * * * /home/engram/engram-cloud/scripts/offsite.sh
```

Editar `scripts/offsite.sh` con tu `AGE_RECIPIENT` real (clave pública
age guardada en password manager corp).

## 11. Manejo de tokens

Ver `SECURITY.md` y `docs/CONTINGENCY-PLAN.md` Escenario 3.

| Var | Para qué | Quién la necesita |
|---|---|---|
| `ENGRAM_CLOUD_TOKEN` | Auth bearer de clientes | Cada dev (en su `~/.bashrc`) |
| `ENGRAM_CLOUD_ADMIN` | Acceso al dashboard admin | Solo el admin del server |
| `ENGRAM_JWT_SECRET` | Firma interna de JWTs | Solo el server |

Rotación recomendada cada 90 días.

## 12. Hardening checklist

- [ ] `.env` con `chmod 600`
- [ ] Postgres SIN `ports:` expuestos
- [ ] SSH solo por clave
- [ ] `ufw` o `nftables` deny incoming default
- [ ] Imagen del cloud pinneada a versión específica
- [ ] Backups corriendo + verificados
- [ ] Off-site backup cifrado
- [ ] Tokens en password manager corp
- [ ] Tailscale ACL limita quién ve el nodo
- [ ] Logs rotando
- [ ] Monitor `/health` cada N min
- [ ] Procedimiento de rotación de token comunicado al equipo

## 13. Troubleshooting

| Síntoma | Causa probable | Acción |
|---|---|---|
| `engram cloud status` → "token not configured" | Falta env var en el shell | `source ~/.bashrc` |
| Sync falla con 401/403 | Token incorrecto | Releer `.env` del server |
| Sync falla con "project not allowed" | Falta en allowlist | Editar `.env`, restart service |
| Container OOM-killed | RAM insuficiente | Subir RAM o tuning Postgres |
| Logs llenan disco | Sin rotación | `/etc/docker/daemon.json` log-opts |

Ver `docs/CONTINGENCY-PLAN.md` para escenarios completos.

## 14. Cuándo escalar

El modelo "1 token compartido" es OK para 2-5 devs de confianza.
Considerar migrar a tokens-por-dev cuando:

- El equipo crece a 6+
- Hay rotación de personas (cada baja = rotación de token global)
- Necesitás auditoría por usuario
- Compliance lo exige (SOC2, ISO27001)

`engram` hoy NO soporta multi-token nativo. Workaround: reverse proxy
con auth previa (nginx + auth_request, o Cloudflare Access) que valide
identidad y reescriba header al token único interno.
