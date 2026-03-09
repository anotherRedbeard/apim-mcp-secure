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
// API 1: OBO MCP Server — type 'mcp' with streamable transport
// ──────────────────────────────────────────────────────
resource oboMcpServerApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'obo-mcp-server'
  properties: {
    displayName: 'OBO MCP Server'
    description: 'Function App API with Echo and GetMe endpoints, exposed as MCP server'
    type: 'mcp'
    subscriptionRequired: false
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
}

// API-level policy: validate Azure AD token + return 401 with PRM link on failure
resource oboMcpServerApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: oboMcpServerApi
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

// PRM endpoint within the MCP API itself
resource mcpPrmOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: oboMcpServerApi
  name: 'mcp-prm-operation'
  properties: {
    displayName: 'Protected Resource Metadata'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-protected-resource'
    description: 'Protected Resource Metadata endpoint (RFC 9728)'
  }
}

resource mcpPrmOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: mcpPrmOperation
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
// API 2: Dynamic Discovery — /.well-known/oauth-protected-resource
// ──────────────────────────────────────────────────────
resource dynamicDiscoveryApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'mcp-prm-dynamic-discovery'
  properties: {
    displayName: 'Dynamic Discovery Endpoint'
    description: 'Model Context Protocol Dynamic Discovery Endpoint'
    subscriptionRequired: false
    path: '/.well-known/oauth-protected-resource'
    protocols: [
      'https'
    ]
  }
}

resource mcpPrmDiscoveryOperation 'Microsoft.ApiManagement/service/apis/operations@2024-06-01-preview' = {
  parent: dynamicDiscoveryApi
  name: 'mcp-prm-discovery-operation'
  properties: {
    displayName: 'Protected Resource Metadata'
    method: 'GET'
    urlTemplate: '/${mcpApiPath}'
    description: 'Protected Resource Metadata endpoint (RFC 9728)'
  }
}

resource mcpPrmGlobalPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-06-01-preview' = {
  parent: mcpPrmDiscoveryOperation
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
