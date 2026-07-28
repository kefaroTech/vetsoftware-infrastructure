[CmdletBinding()]
param(
    [string]$Environment = "prod",
    [switch]$Reconfigure
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$environmentDirectory = Join-Path $repositoryRoot "environments/$Environment"
$backendConfig = Join-Path $environmentDirectory "backend.hcl"

if (-not (Test-Path -LiteralPath $backendConfig)) {
    throw "Falta $backendConfig. Cópielo desde backend.hcl.example y complete las salidas de bootstrap."
}

$arguments = @("-chdir=$environmentDirectory", "init", "-backend-config=backend.hcl")
if ($Reconfigure) {
    $arguments += "-reconfigure"
}

& terraform @arguments
if ($LASTEXITCODE -ne 0) {
    throw "terraform init falló con código $LASTEXITCODE."
}
