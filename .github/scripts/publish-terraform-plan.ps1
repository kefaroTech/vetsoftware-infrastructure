[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet("dev", "prod")][string]$Environment,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][int]$PullRequestNumber,
    [Parameter(Mandatory)][string]$Token
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Repository no tiene formato owner/name."
}
if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    throw "No existe el reporte Terraform: $ReportPath"
}

$marker = "<!-- terraform-plan:$Environment -->"
$body = Get-Content -Raw -LiteralPath $ReportPath
if (-not $body.StartsWith($marker, [StringComparison]::Ordinal)) {
    throw "El reporte no contiene el marcador esperado de $Environment."
}

$headers = @{
    Accept                 = "application/vnd.github+json"
    Authorization          = "Bearer $Token"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "VetSoftwareIaC-Terraform-Plan"
}
$commentsUri = "https://api.github.com/repos/$Repository/issues/$PullRequestNumber/comments?per_page=100"
$comments = @(Invoke-RestMethod -Method Get -Uri $commentsUri -Headers $headers)
$existing = $comments | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string]$_.body) -and
    ([string]$_.body).StartsWith($marker, [StringComparison]::Ordinal)
} | Select-Object -First 1
$payload = @{ body = $body } | ConvertTo-Json

if ($null -eq $existing) {
    Invoke-RestMethod -Method Post -Uri $commentsUri -Headers $headers -ContentType "application/json" -Body $payload | Out-Null
    Write-Host "Comentario de plan creado para $Environment."
}
else {
    Invoke-RestMethod -Method Patch -Uri ([string]$existing.url) -Headers $headers -ContentType "application/json" -Body $payload | Out-Null
    Write-Host "Comentario de plan actualizado para $Environment."
}
