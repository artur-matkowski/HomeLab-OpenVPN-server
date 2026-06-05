#!/usr/bin/env bash
#
# build.sh [tag]  –  build the OpenVPN hub image locally.
#
#   ./scripts/build.sh          # builds arturmatkowski/openvpn-server:latest
#   ./scripts/build.sh dev      # builds arturmatkowski/openvpn-server:dev
#
# Build context is the repo root (the Dockerfile COPYs from src/). Runs from any cwd.
set -euo pipefail

IMAGE_NAME=arturmatkowski/openvpn-server
TAG="${1:-latest}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Building ${IMAGE_NAME}:${TAG} from ${REPO_ROOT}"
docker build -t "${IMAGE_NAME}:${TAG}" "${REPO_ROOT}"
