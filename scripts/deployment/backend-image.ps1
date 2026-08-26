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
    # Mandatory aplica una validacion implicita de "no vacio" a cada elemento del
    # array, y el resumen usa lineas en blanco como separadores de markdown: sin
    # AllowEmptyString, escribirlo falla con "Cannot bind argument".
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

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

# El build publica con provenance y SBOM, asi que el tag no apunta a una imagen
# sino a un OCI index: una lista con el manifiesto de linux/arm64 y sus
# atestaciones. ECR escanea los manifiestos de plataforma, nunca el index, y los
# labels tambien viven en el manifiesto. Preguntar por el digest del tag devuelve
# ScanNotFoundException; hay que bajar un nivel.
function Resolve-PlatformManifest {
    param([Parameter(Mandatory)][string]$Digest)

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

        if ($null -eq $manifest.manifests) {
            return [PSCustomObject]@{
                Digest   = $manifestDigest
                Manifest = $manifest
                FromIndex = ($manifestDigest -ne $Digest)
            }
        }

        $child = @($manifest.manifests | Where-Object {
            $_.platform.architecture -eq "arm64" -and $_.platform.os -eq "linux"
        }) | Select-Object -First 1
        if ($null -eq $child) {
            throw "El index de la imagen no contiene ningún manifiesto linux/arm64."
        }
        $manifestDigest = [string]$child.digest
    }

    throw "No fue posible resolver el manifiesto de plataforma de $Digest."
}

# La fuente de verdad del escaneo es describe-image-scan-findings, la misma que
# consulta el waiter de AWS. describe-images parece mas comodo -no falla cuando no
# hay escaneo- pero puede no exponer todavia imageScanStatus mientras el escaneo
# esta en vuelo, y eso hace ver como "sin escaneo" a una imagen que si lo tiene.
# Aqui el error se captura a un archivo para distinguir un ScanNotFoundException,
# que es "todavia no", de un error real de permisos.
function Get-ImageScanState {
    param([Parameter(Mandatory)][string]$Digest)

    $errorPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ecr-scan-" + [Guid]::NewGuid().ToString("N") + ".err")

    try {
        $raw = & aws ecr describe-image-scan-findings `
            --repository-name $repositoryName `
            --image-id "imageDigest=$Digest" `
            --output json 2>$errorPath

        if ($LASTEXITCODE -ne 0) {
            $detail = ""
            if (Test-Path -LiteralPath $errorPath) {
                $detail = ((Get-Content -LiteralPath $errorPath -Raw) -replace '\s+', ' ').Trim()
            }

            return [PSCustomObject]@{
                Status      = ""
                Description = $detail
                Critical    = 0
                High        = 0
            }
        }

        $scan = (($raw -join [Environment]::NewLine) | ConvertFrom-Json)
        $efectivos = Resolve-EffectiveCounts -Scan $scan
        $critical = $efectivos.Critical
        $high = $efectivos.High

        return [PSCustomObject]@{
            Status      = [string]$scan.imageScanStatus.status
            Description = [string]$scan.imageScanStatus.description
            Critical    = $critical
            High        = $high
        }
    }
    finally {
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }
}

# Excepciones del escaneo, con caducidad OBLIGATORIA.
#
# Una excepcion sin fecha deja de ser una excepcion: se convierte en un punto ciego
# permanente que nadie recuerda haber concedido. Por eso cada entrada caduca, y al
# caducar el gate vuelve a bloquear diciendo por que.
#
# Solo se justifica cuando NO hay arreglo disponible. Si el paquete tiene version
# parcheada, lo que toca es reconstruir la imagen, no perdonar el hallazgo.
$scanWaivers = @{
    "CVE-2026-8932" = @{
        Until  = "2026-09-25"
        Reason = "curl/libcurl4t64 8.5.0-2ubuntu10.12 es la ultima que Ubuntu publica para noble: no existe version parcheada que instalar. curl esta en la imagen solo para el health check contra localhost. Seguimiento: sacar curl y comprobar la salud con un binario estatico."
    }
}

# Descuenta de los conteos los hallazgos perdonados que siguen vigentes.
#
# Un perdon caducado NO descuenta: vuelve a bloquear, que es lo unico que hace que la
# fecha signifique algo. Y un perdon que ya no corresponde a ningun hallazgo se avisa
# para que se retire, porque una lista de excepciones que nadie poda acaba tapando
# hallazgos nuevos con el mismo identificador.
function Resolve-EffectiveCounts {
    param([Parameter(Mandatory)]$Scan)

    $counts = $Scan.imageScanFindings.findingSeverityCounts
    $critical = 0
    $high = 0
    if ($null -ne $counts.CRITICAL) { $critical = [int]$counts.CRITICAL }
    if ($null -ne $counts.HIGH) { $high = [int]$counts.HIGH }

    $hallazgos = @()
    foreach ($f in @($Scan.imageScanFindings.findings)) {
        if ($f.name) { $hallazgos += [PSCustomObject]@{ Id = [string]$f.name; Severity = [string]$f.severity } }
    }
    foreach ($f in @($Scan.imageScanFindings.enhancedFindings)) {
        $id = [string]$f.packageVulnerabilityDetails.vulnerabilityId
        if ($id) { $hallazgos += [PSCustomObject]@{ Id = $id; Severity = [string]$f.severity } }
    }

    # Sin lista de hallazgos no se puede descontar sin adivinar: se devuelven los
    # conteos crudos y que el gate decida con ellos. Fallar cerrado, no abierto.
    if ($hallazgos.Count -eq 0) {
        return [PSCustomObject]@{ Critical = $critical; High = $high }
    }

    $hoy = (Get-Date).Date
    foreach ($entrada in $scanWaivers.GetEnumerator()) {
        $id = $entrada.Key
        $hasta = [datetime]::ParseExact($entrada.Value.Until, "yyyy-MM-dd", $null)
        $coincidencias = @($hallazgos | Where-Object { $_.Id -eq $id -and $_.Severity -in @("CRITICAL", "HIGH") })

        if ($coincidencias.Count -eq 0) {
            Write-Host "[ECR] La excepcion de $id ya no corresponde a ningun hallazgo: retirala de scanWaivers." -ForegroundColor Yellow
            continue
        }

        if ($hoy -gt $hasta) {
            Write-Warning "[ECR] La excepcion de $id caduco el $($entrada.Value.Until) y ya NO descuenta: el gate bloquea. Renuevala con motivo o arregla el hallazgo."
            continue
        }

        foreach ($c in $coincidencias) {
            if ($c.Severity -eq "CRITICAL") { $critical-- } else { $high-- }
        }
        Write-Host "[ECR] Perdonado $id ($($coincidencias.Count) hallazgo(s)) hasta $($entrada.Value.Until). Motivo: $($entrada.Value.Reason)" -ForegroundColor Yellow
    }

    if ($critical -lt 0) { $critical = 0 }
    if ($high -lt 0) { $high = 0 }
    return [PSCustomObject]@{ Critical = $critical; High = $high }
}

# SCAN_ON_PUSH solo alcanza a las imagenes empujadas despues de configurarlo. Para
# una anterior -o para un escaneo que expiro- se pide uno a demanda, que el
# escaneo basico admite una vez cada 24 horas por imagen.
#
# Devuelve si conviene seguir esperando: la quota agotada significa que ya hubo un
# escaneo en las ultimas 24 horas, o sea que hay uno en vuelo y merece el margen
# largo en vez del corto de "esto no va a aparecer nunca".
function Start-ImageScanOnce {
    param([Parameter(Mandatory)][string]$Digest)

    $errorPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ecr-start-scan-" + [Guid]::NewGuid().ToString("N") + ".err")

    try {
        Write-Host "[ECR] Sin escaneo registrado; solicitando uno a demanda..." -ForegroundColor Cyan
        & aws ecr start-image-scan `
            --repository-name $repositoryName `
            --image-id "imageDigest=$Digest" `
            --output json 2>$errorPath | Out-Null

        if ($LASTEXITCODE -eq 0) { return $true }

        $detail = ""
        if (Test-Path -LiteralPath $errorPath) {
            $detail = ((Get-Content -LiteralPath $errorPath -Raw) -replace '\s+', ' ').Trim()
        }

        if ($detail -match "LimitExceededException") {
            Write-Host "[ECR] La imagen ya consumió su escaneo del período; hay uno en vuelo." -ForegroundColor Cyan
            return $true
        }

        Write-Warning "No fue posible iniciar el escaneo a demanda: $detail"
        return $false
    }
    finally {
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ImageIntegrity {
    param(
        [Parameter(Mandatory)][string]$Digest,
        [Parameter(Mandatory)][string]$ExpectedImageUri
    )

    $platform = Resolve-PlatformManifest -Digest $Digest
    if ($platform.FromIndex) {
        Write-Host "[ECR] El tag apunta a un index; se evalúa el manifiesto linux/arm64 $($platform.Digest)." -ForegroundColor Cyan
    }

    Write-Host "[ECR] Esperando y evaluando el escaneo..." -ForegroundColor Cyan
    # ACTIVE es el estado terminal del escaneo mejorado de Inspector; COMPLETE, el
    # del escaneo basico. El resto de los terminales significan que no va a haber
    # hallazgos utilizables.
    $terminal = @("COMPLETE", "ACTIVE", "FAILED", "UNSUPPORTED_IMAGE", "SCAN_ELIGIBILITY_EXPIRED", "FINDINGS_UNAVAILABLE")
    # Un escaneo en curso progresa y merece los diez minutos. Uno que nunca se
    # encolo no va a aparecer por esperarlo: se corta antes, con el margen justo
    # para que ECR registre el de una imagen recien empujada. En cuanto sabemos
    # que hay uno en vuelo, el corto deja de aplicar.
    $missingDeadline = (Get-Date).AddMinutes(3)
    $progressDeadline = (Get-Date).AddMinutes(10)
    $scanPending = $false
    $state = Get-ImageScanState -Digest $platform.Digest

    if ([string]::IsNullOrWhiteSpace($state.Status)) {
        $scanPending = Start-ImageScanOnce -Digest $platform.Digest
        $state = Get-ImageScanState -Digest $platform.Digest
    }

    while ($state.Status -notin $terminal) {
        $deadline = if ([string]::IsNullOrWhiteSpace($state.Status) -and -not $scanPending) {
            $missingDeadline
        }
        else {
            $progressDeadline
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 15
        $state = Get-ImageScanState -Digest $platform.Digest
    }

    if ($state.Status -in @("COMPLETE", "ACTIVE")) {
        if ($state.Critical -ne 0 -or $state.High -ne 0) {
            throw (@(
                    "El escaneo ECR rechazó la imagen: critical=$($state.Critical), high=$($state.High).",
                    "  Para ver los hallazgos:",
                    "  aws ecr describe-image-scan-findings --repository-name $repositoryName --image-id imageDigest=$($platform.Digest)"
                ) -join [Environment]::NewLine)
        }

        Write-Host "[ECR] Imagen certificada: $ExpectedImageUri" -ForegroundColor Green
        return $platform.Digest
    }

    $reason = if ([string]::IsNullOrWhiteSpace($state.Status)) {
        "ECR no registró ningún escaneo para ese manifiesto. $($state.Description)".Trim()
    }
    else {
        "el escaneo terminó en $($state.Status). $($state.Description)".Trim()
    }
    throw (@(
            "No hay un escaneo utilizable para la imagen: $reason.",
            "  Digest del tag:      $Digest",
            "  Manifiesto evaluado: $($platform.Digest)",
            "  Verifique que $repositoryName tenga escaneo habilitado -scan on push básico o Amazon Inspector- y que el manifiesto sea de un sistema operativo soportado."
        ) -join [Environment]::NewLine)
}

# Trazabilidad sin pedirsela a nadie: la imagen ya trae el commit completo y la
# URL del run en sus labels OCI. Es informativa, asi que cualquier fallo -por
# ejemplo un rol sin ecr:GetDownloadUrlForLayer- degrada a un aviso, nunca corta
# el despliegue.
function Get-ImageTraceability {
    param([Parameter(Mandatory)][string]$Digest)

    try {
        $configDigest = [string](Resolve-PlatformManifest -Digest $Digest).Manifest.config.digest
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

# Mismo contrato que New-OptionalVariableFile de .github/scripts/terraform-cycle.ps1.
# El ciclo general pasa las variables no sensibles del ambiente por TF_VARS_JSON; si
# el despliegue de imagen no las ve, su plan diverge del real y pide destruir lo que
# esas variables sostienen -las alertas de costo, por ejemplo-, con lo que el guard
# image-only lo rechaza sin que haya nada mal.
function New-OptionalVariableFile {
    if ([string]::IsNullOrWhiteSpace($env:TF_VARS_JSON)) {
        return ""
    }

    try {
        $configuration = $env:TF_VARS_JSON | ConvertFrom-Json
    }
    catch {
        throw "TF_VARS_JSON no contiene un objeto JSON válido: $($_.Exception.Message)"
    }
    if ($null -eq $configuration -or $configuration -isnot [PSCustomObject]) {
        throw "TF_VARS_JSON debe ser un objeto JSON."
    }

    # backend_image_uri lo fija este script con el digest ya certificado, y el resto
    # son secretos que nunca deben viajar en una variable de repositorio.
    $forbiddenVariables = @(
        "backend_image_uri",
        "cloudflare_tunnel_token",
        "dian_enc_key",
        "environment",
        "jwt_secret",
        "otel_exporter_otlp_headers",
        "otlp_api_key",
        "otlp_username",
        "recaptcha_secret",
        "resend_api_key"
    )
    $forbiddenConfigured = @(@($configuration.PSObject.Properties.Name) | Where-Object {
        $_ -in $forbiddenVariables
    })
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

    Write-Host "[Terraform] Variables del ambiente tomadas de TF_VARS_JSON." -ForegroundColor Cyan
    return $variableFile
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
    # Los argumentos van citados y en un array. Sin comillas, PowerShell pasa
    # -out=$PlanPath literal -no expande una variable dentro de un token que
    # empieza con guion-, terraform guarda el plan en un archivo llamado
    # "$PlanPath" dentro del directorio del -chdir, y el show siguiente falla
    # buscandolo en la ruta absoluta.
    $planArguments = @(
        "-chdir=$environmentDirectory",
        "plan",
        "-input=false",
        "-lock-timeout=5m",
        "-out=$PlanPath",
        "-no-color",
        "-detailed-exitcode"
    )
    if (-not [string]::IsNullOrWhiteSpace($script:variableFile)) {
        $planArguments += "-var-file=$script:variableFile"
    }
    & terraform @planArguments | ForEach-Object { Write-Host $_ }
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
        # $unexpected.address no enumera: System.Array tiene su propio miembro
        # Address y PowerShell lo resuelve antes que la propiedad de cada
        # elemento, asi que el mensaje salia con la firma del metodo en vez de
        # los recursos. Justo cuando mas se necesita leerlo.
        $addresses = ($unexpected | ForEach-Object { $_.address } | Sort-Object -Unique) -join ", "
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
        ($changedResources | ForEach-Object { $_.address } | Sort-Object -Unique) -join ", "
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
        DesiredCount    = [int]$service.desiredCount
        PreviousImage   = [string]$backend[0].image
        PreviousVersion = (Resolve-DeployedVersion -ImageReference ([string]$backend[0].image))
    }
}

# El apagado programado no para solo el servicio: tambien detiene la instancia RDS
# -20:15, hora America/Bogota- y nada la vuelve a arrancar por hora, asi que el
# ambiente puede estar apagado a cualquier hora. Levantar la tarea sin base solo
# produce un crashloop en Liquibase, de modo que la verificacion necesita el
# ambiente entero.
function Get-DatabaseIdentifier {
    $endpoint = (& terraform "-chdir=$environmentDirectory" output -raw database_endpoint)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($endpoint)) {
        return ""
    }

    $identifier = ($endpoint -split "\.")[0]
    if ($identifier -notmatch '^[a-z][a-z0-9-]*$') {
        return ""
    }

    return $identifier
}

function Get-DatabaseStatus {
    param([Parameter(Mandatory)][string]$Identifier)

    $status = (& aws rds describe-db-instances `
            --db-instance-identifier $Identifier `
            --query "DBInstances[0].DBInstanceStatus" --output text)
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    return ([string]$status).Trim()
}

function Wait-DatabaseAvailable {
    param([Parameter(Mandatory)][string]$Identifier)

    Invoke-ExternalCommand -Command "aws" -Arguments @(
        "rds", "wait", "db-instance-available",
        "--db-instance-identifier", $Identifier
    )
}

# Con cero tareas el steady state es trivial y el smoke test no tiene contra que
# correr, asi que se levanta una tarea solo para verificar. El servicio declara
# ignore_changes sobre desired_count -lo gobierna el scheduler-, de modo que
# tocarlo por API no genera drift para Terraform.
function Set-ServiceDesiredCount {
    param(
        [Parameter(Mandatory)][PSCustomObject]$ServiceState,
        [Parameter(Mandatory)][int]$DesiredCount
    )

    Write-Host "[ECS] Ajustando el servicio a $DesiredCount tarea(s)..." -ForegroundColor Cyan
    & aws ecs update-service `
        --cluster $ServiceState.ClusterName `
        --service $ServiceState.ServiceName `
        --desired-count $DesiredCount `
        --query "service.desiredCount" --output text | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible ajustar el servicio a $DesiredCount tarea(s)."
    }

    Invoke-ExternalCommand -Command "aws" -Arguments @(
        "ecs", "wait", "services-stable",
        "--cluster", $ServiceState.ClusterName,
        "--services", $ServiceState.ServiceName
    )
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

    # El waiter da el servicio por estable en cuanto runningCount alcanza a
    # desiredCount con un solo deployment, pero ECS tarda unos segundos mas en
    # marcar rolloutState como COMPLETED. Leerlo de inmediato lo encuentra en
    # IN_PROGRESS y dispara un rollback que nada justifica, sobre un despliegue que
    # de hecho funciono. Se espera a que el estado se asiente; FAILED corta al
    # instante, que es lo unico que si es un fallo.
    $rolloutDeadline = (Get-Date).AddMinutes(3)
    $service = $null
    $primary = $null

    while ($true) {
        $serviceResponse = Get-ExternalJson -Command "aws" -Arguments @(
            "ecs", "describe-services",
            "--cluster", $ServiceState.ClusterName,
            "--services", $ServiceState.ServiceName,
            "--output", "json"
        )
        $service = @($serviceResponse.services) | Select-Object -First 1
        $primary = @($service.deployments | Where-Object { $_.status -eq "PRIMARY" }) | Select-Object -First 1
        $rolloutState = [string]$primary.rolloutState

        if ($rolloutState -eq "COMPLETED") { break }
        if ($rolloutState -eq "FAILED") {
            throw "El deployment PRIMARY falló: $(([string]$primary.rolloutStateReason).Trim())"
        }
        if ((Get-Date) -ge $rolloutDeadline) {
            $rollout = if ($null -eq $primary) { "sin deployment PRIMARY" } else { "rolloutState=$rolloutState. $($primary.rolloutStateReason)" }
            throw "El deployment PRIMARY no terminó a tiempo: $($rollout.Trim())"
        }

        Write-Host "[ECS] El rollout figura en '$rolloutState'; se espera a que ECS lo cierre." -ForegroundColor Cyan
        Start-Sleep -Seconds 10
    }

    if ($service.runningCount -ne $service.desiredCount -or $service.pendingCount -ne 0) {
        throw "ECS no está estable: desired=$($service.desiredCount), running=$($service.runningCount), pending=$($service.pendingCount)."
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

# El aviso de despliegue sale por el topic de alertas que Amazon Q ya publica en
# Slack: reusar ese canal evita un webhook nuevo y un secreto mas que rotar. Solo
# dev, porque es el unico ambiente cuyo rol de apply esta autorizado a publicar en
# el topic y a usar la CMK que lo cifra.
function Get-NotificationTopicArn {
    if ($Environment -ne "dev") {
        return ""
    }

    try {
        # El aviso de despliegue es un evento, no una alarma: sale por el topic
        # de eventos, que aterriza en el canal de infra junto a los apagados.
        $alerting = Get-ExternalJson -Command "terraform" -Arguments @(
            "-chdir=$environmentDirectory", "output", "-json", "alerting"
        )
        if (-not $alerting.slack_enabled) {
            return ""
        }

        return [string]$alerting.events_topic_arn
    }
    catch {
        return ""
    }
}

# Un aviso nunca puede tumbar un despliegue: todo fallo aca es una advertencia.
# El formato es el de las "custom notifications" de Amazon Q -version, source y
# content-, lo unico que ese integrador acepta de un emisor propio.
function Send-DeploymentNotification {
    param(
        [Parameter(Mandatory)][ValidateSet("Deployed", "RolledBack", "Failed")][string]$Result,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reason
    )

    try {
        $topicArn = Get-NotificationTopicArn
        if ([string]::IsNullOrWhiteSpace($topicArn)) {
            Write-Host "[Slack] Sin topic de alertas configurado; no se envía aviso." -ForegroundColor Cyan
            return
        }

        $previousVersion = if ($null -ne $serviceState -and -not [string]::IsNullOrWhiteSpace($serviceState.PreviousVersion)) {
            $serviceState.PreviousVersion
        }
        else {
            "desconocida"
        }

        $title = switch ($Result) {
            "Deployed" { ":rocket: Backend $Environment desplegado - $Version" }
            "RolledBack" { ":rewind: Backend $Environment revertido - $Version falló" }
            default { ":x: Backend $Environment sin desplegar - $Version falló" }
        }

        $description = @(
            "*Ambiente:* $Environment",
            "*Versión:* $Version",
            "*Versión anterior:* $previousVersion"
        )
        # El digest completo son 71 caracteres que nadie lee en Slack; los primeros
        # doce alcanzan para casarlo con el de ECR.
        $description += "*Imagen:* $($image.Digest.Substring(0, [Math]::Min(19, $image.Digest.Length)))..."
        if (-not [string]::IsNullOrWhiteSpace($sourceCommit)) {
            $description += "*Commit:* $($sourceCommit.Substring(0, [Math]::Min(12, $sourceCommit.Length)))"
        }
        if ($Result -eq "RolledBack") {
            $description += "*Corriendo ahora:* $previousVersion"
        }
        if (-not [string]::IsNullOrWhiteSpace($Reason)) {
            $description += "*Motivo:* $Reason"
        }
        if ($startedDatabase -or $scaledForVerification) {
            $description += "_El ambiente estaba apagado: se encendió para verificar y se volvió a apagar._"
        }
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTOR)) {
            $description += "*Lanzado por:* $env:GITHUB_ACTOR"
        }

        $nextSteps = @()
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
            $runUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
            $nextSteps += "<$runUrl|Ver la corrida en GitHub Actions>"
        }

        $content = [ordered]@{
            textType    = "client-markdown"
            title       = $title
            description = ($description -join "`n")
        }
        if ($nextSteps.Count -gt 0) {
            $content.nextSteps = $nextSteps
        }

        $payload = [ordered]@{
            version = "1.0"
            source  = "custom"
            content = $content
        }

        # El JSON viaja por archivo y no como argumento: pasarlo en linea deja las
        # comillas a merced de como cada shell rearme el comando.
        $payloadRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
        $payloadPath = Join-Path $payloadRoot "backend-$Environment-notification.json"
        ($payload | ConvertTo-Json -Depth 5 -Compress) | Set-Content -LiteralPath $payloadPath -Encoding utf8

        & aws sns publish `
            --topic-arn $topicArn `
            --message "file://$payloadPath" `
            --query "MessageId" --output text | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "aws sns publish falló con código $LASTEXITCODE."
        }

        Write-Host "[Slack] Aviso de despliegue publicado." -ForegroundColor Green
    }
    catch {
        Write-Warning "No fue posible avisar del despliegue en Slack: $($_.Exception.Message)"
        Write-WorkflowSummary -Lines @("", "- WARNING: the Slack deployment notification could not be published")
    }
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
# One placeholder per secret: modules/secrets composes the JSON now. Each value
# must satisfy its own variable validation at plan time -jwt_secret needs 32
# characters or more, the other six must not be empty- while still reading as an
# obvious placeholder.
$env:TF_VAR_jwt_secret = "image-only-plan-placeholder-32chars"
$env:TF_VAR_resend_api_key = "not-used"
$env:TF_VAR_recaptcha_secret = "not-used"
# DIAN_ENC_KEY is decoded as AES-256, so it must be base64 of exactly 32 bytes.
# This one decodes to 32 "X" characters: deliberately low entropy, because a
# readable placeholder trips the gitleaks generic-api-key rule (#196).
$env:TF_VAR_dian_enc_key = "WFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFg="
$env:TF_VAR_otlp_username = "not-used"
$env:TF_VAR_otlp_api_key = "not-used"
$env:TF_VAR_otel_exporter_otlp_headers = "Authorization=Basic bm90LXVzZWQ6bm90LXVzZWQ="
$env:TF_VAR_cloudflare_tunnel_token = "image-only-plan-placeholder-32chars"

$accountId = (& aws sts get-caller-identity --query Account --output text)
if ($LASTEXITCODE -ne 0 -or $accountId -notmatch '^[0-9]{12}$') {
    throw "No fue posible resolver la cuenta AWS activa."
}

$image = Resolve-DeployableImage
$imageUri = "$accountId.dkr.ecr.$env:AWS_REGION.amazonaws.com/$repositoryName@$($image.Digest)"

$scannedDigest = Assert-ImageIntegrity -Digest $image.Digest -ExpectedImageUri $imageUri
$labels = Get-ImageTraceability -Digest $image.Digest
$sourceCommit = if ($null -ne $labels) { [string]$labels.'org.opencontainers.image.revision' } else { "" }
$sourceRunUrl = if ($null -ne $labels) { [string]$labels.'com.vetsoftware.image.run-url' } else { "" }

$summaryDetails = @(
    "- Version: ``$Version``",
    "- Digest: ``$($image.Digest)``",
    "- Commit tag: ``$($image.CommitTag)``"
)
if ($scannedDigest -ne $image.Digest) {
    $summaryDetails += "- Scanned manifest: ``$scannedDigest``"
}
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
    if ($serviceState.DesiredCount -eq 0) {
        Write-Warning "El ambiente está apagado: el apply levantará la base y una tarea para verificar, y volverá a apagarlas. Sumará varios minutos."
        $summaryDetails += "- Environment is off: the apply starts the database and one task to verify, then shuts both back down"
    }
}

$script:variableFile = New-OptionalVariableFile
$planPath = Join-Path $env:RUNNER_TEMP "backend-$Environment-$Mode.tfplan"
$changeCount = New-GuardedPlan -ImageUri $imageUri -PlanPath $planPath -SummaryDetails $summaryDetails

if ($Mode -eq "Plan") {
    Write-Host "Plan image-only validado; no se aplicaron cambios." -ForegroundColor Green
    exit 0
}

$scaledForVerification = $false
$startedDatabase = $false
$databaseIdentifier = ""
# Lo que se le va a contar a Slack. Arranca en el peor caso: si algo revienta sin
# llegar siquiera al rollback, lo que se despacha es el fallo.
$notificationResult = "Failed"
$notificationReason = ""

try {
    try {
        # La base va antes del apply, no despues. El servicio tiene
        # wait_for_steady_state, asi que si ya hay tareas corriendo el propio apply
        # dispara un deployment y espera a que levante: sin base, esas tareas mueren
        # en Liquibase y el circuit breaker termina cortando el apply con "No
        # rollback candidate was found". Condicionarlo al desired_count tampoco
        # servia, porque una corrida anterior puede haber dejado el servicio en uno.
        $databaseIdentifier = Get-DatabaseIdentifier
        if ([string]::IsNullOrWhiteSpace($databaseIdentifier)) {
            throw "No fue posible resolver la instancia RDS desde el output database_endpoint."
        }

        $databaseStatus = Get-DatabaseStatus -Identifier $databaseIdentifier
        if ($databaseStatus -eq "stopped") {
            Write-Warning "La base está apagada; se arranca para poder desplegar y verificar, y se vuelve a apagar al final."
            Write-Host "[RDS] Arrancando $databaseIdentifier..." -ForegroundColor Cyan
            Invoke-ExternalCommand -Command "aws" -Arguments @(
                "rds", "start-db-instance",
                "--db-instance-identifier", $databaseIdentifier,
                "--query", "DBInstance.DBInstanceStatus", "--output", "text"
            )
            # Solo se apaga lo que este script haya arrancado.
            $startedDatabase = $true
            Wait-DatabaseAvailable -Identifier $databaseIdentifier
        }
        elseif ($databaseStatus -ne "available") {
            Write-Host "[RDS] $databaseIdentifier está en estado '$databaseStatus'; se espera a que quede disponible." -ForegroundColor Cyan
            Wait-DatabaseAvailable -Identifier $databaseIdentifier
        }

        if ($changeCount -gt 0) {
            Write-Host "[Terraform] Aplicando el plan aprobado..." -ForegroundColor Cyan
            Invoke-ExternalCommand -Command "terraform" -Arguments @(
                "-chdir=$environmentDirectory", "apply", "-input=false", $planPath
            )
        }

        # Con el servicio en cero el apply no despliega nada, asi que se levanta una
        # tarea aca: nace con la revision nueva y da algo real que verificar.
        if ($serviceState.DesiredCount -eq 0) {
            Write-Warning "El servicio está en cero tareas; se levanta una para poder verificar el despliegue."
            Set-ServiceDesiredCount -ServiceState $serviceState -DesiredCount 1
            $scaledForVerification = $true
        }

        Assert-ServiceDeployment -ServiceState $serviceState -ExpectedImageUri $imageUri
        $notificationResult = "Deployed"
    }
    catch {
        $deploymentError = $_
        $notificationReason = $deploymentError.Exception.Message
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
            $notificationResult = "RolledBack"
            Write-WorkflowSummary -Lines @("", "- Rollback: completed to ``$($serviceState.PreviousImage)``")
        }
        else {
            Write-Warning "No se automatizó rollback porque la imagen anterior no estaba fijada por digest; el circuit breaker de ECS conserva la última revisión estable."
            Write-WorkflowSummary -Lines @("", "- Rollback: delegated to ECS circuit breaker; previous state was not digest-pinned")
        }
        throw $deploymentError
    }
}
finally {
    # Devolver el ambiente a como estaba, pase lo que pase: si la verificacion
    # fallo, si el rollback fallo, o si algo revento en el medio. Primero las
    # tareas y despues la base, para no dejar la aplicacion golpeando una base que
    # se esta apagando. Un fallo aca no puede tapar el error original, asi que se
    # reporta y no se relanza; ademas el apagado programado lo corrige en su
    # proxima ejecucion.
    # Tambien se baja el servicio cuando la base se arranco aca aunque el servicio
    # ya estuviera en uno: si hubo que arrancar la base, el ambiente estaba apagado,
    # y dejar tareas contra una base que se apaga es un crashloop garantizado hasta
    # que alguien encienda el ambiente a mano.
    if ($scaledForVerification -or $startedDatabase) {
        try {
            Set-ServiceDesiredCount -ServiceState $serviceState -DesiredCount 0
            Write-Host "[ECS] Servicio devuelto a cero tareas." -ForegroundColor Green
        }
        catch {
            Write-Warning "No fue posible devolver el servicio a cero tareas: $($_.Exception.Message). El apagado programado lo corregirá en su próxima ejecución."
            Write-WorkflowSummary -Lines @("", "- WARNING: the service was left running; the scheduled shutdown will scale it back to zero")
        }
    }

    if ($startedDatabase) {
        try {
            Write-Host "[RDS] Apagando $databaseIdentifier..." -ForegroundColor Cyan
            Invoke-ExternalCommand -Command "aws" -Arguments @(
                "rds", "stop-db-instance",
                "--db-instance-identifier", $databaseIdentifier,
                "--query", "DBInstance.DBInstanceStatus", "--output", "text"
            )
            Write-WorkflowSummary -Lines @("", "- Environment was off: started the database and one task to verify, then shut both back down")
        }
        catch {
            Write-Warning "No fue posible apagar $databaseIdentifier`: $($_.Exception.Message). Quedará corriendo hasta el apagado programado de las 20:15."
            Write-WorkflowSummary -Lines @("", "- WARNING: the database was left running; the scheduled shutdown will stop it at 20:15")
        }
    }

    # Al final de todo, para que el aviso cuente el desenlace completo: si hubo
    # rollback y si el ambiente quedo otra vez apagado.
    Send-DeploymentNotification -Result $notificationResult -Reason $notificationReason
}
