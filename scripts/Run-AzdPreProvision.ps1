[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'vendor\Azd.MaesterHooks\Maester-PreProvision.psm1') -Force

if (-not $TenantId) { $TenantId = $env:AZURE_TENANT_ID }
if ([string]::IsNullOrWhiteSpace($TenantId)) { throw 'TenantId is required. Pass -TenantId or set AZURE_TENANT_ID.' }

# Read-only migration inventory precedes the wizard and ownership writes. An old
# incremental deployment cannot silently retain keyed mounts or inherited grants.
if (-not $SubscriptionId) { $SubscriptionId = $env:AZURE_SUBSCRIPTION_ID }
$targetGroup = if ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { "rg-$env:AZURE_ENV_NAME" }
Import-Module (Join-Path $PSScriptRoot 'Maester-KeylessMigration.psm1') -Force
Assert-MaesterKeylessProvisioning -SubscriptionId $SubscriptionId -TenantId $TenantId `
  -ResourceGroupName $targetGroup -EnvironmentName $env:AZURE_ENV_NAME

Invoke-MaesterPreProvision `
  -SolutionName 'container-app-job' `
  -SubscriptionId $SubscriptionId `
  -TenantId $TenantId `
  -Location $env:AZURE_LOCATION

# Capture infrastructure separately from optional Graph/setup. Only this hook's
# exact HTTP 201 response can establish fresh dedicated resource-group ownership.
Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-InfrastructureOwnership.psm1') -Force
Initialize-MaesterInfrastructureOwnership -ProjectRoot (Split-Path $PSScriptRoot -Parent) `
  -EnvironmentName $env:AZURE_ENV_NAME -SolutionName 'container-app-job' `
  -TenantId $TenantId -SubscriptionId $SubscriptionId | Out-Null
