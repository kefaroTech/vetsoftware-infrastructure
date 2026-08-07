[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet("dev", "prod")]
    [string]$Environment = "dev",

    # Fecha de referencia en UTC, formato yyyy-MM-dd. El informe cubre el dia
    # anterior a esta fecha. Vacio significa hoy, que es como corre por horario;
    # darle un valor sirve para reenviar a mano un dia que no salio.
    [Parameter()]
    [string]$AsOf = ""
)

# Cuenta en Slack cuanto costo el dia anterior, y los lunes tambien la semana que
# termino. Sale por el mismo topic que ya escucha Amazon Q, el de los avisos de
# despliegue y de encendido.
#
# Solo lee: corre con el rol de plan, no con el de apply. Un cron sin supervision
# no tiene por que poder aplicar infraestructura.
#
# La cifra es de la cuenta AWS completa, no de un ambiente: Cost Explorer factura
# por cuenta. Mientras dev y prod compartan cuenta, el total incluye a los dos, y
# por eso el mensaje nombra la cuenta que consulto en lugar del ambiente.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$projectName = "vetsoftware"
$topicName = "$projectName-$Environment-alarms"
# Cost Explorer atiende en un solo endpoint, us-east-1, sin importar donde vivan
# los recursos. Se fija aca para que el informe no dependa de la region del runner.
$costExplorerRegion = "us-east-1"
# Cada pagina es un request facturado a USD 0.01. Con una cuenta y siete dias
# agrupados por servicio nunca deberia pasar de una, pero el tope evita que un
# token que no avanza se convierta en una factura.
$maxPages = 5
$topServices = 5
$invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Write-WorkflowSummary {
    # Mandatory valida "no vacio" elemento por elemento, y el resumen usa lineas en
    # blanco como separadores de markdown.
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Lines -Encoding utf8
    }
}

function Format-Money {
    param([Parameter(Mandatory)][decimal]$Amount)

    return "USD " + $Amount.ToString("N2", $invariant)
}

# El nombre del topic lo fija el modulo de monitoreo: <proyecto>-<ambiente>-alarms.
# Aca no hay terraform del que leer el ARN, asi que se arma con esa convencion y se
# confirma que exista antes de intentar publicar.
function Get-NotificationTopicArn {
    param([Parameter(Mandatory)][string]$AccountId)

    $region = @($env:AWS_REGION, $env:AWS_DEFAULT_REGION) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($region)) {
        $region = (& aws configure get region)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($region)) {
            return ""
        }
    }

    $arn = "arn:aws:sns:$(([string]$region).Trim()):${AccountId}:$topicName"
    & aws sns get-topic-attributes --topic-arn $arn --query "Attributes.TopicArn" --output text 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    return $arn
}

function Get-AccountId {
    $accountId = (& aws sts get-caller-identity --query "Account" --output text)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountId)) {
        throw "No fue posible identificar la cuenta AWS."
    }

    return ([string]$accountId).Trim()
}

# Devuelve los tramos diarios que Cost Explorer entrega para la ventana pedida.
# Start es inclusivo y End exclusivo, como en la API.
function Get-CostByService {
    param(
        [Parameter(Mandatory)][string]$Start,
        [Parameter(Mandatory)][string]$End
    )

    $results = @()
    $nextToken = ""
    for ($page = 1; $page -le $maxPages; $page++) {
        $arguments = @(
            "ce", "get-cost-and-usage",
            "--region", $costExplorerRegion,
            "--time-period", "Start=$Start,End=$End",
            "--granularity", "DAILY",
            "--metrics", "UnblendedCost",
            "--group-by", "Type=DIMENSION,Key=SERVICE",
            "--output", "json"
        )
        if (-not [string]::IsNullOrWhiteSpace($nextToken)) {
            $arguments += @("--next-page-token", $nextToken)
        }

        # La salida se une antes de convertirla: la CLI la entrega en varias lineas
        # y ConvertFrom-Json solo acepta un arreglo de cadenas desde PowerShell 6.
        $raw = (& aws @arguments) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            throw "aws ce get-cost-and-usage falló con código $LASTEXITCODE."
        }

        $response = ($raw | ConvertFrom-Json)
        if ($null -ne $response.ResultsByTime) {
            $results += $response.ResultsByTime
        }

        $nextToken = [string]$response.NextPageToken
        if ([string]::IsNullOrWhiteSpace($nextToken)) {
            return $results
        }
    }

    throw "Cost Explorer devolvió más de $maxPages páginas; se corta para no seguir facturando requests."
}

# Suma por servicio los tramos recibidos. Los servicios en cero se descartan: una
# cuenta cualquiera reporta decenas y solo alargan el mensaje.
function Get-ServiceTotals {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results)

    $totals = @{}
    foreach ($entry in $Results) {
        foreach ($group in @($entry.Groups)) {
            $amount = [decimal]::Parse([string]$group.Metrics.UnblendedCost.Amount, $invariant)
            if ($amount -le 0) {
                continue
            }

            $service = [string]$group.Keys[0]
            $previous = if ($totals.ContainsKey($service)) { $totals[$service] } else { [decimal]0 }
            $totals[$service] = $previous + $amount
        }
    }

    return $totals
}

# Titula el total y desglosa los servicios que de verdad pesan. El resto se resume
# en una linea: en una cuenta chica la cola son centavos que nadie va a leer.
function Get-BreakdownLines {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][hashtable]$Totals
    )

    $total = [decimal]0
    foreach ($amount in $Totals.Values) {
        $total += $amount
    }

    $lines = @("*$Title* $(Format-Money -Amount $total)")
    if ($Totals.Count -eq 0) {
        return $lines
    }

    $ranked = $Totals.GetEnumerator() | Sort-Object -Property Value -Descending
    foreach ($service in @($ranked | Select-Object -First $topServices)) {
        $lines += "• $($service.Key): $(Format-Money -Amount $service.Value)"
    }

    $rest = @($ranked | Select-Object -Skip $topServices)
    if ($rest.Count -gt 0) {
        $restTotal = [decimal]0
        foreach ($service in $rest) {
            $restTotal += $service.Value
        }
        $lines += "• otros $($rest.Count) servicio(s): $(Format-Money -Amount $restTotal)"
    }

    return $lines
}

# Un aviso nunca se manda a medias: si falla la publicacion, el workflow falla y se
# ve en el log. El formato es el de las "custom notifications" de Amazon Q -version,
# source y content-, lo unico que ese integrador acepta de un emisor propio.
function Send-CostNotification {
    param(
        [Parameter(Mandatory)][string]$TopicArn,
        [Parameter(Mandatory)][string]$Title,
        # Mandatory valida "no vacio" elemento por elemento, y el cuerpo usa lineas
        # en blanco para separar el dia de la semana y de la nota final.
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Description
    )

    $content = [ordered]@{
        textType    = "client-markdown"
        title       = $Title
        description = ($Description -join "`n")
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
    $payloadPath = Join-Path $payloadRoot "cost-report-$Environment.json"
    ($payload | ConvertTo-Json -Depth 5 -Compress) | Set-Content -LiteralPath $payloadPath -Encoding utf8

    & aws sns publish `
        --topic-arn $TopicArn `
        --message "file://$payloadPath" `
        --query "MessageId" --output text | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "aws sns publish falló con código $LASTEXITCODE."
    }
}

$reference = if ([string]::IsNullOrWhiteSpace($AsOf)) {
    [DateTime]::UtcNow.Date
}
else {
    try {
        [DateTime]::ParseExact($AsOf, "yyyy-MM-dd", $invariant)
    }
    catch {
        throw "AsOf debe tener la forma yyyy-MM-dd; se recibió '$AsOf'."
    }
}

$yesterday = $reference.AddDays(-1)
# Corriendo un lunes, los siete dias que terminan ayer son exactamente la semana
# pasada de lunes a domingo. La consulta se pide una sola vez para toda la ventana
# y el dia se recorta de ahi: dos requests separados costarian el doble sin agregar
# nada.
$isWeeklyReport = $reference.DayOfWeek -eq [DayOfWeek]::Monday
$windowStart = if ($isWeeklyReport) { $yesterday.AddDays(-6) } else { $yesterday }

$startLabel = $windowStart.ToString("yyyy-MM-dd", $invariant)
$endLabel = $reference.ToString("yyyy-MM-dd", $invariant)
$yesterdayLabel = $yesterday.ToString("yyyy-MM-dd", $invariant)

Write-Host "== Informe de costos de ${Environment}: $yesterdayLabel ==" -ForegroundColor Cyan
Write-Host "Ventana consultada: $startLabel a $endLabel (UTC)." -ForegroundColor Cyan

$accountId = Get-AccountId
$results = Get-CostByService -Start $startLabel -End $endLabel

$yesterdayResults = @($results | Where-Object { $_.TimePeriod.Start -eq $yesterdayLabel })
if ($yesterdayResults.Count -eq 0) {
    # Cost Explorer refresca al menos una vez cada 24 horas y tarda en poblar los
    # dias recien habilitados. Publicar "USD 0.00" cuando lo que pasa es que no hay
    # dato seria mentir, asi que se avisa en el log y se corta sin mensaje.
    Write-Warning "Cost Explorer todavía no tiene datos de $yesterdayLabel; no se envía informe."
    Write-WorkflowSummary -Lines @(
        "## Informe de costos sin enviar",
        "",
        "- Cost Explorer no devolvió datos de ``$yesterdayLabel``.",
        "- Es lo esperado si Cost Explorer se habilitó hace menos de 24 horas."
    )
    return
}

$topicArn = Get-NotificationTopicArn -AccountId $accountId
if ([string]::IsNullOrWhiteSpace($topicArn)) {
    throw "No se encontró el topic '$topicName' en la cuenta $accountId; sin canal no hay informe que enviar."
}

$dailyTotals = Get-ServiceTotals -Results $yesterdayResults
$description = Get-BreakdownLines -Title "Gasto del ${yesterdayLabel}:" -Totals $dailyTotals

$dailyTotal = [decimal]0
foreach ($amount in $dailyTotals.Values) {
    $dailyTotal += $amount
}

$title = ":money_with_wings: Costo del $yesterdayLabel - $(Format-Money -Amount $dailyTotal)"
if ($isWeeklyReport) {
    $weeklyTotals = Get-ServiceTotals -Results $results
    $description += ""
    $description += Get-BreakdownLines -Title "Semana pasada ($startLabel a ${yesterdayLabel}):" -Totals $weeklyTotals
    $title = ":money_with_wings: Costo del $yesterdayLabel y de la semana pasada"
}

$description += ""
$description += "_Cuenta $accountId, costo sin combinar, fechas en UTC. Los cargos del periodo en curso son estimados._"

Send-CostNotification -TopicArn $topicArn -Title $title -Description $description

Write-Host "Informe publicado: $(Format-Money -Amount $dailyTotal) el $yesterdayLabel." -ForegroundColor Green
Write-WorkflowSummary -Lines @(
    "## Informe de costos publicado",
    "",
    "- Día: ``$yesterdayLabel`` con $(Format-Money -Amount $dailyTotal)",
    "- Ventana consultada: ``$startLabel`` a ``$endLabel`` (UTC)",
    "- Semana pasada incluida: $(if ($isWeeklyReport) { 'sí' } else { 'no' })"
)
