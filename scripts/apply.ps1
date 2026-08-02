[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Environment = "prod",
    [string]$Plan = "vetsoftware.tfplan"
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$environmentDirectory = Join-Path $repositoryRoot "environments/$Environment"
$planPath = Join-Path $environmentDirectory $Plan

if (-not (Test-Path -LiteralPath $planPath)) {
    throw "No existe $planPath. Ejecute primero scripts/plan.ps1."
}

if ($PSCmdlet.ShouldProcess("AWS/$Environment", "Aplicar el plan Terraform $Plan")) {
    & terraform "-chdir=$environmentDirectory" apply -input=false $Plan
    if ($LASTEXITCODE -ne 0) {
        throw "terraform apply falló con código $LASTEXITCODE."
    }
}
