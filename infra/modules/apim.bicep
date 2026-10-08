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

@description('Audience to validate on inbound tokens — set to the Application ID URI of the backend API app (e.g., api://<obo-client-id>)')
param mcpClientAudience string

@description('Fully qualified delegated scope for the Azure DevOps MCP backend')
param azureDevOpsMcpScope string

@description('Fully qualified delegated scope for the Fabric Core MCP backend')
param fabricMcpScope string

var apimName = '${abbrs.apiManagementService}${resourceToken}'

resource oboIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${abbrs.managedIdentities}obo-${resourceToken}'
  location: location
  tags: tags
}

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' = {
  name: apimName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${oboIdentity.id}': {}
    }
  }
  sku: {
    name: 'Basicv2'
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

// Named values for OBO token exchange
resource namedValueTenantId 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'entraid-tenant'
  properties: {
    displayName: 'entraid-tenant'
    value: entraIdTenantId
    secret: false
  }
}

resource namedValueClientId 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'obo-client-id'
  properties: {
    displayName: 'obo-client-id'
    value: oboClientId
    secret: false
  }
}

resource namedValueManagedIdentityClientId 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'obo-managed-identity-client-id'
  properties: {
    displayName: 'obo-managed-identity-client-id'
    value: oboIdentity.properties.clientId
    secret: false
  }
}

resource namedValueMcpClientAudience 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'mcp-client-audience'
  properties: {
    displayName: 'mcp-client-audience'
    value: mcpClientAudience
    secret: false
  }
}

resource namedValueAzureDevOpsMcpScope 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'azdo-mcp-scope'
  properties: {
    displayName: 'azdo-mcp-scope'
    value: azureDevOpsMcpScope
    secret: false
  }
}

resource namedValueFabricMcpScope 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'fabric-mcp-scope'
  properties: {
    displayName: 'fabric-mcp-scope'
    value: fabricMcpScope
    secret: false
  }
}

output apimName string = apim.name
output apimGatewayUrl string = apim.properties.gatewayUrl
output apimPrincipalId string = apim.identity.principalId
output oboManagedIdentityName string = oboIdentity.name
output oboManagedIdentityClientId string = oboIdentity.properties.clientId
output oboManagedIdentityPrincipalId string = oboIdentity.properties.principalId
