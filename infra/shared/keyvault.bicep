// Azure Key Vault
// RBAC authorization (Azure RBAC, no access policies); soft delete ON; purge protection PARAMETERIZED (default FALSE for destroy.yml).
// Public network access enabled; diagnostics (allLogs + AllMetrics) sent to LAW.
// Deployed into rg-edi-shared.

targetScope = 'resourceGroup'

@description('Key Vault name')
param name string

@description('Location for Key Vault')
param location string

@description('Resource tags')
param tags object = {}

@description('Enable purge protection (default: false for dev/test; set true for production)')
param enablePurgeProtection bool = false

@description('Log Analytics Workspace ID for diagnostics')
param logAnalyticsWorkspaceId string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true // RBAC-only; no access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: enablePurgeProtection ? true : null // Azure rejects an explicit false; omit the property when disabled so destroy.yml can fully tear down
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Diagnostics (allLogs + AllMetrics → LAW)
resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: keyVault
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

output id string = keyVault.id
output name string = keyVault.name
output uri string = keyVault.properties.vaultUri
