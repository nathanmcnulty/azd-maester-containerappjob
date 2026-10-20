# Read-only fail-closed gate. This module never rewrites ownership receipts,
# removes grants, disables keys, deletes storage registrations, or deletes data.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1')
. (Join-Path $PSScriptRoot 'Resolve-DeploymentTargets.ps1')

function Invoke-MaesterMigrationRead {
  param([string]$Path, [string]$GroupId, [string]$SubscriptionId, [string]$TenantId)
  if (-not $Path.StartsWith("$GroupId/", [StringComparison]::OrdinalIgnoreCase) -and $Path.Split('?')[0] -ine $GroupId) { throw 'Migration inventory escaped its selected resource group.' }
  if ($Path -match '[#\s]' -or $Path.Contains('..')) { throw 'Invalid migration inventory path.' }
  $token = Get-AzCliAccessToken -Resource 'https://management.azure.com/' -SubscriptionId $SubscriptionId -TenantId $TenantId
  if ([string]::IsNullOrWhiteSpace($token)) { throw 'No verified ARM token is available for migration inventory.' }
  try {
    try { $response = Invoke-WebRequest -Method GET -Uri "https://management.azure.com$Path" -Headers @{ Authorization = "Bearer $token" } -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 60 -OperationTimeoutSeconds 60 -ErrorAction Stop }
    catch { throw 'Unable to read the exact migration target. No migration or provisioning is permitted.' }
    if ($response.StatusCode -eq 404 -and $Path.Split('?')[0] -ieq $GroupId) { return $null }
    if ($response.StatusCode -ne 200) { throw 'Migration inventory is incomplete. No migration or provisioning is permitted.' }
    try { $value = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'Malformed migration inventory. No migration or provisioning is permitted.' }
    if ($value -isnot [Collections.IDictionary] -or $value['nextLink']) { throw 'Incomplete or paginated migration inventory. No migration or provisioning is permitted.' }
    return $value
  } finally { $token = $null }
}

function Assert-MaesterKeylessProvisioning {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_().-]{1,90}(?<!\.)$')][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$EnvironmentName
  )
  $ErrorActionPreference = 'Stop'
  $values = Get-MaesterDeploymentValues -EnvironmentName $EnvironmentName -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
  if ([string]$values['AZURE_TENANT_ID'] -ine $TenantId) { throw 'Migration tenant differs from the selected environment.' }
  $null = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
  $groupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
  $context = @{ GroupId = $groupId; SubscriptionId = $SubscriptionId; TenantId = $TenantId }
  $group = Invoke-MaesterMigrationRead @context -Path "${groupId}?api-version=2021-04-01"
  if ($null -eq $group) { return } # Exact RG 404 only; authentication failures are not absence.
  if ($group['id'] -ine $groupId) { throw 'Migration resource-group identity mismatch.' }
  $resources = Invoke-MaesterMigrationRead @context -Path "$groupId/resources?api-version=2021-04-01"
  if (-not $resources.Contains('value') -or $null -eq $resources['value']) { throw 'Missing migration resources inventory.' }
  $blockers = [Collections.Generic.List[string]]::new()
  $jobPrincipals = [Collections.Generic.List[string]]::new()
  $accounts = [Collections.Generic.List[object]]::new()
  foreach ($resource in $resources['value']) {
    $id = [string]$resource['id']
    if (-not $id.StartsWith("$groupId/providers/", [StringComparison]::OrdinalIgnoreCase) -or $id -match '[?#\s]' -or $id.Contains('..')) { throw 'Invalid resource in migration inventory.' }
    switch ([string]$resource['type']) {
      'Microsoft.App/jobs' {
        $job = Invoke-MaesterMigrationRead @context -Path "${id}?api-version=2024-03-01"
        if ($job['id'] -ine $id -or -not $job['properties'] -or -not $job['identity']['principalId']) { throw 'Incomplete job migration inventory.' }
        $jobPrincipals.Add([string]$job['identity']['principalId'])
        foreach ($volume in $job['properties']['template']['volumes']) {
          if ([string]$volume['storageType'] -in @('AzureFile', 'NfsAzureFile')) { $blockers.Add("Job volume: $id/$($volume['name'])") }
        }
      }
      'Microsoft.App/managedEnvironments' {
        $storages = Invoke-MaesterMigrationRead @context -Path "$id/storages?api-version=2024-03-01"
        if (-not $storages.Contains('value') -or $null -eq $storages['value']) { throw 'Missing environment storage inventory.' }
        foreach ($storage in $storages['value']) {
          if ($storage['properties']['azureFile'] -or [string]$storage['name'] -eq 'scriptstorage') { $blockers.Add("Environment storage: $($storage['id'])") }
        }
      }
      'Microsoft.Storage/storageAccounts' {
        $account = Invoke-MaesterMigrationRead @context -Path "${id}?api-version=2023-05-01"
        if ($account['id'] -ine $id -or -not $account['properties']) { throw 'Incomplete storage migration inventory.' }
        if ($account['properties']['allowSharedKeyAccess'] -ne $false) { $blockers.Add("Shared Key remains enabled: $id") }
        $accounts.Add($account)
      }
    }
  }
  foreach ($account in $accounts) {
    # atScope() includes ancestors, not descendants (Authorization REST 2022-04-01).
    # https://learn.microsoft.com/rest/api/authorization/role-assignments/list-for-scope
    $roles = Invoke-MaesterMigrationRead @context -Path "$($account['id'])/providers/Microsoft.Authorization/roleAssignments?`$filter=atScope()&api-version=2022-04-01"
    if (-not $roles.Contains('value') -or $null -eq $roles['value']) { throw 'Missing role assignment migration inventory.' }
    foreach ($role in $roles['value']) {
      if ($role['properties']['principalId'] -in $jobPrincipals -and
          ([string]$role['properties']['roleDefinitionId']).Split('/')[-1] -in @('ba92f5b4-2d11-453d-a403-e96b0029c9fe', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')) {
        $blockers.Add("Broad job Blob writer (Contributor/Owner): $($role['id'])")
      }
    }
  }
  if ($blockers.Count) {
    throw ("Keyless migration requires a separately reviewed, receipt-aware plan before provisioning. Preserve retained shares, grants and prior ownership receipts; this check changes nothing. Blockers: " + ($blockers -join '; '))
  }
}
Export-ModuleMember -Function Assert-MaesterKeylessProvisioning
