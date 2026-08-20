<#
.SYNOPSIS
    Ejecuta el ciclo de deteccion de deriva y clasifica lo que encuentra.

.DESCRIPTION
    terraform-cycle.ps1 -Mode Drift lanza "plan -refresh-only -detailed-exitcode"
    y lanza una excepcion en cuanto el codigo detallado vale 2, sin distinguir
    QUE se movio. En dev eso significa rojo todos los dias por objetos que se
    mueven solos -el apagado programado de EventBridge para el servicio ECS y la
    instancia RDS, y dos atributos que el proveedor de AWS reescribe siempre-, y
    un vigilante que grita siempre es un vigilante al que nadie mira: entre el 7
    y el 12 de agosto de 2026 el drift de dev estuvo en rojo seis ciclos
    seguidos y, escondido entre el ruido, llevaba desde el primero reportando
    que la suscripcion de correo de las alarmas habia desaparecido.

    Este triage separa las dos cosas. La deriva conocida -direccion Y atributo,
    los dos tienen que coincidir- se reporta como aviso y NO tumba el job; todo
    lo demas lo tumba. El criterio es de denegacion por defecto: cualquier
    direccion que no este en la tabla, cualquier atributo no listado de una
    direccion que si lo esta, cualquier objeto borrado y cualquier fallo del
    ciclo que no sea deriva terminan en rojo.

    No se usa "ignore_changes" en los modulos a proposito: eso apagaria tambien
    el apply, que es donde esos atributos SI tienen que reconciliarse. Aqui solo
    se silencia el informe.

.PARAMETER Environment
    Ambiente a inspeccionar. Selecciona ademas que entradas de la tabla aplican.

.PARAMETER CycleScript
    Ruta del ciclo Terraform. Por defecto .github/scripts/terraform-cycle.ps1.

.PARAMETER AnalyzeOnly
    No ejecuta el ciclo: clasifica un log ya capturado. Es lo que permite probar
    el clasificador sin credenciales de AWS ni tocar el state remoto.

.PARAMETER LogPath
    Log a clasificar con -AnalyzeOnly, o destino de la captura sin el.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    [Parameter()]
    [string]$CycleScript,

    [Parameter()]
    [switch]$AnalyzeOnly,

    [Parameter()]
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
if ([string]::IsNullOrWhiteSpace($CycleScript)) {
    $CycleScript = Join-Path $repositoryRoot ".github/scripts/terraform-cycle.ps1"
}

$temporaryDirectory = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [IO.Path]::GetTempPath()
}
else {
    $env:RUNNER_TEMP
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $temporaryDirectory "terraform-drift-$Environment.log"
}
$reportPath = Join-Path $temporaryDirectory "drift-triage-$Environment.md"

# ---------------------------------------------------------------------------
# Deriva conocida. Cada entrada exige coincidencia EXACTA de direccion y de
# atributo: si el mismo recurso se mueve por otro atributo, el job se pone en
# rojo igual. Toda entrada lleva su causa y como se cierra; esta tabla no es un
# cajon de sastre, es una lista con fecha de caducidad.
# ---------------------------------------------------------------------------
$knownDrift = @(
    @{
        Address      = "module.backend.aws_ecs_service.backend"
        Attributes   = @("desired_count")
        Environments = @("dev")
        Reason       = "El apagado programado (modules/scheduled_shutdown, EventBridge 20:00 Bogota L-V) escala el servicio a cero. Vuelve a uno al arrancar el entorno."
        Closes       = "Deja de ser ruido el dia que dev no se apague, o si el drift pasa a correr solo con el entorno arriba."
    },
    @{
        Address      = "module.database.aws_db_instance.this"
        Attributes   = @("status", "latest_restorable_time")
        Environments = @("dev")
        Reason       = "Mismo apagado programado: la instancia queda 'stopped' y AWS avanza latest_restorable_time con cada snapshot automatico. Ninguno de los dos es un cambio de configuracion."
        Closes       = "Igual que el anterior. latest_restorable_time es ademas de solo lectura: nunca puede indicar un cambio hecho a mano."
    },
    @{
        Address      = "module.cost_report.aws_iam_role.scheduler"
        Attributes   = @("inline_policy")
        Environments = @("dev", "prod")
        Reason       = "La politica vive en aws_iam_role_policy.scheduler (modules/cost_report/main.tf:166). El proveedor la relee dentro del atributo obsoleto inline_policy del rol, asi que el refresh la ve aparecer siempre."
        Closes       = "Se cierra cuando el proveedor de AWS retire inline_policy, o marcando ese atributo en el modulo. Requiere tocar modules/, fuera del alcance de este script."
    },
    @{
        Address      = "module.cost_report.aws_lambda_function.this"
        Attributes   = @("layers")
        Environments = @("dev", "prod")
        Reason       = "La funcion no declara capas; el proveedor normaliza el valor ausente a lista vacia en cada lectura."
        Closes       = "Mismo caso que el anterior: es una normalizacion del proveedor, no un cambio en AWS."
    }
)

function Get-DriftBlocks {
    <#
        Extrae los bloques de deriva del texto de un plan -refresh-only.

        Terraform los imprime bajo "Objects have changed outside of Terraform"
        con una cabecera "  # <direccion> has changed | has been deleted" y, con
        dos espacios mas de sangria, los atributos que se movieron. Los
        atributos de primer nivel del recurso quedan a seis espacios; lo que
        aparece a ocho no cambio y lo que aparece a diez o mas es contenido
        anidado. Por eso el filtro es por sangria exacta: sin el, cada clave de
        un jsonencode contaria como atributo movido.
    #>
    # AllowEmptyString: el plan trae lineas en blanco y un parametro obligatorio
    # las rechaza una a una.
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

    $blocks = New-Object System.Collections.Generic.List[hashtable]
    $current = $null

    foreach ($line in $Lines) {
        $text = ($line -replace "`r", "")

        if ($text -match '^\s{2}# (?<address>\S+) has (?<kind>changed|been deleted)\s*$') {
            if ($null -ne $current) { $blocks.Add($current) }
            $current = @{
                Address    = $Matches.address
                Kind       = if ($Matches.kind -eq "changed") { "changed" } else { "deleted" }
                Attributes = New-Object System.Collections.Generic.List[string]
            }
            continue
        }

        if ($null -eq $current) { continue }

        if ($text -match '^\s{4}\}\s*$') {
            $blocks.Add($current)
            $current = $null
            continue
        }

        if ($text -match '^\s{6}[-+~] (?<attribute>[A-Za-z_][A-Za-z0-9_]*)\b') {
            if (-not $current.Attributes.Contains($Matches.attribute)) {
                $current.Attributes.Add($Matches.attribute)
            }
        }
    }

    if ($null -ne $current) { $blocks.Add($current) }
    return $blocks
}

function Test-KnownDrift {
    param([Parameter(Mandatory)][hashtable]$Block)

    # Un objeto borrado nunca es ruido: que algo desaparezca de AWS siempre hay
    # que mirarlo, por muy conocida que sea la direccion.
    if ($Block.Kind -eq "deleted") { return $false }
    if ($Block.Attributes.Count -eq 0) { return $false }

    $entry = $knownDrift | Where-Object {
        $_.Address -eq $Block.Address -and $Environment -in $_.Environments
    } | Select-Object -First 1
    if ($null -eq $entry) { return $false }

    foreach ($attribute in $Block.Attributes) {
        if ($attribute -notin $entry.Attributes) { return $false }
    }
    return $true
}

# ---------------------------------------------------------------------------
# 1. Ejecutar el ciclo y capturar todo lo que imprime.
# ---------------------------------------------------------------------------
$cycleFailed = $false
$cycleError = ""

if ($AnalyzeOnly) {
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        throw "No existe el log a clasificar: $LogPath"
    }
    Write-Host "[Triage] Clasificando un log existente: $LogPath"
}
else {
    if (-not (Test-Path -LiteralPath $CycleScript -PathType Leaf)) {
        throw "No existe el ciclo Terraform: $CycleScript"
    }

    $captured = New-Object System.Collections.Generic.List[string]
    try {
        # *>&1 junta los seis flujos: el ciclo imprime el plan con Write-Host,
        # que sin esta redireccion no pasa por la tuberia y no se podria
        # clasificar nada.
        & $CycleScript -Mode Drift -Environment $Environment *>&1 | ForEach-Object {
            $text = if ($_ -is [System.Management.Automation.InformationRecord]) {
                [string]$_.MessageData
            }
            else {
                [string]$_
            }
            $captured.Add($text)
            Write-Host $text
        }
    }
    catch {
        $cycleFailed = $true
        $cycleError = [string]$_.Exception.Message
        Write-Host $cycleError
    }

    Set-Content -LiteralPath $LogPath -Value $captured -Encoding utf8
}

$logLines = @(Get-Content -LiteralPath $LogPath -Encoding utf8)

# ---------------------------------------------------------------------------
# 2. Clasificar.
# ---------------------------------------------------------------------------
# El @() no es decorativo: una lista vacia se desenrolla a $null al volver de la
# funcion y con Set-StrictMode leer .Count sobre $null aborta el script.
$blocks = @(Get-DriftBlocks -Lines $logLines)
$known = @($blocks | Where-Object { Test-KnownDrift -Block $_ })
$unexpected = @($blocks | Where-Object { -not (Test-KnownDrift -Block $_) })

$driftReported = @($logLines | Where-Object { $_ -match 'Se detecto drift en' }).Count -gt 0

$status = if ($cycleFailed -and -not $driftReported) {
    # El ciclo se cayo por algo que no es deriva: credenciales, lock del state,
    # una variable sin valor. Es justo el caso que el vigilante tiene que
    # delatar, porque significa que dejo de vigilar.
    "cycle-failed"
}
elseif ($unexpected.Count -gt 0) {
    "unexpected-drift"
}
elseif ($driftReported -and $blocks.Count -eq 0) {
    # Terraform dijo que hay deriva y el clasificador no supo leerla. Denegacion
    # por defecto: antes un falso rojo que un verde inventado.
    "unparsed-drift"
}
elseif ($known.Count -gt 0) {
    "known-noise"
}
else {
    "clean"
}

# ---------------------------------------------------------------------------
# 3. Informe.
# ---------------------------------------------------------------------------
$runUrl = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SERVER_URL) -and
    -not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY) -and
    -not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
    "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
}
else {
    "ejecucion local"
}

$headline = switch ($status) {
    "clean" { "Sin deriva en $Environment." }
    "known-noise" { "Deriva conocida en $Environment ($($known.Count) objeto(s)); nada nuevo." }
    "unexpected-drift" { "Deriva NO clasificada en ${Environment}: $($unexpected.Count) objeto(s)." }
    "unparsed-drift" { "Terraform reporto deriva en $Environment y el triage no pudo clasificarla." }
    "cycle-failed" { "El ciclo de deriva de $Environment fallo antes de poder clasificar nada." }
}

# Huella de lo que NO se pudo clasificar. Sirve para que el aviso distinga
# "sigue lo mismo de ayer" de "hay algo nuevo": con la cadencia diaria, repetir
# el mismo mensaje cada dia volveria a convertir al vigilante en ruido, pero
# callarse cuando aparece un objeto distinto seria peor todavia.
$fingerprintSource = @($unexpected | ForEach-Object { "$($_.Address)|$($_.Kind)" } | Sort-Object) -join ";"
if ([string]::IsNullOrWhiteSpace($fingerprintSource)) { $fingerprintSource = $status }
$fingerprint = [BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($fingerprintSource))
).Replace("-", "").Substring(0, 12).ToLowerInvariant()

$report = New-Object System.Collections.Generic.List[string]
$report.Add("<!-- terraform-drift:$Environment -->")
$report.Add("## Deriva - $Environment")
$report.Add("")
$report.Add("- Veredicto: **$status**")
$report.Add("- $headline")
$report.Add("- Huella: ``$fingerprint``")
$report.Add("- Ejecucion: $runUrl")
$report.Add("")

if ($unexpected.Count -gt 0) {
    $report.Add("### Sin clasificar - hay que mirarlo")
    $report.Add("")
    foreach ($block in $unexpected) {
        $detail = if ($block.Kind -eq "deleted") {
            "**borrado en AWS**"
        }
        elseif ($block.Attributes.Count -gt 0) {
            "atributos: ``$($block.Attributes -join '`, `')``"
        }
        else {
            "sin atributos legibles"
        }
        $report.Add("- ``$($block.Address)`` - $detail")
    }
    $report.Add("")
}

if ($known.Count -gt 0) {
    $report.Add("### Conocida - silenciada a proposito")
    $report.Add("")
    foreach ($block in $known) {
        $entry = $knownDrift | Where-Object { $_.Address -eq $block.Address } | Select-Object -First 1
        $report.Add("- ``$($block.Address)`` (``$($block.Attributes -join '`, `')``): $($entry.Reason)")
    }
    $report.Add("")
}

if ($status -eq "cycle-failed") {
    $report.Add("### Fallo del ciclo")
    $report.Add("")
    $report.Add('```text')
    $report.Add($cycleError)
    $report.Add('```')
    $report.Add("")
}

Set-Content -LiteralPath $reportPath -Value $report -Encoding utf8

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $report[1..($report.Count - 1)] -Encoding utf8
}
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "status=$status" -Encoding utf8
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "report_path=$reportPath" -Encoding utf8
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "log_path=$LogPath" -Encoding utf8
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "headline=$headline" -Encoding utf8
    Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "fingerprint=$fingerprint" -Encoding utf8
}

Write-Host ""
Write-Host "[Triage] $headline"
Write-Host "[Triage] Informe: $reportPath"

if ($status -in @("clean", "known-noise")) {
    if ($status -eq "known-noise") {
        Write-Host "::notice title=Deriva conocida en $Environment::$headline El detalle esta en el resumen del job."
    }
    exit 0
}

Write-Host "::error title=Deriva sin resolver en $Environment::$headline"
exit 1
