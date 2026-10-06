param location string
param resourceToken string
param tags object
param apimName string
param apimPrincipalId string
param azureDevOpsMcpApiName string

@minValue(0)
@maxValue(8192)
@description('Temporary payload logging for all APIs and both frontend/backend directions. Set to 0 after diagnosis; bodies can contain sensitive data and response buffering can disrupt MCP streaming.')
param payloadBytes int = 8192

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${resourceToken}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${resourceToken}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
  }
}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

var monitoringMetricsPublisherRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')

resource telemetryPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(applicationInsights.id, apimPrincipalId, monitoringMetricsPublisherRoleId)
  scope: applicationInsights
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleId
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource logger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'APIM MCP request and dependency telemetry'
    resourceId: applicationInsights.id
    isBuffered: true
    credentials: {
      connectionString: applicationInsights.properties.ConnectionString
      identityClientId: 'SystemAssigned'
    }
  }
  dependsOn: [
    telemetryPublisher
  ]
}

var messageDiagnostics = {
  body: {
    bytes: payloadBytes
  }
  headers: []
}

resource diagnostics 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: logger.id
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    verbosity: 'information'
    httpCorrelationProtocol: 'W3C'
    logClientIp: false
    operationNameFormat: 'Name'
    frontend: {
      request: messageDiagnostics
      response: messageDiagnostics
    }
    backend: {
      request: messageDiagnostics
      response: messageDiagnostics
    }
  }
}

resource azureDevOpsMcpApi 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' existing = {
  parent: apim
  name: azureDevOpsMcpApiName
}

resource azureDevOpsDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  parent: azureDevOpsMcpApi
  name: 'applicationinsights'
  properties: {
    loggerId: logger.id
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    verbosity: 'information'
    httpCorrelationProtocol: 'W3C'
    logClientIp: false
    operationNameFormat: 'Name'
    frontend: {
      request: messageDiagnostics
      response: messageDiagnostics
    }
    backend: {
      request: messageDiagnostics
      response: messageDiagnostics
    }
  }
}

output applicationInsightsName string = applicationInsights.name
output workspaceName string = workspace.name
