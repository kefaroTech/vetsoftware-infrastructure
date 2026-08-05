[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Start", "Stop")]
    [string]$Mode
)

# Enciende y apaga a mano el ambiente de desarrollo, lo mismo que hace el apagado
# programado pero cuando uno quiere. Toca los dos unicos recursos que se pueden
# detener: la instancia RDS y el numero de tareas del servicio ECS. Valkey es
# serverless y la red no cuesta por estar encendida, asi que no entran.
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
# El mismo valor que usa el arranque programado.
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

function Get-ServiceDesiredCount {
    $desired = (& aws ecs describe-services `
            --cluster $clusterName --services $serviceName `
            --query "services[0].desiredCount" --output text)
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible leer el desired count del servicio."
    }

    return [int]$desired
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

Write-Host "== $Mode del ambiente $environment ==" -ForegroundColor Cyan
$databaseStatus = Assert-EnvironmentResources
$previousDesiredCount = Get-ServiceDesiredCount
Write-Host "Estado inicial: base '$databaseStatus', servicio en $previousDesiredCount tarea(s)." -ForegroundColor Cyan

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

    if ($previousDesiredCount -lt $runningDesiredCount) {
        Set-ServiceDesiredCount -DesiredCount $runningDesiredCount
    }
    else {
        Write-Host "[ECS] El servicio ya tenía $previousDesiredCount tarea(s)." -ForegroundColor Green
    }

    Write-Host "Ambiente $environment encendido." -ForegroundColor Green
    Write-WorkflowSummary -Lines @(
        "## Ambiente $environment encendido",
        "",
        "- Base: ``$databaseIdentifier`` disponible",
        "- Servicio: ``$serviceName`` en $runningDesiredCount tarea(s)",
        "- El apagado programado lo detendrá igual a las 20:00 y 20:15."
    )
}
else {
    # Al reves que el arranque: primero las tareas, para no dejar la aplicacion
    # golpeando una base que se esta deteniendo.
    if ($previousDesiredCount -gt 0) {
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
        "- El arranque programado lo encenderá igual a las 07:30 y 08:00."
    )
}
