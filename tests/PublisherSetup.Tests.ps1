Describe 'Setup publishes runtime files through the real target-guarded publisher (offline)' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $savedLocation = Get-Location
    $savedAz = (Get-Command az -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
    $savedAzd = (Get-Command azd -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
    $savedEnv = @{}
    foreach ($name in 'AZURE_ENV_NAME','AZURE_TENANT_ID','INCLUDE_EXCHANGE','INCLUDE_TEAMS','INCLUDE_AZURE','INCLUDE_ACR','MAIL_RECIPIENT','AZURE_RBAC_SCOPES','SECURITY_GROUP_OBJECT_ID','SECURITY_GROUP_DISPLAY_NAME','EASY_AUTH_SECURITY_GROUP_OBJECT_ID','MAESTER_SETUP_CLIENT_ID') {
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
      if ($a[0] -eq 'account' -and $a[1] -eq 'get-access-token') {
        if ('--tenant' -notin $a) { return 'offline-arm' }
        if ($a[([array]::IndexOf($a, '--tenant') + 1)] -ne $s.Tenant) { throw 'Wrong token tenant' }
        $audience = $a[([array]::IndexOf($a, '--resource') + 1)]
        $claims = @{ tid = $s.Tenant; oid = $(if ($s.TokenOperator) { $s.TokenOperator } else { $s.Operator }); aud = $audience; exp = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds() } | ConvertTo-Json -Compress
        return 'header.' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_') + '.signature'
      }
      if ($a[0] -eq 'storage' -and $a[1] -eq 'account' -and $a[2] -eq 'show') {
        if ($a[([array]::IndexOf($a, '--resource-group') + 1)] -ne 'selected-group' -or $a[([array]::IndexOf($a, '--name') + 1)] -ne 'selectedstorage') { throw 'Unscoped storage metadata call' }
        $s.StorageReads++
        if ($s.StorageFailure) { $global:LASTEXITCODE = 1; return '' }
        if ($s.StorageMalformed) { return '{bad' }
        return ($s.Storage | ConvertTo-Json -Compress)
      }
      throw "Unexpected offline Azure command: $($a -join ' ')"
    }
    function global:azd {
      $a = @($args); $global:LASTEXITCODE = 0
      if ($a[0] -eq 'env' -and $a[1] -eq 'get-values') { return ($global:PublisherSetupState.Values | ConvertTo-Json -Compress) }
      if ($a[0] -eq 'env' -and $a[1] -eq 'set' -and $a[2] -eq '-e' -and $a[3] -eq 'selected') { $global:PublisherSetupState.EnvWrites++; return }
      throw "Unexpected offline azd command: $($a -join ' ')"
    }
    function Assert-MaesterConsentPlanApproval { param($Plan,$ApprovedPlanHash); if ($Plan.planHash -ne $ApprovedPlanHash) { throw 'Offline consent mismatch' } }
    function Register-MaesterExternalSetupStarted { $global:PublisherSetupState.MarkerCalls++ }
    function Open-MaesterOwnershipJournal { $global:PublisherSetupState.MarkerCalls | Should -Be 1; $global:PublisherSetupState.JournalOpens++; $session=[pscustomobject]@{}; $session | Add-Member ScriptMethod Dispose {}; $session }
    function Assert-MaesterKeylessProvisioning { $global:PublisherSetupState.MigrationReads++; if ($global:PublisherSetupState.LegacyTarget) { throw 'Keyless migration requires reviewed plan' } }
    function Get-MaesterSetupScopes { @('Application.Read.All') }
    function Get-MaesterSetupAccessPlan { [pscustomobject]@{ planHash = 'fixture-approved-plan'; capability = 'DeploymentSetupAccess'; details = @{ inventory = @{ operator = @{ id = $global:PublisherSetupState.Operator } } } } }
    function Invoke-MaesterSetupAccessPlan { if ($global:PublisherSetupState.DisableBeforePublisher) { $global:PublisherSetupState.Metadata.state = 'Disabled' }; [pscustomobject]@{ Receipts = @{ EXO_APPROLE_ASSIGNMENT_IDS = @(); TEAMS_READER_ROLE_ASSIGNMENT_IDS = @(); AZURE_ROLE_ASSIGNMENT_IDS = @() }; EasyAuth = $null; PrincipalDisplayName = 'offline' } }
    function Invoke-PublisherSetup {
      param([switch]$PlanOnly)
      & (Join-Path $root 'scripts/Setup-PostDeploy.ps1') -SubscriptionId $global:PublisherSetupState.Sub -TenantId $global:PublisherSetupState.Tenant -EnvironmentName selected -ResourceGroupName selected-group -PermissionProfile Minimal -Apply:(-not $PlanOnly) -ApprovedPlanHash fixture-approved-plan
    }
  }
  BeforeEach {
    $env:MAESTER_SETUP_CLIENT_ID = '99999999-9999-4999-8999-999999999999'
    $sub = '11111111-1111-4111-8111-111111111111'; $tenant = '22222222-2222-4222-8222-222222222222'
    $global:PublisherSetupState = @{
      Sub = $sub; Tenant = $tenant; Operator = '55555555-5555-4555-8555-555555555555'; TokenOperator = ''; MigrationReads = 0; LegacyTarget = $false; PinWrites = 0; BlobReads = 0; JournalOpens = 0; MarkerCalls = 0; EnvWrites = 0; Reads = 0; StorageReads = 0; Downloads = 0
      StorageFailure = $false; StorageMalformed = $false; DisableBeforePublisher = $false; DisableDuringDownload = $false; DisableAfterFirstUpload = $false
      Calls = [Collections.Generic.List[string]]::new(); Uploads = [Collections.Generic.List[string]]::new(); StagingPaths = [Collections.Generic.List[string]]::new()
      Metadata = @{ id = "/subscriptions/$sub"; subscriptionId = $sub; tenantId = $tenant; displayName = 'Selected'; state = 'Enabled' }
      DefaultAccount = @{ id = '99999999-9999-4999-8999-999999999999'; tenantId = '88888888-8888-4888-8888-888888888888'; state = 'Enabled' }
      Storage = @{ id = "/subscriptions/$sub/resourceGroups/selected-group/providers/Microsoft.Storage/storageAccounts/selectedstorage"; name = 'selectedstorage'; type = 'Microsoft.Storage/storageAccounts'; resourceGroup = 'selected-group'; allowSharedKeyAccess = $false }
      Values = @{ AZURE_ENV_NAME = 'selected'; AZURE_SUBSCRIPTION_ID = $sub; AZURE_RESOURCE_GROUP = 'selected-group'; STORAGE_ACCOUNT_NAME = 'selectedstorage'; WEB_APP_ENABLED = 'false'; containerAppJobName = 'selected-job'; containerAppJobPrincipalId = '33333333-3333-4333-8333-333333333333' }
    }
    # Keep the real modules loaded so their transport mocks survive entrypoint imports.
    Mock Import-Module {} -ParameterFilter { $Name -like '*Maester-SetupHelpers.psm1' -or $Name -like '*Maester-RuntimeFiles.psm1' -or $Name -like '*Maester-ConsentPlan.psm1' -or $Name -like '*Maester-SetupConsent.psm1' -or $Name -like '*Maester-OwnershipJournal.psm1' -or $Name -like '*Maester-InfrastructureOwnership.psm1' -or $Name -like '*Maester-KeylessMigration.psm1' }
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
      if ($Method -ne 'GET' -or ($Uri -notlike "$base/Microsoft.Storage/storageAccounts/selectedstorage?*" -and $Uri -notlike "$base/Microsoft.App/jobs/selected-job?*")) { throw "Unexpected ARM request: $Method $Uri" }
      $id = ([uri]$Uri).AbsolutePath
      return [pscustomobject]@{
        id = $id; name = ($id -split '/')[-1]; type = $(if ($id -like '*/storageAccounts/*') { 'Microsoft.Storage/storageAccounts' } else { 'Microsoft.App/jobs' })
        tags = @{ workload = 'maester'; solution = 'container-app-job'; environment = 'selected'; managedBy = 'azd' }
        identity = @{ type = 'SystemAssigned'; principalId = '33333333-3333-4333-8333-333333333333' }
      }
    }
    Mock Invoke-WebRequest { throw 'Unexpected download outside the runtime module' }
    Mock Save-MaesterPublicArtifact -ModuleName Maester-RuntimeFiles {
      if ($Uri -notlike 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/*' -and $Uri -notlike 'https://www.powershellgallery.com/api/v2/package/*') { throw "Unexpected download: $Uri" }
      $s = $global:PublisherSetupState; $s.Downloads++
      [IO.File]::WriteAllText($OutFile, 'offline archive fixture')
      $stage = Split-Path $OutFile -Parent
      if ((Split-Path $stage -Leaf) -eq 'packages') { $stage = Split-Path $stage -Parent }
      $s.StagingPaths.Add($stage)
      if ($s.DisableDuringDownload) { $s.Metadata.state = 'Disabled' }
    }
    # Input hashes are fixture-backed; the content-addressed ZIP uses real SHA256.
    Mock Get-FileHash -ModuleName Maester-RuntimeFiles {
      if ($LiteralPath -like '*powershell-7.6.6-linux-x64.tar.gz') { return [pscustomobject]@{ Hash = 'DDBC4A2D113BBD46D283CFEDCBCD117A70CAEFD7673F41F2B4E0000BADF103BC' } }
      if ($LiteralPath -like '*.nupkg') {
        $lock = Get-Content (Join-Path $root 'runtime-packages.lock.json') -Raw | ConvertFrom-Json
        $package = @($lock.packages | Where-Object { "$($_.name).$($_.version).nupkg" -eq (Split-Path $LiteralPath -Leaf) })
        if ($package.Count -ne 1) { throw 'Unexpected package fixture' }
        return [pscustomobject]@{ Hash = $package[0].sha256 }
      }
      Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256
    }
    Mock Invoke-MaesterBlobRequest -ModuleName Maester-RuntimeFiles {
      $s = $global:PublisherSetupState
      $Uri.AbsoluteUri | Should -BeExactly "https://selectedstorage.blob.core.windows.net/runtime/bundles/$($Bundle.Sha256).zip"
      $Token | Should -Match '^header\.'
      Test-Path -LiteralPath $Bundle.Path -PathType Leaf | Should -BeTrue
      if ($Method -eq 'PUT') {
        $s.Uploads.Add($Bundle.BlobName)
        if ($s.DisableAfterFirstUpload) { $s.Metadata.state = 'Disabled' }
        return 201
      }
      if ($Method -eq 'GET') { $s.BlobReads++; return 200 }
      throw 'Unexpected Blob method'
    }
    $global:PublisherSetupState.Job = @{
      id = "/subscriptions/$sub/resourceGroups/selected-group/providers/Microsoft.App/jobs/selected-job"
      identity = @{ principalId = '33333333-3333-4333-8333-333333333333' }
      properties = @{ template = @{ containers = @(@{ name = 'maester'; image = 'digest-pinned-fixture'; env = @(@{ name = 'STORAGE_ACCOUNT_NAME'; value = 'selectedstorage' }) }) } }
    }
    Mock Invoke-RestMethod -ModuleName Maester-RuntimeFiles {
      $s = $global:PublisherSetupState
      $Uri | Should -BeExactly "https://management.azure.com$($s.Job.id)?api-version=2024-03-01"
      $MaximumRedirection | Should -Be 0
      if ($Method -eq 'PATCH') { $s.PinWrites++; $payload = $Body | ConvertFrom-Json -AsHashtable; $s.Job.properties.template = $payload.properties.template; return }
      if ($Method -ne 'GET') { throw 'Unexpected pin method' }
      return $s.Job | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    }
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

  It 'returns a read-only access plan before runtime publication or setup receipts by default' {
    $result = Invoke-PublisherSetup -PlanOnly
    $result.capability | Should -BeExactly 'DeploymentSetupAccess'
    $global:PublisherSetupState.JournalOpens | Should -Be 0
    $global:PublisherSetupState.MarkerCalls | Should -Be 0
    $global:PublisherSetupState.Downloads | Should -Be 0
    $global:PublisherSetupState.Uploads.Count | Should -Be 0
    $global:PublisherSetupState.EnvWrites | Should -Be 0
  }

  It 'blocks direct setup on a legacy target before Graph or setup writes' {
    $global:PublisherSetupState.LegacyTarget = $true
    { Invoke-PublisherSetup } | Should -Throw '*Keyless migration*'
    Should -Invoke Assert-GraphAccess -Times 0 -Exactly
    $global:PublisherSetupState.JournalOpens | Should -Be 0
    $global:PublisherSetupState.Downloads | Should -Be 0
    $global:PublisherSetupState.Uploads.Count | Should -Be 0
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

  It 'rejects invalid publisher storage <case> before downloads or uploads' -ForEach @('wrong subscription','wrong group','wrong name','wrong type','missing id','failed lookup','malformed lookup','Shared Key enabled' | ForEach-Object { @{ case = $_ } }) {
    switch ($case) {
      'wrong subscription' { $global:PublisherSetupState.Storage.id = $global:PublisherSetupState.Storage.id.Replace($global:PublisherSetupState.Sub, '99999999-9999-4999-8999-999999999999') }
      'wrong group' { $global:PublisherSetupState.Storage.resourceGroup = 'other-group' }
      'wrong name' { $global:PublisherSetupState.Storage.name = 'otherstorage' }
      'wrong type' { $global:PublisherSetupState.Storage.type = 'Microsoft.App/jobs' }
      'missing id' { $global:PublisherSetupState.Storage.Remove('id') }
      'failed lookup' { $global:PublisherSetupState.StorageFailure = $true }
      'malformed lookup' { $global:PublisherSetupState.StorageMalformed = $true }
      'Shared Key enabled' { $global:PublisherSetupState.Storage.allowSharedKeyAccess = $true }
    }
    $expectedError = switch ($case) {
      'missing id' { '*id*' }
      'failed lookup' { '*Unable to verify the selected storage account*' }
      'malformed lookup' { '*Invalid storage account ARM metadata*' }
      default { '*Storage identity or Shared Key policy does not match*' }
    }
    { Invoke-PublisherSetup } | Should -Throw $expectedError
    $global:PublisherSetupState.StorageReads | Should -Be 1
    $global:PublisherSetupState.Downloads | Should -Be 0
    $global:PublisherSetupState.Uploads.Count | Should -Be 0
  }

  It 'rejects a token from a different publishing operator before Blob writes or pin activation' {
    $global:PublisherSetupState.TokenOperator = '66666666-6666-4666-8666-666666666666'
    { Invoke-PublisherSetup } | Should -Throw '*approved publishing operator*'
    $global:PublisherSetupState.Uploads.Count | Should -Be 0
    $global:PublisherSetupState.PinWrites | Should -Be 0
  }

  It 'revalidates the subscription inside the publisher after earlier setup accepted it' {
    $global:PublisherSetupState.DisableBeforePublisher = $true
    { Invoke-PublisherSetup } | Should -Throw '*currently be Enabled*'
    $global:PublisherSetupState.Reads | Should -BeGreaterOrEqual 3
    $global:PublisherSetupState.StorageReads | Should -Be 0
    $global:PublisherSetupState.Downloads | Should -Be 0
    $global:PublisherSetupState.Uploads.Count | Should -Be 0
  }

  It 'stops before the first upload when the subscription becomes Disabled during download' {
    $global:PublisherSetupState.DisableDuringDownload = $true
    { Invoke-PublisherSetup } | Should -Throw '*currently be Enabled*'
    $global:PublisherSetupState.Downloads | Should -Be 10
    $global:PublisherSetupState.Uploads.Count | Should -Be 0
  }

  It 'does not activate the bundle when the subscription becomes Disabled after publication' {
    $global:PublisherSetupState.DisableAfterFirstUpload = $true
    { Invoke-PublisherSetup } | Should -Throw '*currently be Enabled*'
    $global:PublisherSetupState.Downloads | Should -Be 10
    $global:PublisherSetupState.Uploads.Count | Should -Be 1
    $global:PublisherSetupState.Uploads[0] | Should -Match '^bundles/[a-f0-9]{64}\.zip$'
    $global:PublisherSetupState.PinWrites | Should -Be 0
  }

  It 'publishes one verified bundle and activates all four pins despite a different global default' {
    Invoke-PublisherSetup
    $global:PublisherSetupState.Downloads | Should -Be 10
    $global:PublisherSetupState.StorageReads | Should -Be 1
    $global:PublisherSetupState.Uploads.Count | Should -Be 1
    $global:PublisherSetupState.BlobReads | Should -Be 1
    $global:PublisherSetupState.PinWrites | Should -Be 1
    $global:PublisherSetupState.MigrationReads | Should -BeGreaterOrEqual 3
    $pins = @($global:PublisherSetupState.Job.properties.template.containers[0].env | Where-Object name -like 'MAESTER_RUNTIME_*')
    $pins.Count | Should -Be 4
    ($pins | Where-Object name -eq MAESTER_RUNTIME_BLOB_NAME).value | Should -BeExactly $global:PublisherSetupState.Uploads[0]
    @($global:PublisherSetupState.Calls | Where-Object { $_ -like 'storage file*' -or $_ -like '*listKeys*' -or $_ -like '*--account-key*' }).Count | Should -Be 0
    @($global:PublisherSetupState.Calls | Where-Object { $_ -like 'account set*' -or $_ -like 'login*' }).Count | Should -Be 0
  }
}
