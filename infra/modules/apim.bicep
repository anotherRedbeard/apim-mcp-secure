@description('Location for all resources')
param location string

@description('Unique token for resource naming')
param resourceToken string

@description('Tags to apply to all resources')
param tags object

@description('Resource naming abbreviations')
param abbrs object

@description('APIM publisher email')
param publisherEmail string

@description('APIM publisher name')
param publisherName string

@description('Microsoft Entra tenant ID')
param entraIdTenantId string

@description('Client ID for OBO app registration')
param oboClientId string

@secure()
@description('Client secret for OBO app registration')
param oboClientSecret string

var apimName = '${abbrs.apiManagementService}${resourceToken}'

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: 'Consumption'
    capacity: 0
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

// Named values for OBO token exchange
resource namedValueTenantId 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'entraid-tenant'
  properties: {
    displayName: 'entraid-tenant'
    value: entraIdTenantId
    secret: false
  }
}

resource namedValueClientId 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'obo-client-id'
  properties: {
    displayName: 'obo-client-id'
    value: oboClientId
    secret: false
  }
}

resource namedValueClientSecret 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
  parent: apim
  name: 'obo-client-secret'
  properties: {
    displayName: 'obo-client-secret'
    value: oboClientSecret
    secret: true
  }
}

output apimName string = apim.name
output apimGatewayUrl string = apim.properties.gatewayUrl
