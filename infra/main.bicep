targetScope = 'resourceGroup'

@description('Deployment location')
@metadata({
  azd: {
    type: 'location'
    default: 'eastus2'
  }
})
param location string = resourceGroup().location

@description('Environment name from azd')
param environmentName string = 'dev'

@description('Container image to use for the Maester job')
param imageName string = 'mcr.microsoft.com/dotnet/runtime-deps:10.0-noble@sha256:9bc5729cebc4847b28da997c802ab71ce3a2ac42512260c3a151f61132b26f7b'

@description('Optional user-assigned managed identity resource id')
param userAssignedIdentityResourceId string = ''

@description('Optional mail recipient address for Maester report notifications')
param mailRecipient string = ''

@description('Deploy optional Web App hosting component')
@allowed([
  'true'
  'false'
])
@metadata({
  azd: {
    default: 'false'
  }
})
param includeWebAppOption string = 'false'

@description('Enable Exchange Online connectivity and permissions for Maester')
@allowed([
  'true'
  'false'
])
@metadata({
  azd: {
    default: 'false'
  }
})
param includeExchangeOption string = 'false'

@description('Enable Microsoft Teams connectivity and permissions for Maester')
@allowed([
  'true'
  'false'
])
@metadata({
  azd: {
    default: 'false'
  }
})
param includeTeamsOption string = 'false'

@description('Enable Azure RBAC role assignments for Maester')
@allowed([
  'true'
  'false'
])
@metadata({
  azd: {
    default: 'false'
  }
})
param includeAzureOption string = 'false'

@description('Optional Web App SKU for hosting report access portal')
param webAppSkuName string = 'F1'

@description('Deploy Azure Container Registry and build custom Maester image')
@allowed([
  'true'
  'false'
])
@metadata({
  azd: {
    default: 'false'
  }
})
param includeACROption string = 'false'

@description('Job trigger: Schedule retains the weekly assessment; Manual disables scheduled executions.')
@allowed([
  'Schedule'
  'Manual'
])
@metadata({
  azd: {
    default: 'Schedule'
  }
})
param jobTriggerType string = 'Schedule'

var manualJobTriggerConfiguration = {
  triggerType: 'Manual'
  manualTriggerConfig: {
    parallelism: 1
    replicaCompletionCount: 1
  }
}
var scheduledJobTriggerConfiguration = {
  triggerType: 'Schedule'
  scheduleTriggerConfig: {
    cronExpression: '0 0 * * 0'
    parallelism: 1
    replicaCompletionCount: 1
  }
}

@description('Enable can-not-delete locks on key resources')
param enableResourceLocks bool = true

@description('Optional custom tags merged onto top-level resources')
param customTags object = {}

// Standardized parameters and tags for consistency with automation-account and function-app.
// Keep provider resource names within their service limits even when an azd
// environment name is long. The stable suffix prevents collisions between
// environments sharing the same name prefix.
var normalizedEnvironmentName = toLower(environmentName)
var resourceSuffix = toLower(uniqueString(resourceGroup().id, environmentName))
var managedEnvironmentName = 'cae-${substring(normalizedEnvironmentName, 0, min(length(normalizedEnvironmentName), 48))}-${substring(resourceSuffix, 0, 6)}'
var containerAppJobName = 'caj-maester-${substring(normalizedEnvironmentName, 0, min(length(normalizedEnvironmentName), 12))}-${substring(resourceSuffix, 0, 6)}'
var storageAccountName = 'stmaester${resourceSuffix}'
var acrName = 'crmaester${resourceSuffix}'
var fileShareName = 'scripts'
var storageBlobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)
var acrPullRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)
var appServicePlanName = 'asp-${substring(normalizedEnvironmentName, 0, min(length(normalizedEnvironmentName), 28))}-${substring(resourceSuffix, 0, 6)}'
var webAppName = 'app-maester-${resourceSuffix}'
var includeWebApp = toLower(includeWebAppOption) == 'true'
var includeACR = toLower(includeACROption) == 'true'
var defaultTags = {
  workload: 'maester'
  solution: 'container-app-job'
  environment: toLower(environmentName)
  managedBy: 'azd'
}
var resourceTags = union(defaultTags, customTags)

// ──────────────────────────────────────────────
// Storage Account (Azure Files for script mount + Blob for reports)
// ──────────────────────────────────────────────

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: resourceTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true // Required for Azure Files volume mount in Container App Environment
    defaultToOAuthAuthentication: true
    accessTier: 'Hot'
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  name: 'default'
  parent: storageAccount
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  name: fileShareName
  parent: fileService
  properties: {
    shareQuota: 1
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: storageAccount
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 1
      allowPermanentDelete: true
    }
    isVersioningEnabled: false
  }
}

resource containerArchive 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: 'archive'
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

resource containerLatest 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: 'latest'
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

resource storageManagementPolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  name: 'default'
  parent: storageAccount
  properties: {
    policy: {
      rules: [
        {
          name: 'archiveTieringPolicy'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                'archive/'
              ]
            }
            actions: {
              baseBlob: {
                tierToCold: {
                  daysAfterModificationGreaterThan: 180
                }
                delete: {
                  daysAfterModificationGreaterThan: 365
                }
              }
            }
          }
        }
      ]
    }
  }
}

// ──────────────────────────────────────────────
// Container App Environment and Job
// ──────────────────────────────────────────────

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: managedEnvironmentName
  location: location
  tags: resourceTags
  properties: {
    zoneRedundant: false
  }
}

resource managedEnvironmentStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  name: 'scriptstorage'
  parent: managedEnvironment
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: fileShare.name
      accessMode: 'ReadOnly'
    }
  }
}

resource containerAppJob 'Microsoft.App/jobs@2024-03-01' = {
  name: containerAppJobName
  location: location
  tags: resourceTags
  identity: empty(userAssignedIdentityResourceId)
    ? {
        type: 'SystemAssigned'
      }
    : {
        type: 'SystemAssigned, UserAssigned'
        userAssignedIdentities: {
          '${userAssignedIdentityResourceId}': {}
        }
      }
  properties: {
    environmentId: managedEnvironment.id
    configuration: union(jobTriggerType == 'Manual' ? manualJobTriggerConfiguration : scheduledJobTriggerConfiguration, {
      replicaRetryLimit: 1
      replicaTimeout: 3600
      // ACR registry is configured post-deployment by Build-MaesterImage.ps1 to avoid
      // a circular dependency: the Job's system identity needs AcrPull before provisioning
      // can validate ACR access, but AcrPull requires the Job's principalId.
      registries: []
    })
    template: {
      containers: [
        {
          name: 'maester'
          image: imageName
          command: [
            '/bin/sh'
            '/mnt/scripts/Start-MaesterContainerJob.sh'
            includeACR ? 'acr' : 'nonacr'
          ]
          env: [
            {
              name: 'STORAGE_ACCOUNT_NAME'
              value: storageAccount.name
            }
            {
              name: 'INCLUDE_EXCHANGE'
              value: includeExchangeOption
            }
            {
              name: 'INCLUDE_TEAMS'
              value: includeTeamsOption
            }
            {
              name: 'INCLUDE_AZURE'
              value: includeAzureOption
            }
            {
              name: 'MAIL_RECIPIENT'
              value: mailRecipient
            }
            {
              name: 'WEB_APP_NAME'
              value: includeWebApp ? webAppName : ''
            }
            {
              name: 'WEB_APP_RESOURCE_GROUP_NAME'
              value: includeWebApp ? resourceGroup().name : ''
            }
          ]
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          volumeMounts: [
            {
              volumeName: 'scripts'
              mountPath: '/mnt/scripts'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'scripts'
          storageType: 'AzureFile'
          storageName: managedEnvironmentStorage.name
        }
      ]
    }
  }
}

// ──────────────────────────────────────────────
// Optional Azure Container Registry
// ──────────────────────────────────────────────

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = if (includeACR) {
  name: acrName
  location: location
  tags: resourceTags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (includeACR) {
  name: guid(acr.id, containerAppJob.id, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: containerAppJob.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ──────────────────────────────────────────────
// Role Assignments
// ──────────────────────────────────────────────

resource jobStorageBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, containerAppJob.id, 'StorageBlobDataContributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataContributorRoleId
    principalId: containerAppJob.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ──────────────────────────────────────────────
// Optional Web App
// ──────────────────────────────────────────────

module maesterWebApp './vendor/Azd.MaesterReportWebApp/maester-report-webapp.bicep' = if (includeWebApp) {
  name: 'maester-report-webapp'
  params: {
    location: location
    environmentName: environmentName
    solutionName: 'container-app-job'
    appServicePlanName: appServicePlanName
    webAppName: webAppName
    storageAccountName: storageAccount.name
    webAppSkuName: webAppSkuName
    customTags: resourceTags
    enableResourceLocks: enableResourceLocks
    systemAssignedIdentity: true
    publisherPrincipalId: containerAppJob.identity.principalId
    publisherResourceId: containerAppJob.id
  }
}

// ──────────────────────────────────────────────
// Resource Locks
// ──────────────────────────────────────────────

resource storageDeleteLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableResourceLocks) {
  name: 'lock-cannot-delete-storage'
  scope: storageAccount
  properties: {
    level: 'CanNotDelete'
    notes: 'Prevents accidental deletion of Maester storage resources.'
  }
}

resource environmentDeleteLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableResourceLocks) {
  name: 'lock-cannot-delete-environment'
  scope: managedEnvironment
  properties: {
    level: 'CanNotDelete'
    notes: 'Prevents accidental deletion of Maester container environment.'
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────

output containerAppJobName string = containerAppJob.name
output containerAppJobPrincipalId string = containerAppJob.identity.principalId
output storageAccountName string = storageAccount.name
output managedEnvironmentName string = managedEnvironment.name
output acrName string = includeACR ? acr.name : ''
output acrLoginServer string = includeACR ? acr!.properties.loginServer : ''
output webAppName string = includeWebApp ? maesterWebApp!.outputs.webAppName : ''
output STORAGE_ACCOUNT_NAME string = storageAccount.name
output WEB_APP_NAME string = includeWebApp ? maesterWebApp!.outputs.webAppName : ''
output WEB_APP_ENABLED string = includeWebApp ? 'true' : 'false'
output webAppDefaultHostName string = includeWebApp ? maesterWebApp!.outputs.webAppDefaultHostName : ''

// Exact declared IDs only. Existing identities and resources are never adopted.
// Child resources of the report-webapp module are deliberately included; keep
// these expressions aligned with the reviewed module when its declarations change.
var maesterDeclaredResourceIds = filter([
  storageAccount.id
  fileService.id
  fileShare.id
  blobService.id
  containerArchive.id
  containerLatest.id
  storageManagementPolicy.id
  managedEnvironment.id
  managedEnvironmentStorage.id
  containerAppJob.id
  includeACR ? acr!.id : ''
  includeACR ? acrPullRole!.id : ''
  jobStorageBlobContributor.id
  enableResourceLocks ? storageDeleteLock!.id : ''
  enableResourceLocks ? environmentDeleteLock!.id : ''
  includeWebApp ? resourceId('Microsoft.Resources/deployments', 'maester-report-webapp') : ''
  includeWebApp ? resourceId('Microsoft.Web/serverfarms', appServicePlanName) : ''
  includeWebApp ? resourceId('Microsoft.Web/sites', webAppName) : ''
  includeWebApp ? resourceId('Microsoft.Web/sites/basicPublishingCredentialsPolicies', webAppName, 'scm') : ''
  includeWebApp ? resourceId('Microsoft.Web/sites/basicPublishingCredentialsPolicies', webAppName, 'ftp') : ''
  includeWebApp ? extensionResourceId(resourceId('Microsoft.Web/sites', webAppName), 'Microsoft.Authorization/roleAssignments', guid(resourceId('Microsoft.Web/sites', webAppName), containerAppJob.id, 'WebsiteContributor')) : ''
  includeWebApp && enableResourceLocks ? extensionResourceId(resourceId('Microsoft.Web/sites', webAppName), 'Microsoft.Authorization/locks', 'lock-cannot-delete-webapp') : ''
], id => !empty(id))
var maesterDeclaredLockIds = filter([
  enableResourceLocks ? storageDeleteLock!.id : ''
  enableResourceLocks ? environmentDeleteLock!.id : ''
  includeWebApp && enableResourceLocks ? extensionResourceId(resourceId('Microsoft.Web/sites', webAppName), 'Microsoft.Authorization/locks', 'lock-cannot-delete-webapp') : ''
], id => !empty(id))

output MAESTER_OWNED_RESOURCE_IDS string = string(maesterDeclaredResourceIds)
output MAESTER_OWNED_LOCK_IDS string = string(maesterDeclaredLockIds)
output MAESTER_INFRASTRUCTURE_OWNERSHIP_ID string = contains(resourceGroup().tags, 'maester-ownership-id') ? resourceGroup().tags['maester-ownership-id'] : ''
