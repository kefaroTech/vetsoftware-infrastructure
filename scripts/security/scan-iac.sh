#!/usr/bin/env sh
set -eu

TRIVY_IMAGE='aquasec/trivy@sha256:f5d0e600ecda7449e2a9b272805aef698631d3bb3f3a739a750de2c6819acdc9'
REPOSITORY_ROOT="$(git rev-parse --show-toplevel)"
CACHE_DIRECTORY="$REPOSITORY_ROOT/.tools/trivy-cache"

if ! command -v docker >/dev/null 2>&1; then
  echo 'IaC scan blocked: Docker is required to run the pinned Trivy image.' >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo 'IaC scan blocked: Docker is installed but its daemon is not available.' >&2
  exit 1
fi

mkdir -p "$CACHE_DIRECTORY"

MSYS_NO_PATHCONV=1 docker run --rm \
  --mount "type=bind,source=$REPOSITORY_ROOT,target=/repo,readonly" \
  --mount "type=bind,source=$CACHE_DIRECTORY,target=/root/.cache/trivy" \
  "$TRIVY_IMAGE" config \
  --misconfig-scanners terraform \
  --severity MEDIUM,HIGH,CRITICAL \
  --exit-code 1 \
  --rego-error-limit 0 \
  --tf-exclude-downloaded-modules \
  --skip-check-update \
  --disable-telemetry \
  --skip-version-check \
  --skip-dirs /repo/.terraform \
  --skip-dirs /repo/.tools \
  /repo
