#!/bin/sh
# ClearFox one-time installer and HTTPS setup.
#
# This repo (docker-compose.yml + .env) is the customer's deployment. Run the
# installer once to log in to the registry, generate local secrets, and start
# the stack. Afterwards, update with:  git pull && docker compose pull && docker compose up -d
#
# Usage:
#   sudo REGISTRY_USER=acme REGISTRY_PASSWORD=secret ./install.sh   — install / update
#   sudo ./install.sh caddy ai.company.com                          — set up HTTPS
set -e

REGISTRY="docker.clearfox.ai"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${CLEARFOX_PORT:-3000}"

# Colors (disabled if not a terminal). Stored as real escape bytes via printf so
# they render even when placed inside a printf %s argument (not just the format).
if [ -t 1 ]; then
  RED=$(printf '\033[0;31m'); GREEN=$(printf '\033[0;32m'); YELLOW=$(printf '\033[0;33m')
  CYAN=$(printf '\033[0;36m'); BOLD=$(printf '\033[1m'); NC=$(printf '\033[0m')
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

info()  { printf "${CYAN}▸${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}⚠${NC} %s\n" "$1" >&2; }
fail()  { printf "${RED}✗ %s${NC}\n" "$1" >&2; exit 1; }

# --- Read port from .env if available ---

if [ -f "$SCRIPT_DIR/.env" ]; then
  ENV_PORT=$(grep -E '^CLEARFOX_PORT=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
  [ -n "$ENV_PORT" ] && PORT="$ENV_PORT"
fi

# ============================================================
#  caddy subcommand — install Caddy reverse proxy with HTTPS
# ============================================================

if [ "$1" = "caddy" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    fail "Caddy setup requires root — use: sudo $0 caddy <domain>"
  fi

  # Resolve domain: arg > env var > .env file > prompt
  DOMAIN="$2"
  [ -z "$DOMAIN" ] && [ -n "$CLEARFOX_DOMAIN" ] && DOMAIN="$CLEARFOX_DOMAIN"
  if [ -z "$DOMAIN" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    DOMAIN=$(grep -E '^CLEARFOX_DOMAIN=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2- || true)
  fi
  if [ -z "$DOMAIN" ]; then
    printf "Enter your domain (e.g. ai.yourcompany.com): "
    read -r DOMAIN
  fi
  [ -z "$DOMAIN" ] && fail "Domain is required"

  info "Setting up HTTPS for ${BOLD}${DOMAIN}${NC}"

  if command -v caddy >/dev/null 2>&1; then
    ok "Caddy is already installed ($(caddy version 2>/dev/null || echo 'unknown version'))"
  else
    info "Installing Caddy..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
      apt-get update -qq
      apt-get install -y -qq caddy >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y -q 'dnf-command(copr)' >/dev/null
      dnf copr enable -y @caddy/caddy >/dev/null
      dnf install -y -q caddy >/dev/null
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q yum-plugin-copr >/dev/null
      yum copr enable -y @caddy/caddy >/dev/null
      yum install -y -q caddy >/dev/null
    else
      fail "Unsupported package manager. Install Caddy manually: https://caddyserver.com/docs/install"
    fi
    ok "Caddy installed"
  fi

  info "Writing /etc/caddy/Caddyfile..."
  cat > /etc/caddy/Caddyfile << EOF
# ClearFox reverse proxy — auto-HTTPS via Let's Encrypt
${DOMAIN} {
    reverse_proxy localhost:${PORT}
}
EOF
  ok "Caddyfile written"

  if [ -f "$SCRIPT_DIR/.env" ]; then
    if grep -q '^CLEARFOX_DOMAIN=' "$SCRIPT_DIR/.env" 2>/dev/null; then
      sed -i "s|^CLEARFOX_DOMAIN=.*|CLEARFOX_DOMAIN=${DOMAIN}|" "$SCRIPT_DIR/.env"
    elif grep -q '^# CLEARFOX_DOMAIN=' "$SCRIPT_DIR/.env" 2>/dev/null; then
      sed -i "s|^# CLEARFOX_DOMAIN=.*|CLEARFOX_DOMAIN=${DOMAIN}|" "$SCRIPT_DIR/.env"
    else
      echo "CLEARFOX_DOMAIN=${DOMAIN}" >> "$SCRIPT_DIR/.env"
    fi
    ok "Domain saved to .env"
  fi

  info "Starting Caddy..."
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy
  sleep 2
  if systemctl is-active --quiet caddy; then
    ok "Caddy is running"
  else
    printf "\n"; systemctl status caddy --no-pager || true; printf "\n"
    fail "Caddy failed to start. Check the output above or run: journalctl -u caddy"
  fi

  printf "\n${GREEN}${BOLD}HTTPS is configured!${NC}\n\n"
  printf "  ClearFox is now available at ${BOLD}https://${DOMAIN}${NC}\n\n"
  printf "  Make sure:\n"
  printf "    1. DNS for ${BOLD}${DOMAIN}${NC} points to this server's IP\n"
  printf "    2. Ports 80 and 443 are open in your firewall\n"
  printf "    3. Update Portal URL in Admin → Settings to ${BOLD}https://${DOMAIN}${NC}\n\n"
  exit 0
fi

# ============================================================
#  Default — install / update ClearFox
# ============================================================

# --- Detect OS for Docker install hints ---
OS_ID=""; OS_LIKE=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"; OS_LIKE="${ID_LIKE:-}"
fi

suggest_docker_install() {
  case "$OS_ID $OS_LIKE" in
    *ubuntu*|*debian*|*fedora*|*rhel*|*centos*|*rocky*|*almalinux*)
      printf "    ${BOLD}curl -fsSL https://get.docker.com | sudo sh && sudo systemctl enable --now docker${NC}\n"
      printf "    (or follow https://docs.docker.com/engine/install/)\n" ;;
    *alpine*)
      printf "    ${BOLD}sudo apk add --no-cache docker docker-cli-compose && sudo rc-update add docker default && sudo service docker start${NC}\n" ;;
    *arch*)
      printf "    ${BOLD}sudo pacman -S --noconfirm docker docker-compose && sudo systemctl enable --now docker${NC}\n" ;;
    *)
      printf "    ${BOLD}curl -fsSL https://get.docker.com | sudo sh${NC}  (see https://docs.docker.com/engine/install/)\n" ;;
  esac
}

if ! command -v docker >/dev/null 2>&1; then
  printf "${RED}✗ Docker is not installed.${NC}\n" >&2
  printf "  Install it with:\n" >&2
  suggest_docker_install >&2
  exit 1
fi

if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  printf "${RED}✗ Docker Compose is not installed.${NC}\n" >&2
  suggest_docker_install >&2
  exit 1
fi
ok "Docker and Docker Compose found"

# --- Check RAM (recommend 8 GB) ---
if [ -f /proc/meminfo ]; then
  total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  total_gb=$((total_kb / 1024 / 1024))
  if [ "$total_gb" -lt 7 ]; then
    warn "Server reports ~${total_gb} GB RAM. ClearFox recommends at least 8 GB for the full stack."
  else
    ok "${total_gb} GB RAM detected"
  fi
fi

# --- Check CPU AVX (required by MongoDB 5.0+) ---
if [ -f /proc/cpuinfo ] && ! grep -q avx /proc/cpuinfo; then
  fail "Your CPU does not support AVX instructions, required by MongoDB 5.0+. Use a modern CPU (Intel Haswell / AMD Ryzen or newer)."
fi

cd "$SCRIPT_DIR"
[ -f docker-compose.yml ] || fail "docker-compose.yml not found in $SCRIPT_DIR — run this from the cloned repo."

# --- Registry login (required on first install) ---
if [ -n "$REGISTRY_USER" ] && [ -n "$REGISTRY_PASSWORD" ]; then
  info "Logging in to ${REGISTRY}..."
  echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin \
    || fail "Registry login failed — check the credentials we sent you."
  ok "Logged in to ${REGISTRY}"
elif ! docker pull "$REGISTRY/portal:latest" >/dev/null 2>&1; then
  fail "Not logged in to ${REGISTRY}. Re-run with: sudo REGISTRY_USER=<user> REGISTRY_PASSWORD=<pass> ./install.sh"
fi

# --- Generate .env with local secrets on first install ---
if [ ! -f .env ]; then
  info "Generating .env with fresh secrets..."
  cp .env.example .env
  SECRETS_KEY=$(openssl rand -hex 32)
  INTERNAL_KEY=$(openssl rand -hex 32)
  sed -i "s|^# PORTAL_SECRETS_KEY=.*|PORTAL_SECRETS_KEY=${SECRETS_KEY}|" .env
  sed -i "s|^# PORTAL_INTERNAL_AUTH_KEY=.*|PORTAL_INTERNAL_AUTH_KEY=${INTERNAL_KEY}|" .env
  # Warn at the very end (not here) so the "keep it safe" notice isn't buried in install logs.
  ENV_CREATED=1
  ok ".env created with fresh secrets"
else
  ok ".env already present (preserved)"
fi

# --- Pull & start ---
info "Pulling images (this may take a few minutes)..."
$COMPOSE pull --quiet
info "Starting ClearFox..."
$COMPOSE up -d

# --- Wait for healthcheck ---
info "Waiting for portal to be ready..."
attempts=0; max_attempts=40
while [ $attempts -lt $max_attempts ]; do
  if curl -sf "http://localhost:${PORT}/api/health" >/dev/null 2>&1; then break; fi
  attempts=$((attempts + 1)); sleep 3
done
if [ $attempts -ge $max_attempts ]; then
  printf "\n${RED}Portal did not become healthy within 2 minutes.${NC}\n"
  printf "Check logs with: cd %s && %s logs portal\n" "$SCRIPT_DIR" "$COMPOSE"
  exit 1
fi

printf "\n${GREEN}${BOLD}ClearFox is running!${NC}\n\n"
printf "  Open ${BOLD}http://localhost:${PORT}${NC} to complete the setup wizard.\n\n"
printf "  ${BOLD}Set up HTTPS (recommended):${NC}\n"
printf "    sudo ./install.sh caddy ${BOLD}<YOURDOMAIN>${NC}\n\n"
printf "  ${BOLD}Update later:${NC}\n"
printf "    git pull && %s pull && %s up -d\n\n" "$COMPOSE" "$COMPOSE"

# Last line on purpose: a freshly generated .env holds unrecoverable secrets.
if [ -n "${ENV_CREATED:-}" ]; then
  printf "${RED}${BOLD}⚠ Back up your .env now — its secrets are not recoverable. Losing it means losing access to all encrypted data.${NC}\n\n"
fi
