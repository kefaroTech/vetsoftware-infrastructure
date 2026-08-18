# Guardarrail de paridad del endpoint OTLP de Grafana Cloud.
#
# El defecto que vigila: "Terraform plan dev" corre en pull_request SIN environment
# -a proposito, porque la deployment branch policy de iac-plan-dev nunca casa con
# refs/pull/N/merge- y por eso lee variables de REPOSITORIO con prefijo
# (DEV_GRAFANA_OTLP_ENDPOINT), mientras que apply, drift y el circuito de imagen
# corren CON environment y leen GRAFANA_OTLP_ENDPOINT sin prefijo. Son dos origenes
# independientes y nada los obliga a coincidir. Cuando divergieron -us-east-0 frente
# a us-east-3- lo aprobado en el plan no era lo que se aplicaba, y el workflow de
# drift reportaba deriva que no existia.
#
# El valor canonico vive en .github/telemetry-endpoints.json, que si se revisa en el
# pull request. Este script compara el valor efectivo del job contra ese canonico.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("dev", "prod")]
    [string]$Environment,

    # Valor efectivo del job. Si no se pasa, se toma de TF_VAR_grafana_otlp_endpoint,
    # que es lo que acabara leyendo Terraform.
    [Parameter()]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Endpoint,

    # Etiqueta del origen, solo para el mensaje: cambia entre el plan de un PR y el
    # resto de jobs, y saber cual de los dos esta mal es la mitad del arreglo.
    [Parameter()]
    [string]$Source = "TF_VAR_grafana_otlp_endpoint",

    [Parameter()]
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (-not $PSBoundParameters.ContainsKey("Endpoint")) {
    $Endpoint = [Environment]::GetEnvironmentVariable("TF_VAR_grafana_otlp_endpoint")
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

    Write-Host "[telemetry-endpoint] $Message" -ForegroundColor $color
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

# El root de dev normaliza con trimsuffix(var.grafana_otlp_endpoint, "/") en
# locals.tf y el de prod en main.tf: para Terraform la barra final no distingue dos
# valores, y este verificador no puede ser mas estricto que el codigo que protege.
function ConvertTo-NormalizedEndpoint {
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    return $Value.Trim().TrimEnd("/")
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

$canonical = Get-OptionalProperty -Object $entry -Name "otlp_endpoint"

# Ambiente sin valor canonico -hoy prod, que no tiene stack de Grafana Cloud ni
# variables PROD_*-. Avisa y deja pasar: bloquear el ciclo de prod por una decision
# que todavia no se ha tomado convertiria el guardarrail en un estorbo.
if ([string]::IsNullOrWhiteSpace($canonical)) {
    $note = Get-OptionalProperty -Object $entry -Name "note"
    $observed = if ([string]::IsNullOrWhiteSpace($Endpoint)) { "(vacio)" } else { $Endpoint }
    Write-Annotation -Level warning -Message "El ambiente '$Environment' no tiene endpoint OTLP canonico en el manifiesto; no se verifica la paridad. Valor efectivo en $Source : $observed"
    if (-not [string]::IsNullOrWhiteSpace($note)) {
        Write-Host "[telemetry-endpoint] $note"
    }
    Write-Summary -Lines @(
        "### Paridad del endpoint OTLP - $Environment",
        "",
        "WARNING: sin valor canonico en ``.github/telemetry-endpoints.json``; verificacion omitida.",
        "",
        "- Valor efectivo (``$Source``): ``$observed``"
    )
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Endpoint)) {
    Write-Annotation -Level error -Message "El endpoint OTLP de '$Environment' llego vacio en $Source. Esperado: $canonical. Revise la variable en el scope que usa este job: el plan de un pull request lee las de repositorio con prefijo DEV_/PROD_, y apply, drift y el despliegue de imagen las del GitHub Environment."
    Write-Summary -Lines @(
        "### Paridad del endpoint OTLP - $Environment",
        "",
        "ERROR: el valor efectivo llego **vacio**.",
        "",
        "- Origen (``$Source``): _(vacio)_",
        "- Canonico (``.github/telemetry-endpoints.json``): ``$canonical``"
    )
    exit 1
}

$normalizedCanonical = ConvertTo-NormalizedEndpoint -Value $canonical
$normalizedEffective = ConvertTo-NormalizedEndpoint -Value $Endpoint

if (-not [string]::Equals($normalizedCanonical, $normalizedEffective, [StringComparison]::Ordinal)) {
    Write-Annotation -Level error -Message "El endpoint OTLP de '$Environment' no coincide con el canonico. Efectivo ($Source): '$Endpoint'. Canonico (.github/telemetry-endpoints.json): '$canonical'. Corrija la variable de GitHub, o el manifiesto si el stack cambio de verdad; los dos scopes -repositorio con prefijo y GitHub Environment- deben quedar iguales."
    Write-Summary -Lines @(
        "### Paridad del endpoint OTLP - $Environment",
        "",
        "ERROR: el valor efectivo **no coincide** con el canonico versionado.",
        "",
        "| | Valor |",
        "|---|---|",
        "| Efectivo (``$Source``) | ``$Endpoint`` |",
        "| Canonico (``.github/telemetry-endpoints.json``) | ``$canonical`` |",
        "",
        "Los dos scopes de variables deben quedar iguales: repositorio con prefijo ``DEV_``/``PROD_`` para el plan de un pull request, y GitHub Environment para apply, drift y el despliegue de imagen. Detalle en ``docs/TELEMETRIA_OTLP.md``."
    )
    exit 1
}

$stack = Get-OptionalProperty -Object $entry -Name "grafana_stack"
$stackLabel = if ([string]::IsNullOrWhiteSpace($stack)) { "sin stack declarado" } else { "stack $stack" }
Write-Host "[telemetry-endpoint] OK: '$Environment' apunta a $normalizedEffective ($stackLabel)." -ForegroundColor Green
Write-Summary -Lines @(
    "### Paridad del endpoint OTLP - $Environment",
    "",
    "OK: ``$normalizedEffective`` ($stackLabel)."
)
exit 0
