#Requires -Version 7.6
Describe 'Private viewer foundation ARM contract' {
  BeforeAll {
    $script:repo = Split-Path $PSScriptRoot -Parent
    $script:module = Join-Path $script:repo 'infra/modules/maester-viewer-private.bicep'
    $script:bicep = $env:BICEP_CLI_PATH
    if ([string]::IsNullOrWhiteSpace($script:bicep)) { throw 'BICEP_CLI_PATH must identify the reviewed Bicep binary.' }
    $script:arm = Join-Path $TestDrive 'viewer-private.json'
    if (-not (Test-Path $script:bicep)) { throw 'Pinned Bicep 0.46.1 binary is unavailable.' }
    $script:compileOutput = & $script:bicep build $script:module --outfile $script:arm --no-restore 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Private viewer module did not compile.' }
    if ($script:compileOutput -match 'BCP081') { throw 'Private viewer module uses an untyped resource API.' }
    $script:template = Get-Content $script:arm -Raw | ConvertFrom-Json
    $script:resources = @($script:template.resources.PSObject.Properties.Value)
    $script:app = @($script:resources | Where-Object type -eq 'Microsoft.App/containerApps')[0]
  }

  It 'compiles with the pinned Bicep binary and has exactly two containers' {
    @($script:template.resources.PSObject.Properties.Name) | Should -Be @('managedEnvironment', 'storageAccount', 'blobService', 'projectionContainer', 'viewerIdentity', 'viewerReader', 'viewerApp')
    @($script:app.properties.template.containers).Count | Should -Be 2
    @($script:app.properties.template.containers).name | Should -Be @('worker', 'caddy')
  }

  It 'keeps the private topology and bounded fixed replica count' {
    $script:app.properties.PSObject.Properties.Name | Should -Not -Contain 'ingress'
    $script:app.properties.configuration.PSObject.Properties.Name | Should -Not -Contain 'ingress'
    $script:app.properties.template.scale.minReplicas | Should -Be "[parameters('replicaFloor')]"
    $script:app.properties.template.scale.maxReplicas | Should -Be "[parameters('replicaFloor')]"
    $script:app.identity.type | Should -Be 'UserAssigned'
    $script:app.location | Should -Be "[parameters('location')]"
    $script:app.properties.managedEnvironmentId | Should -Be "[if(equals(parameters('location'), reference('managedEnvironment', '2025-07-01', 'full').location), resourceId('Microsoft.App/managedEnvironments', last(split(variables('validatedManagedEnvironmentId'), '/'))), fail('location must match the existing managed environment region.'))]"
  }

  It 'passes only canonical worker arguments and preserves fixed image entrypoints' {
    $worker = @($script:app.properties.template.containers | Where-Object name -eq 'worker')[0]
    @($worker.args) | Should -Be @(
      '-StorageAccountName', "[variables('validatedStorageAccountName')]",
      '-ProjectionContainerName', "[parameters('projectionContainerName')]",
      '-TenantId', "[variables('validatedTenantId')]",
      '-Environment', "[variables('validatedEnvironmentName')]",
      '-UserAssignedIdentityClientId', "[reference('viewerIdentity').clientId]"
    )
    $caddy = @($script:app.properties.template.containers | Where-Object name -eq 'caddy')[0]
    $caddy.PSObject.Properties.Name | Should -Not -Contain 'args'
    $script:app.properties.template.containers | ForEach-Object {
      $_.PSObject.Properties.Name | Should -Not -Contain 'command'
      $_.PSObject.Properties.Name | Should -Not -Contain 'volumeMounts'
    }
  }

  It 'contains only the exact projection-container reader assignment' {
    $roles = @($script:resources | Where-Object type -like '*roleAssignments')
    $roles.Count | Should -Be 1
    $roles[0].properties.roleDefinitionId | Should -Be "[variables('storageBlobDataReaderRoleId')]"
    $roles[0].scope | Should -Be "[resourceId('Microsoft.Storage/storageAccounts/blobServices/containers', variables('validatedStorageAccountName'), 'default', parameters('projectionContainerName'))]"
    $script:template.variables.storageBlobDataReaderRoleId | Should -Be "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')]"
    $roles[0].properties.principalId | Should -Be "[reference('viewerIdentity').principalId]"
    $script:template.resources.projectionContainer.existing | Should -BeTrue
    $script:template.parameters.projectionContainerName.allowedValues | Should -Be @('viewer-projection')
    $script:resources | Where-Object type -eq 'Microsoft.App/containerApps' | Select-Object -ExpandProperty apiVersion | Should -Be '2025-07-01'
    $script:resources | Where-Object type -eq 'Microsoft.App/managedEnvironments' | Select-Object -ExpandProperty apiVersion | Should -Be '2025-07-01'
    @($script:resources | Where-Object type -eq 'Microsoft.ManagedIdentity/userAssignedIdentities').Count | Should -Be 1
    @($script:app.identity.userAssignedIdentities.PSObject.Properties.Name).Count | Should -Be 1
    @($script:app.identity.userAssignedIdentities.PSObject.Properties.Name)[0] | Should -Be "[format('{0}', resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', variables('viewerIdentityName')))]"
  }

  It 'keeps module unwired and free of secret or registry configuration' {
    (Get-Content (Join-Path $script:repo 'infra/main.bicep') -Raw) | Should -Not -Match 'maester-viewer-private'
    $script:app.properties.configuration.PSObject.Properties.Name | Should -Not -Contain 'registries'
    $script:app.properties.template.PSObject.Properties.Name | Should -Not -Contain 'volumes'
    $script:app.properties.template.PSObject.Properties.Name | Should -Not -Contain 'initContainers'
    (Get-Content $script:module -Raw) | Should -Not -Match '(?i)secret|listKeys|SAS|password'
  }

  It 'retains declared input guards and bounds image references' {
    $source = Get-Content $script:module -Raw
    $source | Should -Match "fail\('workerImage must be an immutable lowercase sha256 image from a supported public registry\."
    $source | Should -Match "fail\('caddyImage must be an immutable lowercase sha256 image from a supported public registry\."
    $source | Should -Match "projectionContainerName"
    $source | Should -Match "StorageBlobDataReader"
    $source | Should -Match "tenantId == subscription\(\)\.tenantId"
    $script:template.variables.validatedTenantId | Should -Be "[if(variables('tenantShapeValid'), toLower(subscription().tenantId), fail('tenantId must equal the selected subscription tenant.'))]"
    $script:template.parameters.workerImage.maxLength | Should -Be 512
    $script:template.parameters.caddyImage.maxLength | Should -Be 512
    $source | Should -Not -Match "StorageBlobDataContributor|Owner|Contributor|archive"
  }
}
