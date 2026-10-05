#!/usr/bin/env bash
# Pull the latest published images from the registry and roll them out.
# No source code and no build happen on this host.
#
# Usage:
#   ./deploy.sh              # pull + recreate api and web
#   ./deploy.sh web          # web only
#   ./deploy.sh api          # api only
#   IMAGE_TAG=v1.4.0 ./deploy.sh   # pin a specific published version
#
# Requires a prior `docker login ghcr.io` (install.sh sets this up).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SERVICES="${*:-api web}"

echo "==> Pulling images: $SERVICES (tag: ${IMAGE_TAG:-latest})"
docker compose pull $SERVICES

echo ""
echo "==> Recreating: $SERVICES"
docker compose up -d --no-deps $SERVICES

echo ""
echo "==> Done. Container status:"
docker compose ps
