Describe 'Actual deployment entrypoint target guards (offline)' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $root 'scripts/Maester.AssessmentEvidence.psm1') -Force
    . (Join-Path $PSScriptRoot 'fixtures/AssessmentEvidence.ps1')
    $savedAz = (Get-Command az -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
    $savedAzd = (Get-Command azd -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
    $savedTenant = $env:AZURE_TENANT_ID
    $savedLocation = Get-Location
    function global:az {
      $a = @($args)
      $s = $global:EntrypointState
      $s.Calls.Add(($a -join ' ')); $global:LASTEXITCODE = 0
      if ($a[0] -eq 'rest') {
        if (($a -join ' ') -notlike "*--subscription $($s.Sub)*" -or ($a -join ' ') -notlike "*https://management.azure.com/subscriptions/$($s.Sub)?api-version=2022-12-01*") { throw 'Unscoped metadata request' }
        $s.Reads++
        if ($s.FailRead) { $global:LASTEXITCODE = 1; return '' }
        if ($s.Malformed) { return '{bad' }
        if ($s.DisableAt -eq $s.Reads) { $s.Metadata.state = 'Disabled' }
        return ($s.Metadata | ConvertTo-Json -Compress)
      }
      if ($a[0] -eq 'account' -and $a[1] -in @('list','show')) {
        return '{"id":"99999999-9999-4999-8999-999999999999","tenantId":"88888888-8888-4888-8888-888888888888","state":"Enabled"}'
      }
      if ($a[0] -eq 'account' -and $a[1] -eq 'get-access-token') {
        if (($a -join ' ') -notlike "*--subscription $($s.Sub)*" -and ($a -join ' ') -notlike "*--tenant $($s.Tenant)*") { throw 'Unscoped token request' }
        return 'offline-arm-token'
      }
      if ($a[0] -eq 'acr') {
        if (($a -join ' ') -notlike "*--subscription $($s.Sub)*") { throw 'Unscoped ACR call' }
        if ($a[1] -eq 'list') { return '[{"name":"selectedacr","loginServer":"selectedacr.azurecr.io"}]' }
        if ($a[1] -eq 'build') { $s.Builds++; return }
        if ($a[1] -eq 'manifest') { return ('sha256:' + ('a' * 64)) }
      }
      throw "Unexpected offline Azure command: $($a -join ' ')"
    }
    function global:azd { throw "Unexpected offline azd command: $args" }
    function Invoke-GuardedEntrypoint {
      param([string]$Entry, [switch]$NoTenant)
      $p = @{ SubscriptionId = $global:EntrypointState.Sub; ResourceGroupName = 'selected-group' }
      if (-not $NoTenant) { $p.TenantId = $global:EntrypointState.Tenant }
      switch ($Entry) {
        'Build' { & (Join-Path $root 'scripts/Build-MaesterImage.ps1') @p -EnvironmentName selected -ContainerAppJobName selected-job -AcrName selectedacr }
        'Start' { & (Join-Path $root 'scripts/Invoke-JobValidation.ps1') @p -ContainerAppJobName selected-job -PassThru -RequireNoMail:$global:EntrypointState.RequireNoMail }
        'Setup' { & (Join-Path $root 'scripts/Setup-PostDeploy.ps1') @p -EnvironmentName selected -IncludeExchange }
      }
    }
  }
  BeforeEach {
    $env:AZURE_TENANT_ID = $null
    $sub = '11111111-1111-4111-8111-111111111111'; $tenant = '22222222-2222-4222-8222-222222222222'
    $global:EntrypointState = @{
      Sub = $sub; Tenant = $tenant; Calls = [Collections.Generic.List[string]]::new()
      RequireNoMail = $false; ReaderDenied = $false; ReceiptMode = 'valid'; Status = 'Succeeded'
      Env = @([pscustomobject]@{ name = 'STORAGE_ACCOUNT_NAME'; value = 'selectedstorage' })
      Builds = 0; Writes = 0; Reads = 0; FailRead = $false; Malformed = $false; DisableAt = 0
      Metadata = @{ id = "/subscriptions/$sub"; subscriptionId = $sub; tenantId = $tenant; displayName = 'Selected'; state = 'Enabled' }
    }
    Mock Start-Sleep {}
    Mock Invoke-WebRequest {
      $MaximumRedirection | Should -Be 0
      if ($global:EntrypointState.ReaderDenied) { throw 'offline 403' }
      if ($Uri -like '*comp=list*') { return [pscustomobject]@{ Content = '<EnumerationResults />' } }
      if ($global:EntrypointState.ReceiptMode -eq 'missing') { throw 'offline 404' }
      $r = New-TestValidationReceipt $root
      if (@($global:EntrypointState.Env | Where-Object name -eq 'MAIL_RECIPIENT').Count) { $r.Publication.Mail = 'UpstreamUnverified' }
      if ($global:EntrypointState.ReceiptMode -eq 'stale') { $r.ExecutionName = 'older-good-run' }
      if ($global:EntrypointState.ReceiptMode -eq 'malformed') { return [pscustomobject]@{ Content = '{invalid' } }
      return [pscustomobject]@{ Content = ($r | ConvertTo-Json -Depth 8) }
    }
    Mock Invoke-RestMethod {
      if ($Method -in @('PUT','POST','PATCH','DELETE')) { $global:EntrypointState.Writes++ }
      if ($Method -eq 'POST') { return [pscustomobject]@{ name = 'execution-one' } }
      if ($Uri -like '*/executions/*') { return [pscustomobject]@{ properties = [pscustomobject]@{ status = $global:EntrypointState.Status; template = [pscustomobject]@{ containers = @() } } } }
      return [pscustomobject]@{
        location = 'eastus'; tags = @{}; identity = @{}
        properties = [pscustomobject]@{ configuration = [pscustomobject]@{ registries = @() }; template = [pscustomobject]@{ containers = @([pscustomobject]@{ image = 'old'; env = $global:EntrypointState.Env }) } }
      }
    }
  }
  AfterEach { Set-Location $savedLocation }
  AfterAll {
    $env:AZURE_TENANT_ID = $savedTenant
    Remove-Module Maester-SetupHelpers -Force -ErrorAction SilentlyContinue
    Remove-Item function:az, function:azd
    if ($savedAz) { Set-Item function:global:az $savedAz }
    if ($savedAzd) { Set-Item function:global:azd $savedAzd }
    Remove-Variable EntrypointState -Scope Global
  }

  It 'rejects <entry> <case> before every downstream mutation' -ForEach @(
    foreach ($entry in 'Build','Start','Setup') {
      foreach ($case in 'wrong tenant','wrong subscription','Disabled','missing state','missing tenant','failed read','malformed read') { @{ entry = $entry; case = $case } }
    }
  ) {
    switch ($case) {
      'wrong tenant' { $global:EntrypointState.Metadata.tenantId = '33333333-3333-4333-8333-333333333333' }
      'wrong subscription' { $global:EntrypointState.Metadata.subscriptionId = '44444444-4444-4444-8444-444444444444' }
      'Disabled' { $global:EntrypointState.Metadata.state = 'Disabled' }
      'missing state' { $global:EntrypointState.Metadata.Remove('state') }
      'missing tenant' { $global:EntrypointState.Metadata.Remove('tenantId') }
      'failed read' { $global:EntrypointState.FailRead = $true }
      'malformed read' { $global:EntrypointState.Malformed = $true }
    }
    { Invoke-GuardedEntrypoint $entry } | Should -Throw
    $global:EntrypointState.Builds | Should -Be 0
    $global:EntrypointState.Writes | Should -Be 0
    Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    @($global:EntrypointState.Calls | Where-Object { $_ -notlike 'rest *' }).Count | Should -Be 0
  }

  It 'requires expected tenant before <_> can perform any remote operation' -ForEach @('Build','Start','Setup') {
    { Invoke-GuardedEntrypoint $_ -NoTenant } | Should -Throw '*TenantId is required*'
    $global:EntrypointState.Calls.Count | Should -Be 0
    Should -Invoke Invoke-RestMethod -Times 0 -Exactly
  }

  It 'builds and updates only the intended target despite an unrelated default account' {
    Invoke-GuardedEntrypoint Build
    $global:EntrypointState.Builds | Should -Be 1
    $global:EntrypointState.Writes | Should -Be 1
    $global:EntrypointState.Reads | Should -Be 3
    Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' -and $Uri -like '*/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/selected-group/providers/Microsoft.App/jobs/selected-job?*' }
  }

  It 'starts and returns the successful selected job outcome despite an unrelated default account' {
    $r = Invoke-GuardedEntrypoint Start
    $r.ValidationPassed | Should -BeTrue
    $global:EntrypointState.Writes | Should -Be 1
    $global:EntrypointState.Reads | Should -Be 2
  }

  It 'rejects status-only success when the exact receipt is <_>' -ForEach @('missing','stale','malformed') {
    $global:EntrypointState.ReceiptMode = $_
    { Invoke-GuardedEntrypoint Start } | Should -Throw '*receiptUnavailableOrInvalid*'
    $global:EntrypointState.Writes | Should -Be 1
  }

  It 'preserves normal mail-enabled postprovision without claiming delivery validation' {
    $global:EntrypointState.Env += [pscustomobject]@{ name='MAIL_RECIPIENT'; value='recipient@example.invalid' }
    $r = Invoke-GuardedEntrypoint Start
    $r.ValidationPassed | Should -BeTrue
    $r.ValidationScope | Should -Be 'AssessmentAndBlobWebAppPublication'
    $r.MailDeliveryVerified | Should -BeFalse
    $r.PublicationEvidence.Mail | Should -Be 'UpstreamUnverified'
    $global:EntrypointState.Writes | Should -Be 1
  }

  It 'refuses to start without existing receipt data access' {
    $global:EntrypointState.ReaderDenied = $true
    { Invoke-GuardedEntrypoint Start } | Should -Throw '*receiptReaderUnavailable*'
    $global:EntrypointState.Writes | Should -Be 0
  }

  It 'rejects duplicate destinations, unsafe accounts and mail before start' -ForEach @('duplicate','host','mail','newline') {
    switch ($_) {
      'duplicate' { $global:EntrypointState.Env += [pscustomobject]@{ name = 'STORAGE_ACCOUNT_NAME'; value = 'otherstorage' } }
      'host' { $global:EntrypointState.Env[0].value = 'attacker.invalid/path' }
      'newline' { $global:EntrypointState.Env[0].value = "selectedstorage`n" }
      'mail' { $global:EntrypointState.RequireNoMail = $true; $global:EntrypointState.Env += [pscustomobject]@{ name = 'MAIL_RECIPIENT'; value = 'recipient@example.invalid' } }
    }
    { Invoke-GuardedEntrypoint Start } | Should -Throw '*validation.*'
    $global:EntrypointState.Writes | Should -Be 0
  }

  It 'accepts the configured environment tenant for direct build calls' {
    $env:AZURE_TENANT_ID = $global:EntrypointState.Tenant
    Invoke-GuardedEntrypoint Build -NoTenant
    $global:EntrypointState.Builds | Should -Be 1
  }

  It 'rechecks Enabled state after discovery and refuses the ACR build' {
    $global:EntrypointState.DisableAt = 2
    { Invoke-GuardedEntrypoint Build } | Should -Throw '*currently be Enabled*'
    $global:EntrypointState.Builds | Should -Be 0
    $global:EntrypointState.Writes | Should -Be 0
  }

  It 'rechecks Enabled state after a long ACR build and refuses the job update' {
    $global:EntrypointState.DisableAt = 3
    { Invoke-GuardedEntrypoint Build } | Should -Throw '*currently be Enabled*'
    $global:EntrypointState.Builds | Should -Be 1
    $global:EntrypointState.Writes | Should -Be 0
  }

  It 'rechecks Enabled state before job start despite a previous valid read' {
    $global:EntrypointState.DisableAt = 2
    { Invoke-GuardedEntrypoint Start } | Should -Throw '*currently be Enabled*'
    $global:EntrypointState.Writes | Should -Be 0
  }

  It 'reports execution failure as failure rather than a successful validation' {
    $global:EntrypointState.Status = 'Failed'
    { Invoke-GuardedEntrypoint Start } | Should -Throw '*did not succeed*Failed*'
  }
}

Describe 'Setup entrypoint forwards the validated tenant through real Exchange token splatting' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $savedLocation = Get-Location
    $savedAz = (Get-Command az -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
    $savedAzd = (Get-Command azd -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
    $savedEnv = @{}
    foreach ($name in 'AZURE_ENV_NAME','AZURE_TENANT_ID','INCLUDE_TEAMS','INCLUDE_AZURE','MAIL_RECIPIENT') { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $null) }
    Import-Module (Join-Path $root 'scripts/vendor/Azd.MaesterHooks/Maester-SetupHelpers.psm1') -Force
    function global:az {
      $a = @($args); $s = $global:ExchangeEntryState; $global:LASTEXITCODE = 0
      if ($a[0] -eq 'rest' -and ($a -join ' ') -like "*--subscription $($s.Sub)*") { return ($s.Metadata | ConvertTo-Json -Compress) }
      if ($a[0] -eq 'account' -and $a[1] -eq 'get-access-token') {
        if ('https://outlook.office365.com' -in $a) {
          $s.OutlookArgs = $a
          if ('--tenant' -notin $a -or $a[([array]::IndexOf($a,'--tenant') + 1)] -ne $s.Tenant) { throw 'Unscoped Outlook request' }
          return (@{ accessToken = 'offline-outlook'; tenant = $s.TokenTenant } | ConvertTo-Json -Compress)
        }
        if (($a -join ' ') -like "*--subscription $($s.Sub)*") { return 'offline-arm' }
      }
      throw "Unexpected offline az: $($a -join ' ')"
    }
    function global:azd {
      $a = @($args); $global:LASTEXITCODE = 0
      if ($a[0] -eq 'env' -and $a[1] -eq 'get-values') { return ($global:ExchangeEntryState.Values | ConvertTo-Json -Compress) }
      if ($a[0] -eq 'env' -and $a[1] -eq 'set' -and $a[2] -eq '-e' -and $a[3] -eq 'selected') { return }
      throw "Unexpected offline azd: $($a -join ' ')"
    }
    function Get-MaesterSetupScopes { @('Application.Read.All') }
    function Get-MaesterSetupAccessPlan { throw 'Reached end of Exchange test boundary' }
    # Migration inventory is covered separately; keep this fixture at its Exchange boundary.
    function Assert-MaesterKeylessProvisioning { }
    function global:Invoke-MgGraphRequest { param($Method,$Uri) throw 'Unmocked Graph request' }
    function global:Connect-ExchangeOnline { param($AccessToken,$ShowBanner,$Organization) $global:ExchangeEntryState.Connected++; $AccessToken | Should -Be 'offline-outlook' }
    function global:New-ServicePrincipal { param($AppId,$ObjectId,$DisplayName) $global:ExchangeEntryState.ExchangeWrites++ }
    function global:New-ManagementRoleAssignment { param($Role,$App) $global:ExchangeEntryState.ExchangeWrites++; return [pscustomobject]@{ Identity = 'offline-role' } }
  }
  BeforeEach {
    $sub = '11111111-1111-4111-8111-111111111111'; $tenant = '22222222-2222-4222-8222-222222222222'
    $global:ExchangeEntryState = @{
      Sub = $sub; Tenant = $tenant; TokenTenant = $tenant; OutlookArgs = @(); Connected = 0; ExchangeWrites = 0
      Metadata = @{ id = "/subscriptions/$sub"; subscriptionId = $sub; tenantId = $tenant; displayName = 'Selected'; state = 'Enabled' }
      Values = @{ AZURE_ENV_NAME = 'selected'; AZURE_SUBSCRIPTION_ID = $sub; AZURE_RESOURCE_GROUP = 'selected-group'; STORAGE_ACCOUNT_NAME = 'selectedstorage'; WEB_APP_ENABLED = 'false'; containerAppJobName = 'selected-job'; containerAppJobPrincipalId = '33333333-3333-4333-8333-333333333333' }
    }
    Mock Import-Module {} -ParameterFilter { $Name -like '*Maester-SetupHelpers.psm1' -or $Name -like '*Maester-ConsentPlan.psm1' -or $Name -like '*Maester-SetupConsent.psm1' -or $Name -like '*Maester-KeylessMigration.psm1' }
    Mock Assert-GraphAccess {}
    Mock Get-Module { [pscustomobject]@{ Name = 'ExchangeOnlineManagement' } } -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
    Mock Invoke-GraphRestRequest {
      if ($Uri -like '*/organization?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ verifiedDomains = @([pscustomobject]@{ isInitial = $true; name = 'selected.onmicrosoft.com' }) }) } }
      if ($Method -ne 'GET') { throw 'Unexpected Graph write' }
      $roles = @('Directory.Read.All','DirectoryRecommendations.Read.All','IdentityRiskEvent.Read.All','Policy.Read.All','Policy.Read.ConditionalAccess','RoleManagement.Read.All','Reports.Read.All','UserAuthenticationMethod.Read.All')
      if ($Uri -like '*/me?*') { return $null }
      if ($Uri -like '*appRoleAssignments*') {
        return [pscustomobject]@{ value = @($roles | ForEach-Object { [pscustomobject]@{ principalId = '33333333-3333-4333-8333-333333333333'; resourceId = 'graph'; appRoleId = $_ } }) }
      }
      return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'graph'; appId = '00000003-0000-0000-c000-000000000000'; appRoles = @($roles | ForEach-Object { [pscustomobject]@{ id = $_; value = $_; isEnabled = $true; allowedMemberTypes = @('Application') } }) }) }
    }
    Mock Connect-MgGraphSilent {}
    Mock Test-ModuleAvailable { return $true }
    Mock Grant-ServicePrincipalAppRoleAssignment { return $null }
    Mock Resolve-StepFailureAction { return 'Stop' }
    Mock Invoke-MgGraphRequest {
      if ($Uri -like '*/organization?*') { return [pscustomobject]@{ value = @([pscustomobject]@{ verifiedDomains = @([pscustomobject]@{ isInitial = $true; name = 'selected.onmicrosoft.com' }) }) } }
      return [pscustomobject]@{ appId = '44444444-4444-4444-8444-444444444444'; displayName = 'selected-job' }
    }
    Mock Invoke-RestMethod {
      if ($Method -ne 'GET') { throw 'Reached end of Exchange test boundary' }
      $id = ([uri]$Uri).AbsolutePath
      $type = if ($id -like '*/storageAccounts/*') { 'Microsoft.Storage/storageAccounts' } else { 'Microsoft.App/jobs' }
      return [pscustomobject]@{
        id = $id; name = ($id -split '/')[-1]; type = $type
        tags = @{ workload = 'maester'; solution = 'container-app-job'; environment = 'selected'; managedBy = 'azd' }
        identity = @{ type = 'SystemAssigned'; principalId = '33333333-3333-4333-8333-333333333333' }
      }
    }
  }
  AfterEach { Set-Location $savedLocation }
  AfterAll {
    foreach ($name in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnv[$name]) }
    Remove-Item function:az, function:azd, function:Invoke-MgGraphRequest, function:Connect-ExchangeOnline, function:New-ServicePrincipal, function:New-ManagementRoleAssignment
    if ($savedAz) { Set-Item function:global:az $savedAz }
    if ($savedAzd) { Set-Item function:global:azd $savedAzd }
    Remove-Module Maester-SetupHelpers -Force -ErrorAction SilentlyContinue
    Remove-Variable ExchangeEntryState -Scope Global
  }
  It 'runs the actual setup caller and real helper with selected-tenant Outlook arguments' {
    { & (Join-Path $root 'scripts/Setup-PostDeploy.ps1') -SubscriptionId $global:ExchangeEntryState.Sub -TenantId $global:ExchangeEntryState.Tenant -EnvironmentName selected -ResourceGroupName selected-group -IncludeExchange -PermissionProfile Minimal } | Should -Throw '*end of Exchange test boundary*'
    $global:ExchangeEntryState.Connected | Should -Be 1
    $global:ExchangeEntryState.ExchangeWrites | Should -Be 0
    ($global:ExchangeEntryState.OutlookArgs -join ' ') | Should -BeLike '*--tenant 22222222-2222-4222-8222-222222222222'
  }
  It 'stops the actual setup Exchange role path when Outlook returns a different tenant' {
    $global:ExchangeEntryState.TokenTenant = '55555555-5555-4555-8555-555555555555'
    { & (Join-Path $root 'scripts/Setup-PostDeploy.ps1') -SubscriptionId $global:ExchangeEntryState.Sub -TenantId $global:ExchangeEntryState.Tenant -EnvironmentName selected -ResourceGroupName selected-group -IncludeExchange -PermissionProfile Minimal } | Should -Throw '*Exchange Online token acquisition failed*'
    $global:ExchangeEntryState.Connected | Should -Be 0
    $global:ExchangeEntryState.ExchangeWrites | Should -Be 0
  }
}
