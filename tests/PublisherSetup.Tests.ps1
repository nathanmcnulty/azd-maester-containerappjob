Describe 'Setup publishes runtime files through the real target-guarded publisher (offline)' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $savedLocation = Get-Location
    $savedAz = (Get-Command az -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
    $savedAzd = (Get-Command azd -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
    $savedEnv = @{}
    foreach ($name in 'AZURE_ENV_NAME','AZURE_TENANT_ID','INCLUDE_EXCHANGE','INCLUDE_TEAMS','INCLUDE_AZURE','INCLUDE_ACR','MAIL_RECIPIENT','AZURE_RBAC_SCOPES','SECURITY_GROUP_OBJECT_ID','SECURITY_GROUP_DISPLAY_NAME','EASY_AUTH_SECURITY_GROUP_OBJECT_ID') {
      $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
      [Environment]::SetEnvironmentVariable($name, $null)
    }
    Import-Module (Join-Path $root 'scripts/vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1') -Force
    Import-Module (Join-Path $root 'scripts/Maester-RuntimeFiles.psm1') -Force
    function global:az {
      $a = @($args); $s = $global:PublisherSetupState; $global:LASTEXITCODE = 0
      $s.Calls.Add(($a -join ' '))
      if ($a[0] -eq 'account' -and $a[1] -in @('show','list')) { return ($s.DefaultAccount | ConvertTo-Json -Compress) }
      $subIndex = [array]::IndexOf($a, '--subscription')
      if ($subIndex -lt 0 -or $a[$subIndex + 1] -ne $s.Sub) { throw "Unscoped offline Azure call: $($a -join ' ')" }
      if ($a[0] -eq 'rest') {
        if ("https://management.azure.com/subscriptions/$($s.Sub)?api-version=2022-12-01" -notin $a) { throw 'Unexpected subscription metadata URL' }
        $s.Reads++
        return ($s.Metadata | ConvertTo-Json -Compress)
      }
      if ($a[0] -eq 'account' -and $a[1] -eq 'get-access-token' -and 'https://management.azure.com/' -in $a) { return 'offline-arm' }
      if ($a[0] -eq 'storage' -and $a[1] -eq 'account' -and $a[2] -eq 'show') {
        if ($a[([array]::IndexOf($a, '--resource-group') + 1)] -ne 'selected-group' -or $a[([array]::IndexOf($a, '--name') + 1)] -ne 'selectedstorage') { throw 'Unscoped storage metadata call' }
        $s.StorageReads++
        if ($s.StorageFailure) { $global:LASTEXITCODE = 1; return '' }
        if ($s.StorageMalformed) { return '{bad' }
        return ($s.Storage | ConvertTo-Json -Compress)
      }
      if ($a[0] -eq 'storage' -and $a[1] -eq 'file' -and $a[2] -eq 'upload') {
        foreach ($pair in @(@('--account-name','selectedstorage'), @('--account-key','offline-key'), @('--share-name','scripts'))) {
          $index = [array]::IndexOf($a, $pair[0])
          if ($index -lt 0 -or $a[$index + 1] -ne $pair[1]) { throw 'Incorrect upload target' }
        }
        $source = $a[([array]::IndexOf($a, '--source') + 1)]
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Upload source does not exist' }
        $s.Uploads.Add($a[([array]::IndexOf($a, '--path') + 1)])
        $s.StagingPaths.Add((Split-Path $source -Parent))
        if ($s.DisableAfterFirstUpload) { $s.Metadata.state = 'Disabled' }
        return
      }
      throw "Unexpected offline Azure command: $($a -join ' ')"
    }
    function global:azd {
      $a = @($args); $global:LASTEXITCODE = 0
      if ($a[0] -eq 'env' -and $a[1] -eq 'get-values') { return ($global:PublisherSetupState.Values | ConvertTo-Json -Compress) }
      if ($a[0] -eq 'env' -and $a[1] -eq 'set' -and $a[2] -eq '-e' -and $a[3] -eq 'selected') { return }
      throw "Unexpected offline azd command: $($a -join ' ')"
    }
    function Invoke-PublisherSetup {
      & (Join-Path $root 'scripts/Setup-PostDeploy.ps1') -SubscriptionId $global:PublisherSetupState.Sub -TenantId $global:PublisherSetupState.Tenant -EnvironmentName selected -ResourceGroupName selected-group -PermissionProfile Minimal
    }
  }
  BeforeEach {
    $sub = '11111111-1111-4111-8111-111111111111'; $tenant = '22222222-2222-4222-8222-222222222222'
    $global:PublisherSetupState = @{
      Sub = $sub; Tenant = $tenant; Reads = 0; StorageReads = 0; Downloads = 0
      StorageFailure = $false; StorageMalformed = $false; DisableBeforePublisher = $false; DisableDuringDownload = $false; DisableAfterFirstUpload = $false
      Calls = [Collections.Generic.List[string]]::new(); Uploads = [Collections.Generic.List[string]]::new(); StagingPaths = [Collections.Generic.List[string]]::new()
      Metadata = @{ id = "/subscriptions/$sub"; subscriptionId = $sub; tenantId = $tenant; displayName = 'Selected'; state = 'Enabled' }
      DefaultAccount = @{ id = '99999999-9999-4999-8999-999999999999'; tenantId = '88888888-8888-4888-8888-888888888888'; state = 'Enabled' }
      Storage = @{ id = "/subscriptions/$sub/resourceGroups/selected-group/providers/Microsoft.Storage/storageAccounts/selectedstorage"; name = 'selectedstorage'; type = 'Microsoft.Storage/storageAccounts'; resourceGroup = 'selected-group' }
      Values = @{ AZURE_ENV_NAME = 'selected'; AZURE_SUBSCRIPTION_ID = $sub; AZURE_RESOURCE_GROUP = 'selected-group'; STORAGE_ACCOUNT_NAME = 'selectedstorage'; WEB_APP_ENABLED = 'false'; containerAppJobName = 'selected-job'; containerAppJobPrincipalId = '33333333-3333-4333-8333-333333333333' }
    }
    # Keep the real modules loaded so their transport mocks survive entrypoint imports.
    Mock Import-Module {} -ParameterFilter { $Name -like '*Maester-SetupHelpers.psm1' -or $Name -like '*Maester-RuntimeFiles.psm1' }
    Mock Assert-GraphAccess {}
    Mock Invoke-GraphRestRequest {
      if ($Method -ne 'GET') { throw 'Unexpected Graph write' }
      if ($Uri -like '*/me?*') { return $null }
      $roles = @('Directory.Read.All','DirectoryRecommendations.Read.All','IdentityRiskEvent.Read.All','Policy.Read.All','Policy.Read.ConditionalAccess','RoleManagement.Read.All','Reports.Read.All','UserAuthenticationMethod.Read.All')
      if ($Uri -like '*appRoleAssignments*') { return [pscustomobject]@{ value = @($roles | ForEach-Object { [pscustomobject]@{ principalId = '33333333-3333-4333-8333-333333333333'; resourceId = 'graph'; appRoleId = $_ } }) } }
      if ($Uri -like '*servicePrincipals?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'graph'; appId = '00000003-0000-0000-c000-000000000000'; appRoles = @($roles | ForEach-Object { [pscustomobject]@{ id = $_; value = $_; isEnabled = $true; allowedMemberTypes = @('Application') } }) }) } }
      throw "Unexpected Graph URL: $Uri"
    }
    Mock Invoke-RestMethod {
      $s = $global:PublisherSetupState
      $base = "https://management.azure.com/subscriptions/$($s.Sub)/resourceGroups/selected-group/providers"
      if ($Method -eq 'POST' -and $Uri -eq "$base/Microsoft.Storage/storageAccounts/selectedstorage/listKeys?api-version=2023-05-01") {
        if ($s.DisableBeforePublisher) { $s.Metadata.state = 'Disabled' }
        return [pscustomobject]@{ keys = @([pscustomobject]@{ value = 'offline-key' }) }
      }
      if ($Method -ne 'GET' -or ($Uri -notlike "$base/Microsoft.Storage/storageAccounts/selectedstorage?*" -and $Uri -notlike "$base/Microsoft.App/jobs/selected-job?*")) { throw "Unexpected ARM request: $Method $Uri" }
      $id = ([uri]$Uri).AbsolutePath
      return [pscustomobject]@{
        id = $id; name = ($id -split '/')[-1]; type = $(if ($id -like '*/storageAccounts/*') { 'Microsoft.Storage/storageAccounts' } else { 'Microsoft.App/jobs' })
        tags = @{ workload = 'maester'; solution = 'container-app-job'; environment = 'selected'; managedBy = 'azd' }
        identity = @{ type = 'SystemAssigned'; principalId = '33333333-3333-4333-8333-333333333333' }
      }
    }
    Mock Invoke-WebRequest { throw 'Unexpected download outside the runtime module' }
    Mock Invoke-WebRequest -ModuleName Maester-RuntimeFiles {
      if ($Uri -ne 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/powershell-7.6.6-linux-x64.tar.gz') { throw "Unexpected download: $Uri" }
      $s = $global:PublisherSetupState; $s.Downloads++
      [IO.File]::WriteAllText($OutFile, 'offline archive fixture')
      $s.StagingPaths.Add((Split-Path $OutFile -Parent))
      if ($s.DisableDuringDownload) { $s.Metadata.state = 'Disabled' }
    }
    # No archive/network dependency: hash verification itself is covered by runtime integrity tests.
    Mock Get-FileHash -ModuleName Maester-RuntimeFiles { [pscustomobject]@{ Hash = 'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC' } }
  }
  AfterEach {
    foreach ($path in $global:PublisherSetupState.StagingPaths) { Test-Path -LiteralPath $path | Should -BeFalse }
    Set-Location $savedLocation
  }
  AfterAll {
    foreach ($name in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name]) }
    Remove-Module Maester-RuntimeFiles, Maester-SetupHelpers -Force -ErrorAction SilentlyContinue
    Remove-Item function:az, function:azd
    if ($savedAz) { Set-Item function:global:az $savedAz }
    if ($savedAzd) { Set-Item function:global:azd $savedAzd }
    Remove-Variable PublisherSetupState -Scope Global
  }

  It 'rejects invalid initial subscription <case> before downloads or uploads' -ForEach @('wrong tenant','wrong subscription','Disabled','missing state' | ForEach-Object { @{ case = $_ } }) {
    switch ($case) {
      'wrong tenant' { $global:PublisherSetupState.Metadata.tenantId = '33333333-3333-4333-8333-333333333333' }
      'wrong subscription' { $global:PublisherSetupState.Metadata.subscriptionId = '44444444-4444-4444-8444-444444444444' }
      'Disabled' { $global:PublisherSetupState.Metadata.state = 'Disabled' }
      'missing state' { $global:PublisherSetupState.Metadata.Remove('state') }
    }
    { Invoke-PublisherSetup } | Should -Throw
    $global:PublisherSetupState.Downloads | Should -Be 0
    $global:PublisherSetupState.Uploads.Count | Should -Be 0
  }

  It 'rejects invalid publisher storage <case> before downloads or uploads' -ForEach @('wrong subscription','wrong group','wrong name','wrong type','missing id','failed lookup','malformed lookup' | ForEach-Object { @{ case = $_ } }) {
    switch ($case) {
      'wrong subscription' { $global:PublisherSetupState.Storage.id = $global:PublisherSetupState.Storage.id.Replace($global:PublisherSetupState.Sub, '99999999-9999-4999-8999-999999999999') }
      'wrong group' { $global:PublisherSetupState.Storage.resourceGroup = 'other-group' }
      'wrong name' { $global:PublisherSetupState.Storage.name = 'otherstorage' }
      'wrong type' { $global:PublisherSetupState.Storage.type = 'Microsoft.App/jobs' }
      'missing id' { $global:PublisherSetupState.Storage.Remove('id') }
      'failed lookup' { $global:PublisherSetupState.StorageFailure = $true }
      'malformed lookup' { $global:PublisherSetupState.StorageMalformed = $true }
    }
    $expectedError = switch ($case) {
      'missing id' { '*id*' }
      'failed lookup' { '*Unable to verify the selected storage account*' }
      'malformed lookup' { '*Invalid storage account ARM metadata*' }
      default { '*Storage account ARM identity does not match*' }
    }
    { Invoke-PublisherSetup } | Should -Throw $expectedError
    $global:PublisherSetupState.StorageReads | Should -Be 1
    $global:PublisherSetupState.Downloads | Should -Be 0
    $global:PublisherSetupState.Uploads.Count | Should -Be 0
  }

  It 'revalidates the subscription inside the publisher after earlier setup accepted it' {
    $global:PublisherSetupState.DisableBeforePublisher = $true
    { Invoke-PublisherSetup } | Should -Throw '*currently be Enabled*'
    $global:PublisherSetupState.Reads | Should -Be 2
    $global:PublisherSetupState.StorageReads | Should -Be 0
    $global:PublisherSetupState.Downloads | Should -Be 0
    $global:PublisherSetupState.Uploads.Count | Should -Be 0
  }

  It 'stops before the first upload when the subscription becomes Disabled during download' {
    $global:PublisherSetupState.DisableDuringDownload = $true
    { Invoke-PublisherSetup } | Should -Throw '*currently be Enabled*'
    $global:PublisherSetupState.Downloads | Should -Be 1
    $global:PublisherSetupState.Uploads.Count | Should -Be 0
  }

  It 'stops after exactly one upload when the subscription becomes Disabled between uploads' {
    $global:PublisherSetupState.DisableAfterFirstUpload = $true
    { Invoke-PublisherSetup } | Should -Throw '*currently be Enabled*'
    $global:PublisherSetupState.Downloads | Should -Be 1
    $global:PublisherSetupState.Uploads.Count | Should -Be 1
    $global:PublisherSetupState.Uploads[0] | Should -Be 'Invoke-MaesterContainerJob.ps1'
  }

  It 'uploads all five real staged files to the selected subscription despite a different global default' {
    Invoke-PublisherSetup
    $global:PublisherSetupState.Downloads | Should -Be 1
    $global:PublisherSetupState.StorageReads | Should -Be 1
    $global:PublisherSetupState.Reads | Should -Be 7
    $global:PublisherSetupState.Uploads.Count | Should -Be 5
    ($global:PublisherSetupState.Uploads -join ',') | Should -Be 'Invoke-MaesterContainerJob.ps1,Install-LockedModules.ps1,Start-MaesterContainerJob.sh,runtime-packages.lock.json,powershell-7.6.6-linux-x64.tar.gz'
    @($global:PublisherSetupState.Calls | Where-Object { $_ -like 'storage file upload*' -and $_ -notlike '*--subscription 11111111-1111-4111-8111-111111111111*' }).Count | Should -Be 0
    @($global:PublisherSetupState.Calls | Where-Object { $_ -like 'account set*' -or $_ -like 'login*' }).Count | Should -Be 0
  }
}
