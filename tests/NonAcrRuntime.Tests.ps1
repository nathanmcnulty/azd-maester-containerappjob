BeforeAll {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $repoRoot 'scripts/Maester-RuntimeFiles.psm1') -Force
  function global:az {
    $global:LASTEXITCODE = 0
    if (($args[0..2] -join ' ') -eq 'storage account show') { return ($global:RuntimeTest.Storage | ConvertTo-Json -Compress) }
    if (($args[0..1] -join ' ') -eq 'account get-access-token') { return $global:RuntimeTest.Token }
    throw 'Unexpected external command.'
  }
}
AfterAll { Remove-Item Function:\az; Remove-Variable RuntimeTest -Scope Global }
Describe 'Content-addressed keyless runtime publisher' {
  BeforeEach {
    $global:RuntimeTest = @{
      Storage = @{ id = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/teststorage'; name = 'teststorage'; type = 'Microsoft.Storage/storageAccounts'; resourceGroup = 'test'; allowSharedKeyAccess = $false }
      Token = 'not-used'
    }
    $script:target = @{ SubscriptionId = '11111111-1111-4111-8111-111111111111'; TenantId = '22222222-2222-4222-8222-222222222222'; ResourceGroupName = 'test'; StorageAccountName = 'teststorage'; OperatorObjectId = '33333333-3333-4333-8333-333333333333' }
    Mock Get-AzCliSubscriptionContext -ModuleName Maester-RuntimeFiles { @{ id = $SubscriptionId; tenantId = $TenantId } }
    Mock Get-MaesterPublisherToken -ModuleName Maester-RuntimeFiles { 'fixture-token' }
    Mock New-MaesterRuntimeStaging -ModuleName Maester-RuntimeFiles {
      $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString()); New-Item -ItemType Directory $dir | Out-Null
      Set-Content (Join-Path $dir 'runner') 'verified test'; @{ Path = $dir; Files = @('runner') }
    }
    Mock Invoke-MaesterBlobRequest -ModuleName Maester-RuntimeFiles { if ($Method -eq 'PUT') { 201 } else { 200 } }
  }
  It 'publishes a canonical hash path and independently reads it back' {
    $result = Publish-MaesterRuntimeFiles @target
    $result.BlobName | Should -BeExactly "bundles/$($result.Sha256).zip"
    $result.Sha256 | Should -Match '^[a-f0-9]{64}$'
    $result.Size | Should -BeGreaterThan 0
    Should -Invoke Invoke-MaesterBlobRequest -ModuleName Maester-RuntimeFiles -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' -and $Uri.Host -eq 'teststorage.blob.core.windows.net' -and $Uri.AbsolutePath -match '^/runtime/bundles/[a-f0-9]{64}.zip$' -and $Token -eq 'fixture-token' }
    Should -Invoke Invoke-MaesterBlobRequest -ModuleName Maester-RuntimeFiles -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' }
  }
  It 'verifies a pre-existing immutable blob rather than overwriting it' {
    Mock Invoke-MaesterBlobRequest -ModuleName Maester-RuntimeFiles { if ($Method -eq 'PUT') { 412 } else { 200 } }
    $null = Publish-MaesterRuntimeFiles @target
    Should -Invoke Invoke-MaesterBlobRequest -ModuleName Maester-RuntimeFiles -Times 2 -Exactly
  }
  It 'fails an existing blob whose readback does not verify' {
    Mock Invoke-MaesterBlobRequest -ModuleName Maester-RuntimeFiles { if ($Method -eq 'PUT') { 409 } else { throw 'readback mismatch' } }
    { Publish-MaesterRuntimeFiles @target } | Should -Throw '*readback mismatch*'
  }
  It 'rejects mismatched or key-enabled account before staging: <Property>' -ForEach @(@{Property='id'; Value='wrong'}, @{Property='name';Value='wrong'}, @{Property='type';Value='wrong'}, @{Property='resourceGroup';Value='wrong'}, @{Property='allowSharedKeyAccess';Value=$true}) {
    $global:RuntimeTest.Storage[$Property] = $Value
    { Publish-MaesterRuntimeFiles @target } | Should -Throw '*keyless target*'
    Should -Invoke New-MaesterRuntimeStaging -ModuleName Maester-RuntimeFiles -Times 0 -Exactly
  }
  It 'does not fall back after bounded role propagation retries' {
    Mock Invoke-MaesterBlobRequest -ModuleName Maester-RuntimeFiles { 403 }
    Mock Start-Sleep -ModuleName Maester-RuntimeFiles {}
    { Publish-MaesterRuntimeFiles @target } | Should -Throw '*HTTP 403*'
    Should -Invoke Invoke-MaesterBlobRequest -ModuleName Maester-RuntimeFiles -Times 7 -Exactly
    Should -Invoke Start-Sleep -ModuleName Maester-RuntimeFiles -Times 6 -Exactly
  }
  It 'does not retry permanent HTTP failures or follow redirects' {
    Mock Invoke-MaesterBlobRequest -ModuleName Maester-RuntimeFiles { 302 }
    { Publish-MaesterRuntimeFiles @target } | Should -Throw '*HTTP 302*'
    Should -Invoke Invoke-MaesterBlobRequest -ModuleName Maester-RuntimeFiles -Times 1 -Exactly
  }
  It 'makes deterministic archives despite file timestamp changes' {
    $dir = Join-Path $TestDrive 'deterministic'; New-Item -ItemType Directory $dir | Out-Null; Set-Content (Join-Path $dir 'a') 'fixed bytes'
    $first = New-MaesterRuntimeBundle -Staging @{ Path = $dir; Files = @('a') }
    Remove-Item $first.Path
    (Get-Item (Join-Path $dir 'a')).LastWriteTime = [DateTime]::Now.AddDays(-1)
    $second = New-MaesterRuntimeBundle -Staging @{ Path = $dir; Files = @('a') }
    $second.Sha256 | Should -BeExactly $first.Sha256
  }
  It 'contains no key/SAS credential resolution or moving manifest path' {
    $source = Get-Content (Join-Path $repoRoot 'scripts/Maester-RuntimeFiles.psm1') -Raw
    $source | Should -Not -Match 'StorageKey|listKeys|AZURE_STORAGE_KEY|storage file upload|--auth-mode key'
    $source | Should -Match 'AllowAutoRedirect = \$false'
    $source | Should -Match "'If-None-Match', '\*'"
    $source | Should -Not -Match 'latest\.json'
  }
}
Describe 'Verified operator tokens' {
  BeforeEach {
    Mock Get-AzCliSubscriptionContext -ModuleName Maester-RuntimeFiles { @{} }
    $global:RuntimeTest = @{ Token = '' }
  }
  It 'binds token to tenant, operator, resource, and expiry: <Case>' -ForEach @(@{Case='valid'}, @{Case='tenant'}, @{Case='operator'}, @{Case='audience'}, @{Case='expiry'}, @{Case='malformed'}) {
    $claims = @{ tid = 'tenant'; oid = 'operator'; aud = 'https://storage.azure.com'; exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600 }
    switch ($Case) { tenant { $claims.tid='other' }; operator { $claims.oid='other' }; audience { $claims.aud='https://graph.microsoft.com' }; expiry { $claims.exp=1 } }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    $global:RuntimeTest.Token = "header.$encoded.signature"
    if ($Case -eq 'malformed') { $global:RuntimeTest.Token = 'bad' }
    if ($Case -eq 'valid') { & (Get-Module Maester-RuntimeFiles) { Get-MaesterPublisherToken -SubscriptionId sub -TenantId tenant -OperatorObjectId operator } | Should -BeExactly $global:RuntimeTest.Token }
    else { { & (Get-Module Maester-RuntimeFiles) { Get-MaesterPublisherToken -SubscriptionId sub -TenantId tenant -OperatorObjectId operator } } | Should -Throw '*approved publishing operator*' }
  }
}
Describe 'Coherent job template activation' {
  BeforeEach {
    $script:pinTarget = @{ SubscriptionId='11111111-1111-4111-8111-111111111111'; TenantId='22222222-2222-4222-8222-222222222222'; OperatorObjectId='33333333-3333-4333-8333-333333333333'; RuntimePrincipalId='44444444-4444-4444-8444-444444444444'; ResourceGroupName='test'; JobName='job'; Bundle=@{StorageAccountName='teststorage'; Sha256=('a'*64); BlobName=('bundles/'+('a'*64)+'.zip');Size=100} }
    $global:RuntimeTest = @{ Gets=0; Body=$null; Changed=$false; WrongPrincipal=$false; WrongReadback=$false }
    Mock Get-AzCliSubscriptionContext -ModuleName Maester-RuntimeFiles { @{} }
    Mock Get-MaesterPublisherToken -ModuleName Maester-RuntimeFiles { 'fixture-token' }
    Mock Invoke-RestMethod -ModuleName Maester-RuntimeFiles {
      if ($Method -eq 'PATCH') { $global:RuntimeTest.Body = $Body | ConvertFrom-Json; return }
      $global:RuntimeTest.Gets++
      $template = if ($global:RuntimeTest.Body) { $global:RuntimeTest.Body.properties.template } else { [pscustomobject]@{ containers = @([pscustomobject]@{ name='maester'; image='pinned'; env=@(@{name='UNRELATED';value='preserve'}); resources=@{cpu=1} }); volumes=@() } }
      if ($global:RuntimeTest.Changed -and $global:RuntimeTest.Gets -eq 2) { $template.containers[0].image = 'changed' }
      if ($global:RuntimeTest.WrongReadback -and $global:RuntimeTest.Gets -eq 3) { $template.containers[0].env=@() }
      @{id='/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/test/providers/Microsoft.App/jobs/job';identity=@{principalId=$(if ($global:RuntimeTest.WrongPrincipal) {'wrong'} else {'44444444-4444-4444-8444-444444444444'})};properties=@{template=$template} }
    }
  }
  It 'sets all pins in one PATCH, preserving unrelated values, with readback' {
    Set-MaesterRuntimeBundlePin @pinTarget
    $global:RuntimeTest.Gets | Should -Be 3
    $envs = $global:RuntimeTest.Body.properties.template.containers[0].env
    @($envs).Count | Should -Be 5
    ($envs | Where-Object name -EQ UNRELATED).value | Should -BeExactly 'preserve'
    ($envs | Where-Object name -EQ MAESTER_RUNTIME_SHA256).value | Should -BeExactly ('a'*64)
    Should -Invoke Invoke-RestMethod -ModuleName Maester-RuntimeFiles -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' -and $MaximumRedirection -eq 0 }
  }
  It 'rejects changed template before writing' {
    $global:RuntimeTest.Changed=$true
    { Set-MaesterRuntimeBundlePin @pinTarget } | Should -Throw '*Inspect the selected job*'
    Should -Invoke Invoke-RestMethod -ModuleName Maester-RuntimeFiles -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
  }
  It 'rejects a recreated identity before writing' {
    $global:RuntimeTest.WrongPrincipal=$true
    { Set-MaesterRuntimeBundlePin @pinTarget } | Should -Throw
    Should -Invoke Invoke-RestMethod -ModuleName Maester-RuntimeFiles -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
  }
  It 'reports uncertain activation rather than retrying on mismatched readback' {
    $global:RuntimeTest.WrongReadback=$true
    { Set-MaesterRuntimeBundlePin @pinTarget } | Should -Throw '*may already be pinned*'
    Should -Invoke Invoke-RestMethod -ModuleName Maester-RuntimeFiles -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
  }
}
