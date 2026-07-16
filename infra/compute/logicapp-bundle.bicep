// Logic App Standard Compute Bundle (per app)
// Provisions one self-contained compute unit for either the purchaser or the supplier:
//   1. Storage account          — host runtime + Azure Files content share (StorageV2, TLS1.2, HTTPS-only)
//   2. App Service Plan (WS1)    — Workflow Standard, Windows (Workflow Service Plan hosting model)
//   3. Logic App Standard        — empty (functionapp,workflowapp), UAMI-attached, app settings authored inline (#16)
//   4. Integration Account (Free)— empty container for future EDI artifacts (schemas/maps/agreements)
//
// Identity model (see .squad/decisions/inbox/kaylee-content-share.md):
//   - Host storage (AzureWebJobsStorage) uses the app's UAMI (managed identity, no connection string).
//   - The Azure Files CONTENT SHARE requires a storage key on the Workflow Service Plan hosting model
//     (key access cannot be disabled — Microsoft Learn). That sanctioned exception is NOT inlined:
//     WEBSITE_CONTENTAZUREFILECONNECTIONSTRING references a Key Vault secret, resolved via the UAMI
//     (keyVaultReferenceIdentity). The secret is published out-of-band by CI (no Deployment Script).
//
// Deployed into the app's own resource group (purchaser: East US 2, supplier: Central US).

targetScope = 'resourceGroup'

@description('App Service Plan (WS1 Workflow Standard) name')
param planName string

@description('Logic App Standard (Microsoft.Web/sites) name')
param logicAppName string

@description('Storage account name (lowercase, <=24 chars, no hyphens)')
param storageName string

@description('Integration Account (Free) name')
param integrationAccountName string

@description('Location for all resources in this bundle')
param location string

@description('Resource tags')
param tags object = {}

@description('Resource ID of the user-assigned managed identity to attach to the Logic App')
param uamiId string

@description('Client ID of the user-assigned managed identity (for identity-based host storage)')
param uamiClientId string

@description('Application Insights connection string (from the shared tier)')
param appInsightsConnectionString string

@description('WEBSITE_NODE_DEFAULT_VERSION value for the Logic App runtime')
param nodeDefaultVersion string = '~22'

@description('Service Bus fully-qualified namespace (for built-in connector)')
param serviceBusFullyQualifiedNamespace string

@description('SQL Server FQDN (for built-in connector)')
param sqlServerFqdn string

@description('SQL Database name (for built-in connector)')
param sqlDatabaseName string

// Retained as an output for reference. The content share now uses an inline connection string
// (listKeys) because the Windows WS1 hosting model requires it at site-create time.
var contentShareSecretName = 'contentshare-${storageName}'

// Content share name — deterministic and lowercase for idempotency.
var contentShareName = toLower(logicAppName)

// ============================================================================
// STORAGE ACCOUNT (host runtime + Azure Files content share)
// ============================================================================
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    allowBlobPublicAccess: false
    // Shared key access is REQUIRED: the WS1 content share (Azure Files) cannot use managed identity
    // on the Workflow Service Plan hosting model. Host storage still uses the UAMI (see decision doc).
    allowSharedKeyAccess: true
  }
}

// ============================================================================
// APP SERVICE PLAN — WS1 (Workflow Standard), Windows
// ============================================================================
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  kind: 'elastic' // Workflow Standard elastic plan
  properties: {
    reserved: false // false => Windows
    targetWorkerCount: 1
    maximumElasticWorkerCount: 20
  }
}

// ============================================================================
// LOGIC APP STANDARD (empty) — app settings authored inline (#16)
// ============================================================================
resource logicApp 'Microsoft.Web/sites@2023-12-01' = {
  name: logicAppName
  location: location
  tags: tags
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uamiId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    // Resolve @Microsoft.KeyVault references (content-share secret) using the user-assigned identity.
    keyVaultReferenceIdentity: uamiId
    siteConfig: {
      alwaysOn: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        // --- Runtime identity ---
        {
          name: 'APP_KIND'
          value: 'workflowApp'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet'
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: nodeDefaultVersion
        }
        // --- Observability ---
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        // --- Host storage via managed identity (no connection string) ---
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__clientId'
          value: uamiClientId
        }
        // --- Content share (Azure Files) — sanctioned key exception (spec permits the Azure Files
        // connection string for the Windows hosting model). Must be a REAL connection string at
        // site-create time; a Key Vault reference fails ARM preflight (CouldNotAccessStorageAccount).
        // The storage key stays out of source — resolved at deploy time via listKeys().
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: contentShareName
        }
        // --- Service Bus built-in connector (connection-prefix model) ---
        {
          name: 'serviceBus__fullyQualifiedNamespace'
          value: serviceBusFullyQualifiedNamespace
        }
        {
          name: 'serviceBus__credential'
          value: 'managedidentity'
        }
        {
          name: 'serviceBus__clientId'
          value: uamiClientId
        }
        // --- SQL built-in connector (managed identity) ---
        {
          name: 'sql__serverFqdn'
          value: sqlServerFqdn
        }
        {
          name: 'sql__databaseName'
          value: sqlDatabaseName
        }
        {
          name: 'sql__clientId'
          value: uamiClientId
        }
      ]
    }
  }
}

// ============================================================================
// INTEGRATION ACCOUNT (Free) — empty, ready for future EDI artifacts
// ============================================================================
resource integrationAccount 'Microsoft.Logic/integrationAccounts@2019-05-01' = {
  name: integrationAccountName
  location: location
  tags: tags
  sku: {
    name: 'Free'
  }
  properties: {}
}

// ============================================================================
// OUTPUTS
// ============================================================================
output logicAppId string = logicApp.id
output logicAppName string = logicApp.name
output defaultHostName string = logicApp.properties.defaultHostName
output planId string = plan.id
output storageId string = storage.id
output storageName string = storage.name
output integrationAccountId string = integrationAccount.id
output integrationAccountName string = integrationAccount.name
// Secret name CI must publish (Azure Files connection string) for the content share.
output contentShareSecretName string = contentShareSecretName
