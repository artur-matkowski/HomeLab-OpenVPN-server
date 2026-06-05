#!/usr/bin/env bash
#
# deploy-prod.sh  –  build + run the hub in production (on the VPS).
#
# Builds the image as :latest and brings the stack up using that tag. Config
# comes from .env. No registry/push is involved — the image is built locally on
# the target. PKI/state under /opt/openvpn persists across rebuilds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

if [ ! -f .env ]; then
    echo "ERROR: .env not found. Create it first:" >&2
    echo "       cp .env.example .env   # then edit the values" >&2
    exit 1
fi

./scripts/build.sh latest

echo "Starting stack with image tag :latest"
IMAGE_TAG=latest docker compose up -d

docker compose logs -f openvpn-hub
