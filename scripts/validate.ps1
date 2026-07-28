[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$roots = @(
    (Join-Path $repositoryRoot "bootstrap"),
    (Join-Path $repositoryRoot "environments/prod")
)

& terraform -chdir=$repositoryRoot fmt -check -recursive
if ($LASTEXITCODE -ne 0) {
    throw "terraform fmt encontró archivos sin formato. Ejecute: terraform -chdir=$repositoryRoot fmt -recursive"
}

if (Get-Command tflint -ErrorAction SilentlyContinue) {
    Push-Location $repositoryRoot
    try {
        & tflint --init
        if ($LASTEXITCODE -ne 0) { throw "tflint --init falló." }

        & tflint --chdir=bootstrap --format=compact
        if ($LASTEXITCODE -ne 0) { throw "TFLint encontró problemas en bootstrap." }

        & tflint --chdir=environments/prod --format=compact
        if ($LASTEXITCODE -ne 0) { throw "TFLint encontró problemas en environments/prod." }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Warning "TFLint no está instalado; se omite el lint local. El CI sí lo ejecuta."
}

foreach ($root in $roots) {
    & terraform -chdir=$root init -backend=false -input=false
    if ($LASTEXITCODE -ne 0) {
        throw "terraform init falló en $root."
    }

    & terraform -chdir=$root validate
    if ($LASTEXITCODE -ne 0) {
        throw "terraform validate falló en $root."
    }
}

& terraform -chdir=(Join-Path $repositoryRoot "environments/prod") test
if ($LASTEXITCODE -ne 0) {
    throw "terraform test falló en environments/prod."
}

Write-Host "Formato y configuración Terraform válidos." -ForegroundColor Green
