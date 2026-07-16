// Azure SQL Server + Serverless Database
// Entra-only authentication (no SQL auth); Entra admin = GROUP (objectId from param).
// Lowest-cost Serverless SKU (GeneralPurpose Gen5, min vCores, autoPause enabled).
// Public network access enabled; diagnostics (allLogs + AllMetrics) sent to LAW.

targetScope = 'resourceGroup'

@description('SQL Server logical server name')
param serverName string

@description('SQL Database name')
param databaseName string

@description('Location for SQL resources')
param location string

@description('Resource tags')
param tags object = {}

@description('Entra admin group object ID (for azureADOnlyAuthentication)')
param entraAdminGroupObjectId string

@description('Entra admin group login name (display name for the admin)')
param entraAdminGroupLogin string = 'sql-admins'

@description('Log Analytics Workspace ID for diagnostics')
param logAnalyticsWorkspaceId string

// SQL Server (Entra-only authentication)
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: serverName
  location: location
  tags: tags
  properties: {
    administrators: {
      azureADOnlyAuthentication: true
      administratorType: 'ActiveDirectory'
      login: entraAdminGroupLogin
      sid: entraAdminGroupObjectId
      tenantId: subscription().tenantId
      principalType: 'Group'
    }
    publicNetworkAccess: 'Enabled'
    minimalTlsVersion: '1.2'
  }
}

// Firewall rule: Allow Azure services (required for CI/runner connectivity and managed identity)
resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  name: 'AllowAllWindowsAzureIps'
  parent: sqlServer
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Serverless database (lowest-cost SKU: GeneralPurpose Gen5, 0.5 min vCores, autoPause enabled)
resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  name: databaseName
  parent: sqlServer
  location: location
  tags: tags
  sku: {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1 // min vCores for serverless (0.5-1 range, 1 is the minimum billable)
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    autoPauseDelay: 60 // auto-pause after 60 minutes of inactivity
    minCapacity: json('0.5') // 0.5 vCores minimum
    catalogCollation: 'SQL_Latin1_General_CP1_CI_AS'
    zoneRedundant: false
  }
}

// Diagnostics on the database (allLogs + AllMetrics → LAW)
resource sqlDatabaseDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: sqlDatabase
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output serverId string = sqlServer.id
output serverName string = sqlServer.name
output serverFqdn string = sqlServer.properties.fullyQualifiedDomainName
output databaseId string = sqlDatabase.id
output databaseName string = sqlDatabase.name
