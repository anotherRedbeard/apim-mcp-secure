@description('Name of the existing APIM instance')
param apimName string

@description('Name of the Function App')
param functionAppName string

@description('Default hostname of the Function App')
param functionAppDefaultHostname string

resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' existing = {
  name: apimName
}

// ──────────────────────────────────────────────────────
// Backend: Function App
// ──────────────────────────────────────────────────────
resource functionAppBackend 'Microsoft.ApiManagement/service/backends@2023-05-01-preview' = {
  parent: apim
  name: 'function-app-backend'
  properties: {
    protocol: 'http'
    url: 'https://${functionAppDefaultHostname}/api'
    resourceId: '${environment().resourceManager}${resourceId('Microsoft.Web/sites', functionAppName)}'
  }
}

// ──────────────────────────────────────────────────────
// API 1: OBO MCP Server (Function App API)
// ──────────────────────────────────────────────────────
resource oboMcpServerApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'obo-mcp-server'
  properties: {
    displayName: 'OBO MCP Server'
    description: 'Function App API with Echo and GetMe endpoints, exposed as MCP server'
    path: 'obo-mcp-server'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    format: 'openapi+json'
    value: loadTextContent('../../src/FunctionApp/openapi.json')
    serviceUrl: 'https://${functionAppDefaultHostname}/api'
  }
}

// Set backend policy for the API
resource oboMcpServerApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: oboMcpServerApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '<policies><inbound><base /><set-backend-service backend-id="${functionAppBackend.name}" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

// Operation-level policy for GetMe (OBO token exchange)
resource getMeOperation 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' existing = {
  parent: oboMcpServerApi
  name: 'getMe'
}

resource getMeOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  parent: getMeOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/obo-getme-policy.xml')
  }
}

// ──────────────────────────────────────────────────────
// API 2: MCP Auth (Protected Resource Metadata)
// ──────────────────────────────────────────────────────
resource mcpAuthApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'mcp-auth'
  properties: {
    displayName: 'MCP Auth'
    description: 'Protected Resource Metadata endpoint for MCP OAuth2 discovery'
    path: 'mcp-auth'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
  }
}

resource mcpAuthOperation 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  parent: mcpAuthApi
  name: 'get-prm'
  properties: {
    displayName: 'Get Protected Resource Metadata'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-protected-resource'
    description: 'Returns the OAuth 2.0 Protected Resource Metadata for MCP server discovery'
    responses: [
      {
        statusCode: 200
        description: 'Protected Resource Metadata JSON'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
}

resource mcpAuthOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  parent: mcpAuthOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/mcp-auth-policy.xml')
  }
}
