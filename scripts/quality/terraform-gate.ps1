[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet("full", "terraform", "security", "ci")]
    [string]$Mode = "full"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$env:TF_IN_AUTOMATION = "true"
$env:TF_INPUT = "false"

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$expectedTerraformVersion = "1.15.8"
$expectedTflintVersion = "0.64.0"
$terraformRoots = @(
    "bootstrap",
    "environments/prod",
    "environments/dev",
    "modules/github_iac_roles"
)
$terraformTestRoots = @(
    "environments/prod",
    "environments/dev",
    "modules/github_iac_roles"
)
$logDirectory = Join-Path $repositoryRoot ".tools/logs/terraform-gate"
$timestamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$logFile = Join-Path $logDirectory "terraform-gate-$timestamp-$Mode.log"
$latestLog = Join-Path $logDirectory "latest-$Mode.log"
$script:stepNumber = 0
$script:startedAt = Get-Date
$script:stagedPaths = @()
$exitCode = 0

New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
Start-Transcript -Path $logFile -Force | Out-Null
Write-Host "Persistent log: $logFile"

function Write-Step {
    param([Parameter(Mandatory)][string]$Name)

    $script:stepNumber++
    $elapsed = (Get-Date) - $script:startedAt
    Write-Host ""
    Write-Host ("[{0:00}] {1} (+{2:mm\:ss})" -f $script:stepNumber, $Name, $elapsed) -ForegroundColor Cyan
}

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Gate bloqueado: no se encontro el comando obligatorio '$Name'."
    }
}

function Get-PosixShell {
    $shell = Get-Command "sh" -ErrorAction SilentlyContinue
    if ($shell) {
        return $shell.Source
    }

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $git = Get-Command "git" -ErrorAction SilentlyContinue
        if ($git) {
            $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
            foreach ($relativePath in @("bin/sh.exe", "usr/bin/sh.exe")) {
                $candidate = Join-Path $gitRoot $relativePath
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    return $candidate
                }
            }
        }
    }

    throw "Gate bloqueado: Git Bash o un shell POSIX 'sh' es obligatorio."
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$FailureMessage
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage (exit code $LASTEXITCODE)."
    }
}

function Test-RelevantGatePath {
    param([Parameter(Mandatory)][string]$Path)

    $normalized = $Path.Replace("\", "/")
    return (
        $normalized -match '\.(tf|hcl|tftest\.hcl|tftpl)$' -or
        $normalized -match '\.tfvars\.example$' -or
        $normalized -eq ".terraform-version" -or
        $normalized -eq ".tflint.hcl" -or
        $normalized -eq ".githooks/pre-commit" -or
        $normalized.StartsWith("scripts/quality/") -or
        $normalized.StartsWith("scripts/security/") -or
        $normalized -eq ".github/workflows/terraform.yml"
    )
}

function Invoke-StagedHygiene {
    Write-Step "Higiene del snapshot preparado"
    Invoke-NativeCommand -Command "git" -Arguments @("diff", "--cached", "--check") -FailureMessage "Git detecto whitespace invalido en los cambios preparados"

    $stagedPaths = @(& git diff --cached --name-only --diff-filter=ACMRD)
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible enumerar los archivos preparados."
    }
    $script:stagedPaths = @($stagedPaths | ForEach-Object { $_.Replace("\", "/") })

    $presentStagedPaths = @(& git diff --cached --name-only --diff-filter=ACMR)
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible enumerar los archivos presentes en el snapshot preparado."
    }

    $blockedPaths = @(
        foreach ($path in $presentStagedPaths) {
            $normalized = $path.Replace("\", "/")
            if (
                $normalized -match '(^|/)\.terraform/' -or
                $normalized -match '\.tfstate($|\.)' -or
                $normalized -match '\.tfplan$' -or
                ($normalized -match '\.tfvars$' -and $normalized -notmatch '\.tfvars\.example$') -or
                ($normalized -match '(^|/)backend\.hcl$' -and $normalized -notmatch '\.example$') -or
                $normalized -match '(^|/)\.env($|\.)' -or
                $normalized -match '\.(pem|key|p12|pfx|jks|keystore|kdbx)$' -or
                $normalized -match '^(credentials|secrets)(\.|/|$)'
            ) {
                $path
            }
        }
    )

    if ($blockedPaths.Count -gt 0) {
        throw "Archivos sensibles o generados no permitidos en el commit:`n - $($blockedPaths -join "`n - ")"
    }

    $unstagedPaths = @(& git diff --name-only)
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible enumerar los cambios sin preparar."
    }
    $untrackedPaths = @(& git ls-files --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible enumerar los archivos no rastreados."
    }

    $ambiguousPaths = @(
        @($unstagedPaths + $untrackedPaths) |
            Where-Object { Test-RelevantGatePath -Path $_ } |
            Sort-Object -Unique
    )

    if ($ambiguousPaths.Count -gt 0) {
        throw "El gate no puede certificar un snapshot ambiguo. Prepare o descarte estos cambios IaC antes del commit:`n - $($ambiguousPaths -join "`n - ")"
    }

    Write-Host "Snapshot preparado sin artefactos sensibles ni cambios IaC ambiguos." -ForegroundColor Green
}

function Invoke-SecretScan {
    Write-Step "Gitleaks sobre el snapshot preparado"
    $shell = Get-PosixShell
    Invoke-NativeCommand -Command $shell -Arguments @("scripts/security/scan-secrets.sh", "staged") -FailureMessage "Gitleaks detecto un secreto o no pudo ejecutar el escaneo"
}

function Assert-NoSecuritySuppressions {
    param(
        [Parameter()][switch]$Cached,
        [Parameter()][switch]$ChangedOnly,
        [Parameter()][string[]]$Paths = @()
    )

    Write-Step "Politica de seguridad: excepciones arquitectonicas controladas"
    if ($ChangedOnly -and $Paths.Count -eq 0) {
        Write-Host "Sin archivos preparados: no hay exclusiones nuevas que analizar." -ForegroundColor Green
        return
    }

    $forbiddenTokens = @(
        ("tfsec" + ":ignore"),
        ("checkov" + ":skip"),
        (".trivy" + "ignore"),
        ("--ignore" + "-policy"),
        ("--ignore" + "file")
    )
    $matches = @()

    foreach ($token in $forbiddenTokens) {
        $arguments = @("grep")
        if ($Cached) {
            $arguments += "--cached"
        }
        $arguments += @("-n", "-I", "-e", $token, "--")
        if ($ChangedOnly) {
            $arguments += $Paths
        }
        else {
            $arguments += "."
        }
        $result = @(& git @arguments 2>&1)
        $grepExitCode = $LASTEXITCODE

        if ($grepExitCode -eq 0) {
            $matches += $result
        }
        elseif ($grepExitCode -ne 1) {
            throw "No fue posible verificar exclusiones de seguridad con git grep."
        }
    }

    if ($matches.Count -gt 0) {
        throw "La politica de seguridad prohibe exclusiones globales o no controladas:`n$($matches -join "`n")"
    }

    $trivyIgnoreToken = ("trivy" + ":ignore")
    $approvedExceptions = @(
        "modules/security/main.tf|AVD-AWS-0104|backend_public_https",
        "modules/security/main.tf|AVD-AWS-0104|alloy_public_https",
        "environments/dev/main.tf|AVD-AWS-0104|backend_public_https"
    )

    $arguments = @("grep")
    if ($Cached) {
        $arguments += "--cached"
    }
    $arguments += @("-n", "-I", "-e", $trivyIgnoreToken, "--")
    if ($ChangedOnly) {
        $arguments += $Paths
    }
    else {
        $arguments += "."
    }

    $ignoreLines = @(& git @arguments 2>&1)
    $grepExitCode = $LASTEXITCODE
    if ($grepExitCode -notin @(0, 1)) {
        throw "No fue posible verificar las excepciones inline de Trivy."
    }

    $ignorePaths = @(
        $ignoreLines |
            ForEach-Object {
                if ($_ -match '^([^:]+):\d+:') { $Matches[1] }
                else { throw "Marcador Trivy no interpretable: $_" }
            } |
            Sort-Object -Unique
    )
    $actualExceptions = @()
    $escapedToken = [regex]::Escape($trivyIgnoreToken)
    $structuredIgnore = "(?m)^#$escapedToken`:(?<rule>[A-Za-z0-9-]+)\r?\nresource\s+`"aws_vpc_security_group_egress_rule`"\s+`"(?<resource>[A-Za-z0-9_]+)`"\s+\{"

    foreach ($path in $ignorePaths) {
        if ($Cached) {
            $content = ((& git show ":$path" 2>&1) -join "`n")
            if ($LASTEXITCODE -ne 0) {
                throw "No fue posible leer '$path' desde el snapshot preparado."
            }
        }
        else {
            $content = [System.IO.File]::ReadAllText((Join-Path $repositoryRoot $path))
        }

        $tokenCount = [regex]::Matches($content, $escapedToken).Count
        $structuredMatches = [regex]::Matches($content, $structuredIgnore)
        if ($tokenCount -ne $structuredMatches.Count) {
            throw "'$path' contiene una excepcion Trivy que no esta inmediatamente asociada a un recurso permitido."
        }

        foreach ($match in $structuredMatches) {
            $key = "$path|$($match.Groups['rule'].Value)|$($match.Groups['resource'].Value)"
            if ($key -notin $approvedExceptions) {
                throw "Excepcion Trivy no autorizada: $key"
            }
            $actualExceptions += $key
        }
    }

    if (-not $ChangedOnly) {
        $missingExceptions = @($approvedExceptions | Where-Object { $_ -notin $actualExceptions })
        if ($missingExceptions.Count -gt 0) {
            throw "Falta declarar una excepcion arquitectonica requerida:`n$($missingExceptions -join "`n")"
        }
    }

    Write-Host "Sin exclusiones globales; AWS-0104 autorizado solo para tres reglas HTTPS publicas identificadas." -ForegroundColor Green
}

function Get-PreCommitScope {
    param([Parameter(Mandatory)][string[]]$Paths)

    $roots = @()
    $scanTargets = @()
    $formatFiles = @()
    $runAll = $false

    foreach ($path in $Paths) {
        $normalized = $path.Replace("\", "/")

        $isTerraformCode = (
            $normalized -match '\.tf$' -or
            $normalized -match '\.tfvars(\.example)?$' -or
            $normalized -match '\.tftest\.hcl$' -or
            $normalized -match '\.hcl(\.example)?$' -or
            $normalized -match '\.tftpl$'
        )

        if ($normalized -match '\.(tf|tfvars|tftest\.hcl)$' -and (Test-Path -LiteralPath (Join-Path $repositoryRoot $normalized) -PathType Leaf)) {
            $formatFiles += $normalized
        }

        if (
            $normalized -eq ".terraform-version" -or
            $normalized -eq ".tflint.hcl" -or
            $normalized -eq ".githooks/pre-commit" -or
            $normalized -eq ".github/workflows/terraform.yml" -or
            $normalized.StartsWith("scripts/quality/") -or
            $normalized.StartsWith("scripts/security/")
        ) {
            $runAll = $true
            continue
        }

        if (-not $isTerraformCode) {
            continue
        }

        if ($normalized.StartsWith("bootstrap/")) {
            $roots += "bootstrap"
            $scanTargets += "bootstrap"
            continue
        }
        if ($normalized.StartsWith("environments/prod/")) {
            $roots += "environments/prod"
            $scanTargets += "environments/prod"
            continue
        }
        if ($normalized.StartsWith("environments/dev/")) {
            $roots += "environments/dev"
            $scanTargets += "environments/dev"
            continue
        }

        if ($normalized -match '^modules/([^/]+)/') {
            $moduleName = $Matches[1]
            switch ($moduleName) {
                "ecr" {
                    $roots += "bootstrap"
                    $scanTargets += "bootstrap"
                }
                "github_iac_roles" {
                    $roots += @("bootstrap", "modules/github_iac_roles")
                    $scanTargets += @("bootstrap", "modules/github_iac_roles")
                }
                "scheduled_shutdown" {
                    $roots += "environments/dev"
                    $scanTargets += "environments/dev"
                }
                { $_ -in @("ec2_service", "storage_audit") } {
                    $roots += "environments/prod"
                    $scanTargets += "environments/prod"
                }
                { $_ -in @("alb", "cache", "database", "ecs_backend", "kms", "monitoring", "network", "secrets", "security") } {
                    $roots += @("environments/prod", "environments/dev")
                    $scanTargets += @("environments/prod", "environments/dev")
                }
                default {
                    throw "Modulo Terraform sin mapa de impacto incremental: $moduleName. Actualice Get-PreCommitScope antes de confirmar."
                }
            }
        }
    }

    if ($runAll) {
        $roots = $terraformRoots
        $scanTargets = $terraformRoots
    }

    $roots = @($roots | Sort-Object -Unique)
    $scanTargets = @($scanTargets | Sort-Object -Unique)
    $formatFiles = @($formatFiles | Sort-Object -Unique)

    Write-Step "Alcance incremental calculado desde Git staged"
    Write-Host "Archivos preparados: $($Paths.Count)"
    Write-Host "Archivos Terraform para fmt: $(if ($formatFiles.Count) { $formatFiles -join ', ' } else { 'ninguno' })"
    Write-Host "Raices afectadas: $(if ($roots.Count) { $roots -join ', ' } else { 'ninguna' })"
    Write-Host "Objetivos Trivy: $(if ($scanTargets.Count) { $scanTargets -join ', ' } else { 'ninguno' })"

    return [PSCustomObject]@{
        Roots       = $roots
        ScanTargets = $scanTargets
        FormatFiles = $formatFiles
    }
}

function Assert-Toolchain {
    Write-Step "Versiones obligatorias del toolchain"
    Assert-Command -Name "terraform"
    Assert-Command -Name "tflint"

    $terraformJson = (& terraform version -json 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible leer la version de Terraform."
    }
    $terraformVersion = ($terraformJson | ConvertFrom-Json).terraform_version
    if ($terraformVersion -ne $expectedTerraformVersion) {
        throw "Terraform $expectedTerraformVersion es obligatorio; se encontro $terraformVersion."
    }

    $tflintOutput = (& tflint --version 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw "No fue posible leer la version de TFLint."
    }
    if ($tflintOutput -notmatch "TFLint version $([regex]::Escape($expectedTflintVersion))(\s|$)") {
        throw "TFLint $expectedTflintVersion es obligatorio. Salida detectada: $tflintOutput"
    }

    Write-Host "Terraform $terraformVersion y TFLint $expectedTflintVersion verificados." -ForegroundColor Green
}

function Invoke-TerraformFormat {
    param([Parameter()][string[]]$Files = @())

    if ($Files.Count -eq 0) {
        Write-Step "terraform fmt -check -diff -recursive"
        Invoke-NativeCommand -Command "terraform" -Arguments @("-chdir=$repositoryRoot", "fmt", "-check", "-diff", "-recursive") -FailureMessage "Terraform encontro archivos sin formato; ejecute terraform fmt -recursive"
        return
    }

    Write-Step "terraform fmt sobre archivos preparados"
    Push-Location $repositoryRoot
    try {
        Invoke-NativeCommand -Command "terraform" -Arguments (@("fmt", "-check", "-diff") + $Files) -FailureMessage "Terraform encontro archivos preparados sin formato; ejecute terraform fmt sobre esos archivos"
    }
    finally {
        Pop-Location
    }
}

function Invoke-Tflint {
    param([Parameter()][string[]]$Roots = $terraformRoots)

    Write-Step "TFLint estricto (severidad minima: notice)"
    Push-Location $repositoryRoot
    try {
        Invoke-NativeCommand -Command "tflint" -Arguments @("--init") -FailureMessage "tflint --init fallo"
        foreach ($root in $Roots) {
            Write-Host "TFLint: $root"
            Invoke-NativeCommand -Command "tflint" -Arguments @("--chdir=$root", "--format=compact", "--minimum-failure-severity=notice") -FailureMessage "TFLint encontro incidencias en $root"
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-TerraformValidate {
    param([Parameter(Mandatory)][string]$Root)

    $absoluteRoot = Join-Path $repositoryRoot $Root
    Write-Host "Terraform init/validate: $Root"
    Invoke-NativeCommand -Command "terraform" -Arguments @("-chdir=$absoluteRoot", "init", "-backend=false", "-input=false", "-lockfile=readonly") -FailureMessage "terraform init fallo en $Root"

    $validationLines = @(& terraform "-chdir=$absoluteRoot" validate -json 2>&1)
    $validationExitCode = $LASTEXITCODE
    $validationJson = $validationLines -join "`n"
    try {
        $validation = $validationJson | ConvertFrom-Json
    }
    catch {
        Write-Host $validationJson
        throw "terraform validate no produjo JSON valido en $Root."
    }

    if ($validationExitCode -ne 0 -or -not $validation.valid -or $validation.error_count -gt 0 -or $validation.warning_count -gt 0) {
        Write-Host $validationJson
        throw "terraform validate detecto $($validation.error_count) errores y $($validation.warning_count) advertencias en $Root."
    }

    Write-Host "Validate limpio (0 errores, 0 advertencias): $Root" -ForegroundColor Green
}

function Invoke-TerraformQuality {
    param(
        [Parameter()][string[]]$Roots = $terraformRoots,
        [Parameter()][string[]]$FormatFiles = @()
    )

    Assert-Toolchain
    Invoke-TerraformFormat -Files $FormatFiles
    Invoke-Tflint -Roots $Roots

    Write-Step "Terraform init y validate sin advertencias"
    foreach ($root in $Roots) {
        Invoke-TerraformValidate -Root $root
    }

    Write-Step "Contratos terraform test"
    $affectedTestRoots = @($terraformTestRoots | Where-Object { $_ -in $Roots })
    if ($affectedTestRoots.Count -eq 0) {
        Write-Host "Ninguna raiz afectada tiene contratos terraform test; paso omitido." -ForegroundColor Green
    }
    foreach ($root in $affectedTestRoots) {
        $absoluteRoot = Join-Path $repositoryRoot $root
        Write-Host "Terraform test: $root"
        Invoke-NativeCommand -Command "terraform" -Arguments @("-chdir=$absoluteRoot", "test", "-no-color") -FailureMessage "terraform test fallo en $root"
    }
}

function Invoke-IacSecurityScan {
    param([Parameter()][string[]]$Targets = @())

    Write-Step "Trivy IaC MEDIUM/HIGH/CRITICAL"
    $shell = Get-PosixShell
    Invoke-NativeCommand -Command $shell -Arguments (@("scripts/security/scan-iac.sh") + $Targets) -FailureMessage "Trivy detecto una configuracion insegura o no pudo ejecutar el escaneo"
}

try {
    Set-Location $repositoryRoot
    Write-Host "VetSoftwareIaC strict gate | mode=$Mode | UTC=$([DateTime]::UtcNow.ToString('O'))" -ForegroundColor White

    switch ($Mode) {
        "full" {
            Invoke-StagedHygiene
            $scope = Get-PreCommitScope -Paths $script:stagedPaths
            Assert-NoSecuritySuppressions -Cached -ChangedOnly -Paths $script:stagedPaths
            Invoke-SecretScan
            if ($scope.Roots.Count -gt 0) {
                Invoke-TerraformQuality -Roots $scope.Roots -FormatFiles $scope.FormatFiles
                Invoke-IacSecurityScan -Targets $scope.ScanTargets
            }
            else {
                Write-Step "Calidad Terraform y Trivy"
                Write-Host "Sin cambios Terraform ni cambios del gate: validaciones pesadas omitidas." -ForegroundColor Green
            }
        }
        "terraform" {
            Invoke-TerraformQuality
        }
        "security" {
            Assert-NoSecuritySuppressions
            Invoke-IacSecurityScan
        }
        "ci" {
            Assert-NoSecuritySuppressions
            Invoke-TerraformQuality
            Invoke-IacSecurityScan
        }
    }

    $duration = (Get-Date) - $script:startedAt
    Write-Host ""
    Write-Host ("GATE APROBADO en {0:mm\:ss}." -f $duration) -ForegroundColor Green
}
catch {
    $duration = (Get-Date) - $script:startedAt
    Write-Host ""
    Write-Host ("GATE BLOQUEADO en {0:mm\:ss}: {1}" -f $duration, $_.Exception.Message) -ForegroundColor Red
    $exitCode = 1
}
finally {
    Stop-Transcript | Out-Null
    Copy-Item -Force $logFile $latestLog
}

exit $exitCode
