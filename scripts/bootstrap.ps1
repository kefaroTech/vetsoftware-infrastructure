[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$AutoApprove
)

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$bootstrapDirectory = Join-Path $repositoryRoot "bootstrap"
$environmentDirectories = @{
    (Join-Path $repositoryRoot "environments/prod") = "backend_hcl"
    (Join-Path $repositoryRoot "environments/dev")  = "dev_backend_hcl"
}

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw "Terraform no está disponible en PATH. Instale la versión indicada en .terraform-version y abra una terminal nueva."
}

& terraform "-chdir=$bootstrapDirectory" init -input=false
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

function Write-BackendConfig {
    param(
        [Parameter(Mandatory)]$Backend,
        [Parameter(Mandatory)][string]$EnvironmentDirectory
    )

    $lines = @(
        "bucket       = `"$($Backend.bucket)`"",
        "key          = `"$($Backend.key)`"",
        "region       = `"$($Backend.region)`"",
        "encrypt      = true",
        "use_lockfile = true"
    )

    if ($Backend.kms_key_id) {
        $lines += "kms_key_id   = `"$($Backend.kms_key_id)`""
    }

    $path = Join-Path $EnvironmentDirectory "backend.hcl"
    [System.IO.File]::WriteAllText($path, (($lines -join [Environment]::NewLine) + [Environment]::NewLine))
}

foreach ($entry in $environmentDirectories.GetEnumerator()) {
    $backendJson = & terraform "-chdir=$bootstrapDirectory" output -json $entry.Value
    if ($LASTEXITCODE -ne 0) { throw "No fue posible leer la salida $($entry.Value)." }

    Write-BackendConfig -Backend ($backendJson | ConvertFrom-Json) -EnvironmentDirectory $entry.Key

    & terraform "-chdir=$($entry.Key)" init -backend-config=backend.hcl -input=false
    if ($LASTEXITCODE -ne 0) { throw "El backend fue creado, pero $($entry.Key) no pudo inicializarse." }
}

Write-Host "Backend remoto configurado con states separados para prod y dev." -ForegroundColor Green
