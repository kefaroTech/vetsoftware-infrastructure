[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Plan", "Apply", "Drift")]
    [string]$Mode,

    [Parameter(Mandatory)]
    [ValidateSet("dev", "prod")]
    [string]$Environment
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$environmentDirectory = Join-Path $repositoryRoot "environments/$Environment"
$stateKey = "vetsoftware/$Environment/terraform.tfstate"

function Assert-RequiredEnvironmentVariable {
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Falta la variable de entorno obligatoria $Name."
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command fallo con codigo $LASTEXITCODE."
    }
}

function Get-ExternalJson {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $raw = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command fallo con codigo $LASTEXITCODE."
    }

    return (($raw -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Initialize-Terraform {
    $arguments = @(
        "-chdir=$environmentDirectory",
        "init",
        "-input=false",
        "-reconfigure",
        "-backend-config=bucket=$env:TF_STATE_BUCKET",
        "-backend-config=key=$stateKey",
        "-backend-config=region=$env:AWS_REGION",
        "-backend-config=encrypt=true",
        "-backend-config=use_lockfile=true"
    )
    if (-not [string]::IsNullOrWhiteSpace($env:TF_STATE_KMS_KEY_ARN)) {
        $arguments += "-backend-config=kms_key_id=$env:TF_STATE_KMS_KEY_ARN"
    }

    Write-Host "[Terraform] Inicializando el state remoto de $Environment..." -ForegroundColor Cyan
    Invoke-ExternalCommand -Command "terraform" -Arguments $arguments
    Invoke-ExternalCommand -Command "terraform" -Arguments @(
        "-chdir=$environmentDirectory", "validate", "-no-color"
    )
}

function Set-CurrentBackendImage {
    $configuredImage = $env:TF_VAR_backend_image_uri
    Write-Host "[Terraform] Conservando la imagen ECS activa durante el ciclo general..." -ForegroundColor Cyan
    try {
        $clusterName = (& terraform "-chdir=$environmentDirectory" output -raw ecs_cluster_name)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($clusterName)) {
            throw "No fue posible leer ecs_cluster_name del state."
        }

        $serviceName = (& terraform "-chdir=$environmentDirectory" output -raw ecs_service_name)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serviceName)) {
            throw "No fue posible leer ecs_service_name del state."
        }

        $services = Get-ExternalJson -Command "aws" -Arguments @(
            "ecs", "describe-services",
            "--cluster", [string]$clusterName,
            "--services", [string]$serviceName,
            "--output", "json"
        )
        $service = @($services.services) | Select-Object -First 1
        if ($null -eq $service -or [string]::IsNullOrWhiteSpace([string]$service.taskDefinition)) {
            throw "El servicio ECS no tiene una task definition activa."
        }

        $taskDefinition = Get-ExternalJson -Command "aws" -Arguments @(
            "ecs", "describe-task-definition",
            "--task-definition", [string]$service.taskDefinition,
            "--output", "json"
        )
        $backend = @($taskDefinition.taskDefinition.containerDefinitions | Where-Object { $_.name -eq "backend" })
        if ($backend.Count -ne 1) {
            throw "La task definition activa no contiene exactamente un contenedor backend."
        }

        $repositoryName = if ($Environment -eq "dev") { "vetsoftware-dev-backend" } else { "vetsoftware-backend" }
        $repositoryPattern = [regex]::Escape($repositoryName)
        $imagePattern = "^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(\\.cn)?/${repositoryPattern}@sha256:[0-9a-f]{64}$"
        $image = [string]$backend[0].image
        if ($image -notmatch $imagePattern) {
            throw "La imagen activa no esta fijada al digest esperado de $repositoryName."
        }
        $env:TF_VAR_backend_image_uri = $image
        return
    }
    catch {
        $repositoryName = if ($Environment -eq "dev") { "vetsoftware-dev-backend" } else { "vetsoftware-backend" }
        $repositoryPattern = [regex]::Escape($repositoryName)
        if ($configuredImage -match "^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(\\.cn)?/${repositoryPattern}@sha256:[0-9a-f]{64}$") {
            $env:TF_VAR_backend_image_uri = $configuredImage
            Write-Host "[Terraform] No existe baseline ECS; se usara BACKEND_IMAGE_URI para el primer despliegue." -ForegroundColor Yellow
            return
        }
        throw "No existe una imagen backend reutilizable. Configure BACKEND_IMAGE_URI para el primer despliegue. Detalle: $($_.Exception.Message)"
    }
}

function New-OptionalVariableFile {
    if ([string]::IsNullOrWhiteSpace($env:TF_VARS_JSON)) {
        return $null
    }

    try {
        $configuration = $env:TF_VARS_JSON | ConvertFrom-Json
    }
    catch {
        throw "TF_VARS_JSON no contiene un objeto JSON valido: $($_.Exception.Message)"
    }
    if ($null -eq $configuration -or $configuration -isnot [PSCustomObject]) {
        throw "TF_VARS_JSON debe ser un objeto JSON."
    }

    $forbiddenVariables = @(
        "application_secrets_json",
        "backend_image_uri",
        "cloudflare_tunnel_token",
        "environment",
        "grafana_secrets_json"
    )
    $configuredVariables = @($configuration.PSObject.Properties.Name)
    $forbiddenConfigured = @($configuredVariables | Where-Object { $_ -in $forbiddenVariables })
    if ($forbiddenConfigured.Count -gt 0) {
        throw "TF_VARS_JSON contiene variables reservadas o sensibles: $($forbiddenConfigured -join ', ')."
    }

    $temporaryDirectory = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        [IO.Path]::GetTempPath()
    }
    else {
        $env:RUNNER_TEMP
    }
    $variableFile = Join-Path $temporaryDirectory "terraform-$Environment.auto.tfvars.json"
    $configuration | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $variableFile -Encoding utf8
    return $variableFile
}

function Write-PlanReport {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$PlanPath
    )

    $showOutput = & terraform "-chdir=$environmentDirectory" show -no-color $PlanPath
    if ($LASTEXITCODE -ne 0) {
        throw "terraform show fallo con codigo $LASTEXITCODE."
    }

    $planText = ($showOutput -join [Environment]::NewLine).Trim()
    $maxCharacters = 55000
    if ($planText.Length -gt $maxCharacters) {
        $planText = $planText.Substring(0, $maxCharacters) + "`n`n[plan truncado; consulte el log completo del job]"
    }

    $result = if ($ExitCode -eq 2) { "cambios detectados" } else { "sin cambios" }
    $marker = "<!-- terraform-plan:$Environment -->"
    $runUrl = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SERVER_URL) -and
        -not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY) -and
        -not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
        "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    }
    else {
        "ejecucion local"
    }
    $commit = if ([string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) { "desconocido" } else { $env:GITHUB_SHA }
    $report = @(
        $marker,
        "## Terraform $($Mode.ToLowerInvariant()) - $Environment",
        "",
        "- Resultado: **$result**",
        "- Revision: ``$commit``",
        "- Ejecucion: $runUrl",
        "- Plan fresco: generado en esta ejecucion; no se reutilizan artefactos de otros runs",
        "",
        "<details>",
        "<summary>Ver plan Terraform</summary>",
        "",
        '```text',
        $planText,
        '```',
        "",
        "</details>"
    )

    $temporaryDirectory = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        [IO.Path]::GetTempPath()
    }
    else {
        $env:RUNNER_TEMP
    }
    $reportPath = Join-Path $temporaryDirectory "terraform-$Environment-$($Mode.ToLowerInvariant()).md"
    Set-Content -LiteralPath $reportPath -Value $report -Encoding utf8

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $report[1..($report.Count - 1)] -Encoding utf8
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "has_changes=$($ExitCode -eq 2)" -Encoding utf8
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "report_path=$reportPath" -Encoding utf8
    }
}

@(
    "AWS_REGION",
    "TF_STATE_BUCKET",
    "TF_VAR_api_domain_name",
    "TF_VAR_cors_allowed_origins",
    "TF_VAR_email_from",
    "TF_VAR_grafana_otlp_endpoint",
    "TF_VAR_login_url",
    "TF_VAR_password_reset_url",
    "TF_VAR_registration_verification_url"
) | ForEach-Object { Assert-RequiredEnvironmentVariable -Name $_ }

if ($Mode -eq "Apply") {
    @(
        "TF_VAR_application_secrets_json",
        "TF_VAR_cloudflare_tunnel_token",
        "TF_VAR_grafana_secrets_json"
    ) | ForEach-Object { Assert-RequiredEnvironmentVariable -Name $_ }
}
else {
    # Plan y drift no reciben secretos de runtime. Los valores write-only son
    # ephemeral y sus versiones controlan cualquier rotacion intencional.
    $env:TF_VAR_application_secrets_json = '{"JWT_SECRET":"terraform-plan-placeholder-32chars","RESEND_API_KEY":"not-used","RECAPTCHA_SECRET":"not-used"}'
    $env:TF_VAR_cloudflare_tunnel_token = "terraform-plan-placeholder-32chars"
    $env:TF_VAR_grafana_secrets_json = '{"OTLP_USERNAME":"not-used","OTLP_API_KEY":"not-used"}'
}

Initialize-Terraform
Set-CurrentBackendImage
$variableFile = New-OptionalVariableFile

$temporaryDirectory = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [IO.Path]::GetTempPath()
}
else {
    $env:RUNNER_TEMP
}
$planPath = Join-Path $temporaryDirectory "terraform-$Environment-$($Mode.ToLowerInvariant()).tfplan"
$planArguments = @(
    "-chdir=$environmentDirectory",
    "plan",
    "-input=false",
    "-lock-timeout=5m",
    "-out=$planPath",
    "-no-color",
    "-detailed-exitcode"
)
if ($Mode -eq "Drift") {
    $planArguments += "-refresh-only"
}
if (-not [string]::IsNullOrWhiteSpace($variableFile)) {
    $planArguments += "-var-file=$variableFile"
}

Write-Host "[Terraform] Generando plan $($Mode.ToLowerInvariant()) de $Environment..." -ForegroundColor Cyan
& terraform @planArguments 2>&1 | ForEach-Object { Write-Host $_ }
$planExitCode = $LASTEXITCODE
if ($planExitCode -notin @(0, 2)) {
    throw "terraform plan fallo con codigo $planExitCode."
}

Write-PlanReport -ExitCode $planExitCode -PlanPath $planPath

if ($Mode -eq "Apply") {
    Write-Host "[Terraform] Aplicando exactamente el plan recien generado..." -ForegroundColor Cyan
    Invoke-ExternalCommand -Command "terraform" -Arguments @(
        "-chdir=$environmentDirectory", "apply", "-input=false", "-lock-timeout=5m", $planPath
    )
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value @("", "### Apply", "", "Plan aplicado correctamente.") -Encoding utf8
    }
    exit 0
}

if ($Mode -eq "Drift" -and $planExitCode -eq 2) {
    throw "Se detecto drift en $Environment. Revise el plan; este workflow nunca ejecuta apply."
}

Write-Host "Terraform $($Mode.ToLowerInvariant()) finalizo: codigo detallado $planExitCode." -ForegroundColor Green
