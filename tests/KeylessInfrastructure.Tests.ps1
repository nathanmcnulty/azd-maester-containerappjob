Describe 'Compiled keyless runtime infrastructure' {
  BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $bicep = $env:BICEP_CLI_PATH
    if (-not $bicep) { $bicep = (Get-Command bicep -ErrorAction SilentlyContinue).Source }
    if (-not $bicep -or -not (Test-Path -LiteralPath $bicep -PathType Leaf)) { throw 'Set BICEP_CLI_PATH to the Bicep CLI executable.' }
    $compiledPath = Join-Path $TestDrive 'keyless.json'
    & $bicep build (Join-Path $root 'infra/main.bicep') --outfile $compiledPath
    if ($LASTEXITCODE -ne 0) { throw 'Production Bicep compilation failed.' }
    $compiledText = Get-Content $compiledPath -Raw
    $compiled = $compiledText | ConvertFrom-Json -AsHashtable
    $job = @($compiled.resources | Where-Object type -eq 'Microsoft.App/jobs')[0]
    $roles = @($compiled.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
  }

  It 'uses a digest-pinned official bootstrap image and preserves optional ACR' {
    $compiled.parameters.imageName.defaultValue | Should -BeExactly 'mcr.microsoft.com/azure-powershell@sha256:3459545c448b8ae639370b3cf46e1816a3d68a045e45b96ba25e46e8de815581'
    $compiled.parameters.includeACROption.defaultValue | Should -BeExactly 'false'
    $job.properties.template.containers[0].command | Should -Match '/opt/maester/Start-MaesterContainerJob.sh'
    ($compiled.variables.Values -join "`n") | Should -Match 'maester-bootstrap'
  }

  It 'disables Shared Key and declares no key lookup, SMB mount or environment storage' {
    $account = @($compiled.resources | Where-Object type -eq 'Microsoft.Storage/storageAccounts')[0]
    $account.properties.allowSharedKeyAccess | Should -BeFalse
    $compiledText | Should -Not -Match '(?i)listKeys\(|AzureFile|fileServices|managedEnvironments/storages'
    $job.properties.template.ContainsKey('volumes') | Should -BeFalse
    $job.properties.template.containers[0].ContainsKey('volumeMounts') | Should -BeFalse
  }

  It 'creates exactly three job Blob roles at private container scopes, never account scope' {
    $blobRoles = @($roles | Where-Object { $_.properties.roleDefinitionId -match 'storageBlobDataContributorRoleId|storageBlobDataReaderRoleId' })
    $blobRoles.Count | Should -Be 3
    $compiled.variables.storageBlobDataReaderRoleId | Should -Match '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    $compiled.variables.storageBlobDataContributorRoleId | Should -Match 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    @($blobRoles | Where-Object { $_.scope -match "'runtime'" -and $_.properties.roleDefinitionId -match 'storageBlobDataReaderRoleId' }).Count | Should -Be 1
    foreach ($container in 'archive', 'latest') {
      @($blobRoles | Where-Object { $_.scope -match "'$container'" -and $_.properties.roleDefinitionId -match 'storageBlobDataContributorRoleId' }).Count | Should -Be 1
    }
    foreach ($role in $blobRoles) {
      $role.scope | Should -Match '/blobServices/containers'
      $role.properties.principalType | Should -BeExactly 'ServicePrincipal'
    }
    @($compiled.resources | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts/blobServices/containers' -and $_.name -match "runtime" })[0].properties.publicAccess | Should -BeExactly 'None'
  }

  It 'starts with empty external bundle pins that fail closed until publication' {
    $envs = $job.properties.template.containers[0].env
    foreach ($name in 'MAESTER_RUNTIME_BLOB_NAME', 'MAESTER_RUNTIME_SHA256', 'MAESTER_RUNTIME_SIZE') {
      @($envs | Where-Object name -eq $name)[0].value | Should -BeExactly ''
    }
    @($envs | Where-Object name -eq 'MAESTER_RUNTIME_STORAGE_ACCOUNT').Count | Should -Be 1
    @($envs | Where-Object name -eq 'MAESTER_RUNTIME_BOOTSTRAP').Count | Should -Be 1
  }

  It 'packages executable ACR content instead of mounting a share' {
    $docker = Get-Content (Join-Path $root 'Dockerfile') -Raw
    $docker | Should -Match 'COPY scripts/Invoke-MaesterContainerJob.ps1 .* /opt/maester/'
    $docker | Should -Match 'COPY runtime-packages.lock.json /opt/maester/runtime-packages.lock.json'
    $docker | Should -Match 'CMD \["/bin/sh", "/opt/maester/Start-MaesterContainerJob.sh", "acr"\]'
    $docker | Should -Not -Match '/mnt/scripts|Azure Files'
  }
}
