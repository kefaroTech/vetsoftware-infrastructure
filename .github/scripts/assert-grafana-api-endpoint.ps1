# Guardarrail de paridad del host de la API de Grafana (provisioning de
# alertas Grafana-managed).
#
# Tercer hermano de assert-telemetry-endpoint.ps1 y assert-ruler-endpoint.ps1,
# con la misma logica: las variables de GitHub no se revisan en un pull
# request, el manifiesto versionado si. Compara el valor efectivo del job
# -vars.GRAFANA_API_URL del GitHub Environment- contra el campo
# grafana_api_url de .github/telemetry-endpoints.json.
#
# Script aparte y no una extension de assert-ruler-endpoint.ps1 por el mismo
# motivo por el que aquel no extendio al de OTLP: este valor tiene otro ciclo
# de vida (puede faltar legitimamente mientras el ruler ya funciona) y su
# mismatch debe cortar solo el provisioning, no el sync de reglas. Los
# workflows lo invocan DESPUES del sync de mimirtool a proposito.
#
# Semantica, identica a la de los hermanos:
# - canonico null en el manifiesto -> warning y exit 0 (avisa y pasa).
# - valor efectivo vacio con canonico definido -> exit 1.
# - mismatch -> exit 1, antes de que el paso de provisioning toque el token.
# - la barra final de la URL no distingue dos valores.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    # Valor efectivo del job. Si no se pasa, se toma de la variable de entorno
    # que exportan los workflows de sync.
    [Parameter()]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$ApiUrl,

    # Etiqueta del origen, solo para el mensaje.
    [Parameter()]
    [string]$Source = "vars.GRAFANA_API_URL",

    [Parameter()]
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (-not $PSBoundParameters.ContainsKey("ApiUrl")) {
    $ApiUrl = [Environment]::GetEnvironmentVariable("GRAFANA_API_URL")
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

    Write-Host "[grafana-api-endpoint] $Message" -ForegroundColor $color
    if ($inActions) {
        # Un salto de linea real rompe el comando de anotacion de Actions.
        $flattened = $Message -replace "`r?`n", " "
        Write-Host "::${Level}::$flattened"
    }
}

function Write-Summary {
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

$canonicalUrl = Get-OptionalProperty -Object $entry -Name "grafana_api_url"

# Ambiente sin valor canonico: avisa y deja pasar, igual que el OTLP de prod.
# El sub-gate de provisioning del workflow decide por su cuenta si hay con que
# aplicar.
if ([string]::IsNullOrWhiteSpace($canonicalUrl)) {
    $note = Get-OptionalProperty -Object $entry -Name "grafana_api_note"
    $observedUrl = Format-Observed -Value $ApiUrl
    Write-Annotation -Level warning -Message "El ambiente '$Environment' no tiene grafana_api_url canonico en el manifiesto; no se verifica la paridad. Valor efectivo en $Source : $observedUrl"
    if (-not [string]::IsNullOrWhiteSpace($note)) {
        Write-Host "[grafana-api-endpoint] $note"
    }
    Write-Summary -Lines @(
        "### Paridad de la API de Grafana - $Environment",
        "",
        "WARNING: sin valor canonico en ``.github/telemetry-endpoints.json``; verificacion omitida.",
        "",
        "- URL efectiva (``$Source``): ``$observedUrl``"
    )
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
    Write-Annotation -Level error -Message "GRAFANA_API_URL llego vacia en $Source con canonico definido ($canonicalUrl). Revise la variable del GitHub Environment que usa este job."
    Write-Summary -Lines @(
        "### Paridad de la API de Grafana - $Environment",
        "",
        "ERROR: valor efectivo vacio en ``$Source``; canonico: ``$canonicalUrl``."
    )
    exit 1
}

$normalizedCanonicalUrl = ConvertTo-NormalizedUrl -Value $canonicalUrl
$normalizedEffectiveUrl = ConvertTo-NormalizedUrl -Value $ApiUrl

if (-not [string]::Equals($normalizedCanonicalUrl, $normalizedEffectiveUrl, [StringComparison]::Ordinal)) {
    Write-Annotation -Level error -Message "La API de Grafana de '$Environment' no coincide con la canonica. Efectivo ($Source): '$ApiUrl'. Canonico (.github/telemetry-endpoints.json): '$canonicalUrl'. Corrija la variable del GitHub Environment, o el manifiesto si el stack cambio de verdad."
    Write-Summary -Lines @(
        "### Paridad de la API de Grafana - $Environment",
        "",
        "ERROR: el valor efectivo **no coincide** con el canonico versionado.",
        "",
        "| | Efectivo (``$Source``) | Canonico |",
        "|---|---|---|",
        "| URL | ``$ApiUrl`` | ``$canonicalUrl`` |",
        "",
        "Detalle en ``docs/ALERTAS_GRAFANA_CLOUD.md``."
    )
    exit 1
}

$stack = Get-OptionalProperty -Object $entry -Name "grafana_stack"
$stackLabel = if ([string]::IsNullOrWhiteSpace($stack)) { "sin stack declarado" } else { "stack $stack" }
Write-Host "[grafana-api-endpoint] OK: '$Environment' apunta a $normalizedEffectiveUrl ($stackLabel)." -ForegroundColor Green
Write-Summary -Lines @(
    "### Paridad de la API de Grafana - $Environment",
    "",
    "OK: ``$normalizedEffectiveUrl`` ($stackLabel)."
)
exit 0
