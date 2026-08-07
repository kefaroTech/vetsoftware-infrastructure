[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Start", "Stop")]
    [string]$Mode
)

# Enciende y apaga el ambiente de desarrollo. El encendido solo ocurre por aca:
# nada lo levanta por hora, asi que el ambiente arranca cuando alguien corre este
# script. El apagado sigue ademas programado, y este script lo adelanta. Toca los
# dos unicos recursos que se pueden detener: la instancia RDS y el numero de tareas
# del servicio ECS. Valkey es serverless y la red no cuesta por estar encendida,
# asi que no entran.
#
# Solo dev, y a proposito: prod no tiene apagado programado y un boton para
# detenerla seria una herramienta esperando un accidente.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$projectName = "vetsoftware"
$environment = "dev"
$clusterName = "$projectName-$environment-backend"
$serviceName = "backend"
$databaseIdentifier = "$projectName-$environment-mysql"
# El maximo que admite el escalado de dev: una sola tarea.
$runningDesiredCount = 1

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command falló con código $LASTEXITCODE."
    }
}

function Write-WorkflowSummary {
    # Mandatory valida "no vacio" elemento por elemento, y el resumen usa lineas en
    # blanco como separadores de markdown.
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Lines -Encoding utf8
    }
}

# Los nombres siguen la convencion <proyecto>-<ambiente>, igual que el resto del
# repositorio. Si alguno dejara de existir conviene enterarse antes de tocar nada,
# y con el nombre buscado a la vista.
function Assert-EnvironmentResources {
    $status = (& aws rds describe-db-instances `
            --db-instance-identifier $databaseIdentifier `
            --query "DBInstances[0].DBInstanceStatus" --output text)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($status)) {
        throw "No se encontró la instancia RDS '$databaseIdentifier'."
    }

    $service = (& aws ecs describe-services `
            --cluster $clusterName --services $serviceName `
            --query "services[0].status" --output text)
    if ($LASTEXITCODE -ne 0 -or $service -ne "ACTIVE") {
        throw "No se encontró un servicio ECS activo '$serviceName' en el cluster '$clusterName'."
    }

    return ([string]$status).Trim()
}

# El desired count solo dice lo que el servicio pretende. Un deployment que el
# circuit breaker marco fallido -y que no encontro revision estable a la que
# volver- deja el servicio pidiendo tareas y sin levantar ninguna, sin reintentar
# nunca mas. Por eso hace falta mirar tambien cuantas corren de verdad.
function Get-ServiceCounts {
    $raw = (& aws ecs describe-services `
            --cluster $clusterName --services $serviceName `
            --query "services[0].[desiredCount,runningCount]" --output text)
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible leer el estado del servicio."
    }

    $parts = ([string]$raw).Trim() -split "\s+"
    if ($parts.Count -lt 2) {
        throw "Respuesta inesperada al leer el estado del servicio: '$raw'."
    }

    return [PSCustomObject]@{
        Desired = [int]$parts[0]
        Running = [int]$parts[1]
    }
}

# Vuelve a poner en marcha un servicio atascado tras un deployment fallido: ECS
# arranca un deployment nuevo con la task definition vigente.
function Start-NewDeployment {
    Write-Host "[ECS] El servicio pide tareas pero no tiene ninguna corriendo; se fuerza un deployment nuevo..." -ForegroundColor Cyan
    & aws ecs update-service `
        --cluster $clusterName `
        --service $serviceName `
        --force-new-deployment `
        --query "service.desiredCount" --output text | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible forzar un deployment nuevo."
    }

    Invoke-ExternalCommand -Command "aws" -Arguments @(
        "ecs", "wait", "services-stable",
        "--cluster", $clusterName,
        "--services", $serviceName
    )
}

function Set-ServiceDesiredCount {
    param([Parameter(Mandatory)][int]$DesiredCount)

    Write-Host "[ECS] Ajustando $serviceName a $DesiredCount tarea(s)..." -ForegroundColor Cyan
    & aws ecs update-service `
        --cluster $clusterName `
        --service $serviceName `
        --desired-count $DesiredCount `
        --query "service.desiredCount" --output text | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible ajustar el servicio a $DesiredCount tarea(s)."
    }

    Invoke-ExternalCommand -Command "aws" -Arguments @(
        "ecs", "wait", "services-stable",
        "--cluster", $clusterName,
        "--services", $serviceName
    )
}

function Wait-DatabaseAvailable {
    Write-Host "[RDS] Esperando a que $databaseIdentifier quede disponible..." -ForegroundColor Cyan
    Invoke-ExternalCommand -Command "aws" -Arguments @(
        "rds", "wait", "db-instance-available",
        "--db-instance-identifier", $databaseIdentifier
    )
}

# El aviso sale por el topic de alertas que Amazon Q ya publica en Slack -el mismo
# que usa el aviso de despliegue-: reusar ese canal evita un webhook nuevo y un
# secreto mas que rotar. Aca no hay terraform del que leer el ARN, asi que se arma
# con la convencion que fija el modulo de monitoreo, <proyecto>-<ambiente>-alarms,
# y se confirma que exista antes de intentar publicar.
function Get-NotificationTopicArn {
    $region = @($env:AWS_REGION, $env:AWS_DEFAULT_REGION) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($region)) {
        $region = (& aws configure get region)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($region)) {
            return ""
        }
    }

    $accountId = (& aws sts get-caller-identity --query "Account" --output text)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountId)) {
        return ""
    }

    $arn = "arn:aws:sns:$(([string]$region).Trim()):$(([string]$accountId).Trim()):$projectName-$environment-alarms"
    & aws sns get-topic-attributes --topic-arn $arn --query "Attributes.TopicArn" --output text 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    return $arn
}

# Un aviso nunca puede tumbar un encendido ni un apagado: todo fallo aca es una
# advertencia. El formato es el de las "custom notifications" de Amazon Q -version,
# source y content-, lo unico que ese integrador acepta de un emisor propio.
function Send-EnvironmentNotification {
    param(
        [Parameter(Mandatory)][ValidateSet("Started", "Stopped", "Failed")][string]$Result,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reason
    )

    try {
        $topicArn = Get-NotificationTopicArn
        if ([string]::IsNullOrWhiteSpace($topicArn)) {
            Write-Host "[Slack] Sin topic de alertas configurado; no se envía aviso." -ForegroundColor Cyan
            return
        }

        $title = switch ($Result) {
            "Started" { ":sunrise: Ambiente $environment encendido" }
            "Stopped" { ":new_moon: Ambiente $environment apagado a mano" }
            default {
                $action = if ($Mode -eq "Start") { "encender" } else { "apagar" }
                ":x: No fue posible $action el ambiente $environment"
            }
        }

        $description = @("*Ambiente:* $environment")
        switch ($Result) {
            "Started" {
                $description += "*Base:* ``$databaseIdentifier`` disponible"
                $description += "*Servicio:* ``$serviceName`` en $runningDesiredCount tarea(s)"
                $description += "_El apagado programado lo detendrá igual a las 20:00 y 20:15._"
            }
            "Stopped" {
                $description += "*Servicio:* ``$serviceName`` en 0 tareas"
                $description += "*Base:* ``$databaseIdentifier`` deteniéndose"
                $description += "_No hay arranque programado: para volver a encenderlo, ejecute *Start dev environment*._"
            }
            default {
                # Puede fallar antes de haber leido nada: el aviso vale igual, y lo
                # que se sepa del estado inicial se cuenta solo si se alcanzo a leer.
                if ($null -ne $serviceCounts) {
                    $description += "*Estado inicial:* base ``$databaseStatus``, servicio con $($serviceCounts.Running) de $($serviceCounts.Desired) tarea(s)"
                }
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($Reason)) {
            $description += "*Motivo:* $Reason"
        }
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTOR)) {
            $description += "*Lanzado por:* $env:GITHUB_ACTOR"
        }

        $content = [ordered]@{
            textType    = "client-markdown"
            title       = $title
            description = ($description -join "`n")
        }
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
            $runUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
            $content.nextSteps = @("<$runUrl|Ver la corrida en GitHub Actions>")
        }

        $payload = [ordered]@{
            version = "1.0"
            source  = "custom"
            content = $content
        }

        # El JSON viaja por archivo y no como argumento: pasarlo en linea deja las
        # comillas a merced de como cada shell rearme el comando.
        $payloadRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
        $payloadPath = Join-Path $payloadRoot "dev-environment-$($Mode.ToLowerInvariant())-notification.json"
        ($payload | ConvertTo-Json -Depth 5 -Compress) | Set-Content -LiteralPath $payloadPath -Encoding utf8

        & aws sns publish `
            --topic-arn $topicArn `
            --message "file://$payloadPath" `
            --query "MessageId" --output text | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "aws sns publish falló con código $LASTEXITCODE."
        }

        Write-Host "[Slack] Aviso de $Mode publicado." -ForegroundColor Green
    }
    catch {
        Write-Warning "No fue posible avisar en Slack: $($_.Exception.Message)"
        Write-WorkflowSummary -Lines @("", "- WARNING: the Slack notification could not be published")
    }
}

Write-Host "== $Mode del ambiente $environment ==" -ForegroundColor Cyan

# Lo que se le va a contar a Slack. Arranca en el peor caso: si algo revienta a
# mitad de camino, el aviso que sale es el del fallo y no un exito que no ocurrio.
$databaseStatus = ""
$serviceCounts = $null
$notificationResult = "Failed"
$notificationReason = ""

try {
    $databaseStatus = Assert-EnvironmentResources
    $serviceCounts = Get-ServiceCounts
    Write-Host "Estado inicial: base '$databaseStatus', servicio con $($serviceCounts.Running) de $($serviceCounts.Desired) tarea(s) corriendo." -ForegroundColor Cyan

    if ($Mode -eq "Start") {
        # La base primero: una tarea que arranca sin base muere en Liquibase y el
        # circuit breaker la marca fallida.
        if ($databaseStatus -eq "stopped") {
            Write-Host "[RDS] Arrancando $databaseIdentifier..." -ForegroundColor Cyan
            Invoke-ExternalCommand -Command "aws" -Arguments @(
                "rds", "start-db-instance",
                "--db-instance-identifier", $databaseIdentifier,
                "--query", "DBInstance.DBInstanceStatus", "--output", "text"
            )
            Wait-DatabaseAvailable
        }
        elseif ($databaseStatus -ne "available") {
            Wait-DatabaseAvailable
        }
        else {
            Write-Host "[RDS] La base ya estaba disponible." -ForegroundColor Green
        }

        if ($serviceCounts.Desired -lt $runningDesiredCount) {
            Set-ServiceDesiredCount -DesiredCount $runningDesiredCount
        }
        elseif ($serviceCounts.Running -lt $serviceCounts.Desired) {
            Start-NewDeployment
        }
        else {
            Write-Host "[ECS] El servicio ya tenía $($serviceCounts.Running) tarea(s) corriendo." -ForegroundColor Green
        }

        Write-Host "Ambiente $environment encendido." -ForegroundColor Green
        Write-WorkflowSummary -Lines @(
            "## Ambiente $environment encendido",
            "",
            "- Base: ``$databaseIdentifier`` disponible",
            "- Servicio: ``$serviceName`` en $runningDesiredCount tarea(s)",
            "- El apagado programado lo detendrá igual a las 20:00 y 20:15."
        )
        $notificationResult = "Started"
    }
    else {
        # Al reves que el arranque: primero las tareas, para no dejar la aplicacion
        # golpeando una base que se esta deteniendo.
        if ($serviceCounts.Desired -gt 0) {
            Set-ServiceDesiredCount -DesiredCount 0
        }
        else {
            Write-Host "[ECS] El servicio ya estaba en cero tareas." -ForegroundColor Green
        }

        if ($databaseStatus -eq "available") {
            Write-Host "[RDS] Apagando $databaseIdentifier..." -ForegroundColor Cyan
            Invoke-ExternalCommand -Command "aws" -Arguments @(
                "rds", "stop-db-instance",
                "--db-instance-identifier", $databaseIdentifier,
                "--query", "DBInstance.DBInstanceStatus", "--output", "text"
            )
        }
        elseif ($databaseStatus -eq "stopped") {
            Write-Host "[RDS] La base ya estaba apagada." -ForegroundColor Green
        }
        else {
            # stop-db-instance solo acepta una instancia disponible.
            Write-Host "[RDS] La base está en estado '$databaseStatus'; se espera para poder detenerla." -ForegroundColor Cyan
            Wait-DatabaseAvailable
            Invoke-ExternalCommand -Command "aws" -Arguments @(
                "rds", "stop-db-instance",
                "--db-instance-identifier", $databaseIdentifier,
                "--query", "DBInstance.DBInstanceStatus", "--output", "text"
            )
        }

        Write-Host "Ambiente $environment apagado." -ForegroundColor Green
        Write-WorkflowSummary -Lines @(
            "## Ambiente $environment apagado",
            "",
            "- Servicio: ``$serviceName`` en 0 tareas",
            "- Base: ``$databaseIdentifier`` deteniéndose",
            "- No hay arranque programado: para volver a encenderlo, ejecute ``Start dev environment``."
        )
        $notificationResult = "Stopped"
    }
}
catch {
    $notificationReason = $_.Exception.Message
    throw
}
finally {
    Send-EnvironmentNotification -Result $notificationResult -Reason $notificationReason
}
