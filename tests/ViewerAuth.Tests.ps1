#Requires -Version 7.6
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

Describe 'Staged viewer authentication ARM contract' {
  BeforeAll {
    if ($PSVersionTable.PSVersion -lt [version]'7.6') { throw 'Viewer auth tests require PowerShell 7.6 or later.' }
    $pesterVersion = (Get-Module Pester).Version
    if ($pesterVersion -ne [version]'6.2.0') { throw "Viewer auth tests require exact Pester 6.2.0; loaded $pesterVersion." }

    $script:repo = Split-Path $PSScriptRoot -Parent
    $script:module = Join-Path $script:repo 'infra/modules/maester-viewer-auth.bicep'
    $script:bicep = $env:BICEP_CLI_PATH
    if ([string]::IsNullOrWhiteSpace($script:bicep) -or -not (Test-Path -LiteralPath $script:bicep -PathType Leaf)) {
      throw 'BICEP_CLI_PATH must identify the reviewed Bicep 0.46.1 binary.'
    }
    $versionOutput = (& $script:bicep --version 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $versionOutput -notmatch 'Bicep CLI version 0\.46\.1\b') {
      throw 'Viewer auth tests require exact Bicep 0.46.1.'
    }

    $script:armPath = Join-Path $TestDrive 'viewer-auth.json'
    $script:compileOutput = @(& $script:bicep build $script:module --outfile $script:armPath --no-restore 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Viewer auth module did not compile.' }
    if ($script:compileOutput.Count -ne 0) { throw 'Viewer auth module emitted unexpected compiler or linter diagnostics.' }
    $script:template = Get-Content -LiteralPath $script:armPath -Raw | ConvertFrom-Json
    $script:resources = @($script:template.resources.PSObject.Properties.Value)
    $script:auth = $script:template.resources.authConfig
  }

  It 'compiles only one existing app reference and its current auth child' {
    @($script:template.resources.PSObject.Properties.Name) | Should -Be @('viewerApp', 'authConfig')
    $script:template.resources.viewerApp.existing | Should -BeTrue
    $script:template.resources.viewerApp.type | Should -Be 'Microsoft.App/containerApps'
    $script:template.resources.viewerApp.apiVersion | Should -Be '2025-07-01'
    $script:auth.type | Should -Be 'Microsoft.App/containerApps/authConfigs'
    $script:auth.apiVersion | Should -Be '2025-07-01'
    $script:auth.name | Should -Be "[format('{0}/{1}', variables('validatedAppName'), 'current')]"
    @($script:auth.dependsOn) | Should -Be @('viewerApp')
    $script:template.outputs.authConfigResourceId.value | Should -Be "[resourceId('Microsoft.App/containerApps/authConfigs', variables('validatedAppName'), 'current')]"
  }

  It 'binds the app, tenant, cloud, client, group and fixed secret-setting name before use' {
    @($script:template.parameters.PSObject.Properties.Name) | Should -Be @(
      'appResourceId', 'tenantId', 'clientId', 'approvedGroupId'
    )
    $script:template.variables.clientSecretSettingName | Should -Be 'viewer-entra-client-secret'
    $script:template.variables.expectedAppResourceId | Should -Be "[resourceId('Microsoft.App/containerApps', variables('appName'))]"
    $script:template.variables.appResourceIdValid | Should -Be "[equals(toLower(parameters('appResourceId')), toLower(variables('expectedAppResourceId')))]"
    $script:template.variables.tenantValid | Should -Match "subscription\(\)\.tenantId"
    $script:template.variables.tenantValid | Should -Match "environment\(\)\.name, 'AzureCloud'"
    $script:template.variables.clientIdValid | Should -Be "[__bicep.isCanonicalGuid(parameters('clientId'))]"
    $script:template.variables.approvedGroupIdValid | Should -Be "[__bicep.isCanonicalGuid(parameters('approvedGroupId'))]"
    $script:template.variables.validatedClientId | Should -Match "variables\('clientIdValid'\)"
    $script:template.variables.validatedApprovedGroupId | Should -Match "variables\('approvedGroupIdValid'\)"

  }

  It 'declares the private-app prerequisite on the auth properties' {
    $guard = $script:auth.properties.platform.enabled
    $guard | Should -Match "reference\('viewerApp'\)"
    $guard | Should -Match "tryGet\(tryGet\(.+, 'configuration'\), 'ingress'\)"
    $guard | Should -Match "equals\(.+, null\(\)\)"
    $guard | Should -Match "fail\('The existing Container App must remain private with ingress absent before auth configuration is written\.'\)"
    $guard | Should -Not -Match 'AllowAnonymous|RedirectToLoginPage'
  }

  It 'enables only Entra ID with one audience and one approved group' {
    $properties = $script:auth.properties
    $properties.platform.enabled | Should -Not -BeNullOrEmpty
    $properties.globalValidation.unauthenticatedClientAction | Should -Be 'Return401'
    @($properties.globalValidation.excludedPaths).Count | Should -Be 0
    $properties.globalValidation.PSObject.Properties.Name | Should -Not -Contain 'redirectToProvider'

    @($properties.identityProviders.PSObject.Properties.Name) | Should -Be @('azureActiveDirectory')
    $aad = $properties.identityProviders.azureActiveDirectory
    $aad.enabled | Should -BeTrue
    $aad.PSObject.Properties.Name | Should -Be @('enabled', 'registration', 'validation')
    $aad.registration.clientId | Should -Be "[variables('validatedClientId')]"
    $aad.registration.clientSecretSettingName | Should -Be "[variables('clientSecretSettingName')]"
    $aad.registration.openIdIssuer | Should -Be "[variables('openIdIssuer')]"
    $script:template.variables.openIdIssuer | Should -Be "[format('https://login.microsoftonline.com/{0}/v2.0', variables('validatedTenantId'))]"
    @($aad.validation.allowedAudiences) | Should -Be @("[variables('validatedClientId')]")

    $policy = $aad.validation.defaultAuthorizationPolicy
    $policy.PSObject.Properties.Name | Should -Be @('allowedPrincipals')
    @($policy.allowedPrincipals.groups) | Should -Be @("[variables('validatedApprovedGroupId')]")
    $policy.allowedPrincipals.PSObject.Properties.Name | Should -Be @('groups')
    $aad.validation.PSObject.Properties.Name | Should -Not -Contain 'jwtClaimChecks'
  }

  It 'uses HTTPS, fixed auth routes, no proxy trust, no token store and no external redirects' {
    $properties = $script:auth.properties
    $properties.httpSettings.requireHttps | Should -BeTrue
    $properties.httpSettings.forwardProxy.convention | Should -Be 'NoProxy'
    @($properties.httpSettings.forwardProxy.PSObject.Properties.Name) | Should -Be @('convention')
    $properties.httpSettings.routes.apiPrefix | Should -Be '/.auth'
    $properties.login.tokenStore.enabled | Should -BeFalse
    @($properties.login.allowedExternalRedirectUrls).Count | Should -Be 0
    $properties.login.preserveUrlFragmentsForLogins | Should -BeFalse
  }

  It 'remains unwired and creates no ingress, identity, role, secret or permission resource' {
    (Get-Content -LiteralPath (Join-Path $script:repo 'infra/main.bicep') -Raw) | Should -Not -Match 'maester-viewer-auth'
    @($script:resources | Where-Object type -like '*roleAssignments').Count | Should -Be 0
    @($script:resources | Where-Object type -like '*userAssignedIdentities').Count | Should -Be 0
    @($script:resources | Where-Object type -eq 'Microsoft.App/containerApps' | Where-Object { -not $_.existing }).Count | Should -Be 0
    $compiled = Get-Content -LiteralPath $script:armPath -Raw
    $compiled | Should -Not -Match 'Microsoft\.Graph|listKeys|listCredentials|AllowAnonymous'
    $script:auth.properties.PSObject.Properties.Name | Should -Not -Contain 'ingress'
  }
}
