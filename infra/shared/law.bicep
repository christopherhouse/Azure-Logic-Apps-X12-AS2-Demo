// Log Analytics Workspace (LAW)
// Single diagnostics sink for the entire EDI demo environment.
// PerGB2018 pricing tier; public network access enabled.

targetScope = 'resourceGroup'

@description('Log Analytics Workspace name')
param name string

@description('Location for the workspace')
param location string

@description('Resource tags')
param tags object = {}

@description('Retention period in days (30-730)')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output id string = logAnalyticsWorkspace.id
output workspaceId string = logAnalyticsWorkspace.properties.customerId
output name string = logAnalyticsWorkspace.name
