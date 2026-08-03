[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("dev", "prod")]
    [string]$Environment
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$bootstrapDirectory = Join-Path $repositoryRoot "bootstrap"
$projectName = if ([string]::IsNullOrWhiteSpace($env:PROJECT_NAME)) { "vetsoftware" } else { $env:PROJECT_NAME }

function Assert-EnvironmentValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Configure $Name en el GitHub Environment iac-bootstrap-$Environment."
    }
    return $value
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command fallo con codigo $LASTEXITCODE."
    }
}

function Get-StackOutput {
    param(
        [Parameter(Mandatory)][object[]]$Outputs,
        [Parameter(Mandatory)][string]$Key
    )

    $output = $Outputs | Where-Object OutputKey -eq $Key | Select-Object -First 1
    if ($null -eq $output -or [string]::IsNullOrWhiteSpace($output.OutputValue)) {
        throw "CloudFormation no emitio el output $Key."
    }
    return $output.OutputValue
}

$awsRegion = Assert-EnvironmentValue -Name "AWS_REGION"
$expectedAccountId = Assert-EnvironmentValue -Name "AWS_ACCOUNT_ID"
$githubOrganization = Assert-EnvironmentValue -Name "GITHUB_ORGANIZATION"
$githubOrganizationId = Assert-EnvironmentValue -Name "GITHUB_ORGANIZATION_ID"
$repositoryIdsJson = Assert-EnvironmentValue -Name "GITHUB_REPOSITORY_IDS_JSON"

try {
    $repositoryIds = $repositoryIdsJson | ConvertFrom-Json -AsHashtable
}
catch {
    throw "GITHUB_REPOSITORY_IDS_JSON debe ser un objeto JSON valido."
}

$requiredRepositoryKeys = @("backend", "iac")
if ($Environment -eq "prod") {
    $requiredRepositoryKeys += @("private_front", "public_front")
}

foreach ($repositoryKey in $requiredRepositoryKeys) {
    if (-not $repositoryIds.ContainsKey($repositoryKey) -or "$($repositoryIds[$repositoryKey])" -notmatch '^[0-9]+$') {
        throw "GITHUB_REPOSITORY_IDS_JSON requiere el ID numerico $repositoryKey."
    }
}

foreach ($optionalRepositoryKey in @("private_front", "public_front")) {
    if (-not $repositoryIds.ContainsKey($optionalRepositoryKey)) {
        $repositoryIds[$optionalRepositoryKey] = ""
    }
}

$callerIdentity = & aws sts get-caller-identity --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "No fue posible consultar la identidad AWS asumida."
}
if ($callerIdentity.Account -ne $expectedAccountId) {
    throw "La cuenta AWS asumida ($($callerIdentity.Account)) no coincide con AWS_ACCOUNT_ID ($expectedAccountId)."
}

$stackName = "$projectName-$Environment-terraform-state"
$templatePath = Join-Path $bootstrapDirectory "state-backend.yml"
Invoke-ExternalCommand -Command "aws" -Arguments @(
    "cloudformation", "deploy",
    "--stack-name", $stackName,
    "--template-file", $templatePath,
    "--parameter-overrides", "ProjectName=$projectName", "Environment=$Environment",
    "--no-fail-on-empty-changeset",
    "--region", $awsRegion
)

$stackOutputsJson = & aws cloudformation describe-stacks `
    --stack-name $stackName `
    --query "Stacks[0].Outputs" `
    --output json `
    --region $awsRegion
if ($LASTEXITCODE -ne 0) {
    throw "No fue posible leer los outputs del stack $stackName."
}
$stackOutputs = $stackOutputsJson | ConvertFrom-Json
$stateBucketName = Get-StackOutput -Outputs $stackOutputs -Key "StateBucketName"
$stateKmsKeyArn = Get-StackOutput -Outputs $stackOutputs -Key "StateKmsKeyArn"

$runnerTemp = Assert-EnvironmentValue -Name "RUNNER_TEMP"
$backendConfigPath = Join-Path $runnerTemp "bootstrap-$Environment.backend.hcl"
$variablesPath = Join-Path $runnerTemp "bootstrap-$Environment.auto.tfvars.json"
$planPath = Join-Path $runnerTemp "bootstrap-$Environment.tfplan"

$backendConfig = @(
    "bucket       = `"$stateBucketName`"",
    "key          = `"$projectName/bootstrap/terraform.tfstate`"",
    "region       = `"$awsRegion`"",
    "encrypt      = true",
    "use_lockfile = true",
    "kms_key_id   = `"$stateKmsKeyArn`""
) -join [Environment]::NewLine
[IO.File]::WriteAllText($backendConfigPath, "$backendConfig$([Environment]::NewLine)")

$terraformVariables = [ordered]@{
    project_name                      = $projectName
    environment                       = $Environment
    aws_region                        = $awsRegion
    state_bucket_name                 = $stateBucketName
    state_kms_key_arn                 = $stateKmsKeyArn
    existing_github_oidc_provider_arn = "arn:aws:iam::${expectedAccountId}:oidc-provider/token.actions.githubusercontent.com"
    github_organization               = $githubOrganization
    github_organization_id            = $githubOrganizationId
    github_repository_ids             = $repositoryIds
    tags                              = [ordered]@{
        Owner      = "VetSoftware"
        CostCenter = $Environment
    }
}
[IO.File]::WriteAllText(
    $variablesPath,
    "$($terraformVariables | ConvertTo-Json -Depth 6)$([Environment]::NewLine)"
)

Invoke-ExternalCommand -Command "terraform" -Arguments @(
    "-chdir=$bootstrapDirectory", "init", "-input=false", "-reconfigure", "-backend-config=$backendConfigPath"
)
Invoke-ExternalCommand -Command "terraform" -Arguments @(
    "-chdir=$bootstrapDirectory", "validate", "-no-color"
)

& terraform "-chdir=$bootstrapDirectory" plan `
    -input=false `
    -lock-timeout=5m `
    -detailed-exitcode `
    -out=$planPath `
    -var-file=$variablesPath
$planExitCode = $LASTEXITCODE
if ($planExitCode -eq 1) {
    throw "Terraform no pudo generar el plan de bootstrap $Environment."
}
if ($planExitCode -notin @(0, 2)) {
    throw "Terraform plan devolvio el codigo inesperado $planExitCode."
}

Invoke-ExternalCommand -Command "terraform" -Arguments @(
    "-chdir=$bootstrapDirectory", "show", "-no-color", $planPath
)

if ($planExitCode -eq 2) {
    Invoke-ExternalCommand -Command "terraform" -Arguments @(
        "-chdir=$bootstrapDirectory", "apply", "-input=false", "-lock-timeout=5m", $planPath
    )
}
else {
    Write-Host "Bootstrap $Environment sin cambios; no se ejecuto apply." -ForegroundColor Green
}

$outputsJson = & terraform "-chdir=$bootstrapDirectory" output -json
if ($LASTEXITCODE -ne 0) {
    throw "No fue posible leer los outputs del bootstrap $Environment."
}
Write-Host $outputsJson

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    @(
        "## Terraform bootstrap $Environment",
        "",
        "- AWS account: ``$expectedAccountId``",
        "- State bucket: ``$stateBucketName``",
        "- Bootstrap state key: ``$projectName/bootstrap/terraform.tfstate``",
        "- Infrastructure state key: ``$projectName/$Environment/terraform.tfstate``",
        "- KMS key: ``$stateKmsKeyArn``",
        "- Terraform changes applied: ``$($planExitCode -eq 2)``"
    ) | Add-Content -Path $env:GITHUB_STEP_SUMMARY
}
