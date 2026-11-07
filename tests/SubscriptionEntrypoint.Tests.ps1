Describe 'Ownership-aware azd subscription entry point' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $bicep = $env:BICEP_CLI_PATH
    if (-not $bicep) { $bicep = (Get-Command bicep -ErrorAction Stop).Source }
    $path = Join-Path $TestDrive 'entrypoint.json'
    & $bicep build (Join-Path $root 'infra/main.bicep') --outfile $path
    if ($LASTEXITCODE -ne 0) { throw 'azd entry point compilation failed.' }
    $compiled = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
    $deployment = @($compiled.resources | Where-Object type -eq 'Microsoft.Resources/deployments')[0]
    $group = @($compiled.resources | Where-Object type -eq 'Microsoft.Resources/resourceGroups')[0]
    $inner = $deployment.properties.template
    $mapping = Get-Content (Join-Path $root 'infra/main.parameters.json') -Raw | ConvertFrom-Json -AsHashtable
    $originalMapping = @{ parameters = @{
      environmentName = @{ value = '${AZURE_ENV_NAME}' }
      includeWebAppOption = @{ value = '${INCLUDE_WEB_APP}' }
      includeExchangeOption = @{ value = '${INCLUDE_EXCHANGE}' }
      includeTeamsOption = @{ value = '${INCLUDE_TEAMS}' }
      includeAzureOption = @{ value = '${INCLUDE_AZURE}' }
      includeACROption = @{ value = '${INCLUDE_ACR}' }
      jobTriggerType = @{ value = '${JOB_TRIGGER_TYPE=Schedule}' }
      mailRecipient = @{ value = '${MAIL_RECIPIENT}' }
      webAppSkuName = @{ value = '${WEB_APP_SKU}' }
    } }
  }

  It 'declares the group for azd teardown discovery while preserving hook-captured metadata' {
    (Get-Content (Join-Path $root 'azure.yaml') -Raw) | Should -Not -Match '(?m)^  module:'
    $compiled.'$schema' | Should -Match '/subscriptionDeploymentTemplate.json#'
    $compiled.resources.Count | Should -Be 2
    $group.name | Should -BeExactly "[parameters('resourceGroupName')]"
    $compiled.variables.groupMetadata | Should -BeExactly "[json(parameters('resourceGroupMetadataJson'))]"
    $group.location | Should -BeExactly "[variables('groupMetadata').location]"
    $group.tags | Should -BeExactly "[variables('groupMetadata').tags]"
    $deployment.dependsOn | Should -Contain "[subscriptionResourceId('Microsoft.Resources/resourceGroups', parameters('resourceGroupName'))]"
    $deployment.type | Should -BeExactly 'Microsoft.Resources/deployments'
    $deployment.resourceGroup | Should -BeExactly "[parameters('resourceGroupName')]"
    $deployment.properties.expressionEvaluationOptions.scope | Should -BeExactly 'inner'
    $inner.'$schema' | Should -Match '/deploymentTemplate.json#'
  }

  It 'forwards every existing azd setting with the same value and leaves inner resources unchanged' {
    foreach ($name in $originalMapping.parameters.Keys) {
      $mapping.parameters[$name].value | Should -BeExactly $originalMapping.parameters[$name].value
      $deployment.properties.parameters[$name].value | Should -BeExactly "[parameters('$name')]"
      if ($compiled.parameters[$name].ContainsKey('defaultValue')) {
        $compiled.parameters[$name].defaultValue | Should -BeExactly $inner.parameters[$name].defaultValue
      }
    }
    $mapping.parameters.Count | Should -Be ($originalMapping.parameters.Count + 3)
    $mapping.parameters.resourceGroupMetadataJson.value | Should -BeExactly '${MAESTER_RESOURCE_GROUP_METADATA}'
    $mapping.parameters.location.value | Should -BeExactly '${AZURE_LOCATION}'
    $mapping.parameters.resourceGroupName.value | Should -BeExactly '${AZURE_RESOURCE_GROUP}'
    ($deployment.properties.parameters.Keys | Sort-Object) -join ',' | Should -BeExactly (($inner.parameters.Keys | Sort-Object) -join ',')
    foreach ($name in $inner.parameters.Keys) {
      $deployment.properties.parameters[$name].value | Should -BeExactly "[parameters('$name')]"
      if ($name -ne 'location') {
        ($compiled.parameters[$name].defaultValue | ConvertTo-Json -Compress) | Should -BeExactly ($inner.parameters[$name].defaultValue | ConvertTo-Json -Compress)
      }
    }
    @($inner.resources | Where-Object type -eq 'Microsoft.App/jobs').Count | Should -Be 1
    @($inner.resources | Where-Object type -eq 'Microsoft.Storage/storageAccounts').Count | Should -Be 1
  }

  It 'preserves every output and accounts for the new owned deployment history resource' {
    ($compiled.outputs.Keys | Sort-Object) -join ',' | Should -BeExactly (($inner.outputs.Keys | Sort-Object) -join ',')
    $compiled.outputs.MAESTER_OWNED_RESOURCE_IDS.value | Should -Match "extensionResourceId\(.+'Microsoft.Resources/deployments', 'maester-resources'\)"
    foreach ($name in @($inner.outputs.Keys | Where-Object { $_ -ne 'MAESTER_OWNED_RESOURCE_IDS' })) {
      $compiled.outputs[$name].value | Should -Match "\.outputs\.$name\.value\]$"
    }
  }

  It 'binds the selected parameter mapping into the existing infrastructure source receipt' {
    Import-Module (Join-Path $root 'scripts/vendor/Azd.MaesterHooks/Maester-InfrastructureOwnership.psm1') -Force
    $module = Get-Module Maester-InfrastructureOwnership
    $fixture = Join-Path $TestDrive 'source-fixture'
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'infra')
    Copy-Item (Join-Path $root 'infra/main.bicep') (Join-Path $fixture 'infra/main.bicep')
    $selected = Join-Path $fixture 'infra/main.parameters.json'
    Copy-Item (Join-Path $root 'infra/main.parameters.json') $selected
    $before = & $module { param($path) Get-MaesterInfrastructureSourceHash $path } $fixture
    Add-Content $selected ' '
    (& $module { param($path) Get-MaesterInfrastructureSourceHash $path } $fixture) | Should -Not -BeExactly $before
  }
}
