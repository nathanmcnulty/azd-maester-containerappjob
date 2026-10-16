targetScope = 'resourceGroup'

@description('Existing Container Apps managed environment resource ID in this resource group.')
param managedEnvironmentResourceId string

@description('Region of the existing managed environment; checked before creating the Container App.')
param location string
@description('Existing storage account name that owns the projection container.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Exact existing storage account resource ID. It must resolve in this resource group and subscription.')
param storageAccountResourceId string

@description('Existing private projection container. This foundation only accepts viewer-projection.')
@allowed([
  'viewer-projection'
])
param projectionContainerName string

@description('Canonical deployment tenant ID.')
param tenantId string

@description('Canonical azd environment name passed to the worker.')
@minLength(1)
@maxLength(64)
param environmentName string

@description('Reviewed immutable worker image reference. A registry digest is required.')
@maxLength(512)
param workerImage string

@description('Reviewed immutable Caddy image reference. A registry digest is required.')
@maxLength(512)
param caddyImage string

@description('Explicit bounded positive replica floor for this unwired experiment.')
@minValue(1)
@maxValue(3)
param replicaFloor int

var managedEnvironmentName = last(split(managedEnvironmentResourceId, '/'))
var expectedManagedEnvironmentId = resourceId('Microsoft.App/managedEnvironments', managedEnvironmentName)
var expectedStorageAccountId = resourceId('Microsoft.Storage/storageAccounts', storageAccountName)
var tenantShapeValid = tenantId == subscription().tenantId
func hasOnlyCharacters(value string, allowed string) bool => length(filter(range(0, length(value)), i => !contains(allowed, substring(value, i, 1)))) == 0
func isLowerHex(value string) bool => length(value) == 64 && hasOnlyCharacters(value, '0123456789abcdef')
var environmentShapeValid = length(environmentName) >= 1 && length(environmentName) <= 64 && hasOnlyCharacters(environmentName, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-') && contains('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789', first(environmentName))
var storageNameValid = length(storageAccountName) >= 3 && length(storageAccountName) <= 24 && hasOnlyCharacters(storageAccountName, 'abcdefghijklmnopqrstuvwxyz0123456789')
// contains(string, string) is case-sensitive; startsWith alone is not.
func isPinnedPublicImage(image string) bool => hasOnlyCharacters(image, 'abcdefghijklmnopqrstuvwxyz0123456789/._-@:') && (startsWith(image, 'mcr.microsoft.com/') || startsWith(image, 'docker.io/') || startsWith(image, 'ghcr.io/')) && length(split(image, '@')) == 2 && !contains(first(split(image, '@')), ':') && contains(image, '@sha256:') && isLowerHex(last(split(image, '@sha256:')))
var validatedManagedEnvironmentId = managedEnvironmentResourceId == expectedManagedEnvironmentId ? managedEnvironmentResourceId : fail('managedEnvironmentResourceId must identify an existing managed environment in this resource group.')
var validatedTenantId = tenantShapeValid ? toLower(subscription().tenantId) : fail('tenantId must equal the selected subscription tenant.')
var validatedEnvironmentName = environmentShapeValid ? environmentName : fail('environmentName must start with an ASCII letter or digit and contain only letters, digits, dot, underscore or hyphen.')
var validatedStorageAccountName = storageNameValid && storageAccountResourceId == expectedStorageAccountId ? storageAccountName : fail('storageAccountName and storageAccountResourceId must identify the same account in this resource group.')
var validatedWorkerImage = isPinnedPublicImage(workerImage) ? workerImage : fail('workerImage must be an immutable lowercase sha256 image from a supported public registry.')
var validatedCaddyImage = isPinnedPublicImage(caddyImage) ? caddyImage : fail('caddyImage must be an immutable lowercase sha256 image from a supported public registry.')
var regionMatchedEnvironmentId = location == managedEnvironment.location ? managedEnvironment.id : fail('location must match the existing managed environment region.')
var viewerAppName = 'capp-maester-viewer-${substring(uniqueString(resourceGroup().id, validatedEnvironmentName), 0, 12)}'
var viewerIdentityName = 'id-maester-viewer-${substring(uniqueString(resourceGroup().id, validatedEnvironmentName, 'identity'), 0, 12)}'
var storageBlobDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')

resource managedEnvironment 'Microsoft.App/managedEnvironments@2025-07-01' existing = {
  name: last(split(validatedManagedEnvironmentId, '/'))
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: validatedStorageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource projectionContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: blobService
  name: projectionContainerName
}

resource viewerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: viewerIdentityName
  location: location
  tags: {
    workload: 'maester'
    component: 'private-viewer-foundation'
    environment: validatedEnvironmentName
  }
}

resource viewerReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(projectionContainer.id, viewerIdentity.id, 'StorageBlobDataReader')
  scope: projectionContainer
  properties: {
    roleDefinitionId: storageBlobDataReaderRoleId
    principalId: viewerIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource viewerApp 'Microsoft.App/containerApps@2025-07-01' = {
  name: viewerAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${viewerIdentity.id}': {}
    }
  }
  tags: {
    workload: 'maester'
    component: 'private-viewer-foundation'
    environment: validatedEnvironmentName
    lifecycle: 'unwired-experiment'
  }
  properties: {
    managedEnvironmentId: regionMatchedEnvironmentId
    configuration: {
      activeRevisionsMode: 'Single'
    }
    template: {
      containers: [
        {
          name: 'worker'
          image: validatedWorkerImage
          args: [
            '-StorageAccountName'
            validatedStorageAccountName
            '-ProjectionContainerName'
            projectionContainerName
            '-TenantId'
            validatedTenantId
            '-Environment'
            validatedEnvironmentName
            '-UserAssignedIdentityClientId'
            viewerIdentity.properties.clientId
          ]
          resources: {
            cpu: 1
            memory: '2Gi'
          }
        }
        {
          name: 'caddy'
          image: validatedCaddyImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: replicaFloor
        maxReplicas: replicaFloor
      }
    }
  }
}

output viewerAppResourceId string = viewerApp.id
output viewerIdentityResourceId string = viewerIdentity.id
output viewerIdentityClientId string = viewerIdentity.properties.clientId
output projectionContainerResourceId string = projectionContainer.id
