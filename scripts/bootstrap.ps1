[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$AutoApprove
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$bootstrapDirectory = Join-Path $repositoryRoot "bootstrap"
$productionDirectory = Join-Path $repositoryRoot "environments/prod"
$backendPath = Join-Path $productionDirectory "backend.hcl"

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw "Terraform no está disponible en PATH. Instale la versión indicada en .terraform-version y abra una terminal nueva."
}

& terraform -chdir=$bootstrapDirectory init -input=false
if ($LASTEXITCODE -ne 0) { throw "No fue posible inicializar bootstrap." }

$applyArguments = @("-chdir=$bootstrapDirectory", "apply", "-input=false")
if ($AutoApprove) { $applyArguments += "-auto-approve" }

if ($PSCmdlet.ShouldProcess("AWS", "Crear el backend remoto de Terraform")) {
    & terraform @applyArguments
    if ($LASTEXITCODE -ne 0) { throw "No fue posible crear el backend remoto." }
}
else {
    return
}

$backendJson = & terraform -chdir=$bootstrapDirectory output -json backend_hcl
if ($LASTEXITCODE -ne 0) { throw "No fue posible leer la salida backend_hcl." }
$backend = $backendJson | ConvertFrom-Json

$lines = @(
    "bucket       = `"$($backend.bucket)`"",
    "key          = `"$($backend.key)`"",
    "region       = `"$($backend.region)`"",
    "encrypt      = true",
    "use_lockfile = true"
)

if ($backend.kms_key_id) {
    $lines += "kms_key_id   = `"$($backend.kms_key_id)`""
}

[System.IO.File]::WriteAllText($backendPath, (($lines -join [Environment]::NewLine) + [Environment]::NewLine))
Write-Host "Backend remoto creado y configuración escrita en environments/prod/backend.hcl." -ForegroundColor Green

& terraform -chdir=$productionDirectory init -backend-config=backend.hcl -input=false
if ($LASTEXITCODE -ne 0) { throw "El backend fue creado, pero environments/prod no pudo inicializarse." }
