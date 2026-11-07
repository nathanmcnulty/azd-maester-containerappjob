Describe 'Resource-group metadata preservation before ARM declaration' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'scripts/Maester-ResourceGroupMetadata.psm1') -Force
    function global:az {
      $a = @($args); $global:LASTEXITCODE = 0
      $global:GroupMetadataFixture.Reads++
      if (($a -join ' ') -notlike "rest --method GET --uri $($global:GroupMetadataFixture.Id)?api-version=2022-09-01 --subscription $($global:GroupMetadataFixture.Sub) --output json --only-show-errors") { throw 'Unexpected or unscoped Azure command' }
      if ($global:GroupMetadataFixture.ReadFailure) { $global:LASTEXITCODE = 1; return '' }
      return ($global:GroupMetadataFixture.Group | ConvertTo-Json -Depth 10 -Compress)
    }
    function global:azd {
      $a = @($args); $global:LASTEXITCODE = 0
      if (($a -join ' ') -eq 'env get-values -e group-test --output json') { return ($global:GroupMetadataFixture.Values | ConvertTo-Json -Compress) }
      if ($a.Count -eq 6 -and ($a[0..2] -join ' ') -eq 'env set MAESTER_RESOURCE_GROUP_METADATA_BASE64' -and $a[4] -eq '-e' -and $a[5] -eq 'group-test') {
        $global:GroupMetadataFixture.WireValues.Add([string]$a[3]); $global:GroupMetadataFixture.Writes.Add(([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($a[3])) | ConvertFrom-Json -AsHashtable)); return
      }
      throw 'Unexpected local environment command'
    }
  }
  AfterAll {
    Remove-Item function:global:az, function:global:azd
    Remove-Module Maester-ResourceGroupMetadata -Force
    Remove-Variable GroupMetadataFixture -Scope Global
  }
  BeforeEach {
    $sub='11111111-1111-4111-8111-111111111111';$tenant='22222222-2222-4222-8222-222222222222'
    $id="/subscriptions/$sub/resourceGroups/rg-group-test"
    $global:GroupMetadataFixture=@{Sub=$sub;Tenant=$tenant;Id=$id;Reads=0;ReadFailure=$false;Writes=[Collections.Generic.List[object]]::new();WireValues=[Collections.Generic.List[string]]::new();Values=@{AZURE_ENV_NAME='group-test';AZURE_SUBSCRIPTION_ID=$sub;AZURE_TENANT_ID=$tenant;AZURE_RESOURCE_GROUP='rg-group-test'};Group=@{id=$id;name='rg-group-test';location='eastus2';tags=@{'maester-ownership-id'='33333333-3333-4333-8333-333333333333';'azd-env-name'='group-test';'existing-owner'='preserve';'unicode'='équipe'};properties=@{provisioningState='Succeeded'}}}
    $project=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path (Join-Path $project '.azure/group-test')
    $receiptPath=Join-Path $project '.azure/group-test/maester-infrastructure-ownership.json'
    @{state='Created';ownershipId='33333333-3333-4333-8333-333333333333';binding=@{environmentName='group-test';subscriptionId=$sub;tenantId=$tenant;resourceGroupId=$id}}|ConvertTo-Json -Depth 5|Set-Content $receiptPath
    $parameters=@{ProjectRoot=$project;EnvironmentName='group-test';SubscriptionId=$sub;TenantId=$tenant;ResourceGroupId=$id;FreshOwned=$true}
    Mock Get-AzCliSubscriptionContext -ModuleName Maester-ResourceGroupMetadata { @{id=$global:GroupMetadataFixture.Sub;tenantId=$global:GroupMetadataFixture.Tenant} }
  }
  It 'preserves every tag and actual group location without changing the ownership receipt' {
    $before=(Get-FileHash $receiptPath).Hash
    Set-MaesterResourceGroupMetadata @parameters
    $global:GroupMetadataFixture.Reads | Should -Be 1
    $global:GroupMetadataFixture.Writes.Count | Should -Be 1
    $saved=$global:GroupMetadataFixture.Writes[0]
    $saved.id | Should -BeExactly $parameters.ResourceGroupId
    $saved.location | Should -BeExactly 'eastus2'
    ($saved.tags|ConvertTo-Json -Compress) | Should -BeExactly ($global:GroupMetadataFixture.Group.tags|ConvertTo-Json -Compress)
    (Get-FileHash $receiptPath).Hash | Should -BeExactly $before
    Should -Invoke Get-AzCliSubscriptionContext -ModuleName Maester-ResourceGroupMetadata -Exactly 1 -ParameterFilter {$SubscriptionId -eq $global:GroupMetadataFixture.Sub -and $TenantId -eq $global:GroupMetadataFixture.Tenant}
  }
  It 'survives raw azd parameter substitution with quotes, backslashes and Unicode tags' {
    $global:GroupMetadataFixture.Group.tags['special'] = 'équipe "quoted" C:\path\item ${literal}'
    Set-MaesterResourceGroupMetadata @parameters
    $wire = $global:GroupMetadataFixture.WireValues[0]
    $wire | Should -Match '^[A-Za-z0-9+/]+={0,2}$'
    $mappingText = Get-Content (Join-Path $root 'infra/main.parameters.json') -Raw
    $resolved = $mappingText.Replace('${MAESTER_RESOURCE_GROUP_METADATA_BASE64}', $wire) | ConvertFrom-Json -AsHashtable
    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($resolved.parameters.resourceGroupMetadataBase64.value)) | ConvertFrom-Json -AsHashtable
    $decoded.tags.special | Should -BeExactly $global:GroupMetadataFixture.Group.tags.special
    $decoded.id | Should -BeExactly $parameters.ResourceGroupId
    $decoded.location | Should -BeExactly 'eastus2'
  }
  It 'preserves an unowned existing group without adding ownership' {
    $parameters.FreshOwned=$false;$global:GroupMetadataFixture.Group.tags=@{'existing-owner'='other-owner'}
    Set-MaesterResourceGroupMetadata @parameters
    $saved=$global:GroupMetadataFixture.Writes[0]
    $saved.tags.Count | Should -Be 1
    $saved.tags.ContainsKey('maester-ownership-id') | Should -BeFalse
  }
  It 'preserves an untagged existing group as an empty tag object' {
    $parameters.FreshOwned=$false;$global:GroupMetadataFixture.Group.tags=$null
    Set-MaesterResourceGroupMetadata @parameters
    $global:GroupMetadataFixture.Writes[0].tags.Count | Should -Be 0
  }
  It 'rejects mismatched selected <Field> before Azure reads or local writes' -ForEach @(
    @{Field='AZURE_SUBSCRIPTION_ID'},@{Field='AZURE_TENANT_ID'},@{Field='AZURE_ENV_NAME'},@{Field='AZURE_RESOURCE_GROUP'}
  ) {
    $global:GroupMetadataFixture.Values[$Field]='wrong-target'
    {Set-MaesterResourceGroupMetadata @parameters}|Should -Throw
    $global:GroupMetadataFixture.Reads|Should -Be 0
    $global:GroupMetadataFixture.Writes.Count|Should -Be 0
  }
  It 'rejects an ownership initializer target from another group' {
    $parameters.ResourceGroupId='/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/other'
    {Set-MaesterResourceGroupMetadata @parameters}|Should -Throw '*differs from ownership initialization*'
    $global:GroupMetadataFixture.Reads|Should -Be 0
  }
  It 'rejects <Case> without writing metadata' -ForEach @(
    @{Case='wrong returned group';Field='id';Value='/subscriptions/other/resourceGroups/other'},
    @{Case='wrong returned name';Field='name';Value='other'},
    @{Case='missing location';Field='location';Value=''},
    @{Case='invalid tags';Field='tags';Value='not-an-object'},
    @{Case='invalid tag value';Field='tags';Value=@{'maester-ownership-id'=@('array')}},
    @{Case='nonready group';Field='properties';Value=@{provisioningState='Deleting'}}
  ) {
    $global:GroupMetadataFixture.Group[$Field]=$Value
    {Set-MaesterResourceGroupMetadata @parameters}|Should -Throw
    $global:GroupMetadataFixture.Writes.Count|Should -Be 0
  }
  It 'rejects a changed fresh ownership marker without adopting it' {
    $global:GroupMetadataFixture.Group.tags['maester-ownership-id']='44444444-4444-4444-8444-444444444444'
    {Set-MaesterResourceGroupMetadata @parameters}|Should -Throw '*ownership marker differs*'
    $global:GroupMetadataFixture.Writes.Count|Should -Be 0
  }
  It 'rejects a failed Azure read without permission changes or writes' {
    $global:GroupMetadataFixture.ReadFailure=$true
    {Set-MaesterResourceGroupMetadata @parameters}|Should -Throw '*Could not read exact*'
    $global:GroupMetadataFixture.Writes.Count|Should -Be 0
  }
  It 'refuses a group managed by another Azure resource without rewriting ownership' {
    $parameters.FreshOwned=$false
    $global:GroupMetadataFixture.Group.managedBy='/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/other/providers/Microsoft.Solutions/applications/owner'
    {Set-MaesterResourceGroupMetadata @parameters}|Should -Throw '*managed by another Azure resource*'
    $global:GroupMetadataFixture.Writes.Count|Should -Be 0
  }
  It 'rejects a missing fresh receipt without adopting the live marker' {
    Remove-Item -LiteralPath $receiptPath
    {Set-MaesterResourceGroupMetadata @parameters}|Should -Throw
    $global:GroupMetadataFixture.Writes.Count|Should -Be 0
  }
  It 'rejects empty fresh ownership even when the live tag is also absent' {
    $receipt=Get-Content $receiptPath -Raw|ConvertFrom-Json -AsHashtable;$receipt.ownershipId=$null
    $receipt|ConvertTo-Json -Depth 5|Set-Content $receiptPath
    $global:GroupMetadataFixture.Group.tags.Remove('maester-ownership-id')
    {Set-MaesterResourceGroupMetadata @parameters}|Should -Throw '*ownership marker differs*'
    $global:GroupMetadataFixture.Writes.Count|Should -Be 0
  }
  It 'gates metadata reads on the existing selected CLI context' {
    Mock Get-AzCliSubscriptionContext -ModuleName Maester-ResourceGroupMetadata {throw 'Selected tenant is disabled'}
    {Set-MaesterResourceGroupMetadata @parameters}|Should -Throw '*disabled*'
    $global:GroupMetadataFixture.Reads|Should -Be 0
    $global:GroupMetadataFixture.Writes.Count|Should -Be 0
  }
}
