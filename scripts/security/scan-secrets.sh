#!/usr/bin/env sh
set -eu

GITLEAKS_IMAGE='ghcr.io/gitleaks/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f'
MODE="${1:-staged}"
REPOSITORY_ROOT="$(git rev-parse --show-toplevel)"

if ! command -v docker >/dev/null 2>&1; then
  echo 'Secret scan blocked: Docker is required to run the pinned Gitleaks image.' >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo 'Secret scan blocked: Docker is installed but its daemon is not available.' >&2
  exit 1
fi

case "$MODE" in
  staged) set -- git /repo --pre-commit --staged ;;
  history) set -- git /repo --log-opts=--all --max-decode-depth=3 --max-archive-depth=2 ;;
  *) echo "Unknown secret scan mode: $MODE (expected staged or history)." >&2; exit 2 ;;
esac

if [ -f "$REPOSITORY_ROOT/.gitleaksignore" ]; then
  set -- "$@" --gitleaks-ignore-path=/repo/.gitleaksignore
fi
if [ -f "$REPOSITORY_ROOT/.gitleaks.toml" ]; then
  set -- "$@" --config=/repo/.gitleaks.toml
fi

MSYS_NO_PATHCONV=1 docker run --rm \
  --mount "type=bind,source=$REPOSITORY_ROOT,target=/repo,readonly" \
  "$GITLEAKS_IMAGE" "$@" \
  --redact=100 --no-banner --no-color
