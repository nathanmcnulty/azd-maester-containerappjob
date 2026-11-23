BeforeAll {
  $repoRoot = Split-Path $PSScriptRoot -Parent
  Import-Module (Join-Path $repoRoot 'scripts/Maester-KeylessMigration.psm1') -Force
}
Describe 'Read-only keyless migration guard' {
  BeforeEach {
    InModuleScope Maester-KeylessMigration {
      $script:sub = '11111111-1111-4111-8111-111111111111'
      $script:tenant = '22222222-2222-4222-8222-222222222222'
      $script:group = "/subscriptions/$sub/resourceGroups/rg-test"
      $script:account = "$group/providers/Microsoft.Storage/storageAccounts/test"
      $script:job = "$group/providers/Microsoft.App/jobs/job"
      $script:environment = "$group/providers/Microsoft.App/managedEnvironments/env"
      $script:principal = '33333333-3333-4333-8333-333333333333'
      $script:state = @{ missing = $false; sharedKey = $false; volume = $false; registration = $false; broadRole = $false; roleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'; roleScope = $script:account; rolesMissing = $false; wrongGroup = $false }
      Mock Get-MaesterDeploymentValues { @{ AZURE_TENANT_ID = $script:tenant } }
      Mock Get-AzCliSubscriptionContext { @{ id = $script:sub; tenantId = $script:tenant } }
      Mock Invoke-MaesterMigrationRead {
        param($Path)
        if ($Path -eq "${script:group}?api-version=2021-04-01") {
          if ($state.missing) { return $null }
          return @{ id = $(if ($state.wrongGroup) { '/wrong' } else { $script:group }) }
        }
        if ($Path -eq "$script:group/resources?api-version=2021-04-01") {
          return @{ value = @(@{ id = $script:account; type = 'Microsoft.Storage/storageAccounts' }, @{ id = $script:job; type = 'Microsoft.App/jobs' }, @{ id = $script:environment; type = 'Microsoft.App/managedEnvironments' }) }
        }
        if ($Path -eq "${script:account}?api-version=2023-05-01") { return @{ id = $script:account; properties = @{ allowSharedKeyAccess = $state.sharedKey } } }
        if ($Path -eq "${script:job}?api-version=2024-03-01") { return @{ id = $script:job; identity = @{ principalId = $script:principal }; properties = @{ template = @{ volumes = @(if ($state.volume) { @(@{ name = 'scripts'; storageType = 'AzureFile' }) } else { @() }) } } } }
        if ($Path -eq "$script:environment/storages?api-version=2024-03-01") { return @{ value = @(if ($state.registration) { @(@{ id = "$script:environment/storages/scriptstorage"; name = 'scriptstorage'; properties = @{ azureFile = @{ accountName = 'test' } } }) } else { @() }) } }
        if ($Path -like '*/providers/Microsoft.Authorization/roleAssignments?*') {
          if ($state.rolesMissing) { return @{} }
          return @{ value = @(if ($state.broadRole) { @(@{ id = "$($state.roleScope)/providers/Microsoft.Authorization/roleAssignments/old"; properties = @{ principalId = $script:principal; roleDefinitionId = "/providers/Microsoft.Authorization/roleDefinitions/$($state.roleId)" } }) } else { @() }) }
        }
        throw "Unexpected read: $Path"
      }
      $script:parameters = @{ SubscriptionId = $sub; TenantId = $tenant; ResourceGroupName = 'rg-test'; EnvironmentName = 'test' }
    }
  }
  It 'permits a verified fresh resource group and a verified keyless deployment' {
    InModuleScope Maester-KeylessMigration {
      { Assert-MaesterKeylessProvisioning @parameters } | Should -Not -Throw
      $state.missing = $true
      { Assert-MaesterKeylessProvisioning @parameters } | Should -Not -Throw
    }
  }
  It 'blocks <Field> without any write path' -ForEach @(@{ Field = 'sharedKey' }, @{ Field = 'volume' }, @{ Field = 'registration' }, @{ Field = 'broadRole' }) {
    InModuleScope Maester-KeylessMigration -Parameters @{ Field = $Field } {
      $state[$Field] = $true
      { Assert-MaesterKeylessProvisioning @parameters } | Should -Throw '*receipt-aware*'
    }
  }
  It 'blocks inherited Blob Data Owner without pretending Reader restricts it' {
    InModuleScope Maester-KeylessMigration {
      $state.broadRole = $true
      $state.roleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
      $state.roleScope = "/subscriptions/$sub"
      { Assert-MaesterKeylessProvisioning @parameters } | Should -Throw '*Broad job Blob writer*'
      Should -Invoke Invoke-MaesterMigrationRead -Times 1 -Exactly -ParameterFilter { $Path -like '*roleAssignments?*atScope()*' }
    }
  }
  It 'fails closed on incomplete inventories and wrong group identity' {
    InModuleScope Maester-KeylessMigration {
      $state.rolesMissing = $true
      { Assert-MaesterKeylessProvisioning @parameters } | Should -Throw '*Missing role assignment*'
      $state.wrongGroup = $true
      { Assert-MaesterKeylessProvisioning @parameters } | Should -Throw '*identity mismatch*'
    }
  }
  It 'runs before wizard and receipt initialization and has no mutation API' {
    $hook = Get-Content (Join-Path $repoRoot 'scripts/Run-AzdPreProvision.ps1') -Raw
    $hook.IndexOf('Assert-MaesterKeylessProvisioning -') | Should -BeLessThan $hook.IndexOf('Invoke-MaesterPreProvision `')
    $setup = Get-Content (Join-Path $repoRoot 'scripts/Setup-PostDeploy.ps1') -Raw
    $setup.IndexOf('Assert-MaesterKeylessProvisioning -') | Should -BeLessThan $setup.IndexOf('Assert-GraphAccess -')
    $setup | Should -Match '(?s)function Assert-CurrentSetupTargets \{\s+Assert-MaesterKeylessProvisioning -'
    $module = Get-Content (Join-Path $repoRoot 'scripts/Maester-KeylessMigration.psm1') -Raw
    $module | Should -Not -Match '-Method (PUT|POST|PATCH|DELETE)|Set-Content|Remove-Item|listKeys'
    $module | Should -Match '-MaximumRedirection 0'
  }
}

Describe 'Migration transport boundaries' {
  BeforeEach {
    InModuleScope Maester-KeylessMigration {
      $script:group = '/subscriptions/11111111-1111-4111-8111-111111111111/resourceGroups/rg-test'
      $script:transport = @{ status = 200; content = '{"value":[]}' }
      Mock Get-AzCliAccessToken { 'test-token-never-logged' }
      Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = $script:transport.status; Content = $script:transport.content } }
      $script:read = @{ GroupId = $group; SubscriptionId = '11111111-1111-4111-8111-111111111111'; TenantId = '22222222-2222-4222-8222-222222222222' }
    }
  }
  It 'allows only exact resource-group 404 as absence' {
    InModuleScope Maester-KeylessMigration {
      $transport.status = 404
      Invoke-MaesterMigrationRead @read -Path "${group}?api-version=2021-04-01" | Should -BeNullOrEmpty
      { Invoke-MaesterMigrationRead @read -Path "$group/resources?api-version=2021-04-01" } | Should -Throw '*incomplete*'
    }
  }
  It 'rejects redirect and denied inventory status <Code>' -ForEach @(301, 302, 401, 403, 500) {
    InModuleScope Maester-KeylessMigration -Parameters @{ Code = $_ } {
      $transport.status = $Code
      { Invoke-MaesterMigrationRead @read -Path "$group/resources?api-version=2021-04-01" } | Should -Throw '*incomplete*'
    }
  }
  It 'rejects pagination and target escapes before new requests' {
    InModuleScope Maester-KeylessMigration {
      $transport.content = '{"value":[],"nextLink":"https://evil.invalid"}'
      { Invoke-MaesterMigrationRead @read -Path "$group/resources?api-version=2021-04-01" } | Should -Throw '*paginated*'
      { Invoke-MaesterMigrationRead @read -Path "$group-other/resources?api-version=2021-04-01" } | Should -Throw '*escaped*'
      Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $MaximumRedirection -eq 0 -and $TimeoutSec -eq 60 -and $OperationTimeoutSeconds -eq 60 }
    }
  }
}
