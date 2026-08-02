#!/usr/bin/env sh
set -eu

MODE="${1:-full}"
REPOSITORY_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPOSITORY_ROOT"

if command -v pwsh >/dev/null 2>&1; then
  POWERSHELL=pwsh
elif command -v powershell.exe >/dev/null 2>&1; then
  POWERSHELL=powershell.exe
else
  echo 'Terraform gate blocked: PowerShell 7 (pwsh) or Windows PowerShell is required.' >&2
  exit 1
fi

exec "$POWERSHELL" -NoLogo -NoProfile -ExecutionPolicy Bypass \
  -File scripts/quality/terraform-gate.ps1 -Mode "$MODE"
