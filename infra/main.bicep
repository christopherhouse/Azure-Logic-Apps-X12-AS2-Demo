// Azure Logic Apps Standard EDI Demo
// Infrastructure Orchestration (Subscription-scoped)
//
// Creates three resource groups:
// - rg-edi-shared (Central US) — shared services (LAW, App Insights, Key Vault, SQL, Service Bus)
// - rg-edi-supplier (Central US) — supplier Logic App Standard, storage, integration account
// - rg-edi-purchaser (East US 2) — purchaser Logic App Standard, storage, integration account
//
// Orchestrates Bicep modules to provision resources, configure RBAC, and wire runtime settings.
//
// Deploy ordering follows docs/infra-deploy-ordering.md (Mal's architectural contract).

targetScope = 'subscription'

// ============================================================================
// PARAMETERS
// ============================================================================

@description('Naming token for deterministic resource names (e.g., jci)')
param namingToken string = 'jci'

@description('Environment name (dev, test, prod)')
param environmentName string = 'dev'

@description('Location for shared resources and supplier resources')
param sharedLocation string = 'centralus'

@description('Location for purchaser resources')
param purchaserLocation string = 'eastus2'

@description('Enable Key Vault purge protection (default: false for dev/test; set true for production)')
param enablePurgeProtection bool = false

@description('''Object ID of the first-party Azure Logic Apps service principal in this tenant
(well-known app ID 7cd684f4-8a78-49b0-91ec-6a35d38739ba). Used to grant Key Vault Crypto User +
Secrets User so the Integration Account can read the Key Vault key backing private AS2 certificates
(design §5.5). Resolve at deploy time: `az ad sp show --id 7cd684f4-8a78-49b0-91ec-6a35d38739ba
--query id -o tsv`. Empty by default — the grant is skipped until AS2 private certs are configured.''')
param logicAppsServicePrincipalObjectId string = ''

// ============================================================================
// VARIABLES
// ============================================================================

// Common tags (SecurityControl=Ignore is required per Infrastructure Spec)
var commonTags = {
  SecurityControl: 'Ignore'
  Environment: environmentName
  Project: 'EDI-AS2-X12-Demo'
}

// Resource group names (LITERAL per spec)
var rgShared = 'rg-edi-shared'
var rgSupplier = 'rg-edi-supplier'
var rgPurchaser = 'rg-edi-purchaser'

// ============================================================================
// EDI EPIC NAMING (design §5.1, §5.4, §6, §8) — deterministic secret / agreement names
// ============================================================================
// Key Vault secret holding the purchaser Integration Account callback URL (SAS = secret).
// CI reads listCallbackUrl post-deploy, writes this secret, then restarts the purchaser app.
var purchaserIaCallbackSecretName = 'purchaser-ia-callback-url'
// Key Vault secret holding the supplier AS2 endpoint (callback) URL — injected supplier-first by CI (§6).
var supplierAs2EndpointSecretName = 'supplier-as2-endpoint-url'
// X12 SEND agreement name — MUST match the agreement created by infra/integration-account/ia-content.bicep
// and the value the workflow reads via @appsetting('X12AgreementName') (design §5.4 / Simon README §2.1).
var x12AgreementName = 'Purchaser-Supplier-X12'

// --- Supplier-inbound 997 epic (LOCKED build-wave contract) --------------------------------
// KV secret holding the SUPPLIER Integration Account callback URL — links the supplier app to its IA
// (WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL). Written by CI post-deploy (mirror of the purchaser IA).
var supplierIaCallbackSecretName = 'supplier-ia-callback-url'
// KV secret holding the PURCHASER 997 receive endpoint (callback) URL — the supplier's outbound AS2 POST
// target for the 997. Injected in CI's non-interleaved dual-callback phase (design §5.2). LOCKED name.
var purchaser997EndpointSecretName = 'purchaser-997-endpoint-url'
// Supplier IA agreement names (Simon D-997-3, LOCKED). The supplier workflow reads these via @appsetting(...).
var supplierX12ReceiveAgreementName = 'Supplier-Purchaser-X12-850'
var supplierX12SendAgreementName = 'Supplier-Purchaser-X12-997'
var supplierAs2AgreementName = 'Supplier-Purchaser-AS2'
// Purchaser IA inbound-997 receive agreement name + the new purchaser 997 receive workflow (CI reads the
// latter's `manual` trigger callback URL in the dual-callback phase). LOCKED names.
var purchaserReceive997AgreementName = 'Purchaser-Supplier-X12-997'
var purchaserInbound997WorkflowName = 'purchaser-inbound-997'

// ============================================================================
// MODULE: NAMING PRIMITIVES (#2)
// ============================================================================

module names 'naming/naming.bicep' = {
  name: 'naming-primitives'
  params: {
    namingToken: namingToken
    environmentName: environmentName
    uniqueBase: subscription().subscriptionId
  }
}

// ============================================================================
// RESOURCE GROUPS (#4)
// ============================================================================

resource rgSharedResource 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgShared
  location: sharedLocation
  tags: commonTags
}

resource rgSupplierResource 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgSupplier
  location: sharedLocation
  tags: commonTags
}

resource rgPurchaserResource 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgPurchaser
  location: purchaserLocation
  tags: commonTags
}

// ============================================================================
// SHARED TIER — LOG ANALYTICS WORKSPACE (#5)
// ============================================================================
module logAnalyticsWorkspace 'shared/law.bicep' = {
  name: 'deploy-law'
  scope: resourceGroup(rgShared)
  params: {
    name: names.outputs.logAnalyticsWorkspace
    location: sharedLocation
    tags: commonTags
  }
  dependsOn: [
    rgSharedResource
  ]
}

// ============================================================================
// SHARED TIER — APPLICATION INSIGHTS (#6)
// ============================================================================
module applicationInsights 'shared/appinsights.bicep' = {
  name: 'deploy-appinsights'
  scope: resourceGroup(rgShared)
  params: {
    name: names.outputs.applicationInsights
    location: sharedLocation
    workspaceResourceId: logAnalyticsWorkspace.outputs.id
    tags: commonTags
  }
}

// ============================================================================
// KEY VAULT (#7)
// ============================================================================
module keyVault 'shared/keyvault.bicep' = {
  name: 'deploy-keyvault'
  scope: resourceGroup(rgShared)
  params: {
    name: names.outputs.keyVault
    location: sharedLocation
    tags: commonTags
    enablePurgeProtection: enablePurgeProtection
    logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
  }
}

// ============================================================================
// SQL SERVER + DATABASE (#9)
// ============================================================================
module sqlServer 'shared/sql.bicep' = {
  name: 'deploy-sql'
  scope: resourceGroup(rgShared)
  params: {
    serverName: names.outputs.sqlServer
    databaseName: names.outputs.sqlDatabase
    location: sharedLocation
    tags: commonTags
    entraAdminGroupObjectId: 'b9dac399-abc0-479d-9900-f2115a98297d'
    entraAdminGroupLogin: 'sql-admins'
    logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
  }
}

// ============================================================================
// SERVICE BUS NAMESPACE (#10)
// ============================================================================
module serviceBus 'shared/servicebus.bicep' = {
  name: 'deploy-servicebus'
  scope: resourceGroup(rgShared)
  params: {
    namespaceName: names.outputs.serviceBusNamespace
    location: sharedLocation
    tags: commonTags
    logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
    topicName: 'purchase-orders.received'
    subscriptionName: 'all-messages'
  }
}

// ============================================================================
// USER-ASSIGNED MANAGED IDENTITIES (#11, #12)
// ============================================================================
module purchaserUami 'modules/managed-identity.bicep' = {
  name: 'deploy-purchaser-uami'
  scope: resourceGroup(rgPurchaser)
  params: {
    name: names.outputs.purchaserUami
    location: purchaserLocation
    tags: commonTags
  }
  dependsOn: [
    rgPurchaserResource
  ]
}

module supplierUami 'modules/managed-identity.bicep' = {
  name: 'deploy-supplier-uami'
  scope: resourceGroup(rgSupplier)
  params: {
    name: names.outputs.supplierUami
    location: sharedLocation
    tags: commonTags
  }
  dependsOn: [
    rgSupplierResource
  ]
}

// ============================================================================
// PURCHASER COMPUTE BUNDLE (#13, app settings #16) — rg-edi-purchaser (East US 2)
// WS1 plan + empty Logic App Standard + storage + Free Integration Account, purchaser UAMI attached.
// ============================================================================
module purchaserCompute 'compute/logicapp-bundle.bicep' = {
  name: 'deploy-purchaser-compute'
  scope: resourceGroup(rgPurchaser)
  params: {
    planName: names.outputs.purchaserPlan
    logicAppName: names.outputs.purchaserLogicApp
    storageName: names.outputs.purchaserStorage
    integrationAccountName: names.outputs.purchaserIntegrationAccount
    location: purchaserLocation
    tags: commonTags
    uamiId: purchaserUami.outputs.id
    uamiClientId: purchaserUami.outputs.clientId
    appInsightsConnectionString: applicationInsights.outputs.connectionString
    serviceBusFullyQualifiedNamespace: serviceBus.outputs.fullyQualifiedNamespace
    sqlServerFqdn: sqlServer.outputs.serverFqdn
    sqlDatabaseName: sqlServer.outputs.databaseName
    // EDI send agreements live on the PURCHASER IA — wire the KV-referenced EDI app settings (design §7).
    keyVaultUri: keyVault.outputs.uri
    integrationAccountCallbackSecretName: purchaserIaCallbackSecretName
    supplierEndpointSecretName: supplierAs2EndpointSecretName
    x12AgreementName: x12AgreementName
    enableOpenTelemetry: true
  }
}

// ============================================================================
// SUPPLIER COMPUTE BUNDLE (#14/#12, app settings #16) — rg-edi-supplier (Central US)
// WS1 plan + empty Logic App Standard + storage + Free Integration Account, supplier UAMI attached.
// Supplier-inbound 997 epic: the supplier now links to its OWN IA (WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL,
// KV-ref) and carries the outbound 997 POST target (Purchaser997EndpointUrl, KV-ref, injected post-deploy)
// plus the X12 receive (850) / send (997) agreement-name settings the workflow reads via @appsetting(...).
// ============================================================================
module supplierCompute 'compute/logicapp-bundle.bicep' = {
  name: 'deploy-supplier-compute'
  scope: resourceGroup(rgSupplier)
  params: {
    planName: names.outputs.supplierPlan
    logicAppName: names.outputs.supplierLogicApp
    storageName: names.outputs.supplierStorage
    integrationAccountName: names.outputs.supplierIntegrationAccount
    location: sharedLocation
    tags: commonTags
    uamiId: supplierUami.outputs.id
    uamiClientId: supplierUami.outputs.clientId
    appInsightsConnectionString: applicationInsights.outputs.connectionString
    serviceBusFullyQualifiedNamespace: serviceBus.outputs.fullyQualifiedNamespace
    sqlServerFqdn: sqlServer.outputs.serverFqdn
    sqlDatabaseName: sqlServer.outputs.databaseName
    // EDI receive/send agreements now live on the SUPPLIER IA — wire the KV-referenced EDI app settings.
    keyVaultUri: keyVault.outputs.uri
    integrationAccountCallbackSecretName: supplierIaCallbackSecretName
    purchaser997EndpointSecretName: purchaser997EndpointSecretName
    x12ReceiveAgreementName: supplierX12ReceiveAgreementName
    x12SendAgreementName: supplierX12SendAgreementName
    enableOpenTelemetry: true
  }
}

// ============================================================================
// RBAC ASSIGNMENTS (#14)
// ============================================================================
module rbac 'rbac/role-assignments.bicep' = {
  name: 'deploy-rbac'
  params: {
    purchaserUamiPrincipalId: purchaserUami.outputs.principalId
    supplierUamiPrincipalId: supplierUami.outputs.principalId
    keyVaultId: keyVault.outputs.id
    serviceBusNamespaceId: serviceBus.outputs.namespaceId
    serviceBusTopicId: '${serviceBus.outputs.namespaceId}/topics/${serviceBus.outputs.topicName}'
    purchaserStorageId: purchaserCompute.outputs.storageId
    supplierStorageId: supplierCompute.outputs.storageId
    rgPurchaser: rgPurchaser
    rgSupplier: rgSupplier
    rgShared: rgShared
    logicAppsServicePrincipalObjectId: logicAppsServicePrincipalObjectId
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================

output resourceGroupShared string = rgShared
output resourceGroupSupplier string = rgSupplier
output resourceGroupPurchaser string = rgPurchaser

output namingOutputs object = names

// Shared tier outputs
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.outputs.id
output applicationInsightsConnectionString string = applicationInsights.outputs.connectionString
output applicationInsightsInstrumentationKey string = applicationInsights.outputs.instrumentationKey
output sqlServerFqdn string = sqlServer.outputs.serverFqdn
output sqlDatabaseName string = sqlServer.outputs.databaseName
output serviceBusNamespaceId string = serviceBus.outputs.namespaceId
output serviceBusFullyQualifiedNamespace string = serviceBus.outputs.fullyQualifiedNamespace
output serviceBusTopicName string = serviceBus.outputs.topicName
output serviceBusSubscriptionName string = serviceBus.outputs.subscriptionName

// Key Vault outputs
output keyVaultId string = keyVault.outputs.id
output keyVaultName string = keyVault.outputs.name
output keyVaultUri string = keyVault.outputs.uri

// UAMI outputs (for RBAC #14, SQL users #15, app settings #16/#17)
output purchaserUamiId string = purchaserUami.outputs.id
output purchaserUamiClientId string = purchaserUami.outputs.clientId
output purchaserUamiPrincipalId string = purchaserUami.outputs.principalId
output purchaserUamiName string = names.outputs.purchaserUami
output supplierUamiName string = names.outputs.supplierUami
output supplierUamiId string = supplierUami.outputs.id
output supplierUamiClientId string = supplierUami.outputs.clientId
output supplierUamiPrincipalId string = supplierUami.outputs.principalId

// Compute bundle outputs (#13/#14): Logic App names, default host names, integration account ids
output purchaserLogicAppName string = purchaserCompute.outputs.logicAppName
output purchaserLogicAppDefaultHostName string = purchaserCompute.outputs.defaultHostName
output purchaserIntegrationAccountId string = purchaserCompute.outputs.integrationAccountId
output purchaserStorageId string = purchaserCompute.outputs.storageId
output purchaserStorageName string = purchaserCompute.outputs.storageName
output purchaserContentShareSecretName string = purchaserCompute.outputs.contentShareSecretName

output supplierLogicAppName string = supplierCompute.outputs.logicAppName
output supplierLogicAppDefaultHostName string = supplierCompute.outputs.defaultHostName
output supplierIntegrationAccountId string = supplierCompute.outputs.integrationAccountId
output supplierStorageId string = supplierCompute.outputs.storageId
output supplierStorageName string = supplierCompute.outputs.storageName
output supplierContentShareSecretName string = supplierCompute.outputs.contentShareSecretName

// EDI epic (design §5/§6/§8): names CI needs for the post-deploy IA-content, callback-URL, and
// supplier-URL-injection steps.
output purchaserIntegrationAccountName string = names.outputs.purchaserIntegrationAccount
output purchaserIaCallbackSecretName string = purchaserIaCallbackSecretName
output supplierAs2EndpointSecretName string = supplierAs2EndpointSecretName
output x12AgreementName string = x12AgreementName
output supplierInboundAckWorkflowName string = 'supplier-inbound-ack'

// Supplier-inbound 997 epic outputs (LOCKED build-wave contract) — CI needs these for the supplier IA
// content deploy, the supplier IA link, and the non-interleaved dual callback-URL injection (design §5.2).
output supplierIntegrationAccountName string = names.outputs.supplierIntegrationAccount
output supplierIaCallbackSecretName string = supplierIaCallbackSecretName
output purchaser997EndpointSecretName string = purchaser997EndpointSecretName
output supplierX12ReceiveAgreementName string = supplierX12ReceiveAgreementName
output supplierX12SendAgreementName string = supplierX12SendAgreementName
output supplierAs2AgreementName string = supplierAs2AgreementName
output purchaserReceive997AgreementName string = purchaserReceive997AgreementName
output purchaserInbound997WorkflowName string = purchaserInbound997WorkflowName
