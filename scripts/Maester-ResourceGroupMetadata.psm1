# Capture existing group metadata for the subscription deployment declaration.
# No cloud mutation or ownership adoption occurs here.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1')

function Set-MaesterResourceGroupMetadata {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')][string]$EnvironmentName,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroupId,
    [Parameter(Mandatory)][bool]$FreshOwned
  )
  Push-Location -LiteralPath $ProjectRoot
  try { $raw = & azd env get-values -e $EnvironmentName --output json; $exitCode = $LASTEXITCODE }
  finally { Pop-Location }
  if ($exitCode -ne 0) { throw 'Could not read selected environment for resource-group metadata.' }
  $values = ($raw -join "`n") | ConvertFrom-Json -AsHashtable -ErrorAction Stop
  $groupName = [string]$values['AZURE_RESOURCE_GROUP']
  if ($values['AZURE_ENV_NAME'] -cne $EnvironmentName -or $values['AZURE_SUBSCRIPTION_ID'] -ine $SubscriptionId.ToString() -or
      $values['AZURE_TENANT_ID'] -ine $TenantId.ToString() -or $groupName -cnotmatch '^[A-Za-z0-9_().-]{1,90}$' -or $groupName.EndsWith('.')) {
    throw 'Selected environment differs from the resource-group metadata target.'
  }
  $expectedId = "/subscriptions/$SubscriptionId/resourceGroups/$groupName"
  if ($ResourceGroupId -ine $expectedId) { throw 'Resource-group metadata target differs from ownership initialization.' }
  $null = Get-AzCliSubscriptionContext -SubscriptionId $SubscriptionId -TenantId $TenantId
  $raw = & az rest --method GET --uri "${expectedId}?api-version=2022-09-01" --subscription $SubscriptionId --output json --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw 'Could not read exact resource-group metadata; no deployment metadata was saved.' }
  $group = ($raw -join "`n") | ConvertFrom-Json -AsHashtable -ErrorAction Stop
  if ($group -isnot [Collections.IDictionary] -or $group['properties'] -isnot [Collections.IDictionary] -or
      $group['id'] -ine $expectedId -or $group['name'] -ine $groupName -or $group['location'] -isnot [string] -or
      $group['location'] -cnotmatch '^[a-z0-9]+$' -or $group['properties']['provisioningState'] -cne 'Succeeded') {
    throw 'Resource-group metadata identity or readiness differs.'
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$group['managedBy'])) {
    throw 'A group managed by another Azure resource is not supported by the default launcher; its metadata was not saved or changed.'
  }
  $tags = if ($null -eq $group['tags']) { @{} } else { $group['tags'] }
  if ($tags -isnot [Collections.IDictionary] -or @($tags.Values | Where-Object { $_ -isnot [string] }).Count) { throw 'Invalid resource-group tags.' }
  if ($FreshOwned) {
    $receiptPath = Join-Path $ProjectRoot ".azure/$EnvironmentName/maester-infrastructure-ownership.json"
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $owner = [guid]::Empty
    if ($receipt['state'] -cnotin @('Created','Ready') -or $receipt['binding']['resourceGroupId'] -ine $expectedId -or
        $receipt['binding']['environmentName'] -cne $EnvironmentName -or $receipt['binding']['tenantId'] -ine $TenantId.ToString() -or
        $receipt['binding']['subscriptionId'] -ine $SubscriptionId.ToString() -or
        -not [guid]::TryParse([string]$receipt['ownershipId'], [ref]$owner) -or $owner -eq [guid]::Empty -or
        $tags['maester-ownership-id'] -cne $receipt['ownershipId']) {
      throw 'Fresh resource-group ownership marker differs; metadata was not saved.'
    }
  }
  $snapshot = [ordered]@{ id = $expectedId; location = $group['location']; tags = $tags }
  Push-Location -LiteralPath $ProjectRoot
  try {
    & azd env set MAESTER_RESOURCE_GROUP_METADATA ($snapshot | ConvertTo-Json -Depth 5 -Compress) -e $EnvironmentName
    if ($LASTEXITCODE -ne 0) { throw 'Could not save selected resource-group metadata.' }
  } finally { Pop-Location }
}

Export-ModuleMember -Function Set-MaesterResourceGroupMetadata
