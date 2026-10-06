#!/usr/bin/env bash
# ============================================================================
#  NETCORE — Production Install Script
#  Usage: sudo bash install.sh [OPTIONS]
#
#  (no flags)    Fresh install, or re-pull + restart if already installed.
#  --clean       Stop and remove all containers, volumes, images, and .env.
#                Use this to wipe a previous installation. Exits when done
#                (does NOT proceed with a fresh install).
#  --reinstall   Same wipe as --clean, then immediately performs a fresh
#                install. ALL DATA WILL BE LOST.
# ============================================================================
set -euo pipefail

# ─── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}──── $* ────${NC}"; }

ask() {
  # ask <prompt> <default> <var_name>
  printf "${CYAN}  %-40s [%s]: ${NC}" "$1" "$2"
  read -r _inp; eval "$3=\"\${_inp:-$2}\""
}

ask_secret() {
  # ask_secret <prompt> <var_name>
  printf "${CYAN}  %-40s : ${NC}" "$1"
  read -rs _sec; echo; eval "$2=\"\$_sec\""
}

# Compute a SHA-256 fingerprint of this machine's hardware identifiers.
# Sources: system UUID (DMI/SMBIOS), primary MAC, systemd machine-id.
# A full-disk clone on a different physical/virtual host will produce a
# different fingerprint; a clone with identical hardware IDs (same VM snapshot
# on the same host) requires an online license check (Phase 5).
_machine_fingerprint() {
  local _uuid _mac _mid
  _uuid=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null \
          || cat /sys/class/dmi/id/board_serial 2>/dev/null \
          || echo "unknown-uuid")
  _mac=$(ip link show 2>/dev/null | awk '/link\/ether/{print $2; exit}' \
         || echo "unknown-mac")
  _mid=$(cat /etc/machine-id 2>/dev/null \
         || cat /var/lib/dbus/machine-id 2>/dev/null \
         || echo "unknown-mid")
  printf '%s|%s|%s' "$_uuid" "$_mac" "$_mid" | sha256sum | awk '{print $1}'
}

# ─── Banner ─────────────────────────────────────────────────────────────────
_VER=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
_TITLE="NETCORE${_VER:+ ${_VER}}"
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
printf "${BOLD}${BLUE}║   %-43s║${NC}\n" "${_TITLE}"
echo -e "${BOLD}${BLUE}║   Smart Load Balancing for MikroTik         ║${NC}"
echo -e "${BOLD}${BLUE}║   Designed and Developed by Pee Deleon   ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Parse flags ─────────────────────────────────────────────────────────────
REINSTALL=false
CLEAN_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --reinstall) REINSTALL=true ;;
    --clean)     CLEAN_ONLY=true ;;
    -h|--help)   sed -n '2,13p' "$0"; exit 0 ;;
  esac
done

# ─── Shared teardown function ────────────────────────────────────────────────
_teardown() {
  # Detect compose command
  if docker compose version >/dev/null 2>&1; then _DC="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then _DC="docker-compose"
  else _DC=""; fi

  section "Tearing down existing installation"

  # 1. Graceful compose shutdown (removes compose-managed volumes)
  if [[ -n "$_DC" ]]; then
    $_DC down --volumes --remove-orphans 2>/dev/null || true
    ok "Compose stack stopped"
  fi

  # 2. Force-stop any lingering netcore containers that compose may have missed
  #    (handles renamed project, leftover containers from old installs, etc.)
  local _lingering
  _lingering=$(docker ps -a --format '{{.Names}}' \
    | grep -E '^(netcore[-_]|ipoe[-_])?(api|web|postgres|redis|nginx|updater)[-_]?[0-9]*$' \
    || true)
  if [[ -n "$_lingering" ]]; then
    echo "$_lingering" | xargs -r docker rm -f 2>/dev/null || true
    ok "Lingering containers removed"
  fi

  # 3. Explicitly remove known volumes by both old and new naming conventions
  #    (compose prefixes volumes with the project/directory name)
  local _vols=(
    netcore_pgdata   netcore_redisdata
    ipoe_pgdata      ipoe_redisdata
    pgdata           redisdata
  )
  for _v in "${_vols[@]}"; do
    docker volume rm "$_v" 2>/dev/null && ok "Volume removed: $_v" || true
  done

  # 4. Remove images: old locally-built (netcore-*) AND ghcr images (ghcr.io/*/netcore-*)
  docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -E '(^netcore-|/netcore-)' \
    | xargs -r docker rmi -f 2>/dev/null || true
  ok "Project images removed"

  # 5. Remove .env so the interactive setup runs fresh
  if [[ -f .env ]]; then
    rm -f .env
    ok ".env removed"
  fi
}

# ─── --clean: wipe only, then exit ───────────────────────────────────────────
if [[ "$CLEAN_ONLY" == "true" ]]; then
  echo -e "\n${BOLD}${RED}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║   ⚠  CLEAN — ALL DATA WILL BE LOST      ⚠   ║${NC}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  This will permanently delete:"
  echo -e "  ${RED}•${NC} All containers (api, web, postgres, redis, nginx, updater)"
  echo -e "  ${RED}•${NC} All Docker volumes (database, redis data)"
  echo -e "  ${RED}•${NC} All pulled/built images (old local + ghcr)"
  echo -e "  ${RED}•${NC} The .env configuration file"
  echo ""
  printf "${RED}  Type YES to confirm: ${NC}"
  read -r _confirm
  if [[ "$_confirm" != "YES" ]]; then echo "Aborted."; exit 0; fi

  _teardown

  echo ""
  ok "Cleanup complete. Run ${BOLD}sudo bash install.sh${NC} to install fresh."
  echo ""
  exit 0
fi

# ─── --reinstall: wipe then continue with fresh install ──────────────────────
if [[ "$REINSTALL" == "true" ]]; then
  echo -e "\n${BOLD}${RED}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${RED}║   ⚠  REINSTALL — ALL DATA WILL BE LOST  ⚠   ║${NC}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  This will permanently delete:"
  echo -e "  ${RED}•${NC} All containers (api, web, postgres, redis, nginx, updater)"
  echo -e "  ${RED}•${NC} All Docker volumes (database, redis data)"
  echo -e "  ${RED}•${NC} All pulled/built images (old local + ghcr)"
  echo -e "  ${RED}•${NC} The .env configuration file"
  echo ""
  printf "${RED}  Type YES to confirm: ${NC}"
  read -r _confirm
  if [[ "$_confirm" != "YES" ]]; then echo "Aborted."; exit 0; fi

  _teardown

  echo ""
  info "Teardown complete — proceeding with fresh installation…"
  echo ""
fi

# ─── 1. Prerequisites ────────────────────────────────────────────────────────
section "Checking prerequisites"

# ── Helper: detect apt/dnf/yum package manager ──────────────────────────────
_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1;   then echo dnf
  elif command -v yum >/dev/null 2>&1;   then echo yum
  else echo ""; fi
}

# ── Auto-install Docker if missing ──────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  warn "Docker not found — installing via get.docker.com …"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- https://get.docker.com | sh
  else
    die "Neither curl nor wget found. Cannot download Docker installer."
  fi
  # Add current user to docker group (effective on next login; daemon runs as root here)
  usermod -aG docker "${SUDO_USER:-root}" 2>/dev/null || true
  command -v docker >/dev/null 2>&1 || die "Docker installation failed."
  ok "Docker installed"
fi

# ── Ensure Docker daemon is running ─────────────────────────────────────────
if ! docker info >/dev/null 2>&1; then
  warn "Docker daemon not running — starting it …"
  systemctl enable --now docker >/dev/null 2>&1 \
    || die "Failed to start Docker daemon. Run: systemctl start docker"
fi

# ── Prefer 'docker compose' (v2 plugin); fall back to 'docker-compose' (v1) ─
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  warn "Docker Compose plugin not found — installing …"
  _PKG=$(_pm)
  case "$_PKG" in
    apt) apt-get install -y docker-compose-plugin >/dev/null 2>&1 ;;
    dnf) dnf install -y docker-compose-plugin >/dev/null 2>&1 ;;
    yum) yum install -y docker-compose-plugin >/dev/null 2>&1 ;;
    *)   die "Cannot auto-install Docker Compose. Install manually: https://docs.docker.com/compose/install/" ;;
  esac
  docker compose version >/dev/null 2>&1 \
    || die "Docker Compose installation failed."
  DC="docker compose"
  ok "Docker Compose installed"
fi

# ── Auto-install openssl if missing ─────────────────────────────────────────
if ! command -v openssl >/dev/null 2>&1; then
  warn "openssl not found — installing …"
  _PKG=$(_pm)
  case "$_PKG" in
    apt) apt-get install -y openssl >/dev/null 2>&1 ;;
    dnf) dnf install -y openssl >/dev/null 2>&1 ;;
    yum) yum install -y openssl >/dev/null 2>&1 ;;
    *)   die "Cannot auto-install openssl. Install manually." ;;
  esac
  command -v openssl >/dev/null 2>&1 || die "openssl installation failed."
  ok "openssl installed"
fi

ok "Docker   $(docker --version | grep -oP '\d+\.\d+\.\d+')"
ok "Compose  $($DC version --short 2>/dev/null || $DC version | grep -oP '\d+\.\d+\.\d+' | head -1)"
ok "OpenSSL  $(openssl version | awk '{print $2}')"

# ─── 2. .env configuration ───────────────────────────────────────────────────
section "Environment configuration"

if [[ -f .env ]]; then
  warn ".env already exists — skipping interactive setup."
  warn "Delete .env and re-run to reconfigure, or edit it manually."
else
  # Detect sensible defaults
  DEFAULT_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' \
               || hostname -I 2>/dev/null | awk '{print $1}' \
               || echo "localhost")
  DEFAULT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null \
               || cat /etc/timezone 2>/dev/null \
               || echo "Asia/Manila")

  echo -e "  ${BOLD}Press Enter to accept the default shown in [brackets].${NC}\n"

  ask  "Server hostname or IP address"        "$DEFAULT_IP"       SERVER_HOST
  ask  "Timezone"                             "$DEFAULT_TZ"       TZ_VAL
  ask  "Admin e-mail"                         "admin@ipoe.local"  ADMIN_EMAIL
  ask_secret "Admin password"                                     ADMIN_PASS
  [[ -z "$ADMIN_PASS" ]] && ADMIN_PASS="ChangeMe123!"

  ask  "Database name"                        "ipoe"              PG_DB
  ask  "Database user"                        "ipoe"              PG_USER
  ask  "LibreQoS ShapedDevices.csv path"      "/opt/libreqos/src" LIBREQOS_DIR

  echo ""
  echo -e "  ${BOLD}License${NC} — required to pull the published containers."
  IMAGE_REGISTRY="ghcr.io/deepeyexeven"
  IMAGE_TAG="latest"
  GHCR_USER="deepeyexeven"
  ask_secret "License key"                                           GHCR_TOKEN

  # Generate strong random secrets
  PG_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
  JWT_SEC=$(openssl rand -hex 32)
  JWT_REF=$(openssl rand -hex 32)
  MT_KEY=$(openssl rand -hex 32)

  echo ""
  ask "Database password (auto-generated, press Enter to use)" "$PG_PASS" PG_PASS

  # Compose the full ShapedDevices.csv path
  LIBREQOS_CSV="${LIBREQOS_DIR%/}/ShapedDevices.csv"

  UPDATE_SECRET=$(openssl rand -hex 32)
  MACHINE_FP=$(_machine_fingerprint)

  cat > .env <<EOF
# ── Machine binding ──────────────────────────────────────────────────────────
# Generated at install time from this host's hardware identifiers.
# Do NOT copy this value to another machine — it will be rejected.
MACHINE_FINGERPRINT=${MACHINE_FP}

# ── Database ────────────────────────────────────────────────────────────────
POSTGRES_DB=${PG_DB}
POSTGRES_USER=${PG_USER}
POSTGRES_PASSWORD=${PG_PASS}
DATABASE_URL=postgresql://${PG_USER}:${PG_PASS}@postgres:5432/${PG_DB}

# ── Redis ────────────────────────────────────────────────────────────────────
REDIS_HOST=redis
REDIS_PORT=6379

# ── JWT ──────────────────────────────────────────────────────────────────────
JWT_SECRET=${JWT_SEC}
JWT_REFRESH_SECRET=${JWT_REF}
JWT_ACCESS_EXPIRY=7d
JWT_REFRESH_EXPIRY=30d

# ── MikroTik AES-256-GCM encryption key (64 hex chars = 32 bytes) ───────────
MIKROTIK_ENCRYPTION_KEY=${MT_KEY}

# ── LibreQoS ─────────────────────────────────────────────────────────────────
LIBREQOS_CSV_PATH=${LIBREQOS_CSV}

# ── API ──────────────────────────────────────────────────────────────────────
API_PORT=3001
NODE_ENV=production

# ── Server host (used for the dashboard URL shown after install) ─────────────
SERVER_HOST=${SERVER_HOST}

# ── Published images (pulled from the registry — no source/build on host) ────
IMAGE_REGISTRY=${IMAGE_REGISTRY}
IMAGE_TAG=${IMAGE_TAG}
GHCR_USER=${GHCR_USER}
GHCR_TOKEN=${GHCR_TOKEN}

# ── Timezone ─────────────────────────────────────────────────────────────────
TZ=${TZ_VAL}

# ── Seed admin ───────────────────────────────────────────────────────────────
SEED_ADMIN_EMAIL=${ADMIN_EMAIL}
SEED_ADMIN_PASSWORD=${ADMIN_PASS}

# ── In-app updater (Docker service — must match this repo's host path) ───────
REPO_DIR=${SCRIPT_DIR}
UPDATE_WEBHOOK_URL=http://updater:9099
UPDATE_WEBHOOK_SECRET=${UPDATE_SECRET}
EOF

  ok ".env written"
  chmod 600 .env
fi

# Source key values for use later in the script
SERVER_HOST=$(grep '^SERVER_HOST=' .env | cut -d= -f2-)
ADMIN_EMAIL=$(grep 'SEED_ADMIN_EMAIL'    .env | cut -d= -f2-)
ADMIN_PASS=$(grep  'SEED_ADMIN_PASSWORD' .env | cut -d= -f2-)

# ─── Machine binding verification ────────────────────────────────────────────
_STORED_FP=$(grep '^MACHINE_FINGERPRINT=' .env 2>/dev/null | cut -d= -f2- || true)
if [[ -n "$_STORED_FP" ]]; then
  _CURRENT_FP=$(_machine_fingerprint)
  if [[ "$_STORED_FP" != "$_CURRENT_FP" ]]; then
    echo ""
    echo -e "${BOLD}${RED}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${RED}║   ⛔  UNAUTHORIZED MACHINE — ACCESS DENIED  ║${NC}"
    echo -e "${BOLD}${RED}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  This installation is bound to a different machine."
    echo -e "  Running a cloned installation on unauthorized hardware"
    echo -e "  is not permitted."
    echo ""
    echo -e "  Contact ${BOLD}John Cabanding${NC} for a new installation."
    echo ""
    die "Machine fingerprint mismatch. Aborted."
  fi
  ok "Machine binding verified"
else
  # Old install (pre-binding feature) — register this machine now.
  _CURRENT_FP=$(_machine_fingerprint)
  echo "" >> .env
  echo "# ── Machine binding (added on upgrade) ──────────────────────────────────"  >> .env
  echo "MACHINE_FINGERPRINT=${_CURRENT_FP}" >> .env
  ok "Machine fingerprint registered for this host"
fi

# ─── 3. Updater webhook service ──────────────────────────────────────────────
section "Configuring in-app updater"

# Ensure UPDATE_WEBHOOK_SECRET exists in .env (handles upgrades from older installs)
if ! grep -q 'UPDATE_WEBHOOK_SECRET' .env; then
  _NEW_SECRET=$(openssl rand -hex 32)
  cat >> .env <<ENVEOF

# ── In-app updater (Docker service — must match this repo's host path) ───────
REPO_DIR=${SCRIPT_DIR}
UPDATE_WEBHOOK_URL=http://updater:9099
UPDATE_WEBHOOK_SECRET=${_NEW_SECRET}
ENVEOF
  ok "UPDATE_WEBHOOK_SECRET generated and added to .env"
fi

# Ensure REPO_DIR is set (needed by the updater Docker service for bind-mount)
if ! grep -q '^REPO_DIR=' .env; then
  echo "REPO_DIR=${SCRIPT_DIR}" >> .env
  ok "REPO_DIR added to .env (${SCRIPT_DIR})"
fi

# Upgrade: swap old host.docker.internal URL for the Docker-internal service name
sed -i 's|UPDATE_WEBHOOK_URL=http://host.docker.internal:9099|UPDATE_WEBHOOK_URL=http://updater:9099|' .env
ok "Updater configured (runs as 'updater' Docker service)"

# ─── Migrate older (source-build) installs to image-based distribution ───────
# Older .env files baked NEXT_PUBLIC_API_URL and had no registry settings.
if grep -q '^NEXT_PUBLIC_API_URL=' .env && ! grep -q '^SERVER_HOST=' .env; then
  _OLD_HOST=$(grep '^NEXT_PUBLIC_API_URL=' .env | sed 's|.*http://||;s|/api.*||')
  echo "SERVER_HOST=${_OLD_HOST}" >> .env
fi
if ! grep -q '^IMAGE_REGISTRY=' .env; then
  echo "" >> .env
  echo "# ── Published images (added on upgrade) ──" >> .env
  _MIG_REG="ghcr.io/deepeyexeven"
  _MIG_TAG="latest"
  _MIG_USER="deepeyexeven"
  ask_secret "License key"                                           _MIG_TOK
  {
    echo "IMAGE_REGISTRY=${_MIG_REG}"
    echo "IMAGE_TAG=${_MIG_TAG}"
    echo "GHCR_USER=${_MIG_USER}"
    echo "GHCR_TOKEN=${_MIG_TOK}"
  } >> .env
  ok "License key saved to .env"
fi

# ─── Detect upgrade vs fresh install ─────────────────────────────────────────
# Upgrade mode = .env already existed AND at least the postgres container is up.
# In upgrade mode we only rebuild and restart the app services (api, web,
# updater). We never restart postgres or redis — that would risk data loss.
UPGRADE=false
if [[ -f .env ]] && $DC ps --status running 2>/dev/null | grep -q postgres; then
  UPGRADE=true
fi

# ─── 4. Pull published images ────────────────────────────────────────────────
section "Pulling published images"

IMAGE_REGISTRY=$(grep '^IMAGE_REGISTRY=' .env | cut -d= -f2-)
IMAGE_TAG=$(grep '^IMAGE_TAG=' .env | cut -d= -f2-)
GHCR_USER=$(grep '^GHCR_USER=' .env | cut -d= -f2-)
GHCR_TOKEN=$(grep '^GHCR_TOKEN=' .env | cut -d= -f2-)
REGISTRY_HOST="${IMAGE_REGISTRY%%/*}"

# Log in to the private registry so the images can be pulled.
if [[ -n "$GHCR_USER" && -n "$GHCR_TOKEN" ]]; then
  if echo "$GHCR_TOKEN" | docker login "$REGISTRY_HOST" -u "$GHCR_USER" --password-stdin >/dev/null 2>&1; then
    ok "Logged in to ${REGISTRY_HOST} as ${GHCR_USER}"
  else
    warn "docker login to ${REGISTRY_HOST} failed — private image pulls may fail."
  fi
else
  warn "No registry credentials in .env — skipping login (public images only)."
fi

info "Pulling images (tag: ${IMAGE_TAG:-latest})…"

_pull_ok=false
for _attempt in 1 2 3; do
  if $DC pull; then
    _pull_ok=true
    break
  fi
  if [[ $_attempt -lt 3 ]]; then
    warn "Pull attempt ${_attempt} failed — retrying in 10s…"
    sleep 10
  fi
done
$_pull_ok || die "docker compose pull failed after 3 attempts. Check your network and registry credentials."

ok "Images pulled"

# ─── 4b. Redis AOF integrity check ───────────────────────────────────────────
# Corrupted incremental AOF files (.incr.aof) cause Redis to crash-loop on
# startup.  This can happen after an unclean shutdown.  We detect and repair
# them now — before Redis starts — so the service comes up cleanly.
section "Checking Redis data integrity"

REDIS_VOLUME="netcore_redisdata"

if docker volume inspect "$REDIS_VOLUME" >/dev/null 2>&1; then
  # Collect all incremental AOF files (newline-separated)
  INCR_FILES=$(docker run --rm \
    -v "${REDIS_VOLUME}:/data" \
    redis:7-alpine \
    find /data -name "*.incr.aof" 2>/dev/null || true)

  if [[ -n "$INCR_FILES" ]]; then
    info "Found incremental AOF files — checking integrity…"
    AOF_REPAIRED=false
    while IFS= read -r aof_file; do
      [[ -z "$aof_file" ]] && continue
      # Attempt automated repair first
      if docker run --rm \
           -v "${REDIS_VOLUME}:/data" \
           redis:7-alpine \
           sh -c "echo yes | redis-check-aof --fix ${aof_file}" \
           >/dev/null 2>&1; then
        ok "AOF repaired: ${aof_file}"
        AOF_REPAIRED=true
      else
        # Fix failed — remove the corrupted file and strip it from the manifest.
        # Redis will recover from the RDB base snapshot on next start.
        warn "AOF repair failed for ${aof_file} — removing (will recover from last snapshot)"
        _aof_basename=$(basename "${aof_file}")
        docker run --rm \
          -v "${REDIS_VOLUME}:/data" \
          redis:7-alpine \
          sh -c "rm -f ${aof_file} && \
                 sed -i \"/${_aof_basename}/d\" /data/appendonlydir/appendonly.aof.manifest"
        AOF_REPAIRED=true
      fi
    done < <(printf '%s\n' "$INCR_FILES")

    if [[ "$AOF_REPAIRED" == "false" ]]; then
      ok "Redis AOF files are healthy"
    fi
  else
    ok "No incremental AOF files found"
  fi
else
  ok "No existing Redis volume — fresh install"
fi

# ─── 5. Start / upgrade services ─────────────────────────────────────────────
section "Starting services"

if [[ "$UPGRADE" == "true" ]]; then
  info "Upgrade mode — restarting app containers only (your data is safe)…"
  $DC up -d --no-deps api web updater nginx
  ok "App containers updated"
else
  $DC up -d
  ok "All containers started"
fi

# ─── 6. Wait for API to be healthy ───────────────────────────────────────────
section "Waiting for API to be ready"

TIMEOUT=180
ELAPSED=0
printf "  "
until docker inspect --format '{{.State.Health.Status}}' \
        "$($DC ps -q api 2>/dev/null | head -1)" 2>/dev/null | grep -q "healthy" \
      || curl -sf http://localhost:3001/api/system/info >/dev/null 2>&1; do
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo ""
    warn "Timed out after ${TIMEOUT}s — check logs with: $DC logs api"
    break
  fi
  printf "."
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
echo ""
ok "API is up"

# ─── 7. Database seed ─────────────────────────────────────────────────────────
section "Seeding database"

# The API CMD already runs 'prisma db push' on startup to apply any schema
# additions. The seed is idempotent (uses upsert) and safe to re-run — it
# only creates the admin user and default profile if they don't already exist.
if $DC exec -T api node /app/apps/api/prisma/seed.js 2>&1 | \
     sed 's/^/  /'; then
  ok "Database seeded"
else
  warn "Seed step had warnings (admin user may already exist — that is fine)."
fi

# Seed default DNS target pool (Quad9, OpenDNS, AdGuard, etc.)
if $DC exec -T api node /app/apps/api/prisma/seed-dns.js 2>&1 | \
     sed 's/^/  /'; then
  ok "DNS target pool seeded"
else
  warn "DNS seed step had warnings — check server logs."
fi

# ─── 8. Done ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
if [[ "$UPGRADE" == "true" ]]; then
echo -e "${BOLD}${GREEN}║   Upgrade complete!                          ║${NC}"
else
echo -e "${BOLD}${GREEN}║   Installation complete!                     ║${NC}"
fi
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Dashboard${NC}   http://${SERVER_HOST}/"
echo -e "  ${BOLD}API${NC}         http://${SERVER_HOST}/api/"
echo ""
echo -e "  ${BOLD}Login${NC}       ${ADMIN_EMAIL}"
echo -e "  ${BOLD}Password${NC}    ${ADMIN_PASS}"
echo ""
echo -e "  ${YELLOW}⚠  Change the default password after your first login.${NC}"
echo ""
echo -e "  Useful commands:"
echo -e "    ${CYAN}$DC ps${NC}              — service status"
echo -e "    ${CYAN}$DC logs -f api${NC}     — API logs"
echo -e "    ${CYAN}$DC logs -f web${NC}     — web logs"
echo -e "    ${CYAN}$DC restart api${NC}     — restart API"
echo -e "    ${CYAN}$DC down${NC}            — stop all services"
echo -e "    ${CYAN}$DC up -d${NC}           — start all services"
echo ""
