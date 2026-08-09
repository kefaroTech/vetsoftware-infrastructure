[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Plan", "Apply", "Drift", "Unlock")]
    [string]$Mode,

    [Parameter(Mandatory)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    # Solo para -Mode Unlock: el ID que reporta Terraform al no poder tomar el lock.
    [Parameter()]
    [string]$LockId
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version Latest

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$environmentDirectory = Join-Path $repositoryRoot "environments/$Environment"
$projectName = "vetsoftware"
$stateKey = "$projectName/$Environment/terraform.tfstate"

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

$script:awsAccountId = $null

function Get-AwsAccountId {
    if ([string]::IsNullOrWhiteSpace($script:awsAccountId)) {
        $accountId = (& aws sts get-caller-identity --query Account --output text)
        if ($LASTEXITCODE -ne 0 -or $accountId -notmatch '^[0-9]{12}$') {
            throw "No fue posible resolver la cuenta AWS activa."
        }

        $script:awsAccountId = $accountId
    }

    return $script:awsAccountId
}

function Resolve-StateBackend {
    # El bucket y la KMS key del state siguen la convencion que fija
    # bootstrap/state-backend.yml, asi que no hace falta configurarlos como
    # variables del Environment. Un valor explicito siempre tiene prioridad.
    if ([string]::IsNullOrWhiteSpace($env:TF_STATE_BUCKET)) {
        $env:TF_STATE_BUCKET = "$projectName-$Environment-tfstate-$(Get-AwsAccountId)"
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
    $repositoryName = if ($Environment -eq "dev") { "vetsoftware-dev-backend" } else { "vetsoftware-backend" }
    $repositoryPattern = [regex]::Escape($repositoryName)
    # PowerShell no escapa con barra invertida dentro de comillas dobles: "\\." llega
    # al motor de regex como \\. y exigiria una barra invertida literal en la URI.
    $imagePattern = "^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?/${repositoryPattern}@sha256:[0-9a-f]{64}$"

    # Escotilla de operacion. El ciclo general hereda la imagen en ejecucion para no
    # revertir despliegues, pero cuando esa imagen esta rota el servicio nunca alcanza
    # steady state y cada apply la vuelve a fijar: sin una salida explicita solo queda
    # reescribir la task definition a mano. Un digest pasado en el dispatch manda sobre
    # la lectura de ECS. El circuito de imagen (deploy-backend-*) sigue siendo la via
    # normal; esto es para cuando ese circuito no puede correr.
    if (-not [string]::IsNullOrWhiteSpace($env:FORCE_BACKEND_IMAGE_URI)) {
        if ($env:FORCE_BACKEND_IMAGE_URI -notmatch $imagePattern) {
            throw "FORCE_BACKEND_IMAGE_URI debe fijar $repositoryName por digest inmutable: <cuenta>.dkr.ecr.<region>.amazonaws.com/$repositoryName@sha256:<64 hex>."
        }

        $env:TF_VAR_backend_image_uri = $env:FORCE_BACKEND_IMAGE_URI
        Write-Host "[Terraform] Imagen forzada desde el dispatch: $env:FORCE_BACKEND_IMAGE_URI" -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
            Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Value @(
                "",
                "### Imagen del backend forzada",
                "",
                "El ciclo no heredo la imagen en ejecucion. El dispatch fijo ``$env:FORCE_BACKEND_IMAGE_URI``."
            )
        }

        return
    }

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
        # Un servicio borrado sigue visible como INACTIVE cerca de una hora y conserva su
        # ultima task definition. Sin filtrar por estado, el ciclo heredaria la imagen de
        # un servicio que ya no existe y volveria a desplegarla.
        $service = @($services.services) | Select-Object -First 1
        if ($null -eq $service -or [string]$service.status -ne "ACTIVE") {
            throw "No hay un servicio ECS ACTIVE del que heredar la imagen."
        }
        if ([string]::IsNullOrWhiteSpace([string]$service.taskDefinition)) {
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

        $image = [string]$backend[0].image
        if ($image -notmatch $imagePattern) {
            throw "La imagen activa no esta fijada al digest esperado de $repositoryName."
        }
        $env:TF_VAR_backend_image_uri = $image
        return
    }
    catch {
        if ($configuredImage -match $imagePattern) {
            $env:TF_VAR_backend_image_uri = $configuredImage
            Write-Host "[Terraform] No existe baseline ECS; se usara BACKEND_IMAGE_URI para el primer despliegue." -ForegroundColor Yellow
            return
        }

        if ($Mode -eq "Apply") {
            throw "No existe una imagen backend reutilizable. Configure BACKEND_IMAGE_URI para el primer despliegue. Detalle: $($_.Exception.Message)"
        }

        # El primer plan de un ambiente corre contra un state vacio: todavia no
        # existe servicio ECS del que heredar la imagen y el ECR puede estar sin
        # publicar. El marcador solo satisface la validacion de digest del root
        # module para que el plan pueda revisarse; apply nunca llega hasta aca.
        $placeholderDigest = "0" * 64
        $placeholderImage = "$(Get-AwsAccountId).dkr.ecr.$env:AWS_REGION.amazonaws.com/$repositoryName@sha256:$placeholderDigest"
        $env:TF_VAR_backend_image_uri = $placeholderImage
        Write-Warning "Sin baseline ECS ni BACKEND_IMAGE_URI valido: el $($Mode.ToLowerInvariant()) usara el marcador $placeholderImage. El apply exigira un digest real. Detalle: $($_.Exception.Message)"
    }
}

# Hasta aqui el ciclo solo comprueba la FORMA de la imagen: que apunte al
# repositorio correcto y este fijada por digest. Nunca comprueba que ese digest
# siga existiendo.
#
# El ciclo de vida de ECR conserva las diez imagenes dev- mas recientes, y diez
# publicaciones caben en una jornada de merges: la que el servicio tiene fijada
# se cae del registro sin que nada avise. Mientras la tarea siga viva no pasa
# nada, porque la imagen ya esta descargada en el host de Fargate. El fallo
# aparece cuando hay que colocar una tarea nueva -es decir, en el siguiente
# encendido- y llega como un CannotPullContainerError dentro de un crash loop, a
# varias capas de distancia de su causa. Paso el 9 de agosto de 2026 y costo una
# noche de diagnostico.
#
# Apply falla: fijar un digest muerto en la task definition deja el servicio sin
# poder arrancar y el ciclo siguiente hereda el mismo digest. Plan y drift solo
# avisan, como el resto de comprobaciones que no mutan. El drift diario corre con
# dev apagado, asi que resuelve el respaldo BACKEND_IMAGE_URI: es justo el sitio
# donde un respaldo podrido se detecta antes de necesitarlo.
function Assert-BackendImageIsPullable {
    $image = $env:TF_VAR_backend_image_uri
    if ([string]::IsNullOrWhiteSpace($image)) {
        return
    }

    $digest = ($image -split "@")[-1]
    $repositoryName = (($image -split "/")[-1] -split "@")[0]

    # El marcador de todo ceros lo pone este mismo script cuando no hay baseline
    # ni respaldo. No es una imagen, y apply nunca llega hasta aca con el.
    if ($digest -eq "sha256:$([string]::new('0', 64))") {
        return
    }

    $describeArguments = @(
        "ecr", "describe-images",
        "--repository-name", $repositoryName,
        "--image-ids", "imageDigest=$digest",
        "--output", "json"
    )
    $describeOutput = & aws @describeArguments 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[Terraform] La imagen del backend sigue en ECR: $digest" -ForegroundColor Green
        return
    }

    # Falla abierto ante cualquier otro error -permisos, throttling, red-. Bloquear
    # un apply por una llamada intermitente a ECR seria peor que el problema que
    # esta comprobacion viene a evitar; solo el "no existe" confirmado detiene.
    $detail = ($describeOutput | Out-String).Trim()
    if ($detail -notmatch "ImageNotFoundException") {
        Write-Warning "No fue posible verificar en ECR el digest de la imagen del backend; el ciclo continua sin comprobarlo. Detalle: $detail"
        return
    }

    # La version mas reciente disponible, para que el mensaje diga que desplegar y
    # no solo que algo esta mal.
    $newestVersion = ""
    $newestOutput = & aws "ecr" "describe-images" "--repository-name" $repositoryName "--query" "sort_by(imageDetails,&imagePushedAt)[-1].imageTags" "--output" "json" 2>$null
    if ($LASTEXITCODE -eq 0) {
        try {
            $tags = @(($newestOutput -join [Environment]::NewLine) | ConvertFrom-Json)
            # Se prefiere la etiqueta de version sobre la dev-<sha>, porque es la
            # que reciben como input los workflows de despliegue.
            $newestVersion = @($tags | Where-Object { $_ -notlike "dev-*" }) | Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($newestVersion)) {
                $newestVersion = @($tags) | Select-Object -First 1
            }
        }
        catch {
            $newestVersion = ""
        }
    }

    $advice = if ([string]::IsNullOrWhiteSpace($newestVersion)) {
        "Publique una imagen y despliegela con 'Deploy backend image $Environment' antes de volver a lanzar el ciclo."
    }
    else {
        "Despliegue una imagen viva con 'Deploy backend image $Environment' usando la version $newestVersion, y vuelva a lanzar el ciclo."
    }

    $message = "La imagen del backend ya no existe en ECR: $image. La expiro el ciclo de vida del registro."
    $summaryPath = $env:GITHUB_STEP_SUMMARY

    if ($Mode -eq "Apply") {
        if (-not [string]::IsNullOrWhiteSpace($summaryPath)) {
            Add-Content -LiteralPath $summaryPath -Encoding utf8 -Value @(
                "",
                "### Imagen del backend inexistente",
                "",
                "``$image`` ya no esta en ECR.",
                "",
                "El apply se detuvo antes de fijarla en la task definition: hacerlo dejaria el servicio sin poder arrancar.",
                "",
                $advice
            )
        }

        throw "$message Aplicar ahora la volveria a fijar en la task definition y el servicio no podria arrancar. $advice"
    }

    Write-Warning "$message El $($Mode.ToLowerInvariant()) continua, pero un encendido con esta imagen fallaria. $advice"
    if (-not [string]::IsNullOrWhiteSpace($summaryPath)) {
        Add-Content -LiteralPath $summaryPath -Encoding utf8 -Value @(
            "",
            "### Imagen del backend inexistente",
            "",
            "``$image`` ya no esta en ECR: la expiro el ciclo de vida del registro.",
            "",
            "Este $($Mode.ToLowerInvariant()) no falla, pero el proximo encendido si: la tarea no podria bajar la imagen.",
            "",
            $advice
        )
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

# Un apply cortado a mitad de CreateService deja el servicio vivo en ECS y fuera del
# state: el ciclo siguiente lo replanea como create y ECS responde
# "Creation of service was not idempotent". Es el unico recurso del stack con una
# ventana de cancelacion apreciable, porque wait_for_steady_state mantiene el create
# abierto varios minutos; el resto se crea en menos de un segundo o usa name_prefix.
# Adoptarlo con import no destruye nada y ademas devuelve el output ecs_service_name
# del que depende Set-CurrentBackendImage para conservar la imagen desplegada.
function Restore-OrphanedEcsService {
    param([Parameter()][string]$VariableFile)

    # El modulo ecs_backend fija el nombre del servicio; no viaja por variable.
    $serviceAddress = "module.backend.aws_ecs_service.backend"
    $serviceName = "backend"

    $stateEntries = & terraform "-chdir=$environmentDirectory" state list 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "No fue posible listar el state para buscar un servicio ECS huerfano; el ciclo continua sin reconciliar."
        return $false
    }
    if (@($stateEntries) -contains $serviceAddress) {
        return $false
    }

    # El output del cluster no depende del servicio, asi que sigue disponible justo
    # en el escenario que hay que detectar. Si falla, el ambiente todavia no tiene
    # cluster y por lo tanto no puede haber un servicio huerfano.
    $clusterName = & terraform "-chdir=$environmentDirectory" output -raw ecs_cluster_name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($clusterName)) {
        return $false
    }

    # No usa Get-ExternalJson porque un cluster inexistente sale con codigo distinto
    # de cero y eso no es un error del ciclo: significa que no hay huerfano posible.
    $describeArguments = @(
        "ecs", "describe-services",
        "--cluster", [string]$clusterName,
        "--services", $serviceName,
        "--output", "json"
    )
    $describeOutput = & aws @describeArguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "No fue posible consultar el servicio $serviceName del cluster $clusterName; el ciclo continua sin reconciliar."
        return $false
    }

    $described = ($describeOutput -join [Environment]::NewLine) | ConvertFrom-Json
    $service = if ($described.PSObject.Properties.Name -contains "services") {
        @($described.services) | Select-Object -First 1
    }
    else {
        $null
    }
    if ($null -eq $service) {
        return $false
    }

    # Un servicio borrado sigue visible como INACTIVE y no estorba: ECS permite
    # reusar el nombre. DRAINING si estorba, y no hay nada que importar.
    $status = [string]$service.status
    if ($status -eq "DRAINING") {
        Write-Warning "El servicio $serviceName de $clusterName sigue DRAINING: ECS rechazara el create hasta que quede INACTIVE. Reintente el ciclo en unos minutos."
        return $false
    }
    if ($status -ne "ACTIVE") {
        return $false
    }

    $summaryPath = $env:GITHUB_STEP_SUMMARY
    if ($Mode -ne "Apply") {
        # Plan y drift jamas mutan el state: solo avisan para que el huerfano se vea
        # antes de aprobar el apply, que es quien lo adopta.
        Write-Warning "El servicio ECS $serviceName existe ACTIVE en $clusterName pero no esta en el state: quedo huerfano de un apply cancelado. Este plan lo muestra como create; el apply lo adoptara con terraform import."
        if (-not [string]::IsNullOrWhiteSpace($summaryPath)) {
            Add-Content -LiteralPath $summaryPath -Encoding utf8 -Value @(
                "",
                "### Servicio ECS huerfano",
                "",
                "``$clusterName/$serviceName`` existe **ACTIVE** en AWS pero no esta en el state, seguramente por un apply cancelado.",
                "",
                "Este plan lo muestra como *create* y ECS lo rechazaria con ``Creation of service was not idempotent``.",
                "El apply lo adopta con ``terraform import`` antes de planear, asi que el plan definitivo sera un *update*."
            )
        }

        return $false
    }

    Write-Host "[Terraform] Adoptando el servicio ECS huerfano $clusterName/$serviceName al state..." -ForegroundColor Yellow
    $importArguments = @(
        "-chdir=$environmentDirectory",
        "import",
        "-input=false",
        "-lock-timeout=5m",
        "-no-color"
    )
    if (-not [string]::IsNullOrWhiteSpace($VariableFile)) {
        $importArguments += "-var-file=$VariableFile"
    }
    $importArguments += @($serviceAddress, "$clusterName/$serviceName")

    # El pipe a Write-Host evita que la salida de terraform contamine el valor de
    # retorno de la funcion, que es el booleano que consulta el cuerpo del script.
    Invoke-ExternalCommand -Command "terraform" -Arguments $importArguments |
        ForEach-Object { Write-Host $_ }

    if (-not [string]::IsNullOrWhiteSpace($summaryPath)) {
        Add-Content -LiteralPath $summaryPath -Encoding utf8 -Value @(
            "",
            "### Servicio ECS huerfano adoptado",
            "",
            "``$clusterName/$serviceName`` existia **ACTIVE** en AWS pero no en el state, seguramente por un apply cancelado.",
            "",
            "Se importo a ``$serviceAddress`` antes de generar el plan, de modo que el apply lo actualiza en lugar de recrearlo."
        )
    }

    return $true
}

# RDS crea /aws/rds/instance/<id>/<log> por su cuenta la primera vez que exporta,
# con retencion infinita y la clave gestionada por AWS. Al pasar esos grupos a
# Terraform el plan los ve como create y CloudWatch responde
# ResourceAlreadyExistsException, de modo que el apply no avanza hasta adoptarlos.
# Importar no toca los eventos ya almacenados: el apply siguiente solo les fija
# caducidad y CMK.
function Restore-UnmanagedRdsLogGroups {
    param([Parameter()][string]$VariableFile)

    # Mismo allowlist que modules/database/variables.tf. Cualquier otro grupo bajo
    # el prefijo -"general" entre ellos- no lo declara el modulo, asi que no hay
    # direccion a la que importarlo y no es este paso quien debe borrarlo.
    $managedExports = @("error", "slowquery", "audit")
    $instanceName = "$projectName-$Environment-mysql"
    $prefix = "/aws/rds/instance/$instanceName/"

    $stateEntries = & terraform "-chdir=$environmentDirectory" state list 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "No fue posible listar el state para buscar log groups de RDS sin gestionar; el ciclo continua sin reconciliar."
        return $false
    }
    $stateEntries = @($stateEntries)

    # Un ambiente recien creado no tiene ningun grupo y la llamada devuelve vacio:
    # no hay nada que adoptar y el create normal es el camino correcto.
    $describeArguments = @(
        "logs", "describe-log-groups",
        "--log-group-name-prefix", $prefix,
        "--query", "logGroups[].logGroupName",
        "--output", "json"
    )
    $describeOutput = & aws @describeArguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "No fue posible listar los log groups de $instanceName; el ciclo continua sin reconciliar."
        return $false
    }

    $existing = @(($describeOutput -join [Environment]::NewLine) | ConvertFrom-Json)
    $pending = @()
    foreach ($logGroupName in $existing) {
        $export = ([string]$logGroupName -split "/")[-1]
        if ($managedExports -notcontains $export) {
            continue
        }

        $address = "module.database.aws_cloudwatch_log_group.database[`"$export`"]"
        if ($stateEntries -contains $address) {
            continue
        }

        $pending += [PSCustomObject]@{ Address = $address; Name = [string]$logGroupName }
    }

    if ($pending.Count -eq 0) {
        return $false
    }

    $names = ($pending | ForEach-Object { $_.Name }) -join ", "
    $summaryPath = $env:GITHUB_STEP_SUMMARY
    if ($Mode -ne "Apply") {
        # Plan y drift jamas mutan el state: solo avisan para que la adopcion se vea
        # antes de aprobar el apply, que es quien la ejecuta.
        Write-Warning "Los log groups $names existen en CloudWatch pero no en el state: los creo RDS. Este plan los muestra como create; el apply los adoptara con terraform import."
        if (-not [string]::IsNullOrWhiteSpace($summaryPath)) {
            Add-Content -LiteralPath $summaryPath -Encoding utf8 -Value @(
                "",
                "### Log groups de RDS sin gestionar",
                "",
                "``$names`` existen en CloudWatch pero no en el state: los creo RDS con retencion infinita y la clave de AWS.",
                "",
                "Este plan los muestra como *create* y CloudWatch lo rechazaria con ``ResourceAlreadyExistsException``.",
                "El apply los adopta con ``terraform import`` antes de planear, asi que el plan definitivo sera un *update* que les fija caducidad y CMK."
            )
        }

        return $false
    }

    foreach ($group in $pending) {
        Write-Host "[Terraform] Adoptando el log group $($group.Name) al state..." -ForegroundColor Yellow
        $importArguments = @(
            "-chdir=$environmentDirectory",
            "import",
            "-input=false",
            "-lock-timeout=5m",
            "-no-color"
        )
        if (-not [string]::IsNullOrWhiteSpace($VariableFile)) {
            $importArguments += "-var-file=$VariableFile"
        }
        $importArguments += @($group.Address, $group.Name)

        # El pipe a Write-Host evita que la salida de terraform contamine el valor de
        # retorno de la funcion, que es el booleano que consulta el cuerpo del script.
        Invoke-ExternalCommand -Command "terraform" -Arguments $importArguments |
            ForEach-Object { Write-Host $_ }
    }

    if (-not [string]::IsNullOrWhiteSpace($summaryPath)) {
        Add-Content -LiteralPath $summaryPath -Encoding utf8 -Value @(
            "",
            "### Log groups de RDS adoptados",
            "",
            "``$names`` existian en CloudWatch fuera del state porque los creo RDS.",
            "",
            "Se importaron antes de generar el plan, de modo que el apply les fija retencion y CMK en lugar de intentar recrearlos."
        )
    }

    return $true
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

# Un apply cancelado deja el .tflock en S3 y todo ciclo posterior muere tras agotar
# el -lock-timeout. Liberarlo exige el ID exacto: force-unlock lo compara contra el
# lock vivo, de modo que un ID viejo no puede pisar una ejecucion en curso.
if ($Mode -eq "Unlock") {
    Assert-RequiredEnvironmentVariable -Name "AWS_REGION"
    if ($LockId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "El modo Unlock exige -LockId con el UUID que aparece en el error 'Error acquiring the state lock'."
    }

    Resolve-StateBackend
    Initialize-Terraform

    Write-Host "[Terraform] Liberando el lock $LockId del state de $Environment..." -ForegroundColor Yellow
    Invoke-ExternalCommand -Command "terraform" -Arguments @(
        "-chdir=$environmentDirectory", "force-unlock", "-force", $LockId
    )

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Value @(
            "### Unlock",
            "",
            "Lock ``$LockId`` liberado en el state de **$Environment**.",
            "",
            "El apply cancelado pudo dejar recursos creados fuera del state. El servicio ECS se adopta solo al inicio del proximo apply; el resto exige revisar el plan antes de aplicar."
        )
    }

    exit 0
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
    $env:TF_VAR_grafana_secrets_json = '{"OTLP_USERNAME":"not-used","OTLP_API_KEY":"not-used","OTEL_EXPORTER_OTLP_HEADERS":"Authorization=Basic bm90LXVzZWQ6bm90LXVzZWQ="}'
}

Resolve-StateBackend
Initialize-Terraform
# Va antes del import porque terraform evalua la configuracion completa al importar
# y el root module exige un backend_image_uri fijado a un digest valido.
Set-CurrentBackendImage
$variableFile = New-OptionalVariableFile

if (Restore-OrphanedEcsService -VariableFile $variableFile) {
    # Con el servicio de vuelta en el state vuelve a existir ecs_service_name, asi
    # que releer la imagen activa evita que el apply revierta el despliegue al
    # BACKEND_IMAGE_URI que se uso como respaldo mientras el servicio faltaba.
    Set-CurrentBackendImage
}

# Va despues de la adopcion porque esta puede cambiar la imagen resuelta: lo que
# se comprueba tiene que ser el valor definitivo, el que acabara en el plan.
Assert-BackendImageIsPullable

# No depende del bloque anterior: son dos reconciliaciones independientes que solo
# comparten el momento, antes de planear.
Restore-UnmanagedRdsLogGroups -VariableFile $variableFile | Out-Null

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

# Un plan con cambios devuelve 2 por -detailed-exitcode. Sin este cierre
# explicito el step hereda ese 2 y GitHub marca el job como fallido pese a que
# el plan es correcto; los casos de error real ya salieron por throw.
exit 0
