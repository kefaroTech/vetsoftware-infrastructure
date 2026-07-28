[CmdletBinding()]
param(
    [string]$Environment = "prod",
    [string]$Output = "vetsoftware.tfplan"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$environmentDirectory = Join-Path $repositoryRoot "environments/$Environment"

& terraform -chdir=$environmentDirectory plan -input=false -out=$Output
if ($LASTEXITCODE -ne 0) {
    throw "terraform plan falló con código $LASTEXITCODE."
}

Write-Host "Plan guardado en environments/$Environment/$Output" -ForegroundColor Green
