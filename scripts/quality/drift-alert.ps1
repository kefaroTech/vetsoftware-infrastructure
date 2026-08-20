<#
.SYNOPSIS
    Avisa de que el vigilante de deriva se puso en rojo.

.DESCRIPTION
    Hasta ahora el drift no notificaba a ningun sitio: su unica senal era un job
    en rojo en la pestana Actions. Entre el 7 y el 16 de agosto de 2026 encadeno
    diez ciclos fallidos sin que nadie lo mirara, y dentro de esos fallos habia
    un hallazgo real -la suscripcion de correo de las alarmas borrada en AWS-.

    Este script convierte ese rojo en algo que llega a una persona:

    1. Abre -o actualiza- un issue en el propio repositorio. Es el canal
       principal porque solo necesita el GITHUB_TOKEN del run: no depende de
       ningun secreto que pueda no estar en el environment del job.
    2. Si recibe una URL de webhook de Slack, publica ademas alli. Es opcional a
       proposito: VETSOFTWARE_GRAFANA_SLACK_WEBHOOK_URL vive hoy en el
       environment iac-apply-dev y el drift corre con iac-plan-dev, que no tiene
       secretos, asi que la expresion del workflow entrega cadena vacia. El dia
       que el secreto se copie al environment de plan, este canal se enciende
       solo.

    Es idempotente: mantiene UN issue abierto por ambiente y comenta en el en
    lugar de abrir uno nuevo cada ciclo. Y si ya comento por el mismo hallazgo
    -misma huella- dentro de la ventana de silencio, no vuelve a comentar: un
    vigilante que habla todos los dias de lo mismo se vuelve ruido otra vez.
    Cualquier objeto nuevo cambia la huella y rompe ese silencio.

.PARAMETER Environment
    Ambiente cuyo vigilante fallo.

.PARAMETER Status
    Veredicto de drift-triage.ps1. Vacio significa que el job murio antes de
    llegar al triage, que tambien hay que avisarlo.

.PARAMETER ReportPath
    Informe markdown de drift-triage.ps1, si llego a generarse.

.PARAMETER Repository
    owner/name del repositorio donde abrir el issue.

.PARAMETER RunUrl
    URL del run que fallo.

.PARAMETER Token
    Token con permiso issues:write.

.PARAMETER SlackWebhookUrl
    Webhook opcional. Vacio desactiva el canal sin fallar.

.PARAMETER Fingerprint
    Huella de lo no clasificado que emite drift-triage.ps1. Distingue "sigue lo
    mismo" de "hay algo nuevo".

.PARAMETER QuietHours
    Horas durante las cuales no se repite un aviso con la misma huella.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    [Parameter()]
    [AllowEmptyString()]
    [string]$Status = "",

    [Parameter()]
    [AllowEmptyString()]
    [string]$ReportPath = "",

    [Parameter(Mandatory)]
    [string]$Repository,

    [Parameter(Mandatory)]
    [string]$RunUrl,

    [Parameter(Mandatory)]
    [string]$Token,

    [Parameter()]
    [AllowEmptyString()]
    [string]$SlackWebhookUrl = "",

    [Parameter()]
    [AllowEmptyString()]
    [string]$Fingerprint = "",

    [Parameter()]
    [int]$QuietHours = 72
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Repository no tiene formato owner/name."
}

$marker = "<!-- terraform-drift-alert:$Environment -->"
$title = "El vigilante de deriva de $Environment esta en rojo"
$effectiveStatus = if ([string]::IsNullOrWhiteSpace($Status)) { "cycle-failed" } else { $Status }

$detail = if (-not [string]::IsNullOrWhiteSpace($ReportPath) -and (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    (Get-Content -Raw -LiteralPath $ReportPath).Trim()
}
else {
    "El triage no dejo informe: el ciclo fallo antes de clasificar nada. Revise el log del run."
}

$effectiveFingerprint = if ([string]::IsNullOrWhiteSpace($Fingerprint)) { "sin-huella" } else { $Fingerprint }
$fingerprintLine = "**Huella:** ``$effectiveFingerprint``"

$body = @(
    $marker,
    "**Veredicto:** ``$effectiveStatus`` · **Ambiente:** ``$Environment``",
    $fingerprintLine,
    "",
    "Run: $RunUrl",
    "",
    $detail,
    "",
    "---",
    "",
    "Que hacer con esto:",
    "",
    "- ``unexpected-drift``: alguien cambio algo en AWS por fuera de Terraform, o un recurso",
    "  desaparecio. Se decide si se revierte con un apply o si el cambio se incorpora al codigo.",
    "  Nunca se aplica sin leer el plan.",
    "- ``unparsed-drift``: Terraform reporto deriva y el clasificador no supo leerla. Es un",
    "  defecto del propio triage (``scripts/quality/drift-triage.ps1``), no de la infraestructura.",
    "- ``cycle-failed``: el vigilante dejo de vigilar. Credenciales, lock del state remoto o una",
    "  variable sin valor. Mientras dure, nadie esta mirando la deriva de este ambiente.",
    "",
    "La deriva conocida y silenciada esta declarada en la tabla de ``scripts/quality/drift-triage.ps1``.",
    "Si lo que aparece arriba deberia estar en esa tabla, se anade alli con su motivo; no se apaga",
    "el vigilante entero.",
    "",
    "Aviso generado automaticamente por el workflow de deriva.",
    "",
    "🤖 Generated with [Claude Code](https://claude.com/claude-code)"
) -join "`n"

$headers = @{
    Accept                 = "application/vnd.github+json"
    Authorization          = "Bearer $Token"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "VetSoftwareIaC-Drift-Alert"
}

function Test-HasProperty {
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) { return $false }
    return ($InputObject.PSObject.Properties.Name -contains $Name)
}

$issueReported = $false
try {
    # Se listan los issues abiertos en vez de usar la API de busqueda: el indice
    # de busqueda tarda en refrescarse y un vigilante que corre a diario abriria
    # duplicados mientras tanto.
    $issuesUri = "https://api.github.com/repos/$Repository/issues?state=open&per_page=100"
    $response = Invoke-RestMethod -Method Get -Uri $issuesUri -Headers $headers
    $openIssues = @($response | Where-Object { $null -ne $_ -and -not (Test-HasProperty -InputObject $_ -Name "pull_request") })
    $existing = $openIssues | Where-Object {
        (Test-HasProperty -InputObject $_ -Name "body") -and
        -not [string]::IsNullOrWhiteSpace([string]$_.body) -and
        ([string]$_.body).Contains($marker)
    } | Select-Object -First 1

    if ($null -eq $existing) {
        $payload = @{ title = $title; body = $body } | ConvertTo-Json -Depth 4
        $created = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$Repository/issues" `
            -Headers $headers -ContentType "application/json" -Body $payload
        Write-Host "[Alerta] Issue abierto: $($created.html_url)"
        $issueReported = $true
    }
    else {
        $number = [int]$existing.number
        $commentsUri = "https://api.github.com/repos/$Repository/issues/$number/comments?per_page=100"
        $commentResponse = Invoke-RestMethod -Method Get -Uri $commentsUri -Headers $headers
        $ourComments = @($commentResponse | Where-Object {
                $null -ne $_ -and
                (Test-HasProperty -InputObject $_ -Name "body") -and
                ([string]$_.body).Contains($marker)
            })
        $latest = $ourComments | Sort-Object { [DateTime]$_.created_at } | Select-Object -Last 1

        # Se compara la HUELLA, no el veredicto: dos derivas distintas comparten
        # el veredicto 'unexpected-drift', y callar la segunda porque la primera
        # es reciente seria justo el fallo que este aviso viene a corregir. Si
        # aparece un objeto nuevo, la huella cambia y el aviso sale igual.
        $recentAndIdentical = $false
        if ($null -ne $latest) {
            $age = (Get-Date).ToUniversalTime() - ([DateTime]$latest.created_at).ToUniversalTime()
            $sameFinding = ([string]$latest.body).Contains($fingerprintLine)
            $recentAndIdentical = ($age.TotalHours -lt $QuietHours) -and $sameFinding
        }

        if ($recentAndIdentical) {
            Write-Host "[Alerta] El issue #$number ya tiene un aviso con la huella $effectiveFingerprint de hace menos de $QuietHours h: no se repite."
            $issueReported = $true
        }
        else {
            $payload = @{ body = $body } | ConvertTo-Json -Depth 4
            Invoke-RestMethod -Method Post -Uri $commentsUri -Headers $headers -ContentType "application/json" -Body $payload | Out-Null
            Write-Host "[Alerta] Comentario anadido al issue #$number."
            $issueReported = $true
        }
    }
}
catch {
    Write-Host "::warning title=No se pudo abrir el issue de deriva::$($_.Exception.Message)"
}

if (-not [string]::IsNullOrWhiteSpace($SlackWebhookUrl)) {
    try {
        $text = ":rotating_light: Deriva en *$Environment* - veredicto ``$effectiveStatus``. Run: $RunUrl"
        $slackPayload = @{ text = $text } | ConvertTo-Json -Depth 3
        Invoke-RestMethod -Method Post -Uri $SlackWebhookUrl -ContentType "application/json" -Body $slackPayload | Out-Null
        Write-Host "[Alerta] Publicado en el webhook de Slack."
    }
    catch {
        Write-Host "::warning title=No se pudo publicar en Slack::$($_.Exception.Message)"
    }
}
else {
    Write-Host "[Alerta] Sin webhook de Slack en este job: el aviso va solo por issue."
}

if (-not $issueReported) {
    # Los dos canales fallaron: el fallo del vigilante se quedaria sin contar.
    Write-Host "::error title=Aviso de deriva no entregado::Ni el issue ni el webhook pudieron notificar la deriva de $Environment."
}

exit 0
