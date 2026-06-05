#!/usr/bin/env bash
#
# deploy-dev.sh  –  build + run the hub for development / testing.
#
# Builds the image as :dev and brings the stack up using that tag. Config comes
# from .env (same file prod uses); only the image tag differs from prod. Run on
# the box you're testing on; PKI/state under /opt/openvpn is reused as-is.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

if [ ! -f .env ]; then
    echo "ERROR: .env not found. Create it first:" >&2
    echo "       cp .env.example .env   # then edit the values" >&2
    exit 1
fi

./scripts/build.sh dev

echo "Starting stack with image tag :dev"
IMAGE_TAG=dev docker compose up -d

docker compose logs -f openvpn-hub
