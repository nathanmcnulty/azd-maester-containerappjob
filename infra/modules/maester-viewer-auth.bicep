targetScope = 'resourceGroup'

@description('Exact resource ID of the existing private Maester viewer Container App in this resource group and subscription.')
param appResourceId string

@description('Canonical Azure tenant ID. It must match the selected subscription tenant.')
param tenantId string

@description('Canonical nonzero client ID of the existing Entra application registration.')
param clientId string

@description('The one canonical nonzero Entra group ID allowed to view reports.')
param approvedGroupId string

func hasOnlyCharacters(value string, allowed string) bool => length(filter(range(0, length(value)), i => !contains(allowed, substring(value, i, 1)))) == 0
func isCanonicalGuid(value string) bool => length(value) == 36 && substring('${value}------------------------------------', 8, 1) == '-' && substring('${value}------------------------------------', 13, 1) == '-' && substring('${value}------------------------------------', 18, 1) == '-' && substring('${value}------------------------------------', 23, 1) == '-' && length(replace(value, '-', '')) == 32 && hasOnlyCharacters(replace(value, '-', ''), '0123456789abcdef') && value != '00000000-0000-0000-0000-000000000000'

var appName = last(split(appResourceId, '/'))
var expectedAppResourceId = resourceId('Microsoft.App/containerApps', appName)
var appResourceIdValid = toLower(appResourceId) == toLower(expectedAppResourceId)
var tenantValid = isCanonicalGuid(tenantId) && tenantId == toLower(subscription().tenantId) && environment().name == 'AzureCloud'
var clientIdValid = isCanonicalGuid(clientId)
var approvedGroupIdValid = isCanonicalGuid(approvedGroupId)
var clientSecretSettingName = 'viewer-entra-client-secret'

var validatedAppName = appResourceIdValid ? appName : fail('appResourceId must identify an existing Container App in this resource group and subscription.')
var validatedTenantId = tenantValid ? tenantId : fail('tenantId must be canonical, match the selected subscription tenant, and target AzureCloud.')
var validatedClientId = clientIdValid ? clientId : fail('clientId must be a canonical nonzero GUID.')
var validatedApprovedGroupId = approvedGroupIdValid ? approvedGroupId : fail('approvedGroupId must be one canonical nonzero GUID.')
#disable-next-line no-hardcoded-env-urls
var openIdIssuer = 'https://login.microsoftonline.com/${validatedTenantId}/v2.0'

resource viewerApp 'Microsoft.App/containerApps@2025-07-01' existing = {
  name: validatedAppName
}

// ARM resolves every property expression before sending the child resource PUT.
// Binding the platform flag to this read makes an ingress-bearing app fail first.
var guardedPlatformEnabled = viewerApp.properties.?configuration.?ingress == null ? true : fail('The existing Container App must remain private with ingress absent before auth configuration is written.')

resource authConfig 'Microsoft.App/containerApps/authConfigs@2025-07-01' = {
  parent: viewerApp
  name: 'current'
  properties: {
    platform: {
      enabled: guardedPlatformEnabled
    }
    globalValidation: {
      unauthenticatedClientAction: 'Return401'
      excludedPaths: []
    }
    httpSettings: {
      requireHttps: true
      forwardProxy: {
        convention: 'NoProxy'
      }
      routes: {
        apiPrefix: '/.auth'
      }
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: validatedClientId
          clientSecretSettingName: clientSecretSettingName
          openIdIssuer: openIdIssuer
        }
        validation: {
          allowedAudiences: [
            validatedClientId
          ]
          defaultAuthorizationPolicy: {
            allowedPrincipals: {
              groups: [
                validatedApprovedGroupId
              ]
            }
          }
        }
      }
    }
    login: {
      allowedExternalRedirectUrls: []
      preserveUrlFragmentsForLogins: false
      tokenStore: {
        enabled: false
      }
    }
  }
}

output authConfigResourceId string = authConfig.id
