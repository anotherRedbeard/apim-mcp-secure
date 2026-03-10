@description('Name of the existing APIM instance')
param apimName string

@description('Name of the Function App')
param functionAppName string

@description('Default hostname of the Function App')
param functionAppDefaultHostname string

@description('MCP API path served via APIM')
param mcpApiPath string = 'obo-mcp-server'

resource apim 'Microsoft.ApiManagement/service@2024-06-01-preview' existing = {
  name: apimName
}

// ──────────────────────────────────────────────────────
// Named Values for MCP configuration
// ──────────────────────────────────────────────────────
resource apimGatewayUrlNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'APIMGatewayURL'
  properties: {
    displayName: 'APIMGatewayURL'
    value: apim.properties.gatewayUrl
    secret: false
  }
}

resource mcpApiPathNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-06-01-preview' = {
  parent: apim
  name: 'McpApiPath'
  properties: {
    displayName: 'McpApiPath'
    value: mcpApiPath
    secret: false
  }
}

// ──────────────────────────────────────────────────────
// Backend: Function App
// ──────────────────────────────────────────────────────
resource functionAppBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'function-app-backend'
  properties: {
    protocol: 'http'
    url: 'https://${functionAppDefaultHostname}/api'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
    type: 'Single'
  }
}

// ──────────────────────────────────────────────────────
// API 1: Function App REST API (imported from OpenAPI)
//   - Echo operation (GET /echo)
//   - GetMe operation (GET /me) with OBO token exchange policy
// ──────────────────────────────────────────────────────
resource functionAppApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'function-app-api'
  properties: {
    displayName: 'Function App API'
    description: 'REST API representation of the Function App with Echo and GetMe endpoints'
    path: 'function-app'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    format: 'openapi+json'
    value: loadTextContent('../../src/FunctionApp/openapi.json')
    serviceUrl: 'https://${functionAppDefaultHostname}/api'
  }
}

// Set backend policy for the Function App API
resource functionAppApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: functionAppApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '<policies><inbound><base /><set-backend-service backend-id="${functionAppBackend.name}" /></inbound><backend><base /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'
  }
}

// Operation-level policy for GetMe (OBO token exchange)
resource getMeOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' existing = {
  parent: functionAppApi
  name: 'getMe'
}

resource getMeOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: getMeOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/obo-getme-policy.xml')
  }
}

// ──────────────────────────────────────────────────────
// API 2: MCP Auth — Protected Resource Metadata (PRM)
// ──────────────────────────────────────────────────────
resource mcpAuthApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
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

resource mcpAuthOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: mcpAuthApi
  name: 'get-prm'
  properties: {
    displayName: 'Get Protected Resource Metadata'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-protected-resource'
    description: 'Returns the OAuth 2.0 Protected Resource Metadata (RFC 9728) for MCP server discovery'
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

resource mcpAuthOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: mcpAuthOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/mcp-prm-policy.xml')
  }
  dependsOn: [
    apimGatewayUrlNamedValue
    mcpApiPathNamedValue
  ]
}

// ──────────────────────────────────────────────────────
// API 3: MCP Server — type 'mcp', proxy to Function App API
// ──────────────────────────────────────────────────────
resource mcpServerApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'obo-mcp-server'
  properties: {
    displayName: 'OBO MCP Server'
    description: 'MCP server proxy to the Function App REST API'
    type: 'mcp'
    subscriptionRequired: false
    sourceApiId: functionAppApi.id
    backendId: functionAppBackend.name
    path: '/${mcpApiPath}'
    protocols: [
      'https'
    ]
    mcpProperties: {
      transportType: 'streamable'
    }
    authenticationSettings: {
      oAuth2AuthenticationSettings: []
      openidAuthenticationSettings: []
    }
    isCurrent: true
  }
  dependsOn: [
    functionAppApi
  ]
}

// MCP Server API-level policy: validate Azure AD token + return 401 with PRM link on failure
resource mcpServerApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: mcpServerApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/mcp-api-policy.xml')
  }
  dependsOn: [
    apimGatewayUrlNamedValue
    mcpApiPathNamedValue
  ]
}
