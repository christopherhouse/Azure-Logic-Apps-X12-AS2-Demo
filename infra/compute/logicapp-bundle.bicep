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

// --- EDI / telemetry configuration (design §7) ---------------------------------
@description('''Key Vault vault URI (e.g. https://kv-name.vault.azure.net/). Used to build
@Microsoft.KeyVault(...) references for the EDI secrets. Only needed for the app that carries the
EDI send agreements (purchaser).''')
param keyVaultUri string = ''

@description('''Key Vault secret NAME holding this app''s Integration Account callback URL (SAS =
secret), referenced by WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL. Empty => the app is not linked to an
IA and the setting is omitted (supplier is HTTP-only this epic). CI publishes the secret post-deploy
and restarts the app (design §5.1, §8-F).''')
param integrationAccountCallbackSecretName string = ''

@description('''Key Vault secret NAME holding the supplier AS2 endpoint (callback) URL, referenced by
SupplierAs2Endpoint__url. Empty => omit (purchaser-only, injected supplier-first by CI — design §6/§8).''')
param supplierEndpointSecretName string = ''

@description('X12 SEND agreement name, surfaced as app setting X12AgreementName and read by the workflow via @appsetting(...) (design §5.4). Empty => omit.')
param x12AgreementName string = ''

// --- Supplier-inbound 997 epic app settings (design §6.1, LOCKED build-wave contract) ---
@description('''Key Vault secret NAME holding the PURCHASER 997 receive endpoint (callback) URL, referenced
by the supplier app setting `Purchaser997EndpointUrl` (the outbound AS2 POST target for the 997). Empty =>
omit (purchaser is receive-only). Injected post-deploy by CI in the non-interleaved dual-callback phase.''')
param purchaser997EndpointSecretName string = ''

@description('''X12 RECEIVE agreement name (supplier inbound 850), surfaced as app setting
`X12ReceiveAgreementName` and read by the supplier workflow via @appsetting(...). Empty => omit.''')
param x12ReceiveAgreementName string = ''

@description('''X12 SEND agreement name (supplier outbound 997), surfaced as app setting
`X12SendAgreementName` and read by the supplier workflow's X12 Encode via @appsetting(...). Empty => omit.''')
param x12SendAgreementName string = ''

@description('Enable Workflows-runtime OpenTelemetry export via AzureFunctionsJobHost__telemetryMode=OpenTelemetry (design §7). host.json carries the AI v2 version switch.')
param enableOpenTelemetry bool = true

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
// APP SETTINGS COMPOSITION (#16 + EDI/telemetry design §7)
// Base settings apply to every app; telemetry + EDI settings are appended
// conditionally so the same bundle serves both the purchaser (EDI send) and the
// supplier (HTTP-only, no IA link this epic).
// ============================================================================
var baseAppSettings = [
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
  // --- Host storage via managed identity (identity-based AzureWebJobsStorage, no connection string) ---
  // The Functions host reads `__credential`; the Workflows Data.Edge runtime reads `__credentialType`.
  // BOTH must be `managedIdentity` (case-sensitive) or the host fails with ServiceUnavailable. The
  // UAMI is selected by resource id (NOT clientId) and blob/queue/table service URIs are explicit.
  // Do NOT emit plain `AzureWebJobsStorage`, `__accountName`, or `__clientId` — they break the
  // identity-based path (see .squad/decisions.md: identity storage live fix, 2026-07-20).
  {
    name: 'AzureWebJobsStorage__credential'
    value: 'managedIdentity'
  }
  {
    name: 'AzureWebJobsStorage__credentialType'
    value: 'managedIdentity'
  }
  {
    name: 'AzureWebJobsStorage__managedIdentityResourceId'
    value: uamiId
  }
  {
    name: 'AzureWebJobsStorage__blobServiceUri'
    value: 'https://${storage.name}.blob.${environment().suffixes.storage}'
  }
  {
    name: 'AzureWebJobsStorage__queueServiceUri'
    value: 'https://${storage.name}.queue.${environment().suffixes.storage}'
  }
  {
    name: 'AzureWebJobsStorage__tableServiceUri'
    value: 'https://${storage.name}.table.${environment().suffixes.storage}'
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

// v2 telemetry host-level OTel export (both apps). The AI telemetry VERSION switch
// (Runtime.ApplicationInsightTelemetryVersion=v2) lives in host.json (source-controlled).
var telemetryAppSettings = enableOpenTelemetry ? [
  {
    name: 'AzureFunctionsJobHost__telemetryMode'
    value: 'OpenTelemetry'
  }
] : []

// Links the app to its Integration Account (purchaser only). SAS callback URL is a secret →
// Key Vault reference resolved via keyVaultReferenceIdentity (design §5.1, §8-F).
var iaLinkAppSettings = empty(integrationAccountCallbackSecretName) ? [] : [
  {
    name: 'WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL'
    value: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}secrets/${integrationAccountCallbackSecretName})'
  }
]

// Outbound AS2 POST target (purchaser only) — supplier callback URL injected supplier-first by CI (design §6).
// NOTE: the setting name is the CLEAN `SupplierAs2EndpointUrl` (no double underscore). The `__` variant
// (`SupplierAs2Endpoint__url`) is treated by the host as a nested config path and resolves to null from
// `@appsetting('SupplierAs2EndpointUrl')`, which broke the outbound POST (see .squad/decisions.md,
// "Supplier endpoint URL stabilization"). The workflow reads `@appsetting('SupplierAs2EndpointUrl')`.
var supplierEndpointAppSettings = empty(supplierEndpointSecretName) ? [] : [
  {
    name: 'SupplierAs2EndpointUrl'
    value: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}secrets/${supplierEndpointSecretName})'
  }
]

// X12 Encode agreement name (purchaser only), read by the workflow via @appsetting('X12AgreementName') (design §5.4).
var x12AgreementAppSettings = empty(x12AgreementName) ? [] : [
  {
    name: 'X12AgreementName'
    value: x12AgreementName
  }
]

// Supplier outbound AS2 POST target for the 997 — the purchaser-inbound-997 callback URL (KV ref,
// injected post-deploy in the non-interleaved dual-callback phase, design §5.2/§6.1). The workflow
// reads @appsetting('Purchaser997EndpointUrl') (clean name, no `__url` — same lesson as SupplierAs2EndpointUrl).
var purchaser997EndpointAppSettings = empty(purchaser997EndpointSecretName) ? [] : [
  {
    name: 'Purchaser997EndpointUrl'
    value: '@Microsoft.KeyVault(SecretUri=${keyVaultUri}secrets/${purchaser997EndpointSecretName})'
  }
]

// Supplier X12 agreement names (design §6.1 / Simon D-997-3): the workflow resolves the 850 RECEIVE
// (X12 Decode) and 997 SEND (X12 Encode) agreements by name via @appsetting(...), so they can be
// renamed without a workflow edit.
var x12ReceiveAgreementAppSettings = empty(x12ReceiveAgreementName) ? [] : [
  {
    name: 'X12ReceiveAgreementName'
    value: x12ReceiveAgreementName
  }
]
var x12SendAgreementAppSettings = empty(x12SendAgreementName) ? [] : [
  {
    name: 'X12SendAgreementName'
    value: x12SendAgreementName
  }
]

var allAppSettings = concat(baseAppSettings, telemetryAppSettings, iaLinkAppSettings, supplierEndpointAppSettings, x12AgreementAppSettings, purchaser997EndpointAppSettings, x12ReceiveAgreementAppSettings, x12SendAgreementAppSettings)

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
      appSettings: allAppSettings
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
// EDI linkage secret name this app expects (empty for non-EDI apps like the supplier this epic).
output integrationAccountCallbackSecretName string = integrationAccountCallbackSecretName
