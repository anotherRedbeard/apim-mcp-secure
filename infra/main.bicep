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

@description('Client ID of the inbound token audience (MCP client app registration)')
param mcpClientAudience string

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
  }
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_FUNCTION_APP_NAME string = functionApp.outputs.functionAppName
output AZURE_APIM_NAME string = apim.outputs.apimName
output AZURE_APIM_GATEWAY_URL string = apim.outputs.apimGatewayUrl
