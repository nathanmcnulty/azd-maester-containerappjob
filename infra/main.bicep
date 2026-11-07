// azd initializes its provider before preprovision. A subscription entry point
// lets the ownership hook create the group before deploying the existing module.
targetScope = 'subscription'

@description('Azure region selected by azd.')
@metadata({ azd: { type: 'location' } })
param location string

param environmentName string = 'dev'
param resourceGroupName string
@description('Exact group metadata captured by the ownership-aware preprovision hook; required before deployment.')
param resourceGroupMetadataJson string = '{}'
param imageName string = 'mcr.microsoft.com/azure-powershell@sha256:3459545c448b8ae639370b3cf46e1816a3d68a045e45b96ba25e46e8de815581'
param userAssignedIdentityResourceId string = ''
param enableResourceLocks bool = true
param customTags object = {}
param includeWebAppOption string = 'false'
param includeExchangeOption string = 'false'
param includeTeamsOption string = 'false'
param includeAzureOption string = 'false'
param includeACROption string = 'false'
param jobTriggerType string = 'Schedule'
param mailRecipient string = ''
param webAppSkuName string = 'F1'

// The hook creates/captures the group first. Declare it so azd down can discover
// it, preserving the captured location and all tags, including ownership.
// Missing hook metadata fails expression evaluation before changing the group.
var groupMetadata = json(resourceGroupMetadataJson)
resource targetGroup 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: groupMetadata.location
  tags: groupMetadata.tags
}

module maester 'resources.bicep' = {
  name: 'maester-resources'
  scope: targetGroup
  params: {
    location: location
    environmentName: environmentName
    imageName: imageName
    userAssignedIdentityResourceId: userAssignedIdentityResourceId
    enableResourceLocks: enableResourceLocks
    customTags: customTags
    includeWebAppOption: includeWebAppOption
    includeExchangeOption: includeExchangeOption
    includeTeamsOption: includeTeamsOption
    includeAzureOption: includeAzureOption
    includeACROption: includeACROption
    jobTriggerType: jobTriggerType
    mailRecipient: mailRecipient
    webAppSkuName: webAppSkuName
  }
}

output containerAppJobName string = maester.outputs.containerAppJobName
output containerAppJobPrincipalId string = maester.outputs.containerAppJobPrincipalId
output storageAccountName string = maester.outputs.storageAccountName
output managedEnvironmentName string = maester.outputs.managedEnvironmentName
output acrName string = maester.outputs.acrName
output acrLoginServer string = maester.outputs.acrLoginServer
output webAppName string = maester.outputs.webAppName
output STORAGE_ACCOUNT_NAME string = maester.outputs.STORAGE_ACCOUNT_NAME
output WEB_APP_NAME string = maester.outputs.WEB_APP_NAME
output WEB_APP_ENABLED string = maester.outputs.WEB_APP_ENABLED
output webAppDefaultHostName string = maester.outputs.webAppDefaultHostName
// Include this deployment history resource in the exact cleanup inventory.
output MAESTER_OWNED_RESOURCE_IDS string = string(concat(json(maester.outputs.MAESTER_OWNED_RESOURCE_IDS), [
  extensionResourceId(targetGroup.id, 'Microsoft.Resources/deployments', 'maester-resources')
]))
output MAESTER_OWNED_LOCK_IDS string = maester.outputs.MAESTER_OWNED_LOCK_IDS
output MAESTER_INFRASTRUCTURE_OWNERSHIP_ID string = maester.outputs.MAESTER_INFRASTRUCTURE_OWNERSHIP_ID
