[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [string]$EnvironmentName,

  [Parameter(Mandatory = $false)]
  [string]$ResourceGroupName,

  [Parameter(Mandatory = $false)]
  [string]$TenantId,

  [Parameter(Mandatory = $false)]
  [string]$SecurityGroupObjectId,

  [Parameter(Mandatory = $false)]
  [string]$SecurityGroupDisplayName,

  [Parameter(Mandatory = $false)]
  [ValidateSet('Minimal', 'Full', 'Extended')]
  [string]$PermissionProfile = 'Full',

  [Parameter(Mandatory = $false)]
  [switch]$IncludeExchange,

  [Parameter(Mandatory = $false)]
  [switch]$IncludeTeams,

  [Parameter(Mandatory = $false)]
  [switch]$IncludeAzure,

  [Parameter(Mandatory = $false)]
  [string[]]$AzureScopes,

  [switch]$IncludeMailSend,
  [switch]$IncludeReportSettingsWrite,
  [switch]$Apply,
  [string]$ApprovedPlanHash,
  [switch]$InteractiveConsent,
  [switch]$AllowInteractiveGraphLogin,
  [switch]$AllowGraphContextReplacement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $projectRoot

Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-SetupHelpers.psm1') -Force


# ──────────────────────────────────────────────
# Resolve parameters from environment
# ──────────────────────────────────────────────

if (-not $SubscriptionId) {
  $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
}
if (-not $SubscriptionId) {
  throw 'SubscriptionId is required. Pass -SubscriptionId or set AZURE_SUBSCRIPTION_ID.'
}

if (-not $TenantId -and $env:AZURE_TENANT_ID) {
  $TenantId = $env:AZURE_TENANT_ID
}

if ([string]::IsNullOrWhiteSpace($TenantId)) { throw 'TenantId is required. Pass -TenantId or set AZURE_TENANT_ID.' }
$azAccount = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
$TenantId = $azAccount.tenantId
$armToken = az account get-access-token --subscription $SubscriptionId --resource https://management.azure.com/ --query accessToken -o tsv
$armHeaders = @{ Authorization = "Bearer $armToken" }
if (-not $EnvironmentName) {
  $EnvironmentName = if ($env:AZURE_ENV_NAME) { $env:AZURE_ENV_NAME } else { 'dev' }
}
if (-not $PSBoundParameters.ContainsKey('PermissionProfile') -and $env:PERMISSION_PROFILE) {
  $envPermissionProfile = $env:PERMISSION_PROFILE.Trim()
  if ($envPermissionProfile -notin @('Minimal', 'Full', 'Extended')) {
    throw "PERMISSION_PROFILE must be 'Minimal', 'Full', or legacy 'Extended'. Current value: '$envPermissionProfile'."
  }
  $PermissionProfile = $envPermissionProfile
}
if (-not $SecurityGroupObjectId) {
  if ($env:SECURITY_GROUP_OBJECT_ID) {
    $SecurityGroupObjectId = $env:SECURITY_GROUP_OBJECT_ID
  }
  elseif ($env:EASY_AUTH_SECURITY_GROUP_OBJECT_ID) {
    $SecurityGroupObjectId = $env:EASY_AUTH_SECURITY_GROUP_OBJECT_ID
  }
}
if (-not $SecurityGroupDisplayName -and $env:SECURITY_GROUP_DISPLAY_NAME) {
  $SecurityGroupDisplayName = $env:SECURITY_GROUP_DISPLAY_NAME
}

# Capability selection is distinct from approval of the resulting concrete plan.
foreach ($capability in @('IncludeMailSend', 'IncludeReportSettingsWrite')) {
  $environmentKey = if ($capability -eq 'IncludeMailSend') { 'INCLUDE_MAIL_SEND' } else { 'INCLUDE_REPORT_SETTINGS_WRITE' }
  if (-not $PSBoundParameters.ContainsKey($capability)) {
    $value = [Environment]::GetEnvironmentVariable($environmentKey)
    if ($null -ne $value -and $value -notin @('true', 'false')) { throw "$environmentKey must be true or false." }
    Set-Variable -Name $capability -Value ($value -eq 'true')
  }
}

if (-not $PSBoundParameters.ContainsKey('IncludeExchange')) {
  $IncludeExchange = ConvertTo-BoolOrDefault -Value $env:INCLUDE_EXCHANGE -Default $false
}
if (-not $PSBoundParameters.ContainsKey('IncludeTeams')) {
  $IncludeTeams = ConvertTo-BoolOrDefault -Value $env:INCLUDE_TEAMS -Default $false
}
if (-not $PSBoundParameters.ContainsKey('IncludeAzure')) {
  $IncludeAzure = ConvertTo-BoolOrDefault -Value $env:INCLUDE_AZURE -Default $false
}

if (-not $PSBoundParameters.ContainsKey('AzureScopes')) {
  if ($env:AZURE_RBAC_SCOPES) {
    $rawScopes = $env:AZURE_RBAC_SCOPES.Trim()
    if ($rawScopes.StartsWith('[')) {
      try {
        $parsed = $rawScopes | ConvertFrom-Json
        if ($parsed -is [string]) {
          $AzureScopes = @($parsed)
        }
        elseif ($parsed) {
          $AzureScopes = @($parsed)
        }
      }
      catch {
        Write-Warning "AZURE_RBAC_SCOPES looked like JSON but could not be parsed. Falling back to ';' splitting. Value: $rawScopes"
        $AzureScopes = @($rawScopes -split ';' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      }
    }
    else {
      $AzureScopes = @($rawScopes -split ';' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
  }
}

if ($IncludeAzure -and (-not $AzureScopes -or $AzureScopes.Count -eq 0)) {
  $AzureScopes = @("/subscriptions/$SubscriptionId")
}

$securityGroupSource = 'parameter'
if (-not $PSBoundParameters.ContainsKey('SecurityGroupObjectId') -and -not $PSBoundParameters.ContainsKey('SecurityGroupDisplayName')) {
  if ($env:SECURITY_GROUP_OBJECT_ID -or $env:EASY_AUTH_SECURITY_GROUP_OBJECT_ID) {
    $securityGroupSource = 'environment'
  }
}

$resolvedResourceGroupName = if ($ResourceGroupName) { $ResourceGroupName } elseif ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { "rg-$EnvironmentName" }

. (Join-Path $PSScriptRoot 'Resolve-DeploymentTargets.ps1')
$deploymentValues = Get-MaesterDeploymentValues -EnvironmentName $EnvironmentName -SubscriptionId $SubscriptionId -ResourceGroupName $resolvedResourceGroupName
$targets = Resolve-MaesterDeploymentTargets -EnvironmentValues $deploymentValues -SubscriptionId $SubscriptionId -ResourceGroupName $resolvedResourceGroupName -EnvironmentName $EnvironmentName -SolutionName 'container-app-job' -GetResource {
  param($path)
  Invoke-RestMethod -Method GET -Uri "https://management.azure.com$path" -Headers $armHeaders
}
$storageAccount = $targets.StorageAccount
$webApp = $targets.WebApp
$containerAppJob = Resolve-MaesterMainDeploymentTarget -EnvironmentValues $deploymentValues `
  -NameOutput 'containerAppJobName' -PrincipalOutput 'containerAppJobPrincipalId' `
  -ProviderType 'Microsoft.App/jobs' -ApiVersion '2024-03-01' `
  -SubscriptionId $SubscriptionId -ResourceGroupName $resolvedResourceGroupName `
  -EnvironmentName $EnvironmentName -SolutionName 'container-app-job' -GetResource {
    param($path)
    Invoke-RestMethod -Method GET -Uri "https://management.azure.com$path" -Headers $armHeaders
  }
$containerAppJobName = [string]$containerAppJob.name
$principalId = [string]$containerAppJob.identity.principalId

# Access planning runs only after every deployment target and ownership guard.
Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-ConsentPlan.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Maester-SetupConsent.psm1') -Force
$includeWebApp = $null -ne $webApp
if ($AllowGraphContextReplacement -and -not $AllowInteractiveGraphLogin) {
  throw 'Context replacement requires explicit -AllowInteractiveGraphLogin and -AllowGraphContextReplacement.'
}
if ($InteractiveConsent -and -not $AllowInteractiveGraphLogin) {
  if ($env:CI -eq 'true' -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected) {
    throw 'Interactive setup is unavailable. Generate a plan with an existing session, then pass -Apply -ApprovedPlanHash.'
  }
  $answer = Read-Host "Allow normal browser sign-in if needed for setup account '$env:MAESTER_SETUP_ACCOUNT' and tenant '$TenantId'? [y/N]"
  $AllowInteractiveGraphLogin = $answer -match '^(?i:y|yes)$'
}
Assert-GraphAccess -TenantId $TenantId -ClientId $env:MAESTER_SETUP_CLIENT_ID -ExpectedAccount $env:MAESTER_SETUP_ACCOUNT `
  -Scopes (Get-MaesterSetupScopes -IncludeTeams:$IncludeTeams -IncludeWebApp:$includeWebApp) `
  -AllowInteractive:$AllowInteractiveGraphLogin -AllowContextReplacement:$AllowGraphContextReplacement

if ($IncludeExchange) {
  # Reading Exchange RBAC is mandatory before approval. No best-effort fallback
  # can convert a missing module or failed inventory into a grant.
  if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    throw 'Install the reviewed ExchangeOnlineManagement module before planning Exchange access.'
  }
  $organization = Invoke-GraphRestRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=verifiedDomains'
  $domains = @($organization.value | ForEach-Object { $_.verifiedDomains } | Where-Object { $_.isInitial -eq $true })
  if ($domains.Count -ne 1) { throw 'Exactly one initial tenant domain is required to inspect Exchange access.' }
  Connect-ExchangeOnlineSilent -Organization $domains[0].name -TenantId $TenantId
}
$accessPlanParameters = @{
  TenantId = $TenantId; SubscriptionId = $SubscriptionId; PrincipalObjectId = $principalId
  ResourceId = $containerAppJob.id; StorageAccount = $storageAccount; WebApp = $webApp; ArmHeaders = $armHeaders
  SecurityGroupObjectId = $SecurityGroupObjectId; SecurityGroupDisplayName = $SecurityGroupDisplayName
  PermissionProfile = $PermissionProfile; IncludeMailSend = [bool]$IncludeMailSend
  IncludeReportSettingsWrite = [bool]$IncludeReportSettingsWrite
  IncludeExchange = $IncludeExchange; IncludeTeams = $IncludeTeams; IncludeAzure = $IncludeAzure; AzureScopes = $AzureScopes
}
$accessPlan = Get-MaesterSetupAccessPlan @accessPlanParameters
Write-Host ($accessPlan | ConvertTo-Json -Depth 30)
if ($InteractiveConsent) {
  $ApprovedPlanHash = Confirm-MaesterConsentPlan -Plan $accessPlan
  $Apply = $true
}
if (-not $Apply) {
  Write-Host 'Plan only. No setup grants, application changes, uploads, or receipts were written. Review the plan and rerun with -Apply -ApprovedPlanHash.'
  return $accessPlan
}
$accessResult = Invoke-MaesterSetupAccessPlan -PlanParameters $accessPlanParameters -ApprovedPlanHash $ApprovedPlanHash
Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'CONTAINER_JOB_MI_PRINCIPAL_ID' -Value $principalId
Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'CONTAINER_JOB_NAME' -Value $containerAppJobName
$exchangeSetupStatus = if ($IncludeExchange) { 'configured' } else { 'disabled' }
$teamsSetupStatus = if ($IncludeTeams) { 'configured' } else { 'disabled' }
$azureSetupStatus = if ($IncludeAzure) { 'configured' } else { 'disabled' }
Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'SETUP_EXCHANGE_STATUS' -Value $exchangeSetupStatus
Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'SETUP_TEAMS_STATUS' -Value $teamsSetupStatus
Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'SETUP_AZURE_STATUS' -Value $azureSetupStatus
foreach ($receiptName in @('EXO_APPROLE_ASSIGNMENT_IDS', 'TEAMS_READER_ROLE_ASSIGNMENT_IDS', 'AZURE_ROLE_ASSIGNMENT_IDS')) {
  Set-MaesterAzdEnvJsonArray -EnvironmentName $EnvironmentName -Name $receiptName -Values @($accessResult.Receipts[$receiptName])
}
if ($IncludeExchange) {
  Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'EXO_SERVICE_PRINCIPAL_DISPLAY_NAME' -Value $accessResult.PrincipalDisplayName
}
if ($accessResult.EasyAuth) {
  Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'EASY_AUTH_ENTRA_APP_OBJECT_ID' -Value $accessResult.EasyAuth.objectId
  Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'EASY_AUTH_ENTRA_APP_CLIENT_ID' -Value $accessResult.EasyAuth.clientId
  Set-MaesterAzdEnvValue -EnvironmentName $EnvironmentName -Name 'EASY_AUTH_ENTRA_APP_DISPLAY_NAME' -Value $accessResult.EasyAuth.displayName
  $SecurityGroupObjectId = $accessResult.EasyAuth.securityGroupId
}

# ──────────────────────────────────────────────
# Upload runner script to Azure Files share
# ──────────────────────────────────────────────

$storageAccountName = $storageAccount.name
$storageKeyPath = "/subscriptions/$SubscriptionId/resourceGroups/$resolvedResourceGroupName/providers/Microsoft.Storage/storageAccounts/$storageAccountName/listKeys?api-version=2023-05-01"
$storageKeysResponse = Invoke-RestMethod -Method POST -Uri "https://management.azure.com$storageKeyPath" -Headers $armHeaders -Body '{}' -ContentType 'application/json'
$storageKey = $storageKeysResponse.keys[0].value

$includeACR = ConvertTo-BoolOrDefault -Value $env:INCLUDE_ACR -Default $false
Import-Module (Join-Path $PSScriptRoot 'Maester-RuntimeFiles.psm1') -Force
Publish-MaesterRuntimeFiles -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroupName $resolvedResourceGroupName -StorageAccountName $storageAccountName -StorageKey $storageKey -ProjectRoot $projectRoot -IncludeACR:$includeACR

Write-Host "Uploaded locked runner files to Azure Files share 'scripts/$storageAccountName'."

# ──────────────────────────────────────────────
# Optional: Build and push ACR image
# ──────────────────────────────────────────────

$includeACR = ConvertTo-BoolOrDefault -Value $env:INCLUDE_ACR -Default $false
if ($includeACR) {
  & "$PSScriptRoot\Build-MaesterImage.ps1" `
    -SubscriptionId $SubscriptionId `
    -TenantId $TenantId `
    -ResourceGroupName $resolvedResourceGroupName `
    -EnvironmentName $EnvironmentName `
    -ContainerAppJobName $containerAppJobName `
    -AcrName $env:ACR_NAME
}

