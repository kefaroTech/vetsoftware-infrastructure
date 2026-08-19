# Guardarrail de paridad del ruler de Mimir de Grafana Cloud.
#
# Hermano de assert-telemetry-endpoint.ps1 y con la misma logica: las variables
# de GitHub no se revisan en un pull request, el manifiesto versionado si. Este
# script compara el valor efectivo del job -vars.GRAFANA_RULER_URL y
# vars.GRAFANA_METRICS_TENANT_ID del GitHub Environment- contra los campos
# ruler_url y metrics_tenant_id de .github/telemetry-endpoints.json.
#
# Es un script aparte y no una extension del de OTLP a proposito: aquel se
# invoca desde nueve jobs confiando en sus valores por defecto (variable
# TF_VAR_grafana_otlp_endpoint, campo otlp_endpoint), y este compara DOS
# valores a la vez. Tocar el original para generalizarlo arriesgaba nueve
# call sites por ahorrar un fichero.
#
# Semantica, identica a la del OTLP:
# - canonico null en el manifiesto -> warning y exit 0 (avisa y pasa).
# - valor efectivo vacio con canonico definido -> exit 1.
# - mismatch -> exit 1, antes de que el job toque el token del ruler.
# - la barra final de la URL no distingue dos valores.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    # Valores efectivos del job. Si no se pasan, se toman de las variables de
    # entorno que exportan los workflows de sync.
    [Parameter()]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$RulerUrl,

    [Parameter()]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$TenantId,

    # Etiqueta del origen, solo para el mensaje.
    [Parameter()]
    [string]$Source = "vars.GRAFANA_RULER_URL / vars.GRAFANA_METRICS_TENANT_ID",

    [Parameter()]
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (-not $PSBoundParameters.ContainsKey("RulerUrl")) {
    $RulerUrl = [Environment]::GetEnvironmentVariable("GRAFANA_RULER_URL")
}
if (-not $PSBoundParameters.ContainsKey("TenantId")) {
    $TenantId = [Environment]::GetEnvironmentVariable("GRAFANA_METRICS_TENANT_ID")
}

if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $PSScriptRoot "../telemetry-endpoints.json"
}

$inActions = $env:GITHUB_ACTIONS -eq "true"

function Write-Annotation {
    param(
        [Parameter(Mandatory)][ValidateSet("error", "warning", "notice")][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    $color = switch ($Level) {
        "error" { "Red" }
        "warning" { "Yellow" }
        default { "Cyan" }
    }

    Write-Host "[ruler-endpoint] $Message" -ForegroundColor $color
    if ($inActions) {
        # Un salto de linea real rompe el comando de anotacion de Actions.
        $flattened = $Message -replace "`r?`n", " "
        Write-Host "::${Level}::$flattened"
    }
}

function Write-Summary {
    # AllowEmptyString: un resumen Markdown lleva lineas en blanco, y un parametro
    # obligatorio las rechaza elemento a elemento sin ella.
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Lines -Encoding utf8
    }
}

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory)][AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# mimirtool trata la URL con y sin barra final como el mismo address; el
# verificador no puede ser mas estricto que la herramienta que protege.
function ConvertTo-NormalizedUrl {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    return $Value.Trim().TrimEnd("/")
}

function Format-Observed {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "(vacio)" }
    return $Value
}

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Write-Annotation -Level error -Message "No existe el manifiesto de endpoints canonicos en $ManifestPath."
    exit 1
}

try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
}
catch {
    Write-Annotation -Level error -Message "El manifiesto $ManifestPath no es JSON valido: $($_.Exception.Message)"
    exit 1
}

$environments = Get-OptionalProperty -Object $manifest -Name "environments"
$entry = Get-OptionalProperty -Object $environments -Name $Environment
if ($null -eq $entry) {
    Write-Annotation -Level error -Message "El manifiesto no declara el ambiente '$Environment'. Anadalo en .github/telemetry-endpoints.json."
    exit 1
}

$canonicalUrl = Get-OptionalProperty -Object $entry -Name "ruler_url"
# El tenant es numerico en Grafana Cloud, pero aqui se compara como texto: un
# JSON con 123456 y una variable "123456" son el mismo valor.
$canonicalTenant = Get-OptionalProperty -Object $entry -Name "metrics_tenant_id"
if ($null -ne $canonicalTenant) { $canonicalTenant = [string]$canonicalTenant }

# Ambiente sin valores canonicos: avisa y deja pasar, igual que el OTLP de
# prod. El paso de gate del workflow decide por su cuenta si hay con que
# sincronizar.
if ([string]::IsNullOrWhiteSpace($canonicalUrl) -or [string]::IsNullOrWhiteSpace($canonicalTenant)) {
    $note = Get-OptionalProperty -Object $entry -Name "ruler_note"
    $observedUrl = Format-Observed -Value $RulerUrl
    $observedTenant = Format-Observed -Value $TenantId
    Write-Annotation -Level warning -Message "El ambiente '$Environment' no tiene ruler_url/metrics_tenant_id canonicos en el manifiesto; no se verifica la paridad. Valores efectivos en $Source : url=$observedUrl tenant=$observedTenant"
    if (-not [string]::IsNullOrWhiteSpace($note)) {
        Write-Host "[ruler-endpoint] $note"
    }
    Write-Summary -Lines @(
        "### Paridad del ruler de Mimir - $Environment",
        "",
        "WARNING: sin valores canonicos en ``.github/telemetry-endpoints.json``; verificacion omitida.",
        "",
        "- URL efectiva (``$Source``): ``$observedUrl``",
        "- Tenant efectivo: ``$observedTenant``"
    )
    exit 0
}

if ([string]::IsNullOrWhiteSpace($RulerUrl) -or [string]::IsNullOrWhiteSpace($TenantId)) {
    $observedUrl = Format-Observed -Value $RulerUrl
    $observedTenant = Format-Observed -Value $TenantId
    Write-Annotation -Level error -Message "El ruler de '$Environment' llego incompleto en $Source. Esperado: url=$canonicalUrl tenant=$canonicalTenant. Revise GRAFANA_RULER_URL y GRAFANA_METRICS_TENANT_ID en el GitHub Environment que usa este job."
    Write-Summary -Lines @(
        "### Paridad del ruler de Mimir - $Environment",
        "",
        "ERROR: valores efectivos incompletos en ``$Source``.",
        "",
        "| | Efectivo | Canonico |",
        "|---|---|---|",
        "| URL | ``$observedUrl`` | ``$canonicalUrl`` |",
        "| Tenant | ``$observedTenant`` | ``$canonicalTenant`` |"
    )
    exit 1
}

$normalizedCanonicalUrl = ConvertTo-NormalizedUrl -Value $canonicalUrl
$normalizedEffectiveUrl = ConvertTo-NormalizedUrl -Value $RulerUrl
$urlMatches = [string]::Equals($normalizedCanonicalUrl, $normalizedEffectiveUrl, [StringComparison]::Ordinal)
$tenantMatches = [string]::Equals($canonicalTenant.Trim(), $TenantId.Trim(), [StringComparison]::Ordinal)

if (-not ($urlMatches -and $tenantMatches)) {
    Write-Annotation -Level error -Message "El ruler de '$Environment' no coincide con el canonico. Efectivo ($Source): url='$RulerUrl' tenant='$TenantId'. Canonico (.github/telemetry-endpoints.json): url='$canonicalUrl' tenant='$canonicalTenant'. Corrija las variables del GitHub Environment, o el manifiesto si el stack cambio de verdad."
    Write-Summary -Lines @(
        "### Paridad del ruler de Mimir - $Environment",
        "",
        "ERROR: los valores efectivos **no coinciden** con los canonicos versionados.",
        "",
        "| | Efectivo (``$Source``) | Canonico |",
        "|---|---|---|",
        "| URL | ``$RulerUrl`` | ``$canonicalUrl`` |",
        "| Tenant | ``$TenantId`` | ``$canonicalTenant`` |",
        "",
        "Detalle en ``docs/ALERTAS_GRAFANA_CLOUD.md``."
    )
    exit 1
}

$stack = Get-OptionalProperty -Object $entry -Name "grafana_stack"
$stackLabel = if ([string]::IsNullOrWhiteSpace($stack)) { "sin stack declarado" } else { "stack $stack" }
Write-Host "[ruler-endpoint] OK: '$Environment' apunta a $normalizedEffectiveUrl con tenant $TenantId ($stackLabel)." -ForegroundColor Green
Write-Summary -Lines @(
    "### Paridad del ruler de Mimir - $Environment",
    "",
    "OK: ``$normalizedEffectiveUrl`` / tenant ``$TenantId`` ($stackLabel)."
)
exit 0
