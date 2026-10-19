BeforeAll {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $repoRoot 'scripts/Maester-RuntimeFiles.psm1') -Force
  $savedAz = (Get-Command az -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
  function global:az {
    $a = @($args); $s = $global:PublisherTest; $global:LASTEXITCODE = 0
    $s.Calls.Add(($a -join ' '))
    if ($a[0] -eq 'account') { throw 'Global account/default access is forbidden.' }
    if ('--subscription' -notin $a -or $a[([array]::IndexOf($a, '--subscription') + 1)] -ne $s.Sub) { throw 'Unscoped transport.' }
    if ($a[0] -eq 'rest') {
      if ($s.MetadataFailure) { $global:LASTEXITCODE = 1; return '' }
      if ($s.Malformed) { return '{invalid' }
      return ($s.Metadata | ConvertTo-Json -Compress)
    }
    if (($a[0..2] -join ' ') -eq 'storage account show') {
      if ($s.StorageFailure) { $global:LASTEXITCODE = 1; return '' }
      if ($s.StorageMalformed) { return '{invalid' }
      if ($a[([array]::IndexOf($a, '--resource-group') + 1)] -ne 'selected-group' -or
          $a[([array]::IndexOf($a, '--name') + 1)] -ne 'test') { throw 'Wrong storage lookup.' }
      return ($s.Storage | ConvertTo-Json -Compress)
    }
    if (($a[0..2] -join ' ') -eq 'storage file upload') {
      $s.Calls[$s.Calls.Count - 2] | Should -BeLike 'rest *'
      $s.Uploads.Add($a)
      if ($s.DisableAfterUpload) { $s.Metadata.state = 'Disabled' }
      $global:LASTEXITCODE = $s.UploadExit
      return
    }
    throw 'Unexpected offline transport.'
  }
}
AfterAll { Remove-Item Function:\az -ErrorAction SilentlyContinue; if ($savedAz) { Set-Item function:global:az $savedAz }; Remove-Variable PublisherTest -Scope Global }

Describe 'Production runtime staging and uploads' {
  BeforeEach {
    $sub = '11111111-1111-4111-8111-111111111111'; $tenant = '22222222-2222-4222-8222-222222222222'
    $script:target = @{ SubscriptionId = $sub; TenantId = $tenant; ResourceGroupName = 'selected-group' }
    $global:PublisherTest = @{
      Sub = $sub; MetadataFailure = $false; Malformed = $false; StorageFailure = $false; StorageMalformed = $false
      UploadExit = 0; DisableAfterUpload = $false; Calls = [Collections.Generic.List[string]]::new(); Uploads = [Collections.Generic.List[object]]::new()
      Metadata = @{ id = "/subscriptions/$sub"; subscriptionId = $sub; tenantId = $tenant; displayName = 'Selected'; state = 'Enabled' }
      Storage = @{ id = "/subscriptions/$sub/resourceGroups/selected-group/providers/Microsoft.Storage/storageAccounts/test"; name = 'test'; type = 'Microsoft.Storage/storageAccounts'; resourceGroup = 'selected-group' }
    }
    $script:before = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'maester-upload-*' | Select-Object -ExpandProperty FullName)
    $script:sourceHash = (Get-FileHash (Join-Path $repoRoot 'runtime-packages.lock.json')).Hash
  }
  AfterEach {
    @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'maester-upload-*' | Select-Object -ExpandProperty FullName | Where-Object { $_ -notin $script:before }).Count | Should -Be 0
    (Get-FileHash (Join-Path $repoRoot 'runtime-packages.lock.json')).Hash | Should -Be $script:sourceHash
  }

  It 'uploads every production non-ACR input and removes only owned staging' {
    Mock Invoke-WebRequest -ModuleName Maester-RuntimeFiles { param($Uri, $OutFile) Set-Content -LiteralPath $OutFile -Value 'download fixture' }
    Mock Get-FileHash -ModuleName Maester-RuntimeFiles { @{ Hash = 'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC' } }
    Publish-MaesterRuntimeFiles @target -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot
    $global:PublisherTest.Uploads.Count | Should -Be 8
    foreach ($file in @('Invoke-MaesterContainerJob.ps1', 'Maester.DriftInputs.psm1', 'Maester.DriftRun.psm1', 'Install-LockedModules.ps1', 'Start-MaesterContainerJob.sh', 'runtime-packages.lock.json', 'powershell-7.6.6-linux-x64.tar.gz')) {
      @($global:PublisherTest.Uploads | Where-Object { $file -in $_ }).Count | Should -Be 1
    }
    Should -Invoke Invoke-WebRequest -ModuleName Maester-RuntimeFiles -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-linux-x64.tar.gz' }
  }

  It 'does not download or upload a runtime archive for ACR' {
    Mock Invoke-WebRequest -ModuleName Maester-RuntimeFiles { throw 'ACR must not download.' }
    Publish-MaesterRuntimeFiles @target -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot -IncludeACR
    $global:PublisherTest.Uploads.Count | Should -Be 7
    Should -Invoke Invoke-WebRequest -ModuleName Maester-RuntimeFiles -Times 0 -Exactly
  }

  It 'rejects download failure before any upload and cleans temporary data' {
    Mock Invoke-WebRequest -ModuleName Maester-RuntimeFiles { param($OutFile) Set-Content $OutFile partial; throw 'download failed' }
    { Publish-MaesterRuntimeFiles @target -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot } | Should -Throw '*download failed*'
    $global:PublisherTest.Uploads.Count | Should -Be 0
  }

  It 'rejects actual wrong archive bytes before any upload' {
    Mock Invoke-WebRequest -ModuleName Maester-RuntimeFiles { param($OutFile) Set-Content $OutFile corrupt }
    { Publish-MaesterRuntimeFiles @target -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot } | Should -Throw '*SHA-256*'
    $global:PublisherTest.Uploads.Count | Should -Be 0
  }

  It 'fails closed on an upload failure and cleans its staged copies' {
    $global:PublisherTest.UploadExit = 7
    { Publish-MaesterRuntimeFiles @target -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot -IncludeACR } | Should -Throw '*Failed to upload*'
    $global:PublisherTest.Uploads.Count | Should -Be 1
  }


  It 'rejects invalid target or metadata before staging: <Case>' -ForEach @(
    @{ Case = 'wrong tenant' }, @{ Case = 'wrong subscription' }, @{ Case = 'disabled' }, @{ Case = 'missing state' },
    @{ Case = 'missing tenant' }, @{ Case = 'malformed subscription' }, @{ Case = 'failed subscription' },
    @{ Case = 'storage id' }, @{ Case = 'storage name' }, @{ Case = 'storage type' }, @{ Case = 'storage group' },
    @{ Case = 'failed storage' }, @{ Case = 'malformed storage' }, @{ Case = 'blank tenant' }, @{ Case = 'blank group' }, @{ Case = 'blank subscription' }, @{ Case = 'invalid group' }
  ) {
    switch ($Case) {
      'wrong tenant' { $global:PublisherTest.Metadata.tenantId = '33333333-3333-4333-8333-333333333333' }
      'wrong subscription' { $global:PublisherTest.Metadata.subscriptionId = '33333333-3333-4333-8333-333333333333' }
      'disabled' { $global:PublisherTest.Metadata.state = 'Disabled' }
      'missing state' { $global:PublisherTest.Metadata.Remove('state') }
      'missing tenant' { $global:PublisherTest.Metadata.Remove('tenantId') }
      'malformed subscription' { $global:PublisherTest.Malformed = $true }
      'failed subscription' { $global:PublisherTest.MetadataFailure = $true }
      'storage id' { $global:PublisherTest.Storage.id = '/subscriptions/wrong/resourceGroups/wrong' }
      'storage name' { $global:PublisherTest.Storage.name = 'wrong' }
      'storage type' { $global:PublisherTest.Storage.type = 'Microsoft.Web/sites' }
      'storage group' { $global:PublisherTest.Storage.resourceGroup = 'wrong' }
      'failed storage' { $global:PublisherTest.StorageFailure = $true }
      'malformed storage' { $global:PublisherTest.StorageMalformed = $true }
      'blank tenant' { $target.TenantId = ' ' }
      'blank group' { $target.ResourceGroupName = ' ' }
      'blank subscription' { $target.SubscriptionId = ' ' }
      'invalid group' { $target.ResourceGroupName = '../other' }
    }
    Mock Invoke-WebRequest -ModuleName Maester-RuntimeFiles { throw 'Must never download.' }
    { Publish-MaesterRuntimeFiles @target -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot } | Should -Throw
    $global:PublisherTest.Uploads.Count | Should -Be 0
    Should -Invoke Invoke-WebRequest -ModuleName Maester-RuntimeFiles -Times 0 -Exactly
  }

  It 'refreshes state after download before the first upload' {
    Mock Invoke-WebRequest -ModuleName Maester-RuntimeFiles { param($OutFile) Set-Content $OutFile fixture; $global:PublisherTest.Metadata.state = 'Disabled' }
    Mock Get-FileHash -ModuleName Maester-RuntimeFiles { @{ Hash = 'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC' } }
    { Publish-MaesterRuntimeFiles @target -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot } | Should -Throw '*Enabled*'
    $global:PublisherTest.Uploads.Count | Should -Be 0
  }

  It 'stops after one upload when state changes between files' {
    $global:PublisherTest.DisableAfterUpload = $true
    { Publish-MaesterRuntimeFiles @target -StorageAccountName test -StorageKey fixture -ProjectRoot $repoRoot -IncludeACR } | Should -Throw '*Enabled*'
    $global:PublisherTest.Uploads.Count | Should -Be 1
  }

  It 'uses the real publisher in setup and the shell entry point in Bicep' {
    $setup = Get-Content (Join-Path $repoRoot 'scripts/Setup-PostDeploy.ps1') -Raw
    $setup | Should -Match 'Publish-MaesterRuntimeFiles .*?-StorageAccountName.*-IncludeACR:\$includeACR'
    $infra = Get-Content (Join-Path $repoRoot 'infra/main.bicep') -Raw
    $infra | Should -Match "'/bin/sh'\s+'/mnt/scripts/Start-MaesterContainerJob.sh'\s+includeACR \? 'acr' : 'nonacr'"
    $docker = Get-Content (Join-Path $repoRoot 'Dockerfile') -Raw
    $bootstrap = Get-Content (Join-Path $repoRoot 'scripts/Start-MaesterContainerJob.sh') -Raw
    $staging = Get-Content (Join-Path $repoRoot 'scripts/Maester-RuntimeFiles.psm1') -Raw
    $hash = [regex]::Match($docker, '[A-F0-9]{64}').Value
    $hash | Should -Not -BeNullOrEmpty
    $bootstrap | Should -Match $hash
    $staging | Should -Match $hash
    $infra | Should -Match ([regex]::Escape(([regex]::Match($docker, 'mcr.microsoft.com/[^\s]+')).Value))
  }
}

Describe 'Hosted runtime harness exit state' {
  It 'clears the expected negative-test native exit only on successful completion' {
    $source = Get-Content (Join-Path $repoRoot 'scripts/Test-NonAcrContainerRuntime.ps1') -Raw
    $source.TrimEnd() | Should -Match '\$global:LASTEXITCODE = 0$'
    $source.LastIndexOf('$global:LASTEXITCODE = 0') | Should -BeGreaterThan $source.LastIndexOf('Remove-Item -LiteralPath $owned')
    $success = Join-Path $TestDrive 'success.ps1'
    $failure = Join-Path $TestDrive 'failure.ps1'
    $reset = ($source.TrimEnd() -split "`n")[-1]
    $wrapper = "`nif (Test-Path variable:LASTEXITCODE) { exit `$LASTEXITCODE }"
    Set-Content $success -Value ("`$ErrorActionPreference = 'Stop'`n& /bin/sh -c 'exit 17'`n" + $reset + $wrapper)
    & pwsh -NoProfile -File $success
    $LASTEXITCODE | Should -Be 0
    Set-Content $failure -Value ("`$ErrorActionPreference = 'Stop'`n& /bin/sh -c 'exit 17'`nthrow 'assertion failed'`n" + $reset + $wrapper)
    & pwsh -NoProfile -File $failure 2>&1 | Out-Null
    $LASTEXITCODE | Should -Be 1
  }
}
