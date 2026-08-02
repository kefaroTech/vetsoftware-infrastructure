[CmdletBinding()]
param()

$gate = Join-Path $PSScriptRoot "quality/terraform-gate.ps1"
& $gate -Mode terraform
exit $LASTEXITCODE
