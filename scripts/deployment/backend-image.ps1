[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Plan", "Apply")]
    [string]$Mode,

    [Parameter(Mandatory)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$ImageDigest,

    [Parameter(Mandatory)]
    [string]$SourceCommit,

    [Parameter(Mandatory)]
    [string]$SourceRunUrl
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$environmentDirectory = Join-Path $repositoryRoot "environments/$Environment"
$repositoryName = if ($Environment -eq "dev") { "vetsoftware-dev-backend" } else { "vetsoftware-backend" }
$projectName = "vetsoftware"
$stateKey = "$projectName/$Environment/terraform.tfstate"
$allowedAddresses = @(
    "module.backend.aws_ecs_service.backend",
    "module.backend.aws_ecs_task_definition.backend"
)

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command falló con código $LASTEXITCODE."
    }
}

function Get-ExternalJson {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $raw = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command falló con código $LASTEXITCODE."
    }

    return (($raw -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Assert-RequiredEnvironmentVariable {
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Falta la variable de entorno obligatoria $Name."
    }
}

function Write-WorkflowSummary {
    param([Parameter(Mandatory)][string[]]$Lines)

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Lines -Encoding utf8
    }
}

function Assert-ReleaseImage {
    param([Parameter(Mandatory)][string]$ExpectedImageUri)

    Write-Host "[ECR] Certificando digest, tags y escaneo..." -ForegroundColor Cyan
    $image = Get-ExternalJson -Command "aws" -Arguments @(
        "ecr", "describe-images",
        "--repository-name", $repositoryName,
        "--image-ids", "imageDigest=$ImageDigest",
        "--output", "json"
    )

    $details = @($image.imageDetails)
    if ($details.Count -ne 1 -or $details[0].imageDigest -ne $ImageDigest) {
        throw "El digest solicitado no existe de forma única en ECR."
    }

    # Produccion se identifica por su release: el digest debe llevar el tag
    # SemVer y el tag del commit. Desarrollo no tiene release, asi que su
    # identidad es el propio commit publicado desde develop.
    $requiredTags = if ($Environment -eq "prod") {
        @($Version, "sha-$($SourceCommit.Substring(0, 12))")
    }
    else {
        @("dev-$($SourceCommit.Substring(0, 12))")
    }
    $actualTags = @($details[0].imageTags)
    foreach ($tag in $requiredTags) {
        if ($tag -notin $actualTags) {
            throw "El digest no contiene el tag obligatorio '$tag'."
        }
    }

    Invoke-ExternalCommand -Command "aws" -Arguments @(
        "ecr", "wait", "image-scan-complete",
        "--repository-name", $repositoryName,
        "--image-id", "imageDigest=$ImageDigest"
    )

    $scan = Get-ExternalJson -Command "aws" -Arguments @(
        "ecr", "describe-image-scan-findings",
        "--repository-name", $repositoryName,
        "--image-id", "imageDigest=$ImageDigest",
        "--output", "json"
    )
    $status = [string]$scan.imageScanStatus.status
    $critical = 0
    $high = 0
    if ($null -ne $scan.imageScanFindings.findingSeverityCounts.CRITICAL) {
        $critical = [int]$scan.imageScanFindings.findingSeverityCounts.CRITICAL
    }
    if ($null -ne $scan.imageScanFindings.findingSeverityCounts.HIGH) {
        $high = [int]$scan.imageScanFindings.findingSeverityCounts.HIGH
    }
    if ($status -ne "COMPLETE" -or $critical -ne 0 -or $high -ne 0) {
        throw "El escaneo ECR rechazó la imagen: status=$status, critical=$critical, high=$high."
    }

    Write-Host "[ECR] Imagen certificada: $ExpectedImageUri" -ForegroundColor Green
}

function Resolve-StateBackend {
    param([Parameter(Mandatory)][string]$AccountId)

    # Misma convencion que bootstrap/state-backend.yml; un valor explicito manda.
    if ([string]::IsNullOrWhiteSpace($env:TF_STATE_BUCKET)) {
        $env:TF_STATE_BUCKET = "$projectName-$Environment-tfstate-$AccountId"
        Write-Host "[Terraform] Bucket de state derivado: $env:TF_STATE_BUCKET" -ForegroundColor Cyan
    }

    if ([string]::IsNullOrWhiteSpace($env:TF_STATE_KMS_KEY_ARN)) {
        $keyAlias = "alias/$projectName-$Environment-tfstate"
        $keyArn = (& aws kms describe-key --key-id $keyAlias --query KeyMetadata.Arn --output text)
        if ($LASTEXITCODE -ne 0 -or $keyArn -notmatch '^arn:[^:]+:kms:[a-z0-9-]+:[0-9]{12}:key/') {
            throw "No fue posible resolver la KMS key $keyAlias que cifra el state de $Environment."
        }

        $env:TF_STATE_KMS_KEY_ARN = $keyArn
        Write-Host "[Terraform] KMS key de state derivada: $env:TF_STATE_KMS_KEY_ARN" -ForegroundColor Cyan
    }
}

function Initialize-Terraform {
    Write-Host "[Terraform] Inicializando state remoto de $Environment..." -ForegroundColor Cyan
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

    Invoke-ExternalCommand -Command "terraform" -Arguments $arguments
    Invoke-ExternalCommand -Command "terraform" -Arguments @(
        "-chdir=$environmentDirectory", "validate", "-no-color"
    )
}

function New-GuardedPlan {
    param(
        [Parameter(Mandatory)][string]$ImageUri,
        [Parameter(Mandatory)][string]$PlanPath
    )

    $env:TF_VAR_backend_image_uri = $ImageUri
    Write-Host "[Terraform] Generando plan image-only..." -ForegroundColor Cyan
    & terraform "-chdir=$environmentDirectory" plan `
        -input=false `
        -lock-timeout=5m `
        -out=$PlanPath `
        -no-color `
        -detailed-exitcode | ForEach-Object { Write-Host $_ }
    $planExitCode = $LASTEXITCODE
    if ($planExitCode -notin @(0, 2)) {
        throw "terraform plan falló con código $planExitCode."
    }

    $plan = Get-ExternalJson -Command "terraform" -Arguments @(
        "-chdir=$environmentDirectory", "show", "-json", $PlanPath
    )
    $changedResources = @($plan.resource_changes | Where-Object {
        $actions = @($_.change.actions)
        -not ($actions.Count -eq 1 -and $actions[0] -in @("no-op", "read"))
    })
    $unexpected = @($changedResources | Where-Object { $_.address -notin $allowedAddresses })
    if ($unexpected.Count -gt 0) {
        $addresses = ($unexpected.address | Sort-Object -Unique) -join ", "
        throw "Plan rechazado: contiene cambios fuera del despliegue image-only: $addresses"
    }

    $taskDefinitionChange = $changedResources | Where-Object {
        $_.address -eq "module.backend.aws_ecs_task_definition.backend"
    } | Select-Object -First 1
    if ($null -ne $taskDefinitionChange) {
        $definitions = $taskDefinitionChange.change.after.container_definitions | ConvertFrom-Json
        $backend = @($definitions | Where-Object { $_.name -eq "backend" })
        if ($backend.Count -ne 1 -or $backend[0].image -ne $ImageUri) {
            throw "El plan no fija el contenedor backend al digest solicitado."
        }
    }

    $changeList = if ($changedResources.Count -eq 0) {
        "sin cambios"
    }
    else {
        ($changedResources.address | Sort-Object -Unique) -join ", "
    }
    Write-Host "[Terraform] Plan permitido: $changeList" -ForegroundColor Green
    Write-WorkflowSummary -Lines @(
        "## Backend image deployment · $Mode",
        "",
        "- Environment: ``$Environment``",
        "- Version: ``$Version``",
        "- Digest: ``$ImageDigest``",
        "- Source commit: ``$SourceCommit``",
        "- Source run: $SourceRunUrl",
        "- Terraform changes: $changeList",
        "- Guard: only ECS task definition/service changes are allowed"
    )

    return $changedResources.Count
}

function Get-CurrentServiceState {
    $clusterName = (& terraform "-chdir=$environmentDirectory" output -raw ecs_cluster_name)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($clusterName)) {
        throw "No existe baseline: falta el output ecs_cluster_name de $Environment."
    }
    $serviceName = (& terraform "-chdir=$environmentDirectory" output -raw ecs_service_name)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($serviceName)) {
        throw "No existe baseline: falta el output ecs_service_name de $Environment."
    }

    $serviceResponse = Get-ExternalJson -Command "aws" -Arguments @(
        "ecs", "describe-services",
        "--cluster", $clusterName,
        "--services", $serviceName,
        "--output", "json"
    )
    $service = @($serviceResponse.services) | Select-Object -First 1
    if ($null -eq $service -or [string]::IsNullOrWhiteSpace([string]$service.taskDefinition)) {
        throw "No existe baseline ECS para $clusterName/$serviceName."
    }

    $taskDefinitionResponse = Get-ExternalJson -Command "aws" -Arguments @(
        "ecs", "describe-task-definition",
        "--task-definition", $service.taskDefinition,
        "--output", "json"
    )
    $backend = @($taskDefinitionResponse.taskDefinition.containerDefinitions | Where-Object {
        $_.name -eq "backend"
    })
    if ($backend.Count -ne 1) {
        throw "La task definition activa no contiene exactamente un contenedor backend."
    }

    return [PSCustomObject]@{
        ClusterName  = [string]$clusterName
        ServiceName  = [string]$serviceName
        PreviousImage = [string]$backend[0].image
    }
}

function Assert-ServiceDeployment {
    param(
        [Parameter(Mandatory)][PSCustomObject]$ServiceState,
        [Parameter(Mandatory)][string]$ExpectedImageUri
    )

    Write-Host "[ECS] Esperando estabilidad del servicio..." -ForegroundColor Cyan
    Invoke-ExternalCommand -Command "aws" -Arguments @(
        "ecs", "wait", "services-stable",
        "--cluster", $ServiceState.ClusterName,
        "--services", $ServiceState.ServiceName
    )

    $serviceResponse = Get-ExternalJson -Command "aws" -Arguments @(
        "ecs", "describe-services",
        "--cluster", $ServiceState.ClusterName,
        "--services", $ServiceState.ServiceName,
        "--output", "json"
    )
    $service = @($serviceResponse.services) | Select-Object -First 1
    $primary = @($service.deployments | Where-Object { $_.status -eq "PRIMARY" }) | Select-Object -First 1
    if ($service.runningCount -ne $service.desiredCount -or $service.pendingCount -ne 0) {
        throw "ECS no está estable: desired=$($service.desiredCount), running=$($service.runningCount), pending=$($service.pendingCount)."
    }
    if ($null -eq $primary -or $primary.rolloutState -ne "COMPLETED") {
        throw "El deployment PRIMARY no terminó correctamente."
    }

    $taskDefinitionResponse = Get-ExternalJson -Command "aws" -Arguments @(
        "ecs", "describe-task-definition",
        "--task-definition", $service.taskDefinition,
        "--output", "json"
    )
    $backend = @($taskDefinitionResponse.taskDefinition.containerDefinitions | Where-Object {
        $_.name -eq "backend"
    })
    if ($backend.Count -ne 1 -or $backend[0].image -ne $ExpectedImageUri) {
        throw "La task definition activa no usa el digest solicitado."
    }

    $healthUrl = "https://$env:TF_VAR_api_domain_name/api/v1/actuator/health/readiness"
    Write-Host "[Smoke] Verificando $healthUrl..." -ForegroundColor Cyan
    Invoke-ExternalCommand -Command "curl" -Arguments @(
        "--fail", "--silent", "--show-error",
        "--retry", "8", "--retry-all-errors", "--retry-delay", "5",
        "--max-time", "20", $healthUrl
    )
    Write-Host "[ECS] Despliegue estable y smoke test correcto." -ForegroundColor Green
}

if ($ImageDigest -notmatch '^sha256:[0-9a-f]{64}$') {
    throw "ImageDigest debe usar sha256:<64 hex>."
}
if ($SourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw "SourceCommit debe ser un SHA Git completo de 40 caracteres."
}
if ($Environment -eq "prod") {
    if ($Version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "Version debe cumplir SemVer estricto X.Y.Z en produccion."
    }
}
else {
    if ($Version -ne "dev-$($SourceCommit.Substring(0, 12))") {
        throw "En desarrollo Version debe ser dev-<12 primeros caracteres de SourceCommit>."
    }
}
$parsedSourceRun = $null
if (-not [Uri]::TryCreate($SourceRunUrl, [UriKind]::Absolute, [ref]$parsedSourceRun) -or
    $parsedSourceRun.Scheme -ne "https" -or
    $parsedSourceRun.Host -ne "github.com" -or
    $parsedSourceRun.AbsolutePath -notmatch '^/kefaroTech/vetsoftware-backend/actions/runs/[0-9]+/?$') {
    throw "SourceRunUrl debe identificar un run de publicación de kefaroTech/vetsoftware-backend en GitHub."
}

@(
    "AWS_REGION",
    "TF_VAR_api_domain_name",
    "TF_VAR_cors_allowed_origins",
    "TF_VAR_email_from",
    "TF_VAR_grafana_otlp_endpoint",
    "TF_VAR_login_url",
    "TF_VAR_password_reset_url",
    "TF_VAR_registration_verification_url"
) | ForEach-Object { Assert-RequiredEnvironmentVariable -Name $_ }

# The image-only workflow must never receive runtime secrets. These ephemeral
# placeholders only satisfy root-module validation. Any attempted secret change
# appears outside the ECS allowlist and is rejected before apply.
$env:TF_VAR_application_secrets_json = '{"JWT_SECRET":"image-only-plan-placeholder-32chars","RESEND_API_KEY":"not-used","RECAPTCHA_SECRET":"not-used"}'
$env:TF_VAR_cloudflare_tunnel_token = "image-only-plan-placeholder-32chars"
$env:TF_VAR_grafana_secrets_json = '{"OTLP_USERNAME":"not-used","OTLP_API_KEY":"not-used","OTEL_EXPORTER_OTLP_HEADERS":"Authorization=Basic bm90LXVzZWQ6bm90LXVzZWQ="}'

$accountId = (& aws sts get-caller-identity --query Account --output text)
if ($LASTEXITCODE -ne 0 -or $accountId -notmatch '^[0-9]{12}$') {
    throw "No fue posible resolver la cuenta AWS activa."
}
$imageUri = "$accountId.dkr.ecr.$env:AWS_REGION.amazonaws.com/$repositoryName@$ImageDigest"

Assert-ReleaseImage -ExpectedImageUri $imageUri
Resolve-StateBackend -AccountId $accountId
Initialize-Terraform
$planPath = Join-Path $env:RUNNER_TEMP "backend-$Environment-$Mode.tfplan"
$changeCount = New-GuardedPlan -ImageUri $imageUri -PlanPath $planPath

if ($Mode -eq "Plan") {
    Write-Host "Plan image-only validado; no se aplicaron cambios." -ForegroundColor Green
    exit 0
}

$serviceState = Get-CurrentServiceState
try {
    if ($changeCount -gt 0) {
        Write-Host "[Terraform] Aplicando el plan aprobado..." -ForegroundColor Cyan
        Invoke-ExternalCommand -Command "terraform" -Arguments @(
            "-chdir=$environmentDirectory", "apply", "-input=false", $planPath
        )
    }
    Assert-ServiceDeployment -ServiceState $serviceState -ExpectedImageUri $imageUri
}
catch {
    $deploymentError = $_
    Write-Warning "El despliegue falló: $($deploymentError.Exception.Message)"
    $escapedRepositoryName = [regex]::Escape($repositoryName)
    # Comillas dobles en PowerShell no escapan con barra invertida: "\\." exigiria una
    # barra invertida literal y el rollback nunca se dispararia.
    if ($serviceState.PreviousImage -match "^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?/${escapedRepositoryName}@sha256:[0-9a-f]{64}$") {
        Write-Warning "Iniciando rollback Terraform al digest anterior."
        $rollbackPlanPath = Join-Path $env:RUNNER_TEMP "backend-$Environment-rollback.tfplan"
        $rollbackChanges = New-GuardedPlan -ImageUri $serviceState.PreviousImage -PlanPath $rollbackPlanPath
        if ($rollbackChanges -gt 0) {
            Invoke-ExternalCommand -Command "terraform" -Arguments @(
                "-chdir=$environmentDirectory", "apply", "-input=false", $rollbackPlanPath
            )
        }
        Assert-ServiceDeployment -ServiceState $serviceState -ExpectedImageUri $serviceState.PreviousImage
        Write-WorkflowSummary -Lines @("", "- Rollback: completed to ``$($serviceState.PreviousImage)``")
    }
    else {
        Write-Warning "No se automatizó rollback porque la imagen anterior no estaba fijada por digest; el circuit breaker de ECS conserva la última revisión estable."
        Write-WorkflowSummary -Lines @("", "- Rollback: delegated to ECS circuit breaker; previous state was not digest-pinned")
    }
    throw $deploymentError
}
