// Application Insights (workspace-based)
// Targets the shared Log Analytics Workspace; provides connection string + instrumentation key
// for Logic Apps app settings.

targetScope = 'resourceGroup'

@description('Application Insights name')
param name string

@description('Location for Application Insights')
param location string

@description('Workspace resource ID for workspace-based App Insights')
param workspaceResourceId string

@description('Resource tags')
param tags object = {}

@description('Application type (default: web)')
@allowed([
  'web'
  'other'
])
param applicationType string = 'web'

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: name
  location: location
  tags: tags
  kind: applicationType
  properties: {
    Application_Type: applicationType
    WorkspaceResourceId: workspaceResourceId
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output id string = applicationInsights.id
output name string = applicationInsights.name
output instrumentationKey string = applicationInsights.properties.InstrumentationKey
output connectionString string = applicationInsights.properties.ConnectionString
