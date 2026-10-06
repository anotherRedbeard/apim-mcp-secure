targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment (e.g., dev, staging, prod)')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('Microsoft Entra tenant ID for OAuth/OBO flows')
param entraIdTenantId string

@description('Client ID of the middle-tier app registration (used for OBO)')
param oboClientId string

@description('Audience to validate on inbound tokens — set to the Application ID URI of the backend API app (e.g., api://<obo-client-id>)')
param mcpClientAudience string

@description('Azure DevOps organization name used by the remote MCP server')
param azureDevOpsOrganizationName string

@description('Fully qualified delegated scope granted to the OBO app for the Azure DevOps MCP enterprise application')
param azureDevOpsMcpScope string

@secure()
@description('Client secret of the middle-tier app registration (used for OBO)')
param oboClientSecret string

@description('APIM publisher email')
param apimPublisherEmail string = 'admin@contoso.com'

@description('APIM publisher name')
param apimPublisherName string = 'Contoso Admin'

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
}

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

module functionApp './modules/function-app.bicep' = {
  name: 'function-app'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    abbrs: abbrs
  }
}

module apim './modules/apim.bicep' = {
  name: 'apim'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    abbrs: abbrs
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    entraIdTenantId: entraIdTenantId
    oboClientId: oboClientId
    mcpClientAudience: mcpClientAudience
    azureDevOpsMcpScope: azureDevOpsMcpScope
    oboClientSecret: oboClientSecret
  }
}

module apimApis './modules/apim-apis.bicep' = {
  name: 'apim-apis'
  scope: rg
  params: {
    apimName: apim.outputs.apimName
    functionAppName: functionApp.outputs.functionAppName
    functionAppDefaultHostname: functionApp.outputs.functionAppDefaultHostname
    azureDevOpsOrganizationName: azureDevOpsOrganizationName
  }
}

module monitoring './modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    apimName: apim.outputs.apimName
    apimPrincipalId: apim.outputs.apimPrincipalId
    azureDevOpsMcpApiName: apimApis.outputs.azureDevOpsMcpApiName
  }
}

output AZURE_APPLICATION_INSIGHTS_NAME string = monitoring.outputs.applicationInsightsName
output AZURE_LOG_ANALYTICS_WORKSPACE_NAME string = monitoring.outputs.workspaceName
output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_FUNCTION_APP_NAME string = functionApp.outputs.functionAppName
output AZURE_APIM_NAME string = apim.outputs.apimName
output AZURE_APIM_GATEWAY_URL string = apim.outputs.apimGatewayUrl
output AZURE_APIM_AZDO_MCP_URL string = '${apim.outputs.apimGatewayUrl}/azure-devops-mcp/mcp'
