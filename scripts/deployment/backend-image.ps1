[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Plan", "Apply")]
    [string]$Mode,

    [Parameter(Mandatory)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    # Unico dato que aporta quien despliega. El digest, el commit y el run de
    # origen se resuelven desde ECR: pedirlos era pedir cuatro campos que la
    # maquina puede averiguar sola.
    [Parameter(Mandatory)]
    [string]$Version,

    # Desactiva la guarda de no-retroceso. Solo para volver a una version
    # anterior a proposito.
    [switch]$AllowRollback
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

# La forma de la version dice a que ambiente pertenece, y el pipeline lo exige.
# Es la guarda que reemplaza a la validacion cruzada de los cuatro campos.
$versionPattern = if ($Environment -eq "prod") {
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}
else {
    '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-dev\.[1-9][0-9]*$'
}
# Prueba de que la imagen salio del pipeline: el mismo digest debe llevar el tag
# del commit que la produjo, con el prefijo propio de cada ciclo.
$commitTagPattern = if ($Environment -eq "prod") { '^sha-[0-9a-f]{12}$' } else { '^dev-[0-9a-f]{12}$' }

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

# Precedencia SemVer acotada a las dos formas que este pipeline acuña. Una
# release siempre gana a sus propios pre-releases: 1.1.0-dev.9 < 1.1.0.
function Get-VersionPrecedenceKey {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-dev\.([1-9][0-9]*))?$') {
        return $null
    }

    $prerelease = if ($Matches[4]) { [int]$Matches[4] } else { [int]::MaxValue }
    return , @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], $prerelease)
}

function Compare-DeployVersion {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Right
    )

    $leftKey = Get-VersionPrecedenceKey -Value $Left
    $rightKey = Get-VersionPrecedenceKey -Value $Right
    if ($null -eq $leftKey -or $null -eq $rightKey) {
        return $null
    }

    for ($index = 0; $index -lt 4; $index += 1) {
        if ($leftKey[$index] -ne $rightKey[$index]) {
            return $leftKey[$index] - $rightKey[$index]
        }
    }

    return 0
}

function Resolve-DeployableImage {
    Write-Host "[ECR] Resolviendo el digest del tag $Version..." -ForegroundColor Cyan

    $response = $null
    try {
        $response = Get-ExternalJson -Command "aws" -Arguments @(
            "ecr", "describe-images",
            "--repository-name", $repositoryName,
            "--image-ids", "imageTag=$Version",
            "--output", "json"
        )
    }
    catch {
        throw "El tag '$Version' no existe en $repositoryName. Use la versión que publicó el pipeline del backend."
    }

    $details = @($response.imageDetails)
    if ($details.Count -ne 1) {
        throw "El tag '$Version' no resuelve a una imagen única en $repositoryName."
    }

    $digest = [string]$details[0].imageDigest
    if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw "ECR no devolvió un digest sha256 válido para '$Version'."
    }

    $tags = @($details[0].imageTags)
    $commitTag = @($tags | Where-Object { $_ -match $commitTagPattern }) | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($commitTag)) {
        throw "El digest de '$Version' no lleva el tag de commit obligatorio ($commitTagPattern); la imagen no salió del pipeline de publicación."
    }

    Write-Host "[ECR] $Version -> $digest (commit $commitTag)" -ForegroundColor Green
    return [PSCustomObject]@{
        Digest    = $digest
        Tags      = $tags
        CommitTag = [string]$commitTag
    }
}

function Assert-ImageIntegrity {
    param(
        [Parameter(Mandatory)][string]$Digest,
        [Parameter(Mandatory)][string]$ExpectedImageUri
    )

    Write-Host "[ECR] Esperando y evaluando el escaneo..." -ForegroundColor Cyan
    Invoke-ExternalCommand -Command "aws" -Arguments @(
        "ecr", "wait", "image-scan-complete",
        "--repository-name", $repositoryName,
        "--image-id", "imageDigest=$Digest"
    )

    $scan = Get-ExternalJson -Command "aws" -Arguments @(
        "ecr", "describe-image-scan-findings",
        "--repository-name", $repositoryName,
        "--image-id", "imageDigest=$Digest",
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

# Trazabilidad sin pedirsela a nadie: la imagen ya trae el commit completo y la
# URL del run en sus labels OCI. Es informativa, asi que cualquier fallo -por
# ejemplo un rol sin ecr:GetDownloadUrlForLayer- degrada a un aviso, nunca corta
# el despliegue.
function Get-ImageTraceability {
    param([Parameter(Mandatory)][string]$Digest)

    try {
        $manifest = $null
        $manifestDigest = $Digest

        for ($hop = 0; $hop -lt 2; $hop += 1) {
            $response = Get-ExternalJson -Command "aws" -Arguments @(
                "ecr", "batch-get-image",
                "--repository-name", $repositoryName,
                "--image-ids", "imageDigest=$manifestDigest",
                "--accepted-media-types",
                "application/vnd.oci.image.index.v1+json",
                "application/vnd.oci.image.manifest.v1+json",
                "application/vnd.docker.distribution.manifest.v2+json",
                "--output", "json"
            )
            $manifest = (@($response.images) | Select-Object -First 1).imageManifest | ConvertFrom-Json
            if ($null -eq $manifest.manifests) { break }

            # La imagen es un index: el manifiesto de arm64 es el que importa,
            # el resto son atestaciones de procedencia.
            $child = @($manifest.manifests | Where-Object {
                $_.platform.architecture -eq "arm64" -and $_.platform.os -eq "linux"
            }) | Select-Object -First 1
            if ($null -eq $child) { return $null }
            $manifestDigest = [string]$child.digest
        }

        $configDigest = [string]$manifest.config.digest
        if ([string]::IsNullOrWhiteSpace($configDigest)) { return $null }

        $downloadUrl = (& aws ecr get-download-url-for-layer `
                --repository-name $repositoryName `
                --layer-digest $configDigest `
                --query downloadUrl --output text)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($downloadUrl)) { return $null }

        return (Invoke-RestMethod -Uri $downloadUrl).config.Labels
    }
    catch {
        Write-Warning "No fue posible leer los labels OCI de la imagen: $($_.Exception.Message)"
        return $null
    }
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
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SummaryDetails
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
    Write-WorkflowSummary -Lines (@(
            "## Backend image deployment · $Mode",
            "",
            "- Environment: ``$Environment``"
        ) + $SummaryDetails + @(
            "- Terraform changes: $changeList",
            "- Guard: only ECS task definition/service changes are allowed"
        ))

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
        ClusterName     = [string]$clusterName
        ServiceName     = [string]$serviceName
        PreviousImage   = [string]$backend[0].image
        PreviousVersion = (Resolve-DeployedVersion -ImageReference ([string]$backend[0].image))
    }
}

# La task definition fija la imagen por digest, asi que la version en ejecucion
# se recupera preguntandole a ECR que tags lleva ese digest.
function Resolve-DeployedVersion {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$ImageReference)

    if ($ImageReference -notmatch '@(sha256:[0-9a-f]{64})$') { return "" }
    $digest = $Matches[1]

    try {
        $response = Get-ExternalJson -Command "aws" -Arguments @(
            "ecr", "describe-images",
            "--repository-name", $repositoryName,
            "--image-ids", "imageDigest=$digest",
            "--output", "json"
        )
        $tags = @(@($response.imageDetails)[0].imageTags)
        $version = @($tags | Where-Object { $_ -match $versionPattern }) | Select-Object -First 1
        return [string]$version
    }
    catch {
        return ""
    }
}

# Con cuatro campos cruzados un dedazo fallaba ruidosamente. Con un solo campo,
# escribir 1.1.0-dev.13 en vez de 1.1.0-dev.31 desplegaria una version vieja sin
# que nadie se entere: esta guarda es lo que hace que simplificar no salga caro.
function Assert-NoRegression {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$RunningVersion)

    if ([string]::IsNullOrWhiteSpace($RunningVersion)) {
        Write-Warning "La imagen en ejecución no expone una versión conocida; se omite la guarda de no-retroceso."
        return
    }

    $comparison = Compare-DeployVersion -Left $Version -Right $RunningVersion
    if ($null -eq $comparison) {
        Write-Warning "No fue posible comparar $Version con $RunningVersion; se omite la guarda de no-retroceso."
        return
    }

    if ($comparison -ge 0) {
        Write-Host "[Guard] $Version no retrocede respecto de $RunningVersion." -ForegroundColor Green
        return
    }

    if ($AllowRollback) {
        Write-Warning "Retroceso autorizado explícitamente: $RunningVersion -> $Version."
        return
    }

    throw "La versión solicitada ($Version) es anterior a la desplegada ($RunningVersion). Repita con allow_rollback si el retroceso es intencional."
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

if ($Version -notmatch $versionPattern) {
    $expected = if ($Environment -eq "prod") { "X.Y.Z" } else { "X.Y.Z-dev.N" }
    throw "En $Environment la versión debe tener la forma $expected; se recibió '$Version'."
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

$image = Resolve-DeployableImage
$imageUri = "$accountId.dkr.ecr.$env:AWS_REGION.amazonaws.com/$repositoryName@$($image.Digest)"

Assert-ImageIntegrity -Digest $image.Digest -ExpectedImageUri $imageUri
$labels = Get-ImageTraceability -Digest $image.Digest
$sourceCommit = if ($null -ne $labels) { [string]$labels.'org.opencontainers.image.revision' } else { "" }
$sourceRunUrl = if ($null -ne $labels) { [string]$labels.'com.vetsoftware.image.run-url' } else { "" }

$summaryDetails = @(
    "- Version: ``$Version``",
    "- Digest: ``$($image.Digest)``",
    "- Commit tag: ``$($image.CommitTag)``"
)
if (-not [string]::IsNullOrWhiteSpace($sourceCommit)) {
    $summaryDetails += "- Source commit: ``$sourceCommit``"
}
if (-not [string]::IsNullOrWhiteSpace($sourceRunUrl)) {
    $summaryDetails += "- Source run: $sourceRunUrl"
}

Resolve-StateBackend -AccountId $accountId
Initialize-Terraform

# La guarda de no-retroceso necesita saber que corre hoy. En Plan un baseline
# ausente es informacion, no un error; en Apply lo sigue siendo porque sin el no
# hay rollback posible.
$serviceState = $null
if ($Mode -eq "Apply") {
    $serviceState = Get-CurrentServiceState
}
else {
    try {
        $serviceState = Get-CurrentServiceState
    }
    catch {
        Write-Warning "Sin baseline ECS todavía: $($_.Exception.Message)"
    }
}

if ($null -ne $serviceState) {
    Assert-NoRegression -RunningVersion $serviceState.PreviousVersion
    if (-not [string]::IsNullOrWhiteSpace($serviceState.PreviousVersion)) {
        $summaryDetails += "- Currently deployed: ``$($serviceState.PreviousVersion)``"
    }
}

$planPath = Join-Path $env:RUNNER_TEMP "backend-$Environment-$Mode.tfplan"
$changeCount = New-GuardedPlan -ImageUri $imageUri -PlanPath $planPath -SummaryDetails $summaryDetails

if ($Mode -eq "Plan") {
    Write-Host "Plan image-only validado; no se aplicaron cambios." -ForegroundColor Green
    exit 0
}

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
        $rollbackDetails = @(
            "- Rollback target: ``$($serviceState.PreviousImage)``"
        )
        $rollbackChanges = New-GuardedPlan -ImageUri $serviceState.PreviousImage -PlanPath $rollbackPlanPath -SummaryDetails $rollbackDetails
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
