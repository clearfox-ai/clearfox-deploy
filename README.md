# ClearFox — Deployment

Self-hosted ClearFox stack (portal + MongoDB + MCP servers). This repo is the
single source of truth for your deployment: the `docker-compose.yml` here pulls
images from the private registry `docker.clearfox.ai`.

## Requirements

- A Linux server with **Docker** and **Docker Compose** (the installer checks).
- At least **8 GB RAM** and a modern CPU (AVX support, required by MongoDB).
- Registry **username + password** — sent to you by ClearFox during onboarding.

## Install (once)

```bash
git clone https://github.com/clearfox-ai/clearfox-deploy /opt/clearfox
cd /opt/clearfox
sudo REGISTRY_USER=<your-username> REGISTRY_PASSWORD=<your-password> ./install.sh
```

The installer logs in to the registry, generates a local `.env` with fresh
secrets, pulls the images, and starts the stack. When it finishes, open
`http://localhost:3000` to run the setup wizard.

### Manual setup (without the installer)

Prefer to do it yourself? Log in to the registry and start the stack manually.
First copy `.env.example` to `.env` and set `PORTAL_SECRETS_KEY` and
`PORTAL_INTERNAL_AUTH_KEY` to random values (`openssl rand -hex 32`):

```bash
docker login docker.clearfox.ai -u <your-username>
docker compose pull
docker compose up -d
```

### HTTPS (recommended)

```bash
sudo ./install.sh caddy ai.yourcompany.com
```

Installs Caddy and obtains a Let's Encrypt certificate automatically. Make sure
DNS for the domain points to this server and ports 80/443 are open.

## Update

```bash
cd /opt/clearfox
git pull
docker compose pull
docker compose up -d
```

Your `.env` (with your secrets) is never overwritten. The registry login
persists, so no need to log in again.

## Customizing the stack

`docker-compose.yml` is overwritten on every `git pull`, so don't edit it
directly. Put changes in a `docker-compose.override.yml` next to it — Compose
merges it automatically and `git pull` never touches it (it's gitignored).

```yaml
# docker-compose.override.yml
services:
  portal:
    ports:
      - "8080:3000"
    mem_limit: 2g
```

Then `docker compose up -d` as usual. Preview the merged result with
`docker compose config`.

## Useful commands

```bash
docker compose logs -f portal   # view logs
docker compose down             # stop
```
