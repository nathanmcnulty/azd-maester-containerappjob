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

Invoke-MaesterPreProvision `
  -SolutionName 'container-app-job' `
  -SubscriptionId $SubscriptionId `
  -TenantId $TenantId `
  -Location $env:AZURE_LOCATION
