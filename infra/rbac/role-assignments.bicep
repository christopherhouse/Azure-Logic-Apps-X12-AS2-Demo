// RBAC Role Assignments for Purchaser and Supplier UAMIs
// Deploys all least-privilege role assignments required for the EDI demo.
//
// Scope: Subscription
// Prerequisites: Both UAMIs, both storage accounts, Key Vault, and Service Bus namespace must exist.
//
// Role assignments are created at the resource group level for each target resource:
//   - Storage roles for the specific storage account (in the app's RG)
//   - Key Vault roles for the Key Vault resource (in rg-edi-shared)
//   - Service Bus roles for the Service Bus namespace (in rg-edi-shared)
//
// Built-in role definition GUIDs:
//   Storage Blob Data Owner:         b7e6dc6d-f1e8-4753-8033-0f276bb0955b
//   Storage Account Contributor:     17d1049b-9a84-46fb-8f53-869881c3d3ab
//   Storage Queue Data Contributor:  974c5e8b-45b9-4653-ba55-5f855dd0fb88
//   Storage Table Data Contributor:  0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3
//   Key Vault Secrets User:          4633458b-17de-408a-b874-0445c86b69e6
//   Key Vault Certificate User:      db79e9a7-68ee-4b58-9aeb-b90e7c24fcba
//   Key Vault Crypto User:           12338af0-0e69-4776-bea7-57ae8d297424
//   Service Bus Data Sender:         69a216fc-b8fb-44d8-bc22-1f3c2cd27a39
//   Service Bus Data Receiver:       4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0
//
// Integration Account private AS2 certificates reference a Key Vault key rather than embedding
// the private key. Per Microsoft Learn ("Add certificates to secure B2B messages in workflows
// for Azure Logic Apps" — logic-apps-enterprise-integration-certificates), the identity that
// reads Key Vault for this is the FIRST-PARTY Azure Logic Apps service principal
// (well-known app ID 7cd684f4-8a78-49b0-91ec-6a35d38739ba), NOT the Integration Account's
// managed identity. It requires list/get/decrypt/sign on the key vault. We grant it
// Key Vault Crypto User (key get + sign/decrypt) and Key Vault Secrets User (list/get) on the
// shared vault. Its per-tenant object ID must be resolved at deploy time
// (`az ad sp show --id 7cd684f4-8a78-49b0-91ec-6a35d38739ba --query id -o tsv`) and passed in.

targetScope = 'subscription'

// ============================================================================
// PARAMETERS
// ============================================================================

@description('Principal ID of the Purchaser UAMI')
param purchaserUamiPrincipalId string

@description('Principal ID of the Supplier UAMI')
param supplierUamiPrincipalId string

@description('Full resource ID of the Purchaser storage account')
param purchaserStorageId string

@description('Full resource ID of the Supplier storage account')
param supplierStorageId string

@description('Full resource ID of the Key Vault (in rg-edi-shared)')
param keyVaultId string

@description('Full resource ID of the Service Bus namespace (in rg-edi-shared)')
param serviceBusNamespaceId string

@description('''Full resource ID of the Service Bus topic the purchaser consumes
(purchase-orders.received). The purchaser UAMI is granted Azure Service Bus Data Receiver here so
its peek-lock trigger and settlement work — this is the durable grant that made the live E2E
round-trip succeed (see .squad/decisions.md).''')
param serviceBusTopicId string

@description('Name of the Purchaser resource group')
param rgPurchaser string

@description('Name of the Supplier resource group')
param rgSupplier string

@description('Name of the Shared resource group')
param rgShared string

@description('''Object ID (principal ID) of the first-party Azure Logic Apps service principal
(well-known app ID 7cd684f4-8a78-49b0-91ec-6a35d38739ba) in this tenant. Resolve at deploy time
with `az ad sp show --id 7cd684f4-8a78-49b0-91ec-6a35d38739ba --query id -o tsv`. Leave empty to
skip the Integration Account private-certificate Key Vault grants (e.g. when AS2 private certs
are not yet configured).''')
param logicAppsServicePrincipalObjectId string = ''

// ============================================================================
// ROLE DEFINITION IDs
// ============================================================================
var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageAccountContributor = '17d1049b-9a84-46fb-8f53-869881c3d3ab'
var storageQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var keyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var keyVaultCertificateUser = 'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'
var keyVaultCryptoUser = '12338af0-0e69-4776-bea7-57ae8d297424'
var serviceBusDataSender = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var serviceBusDataReceiver = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'

// ============================================================================
// PURCHASER UAMI — STORAGE ROLES (scoped to purchaser storage account)
// ============================================================================
module purchaserStorageBlobDataOwner '../modules/role-assignment.bicep' = {
  name: 'purchaser-storage-blob-owner'
  scope: resourceGroup(rgPurchaser)
  params: {
    principalId: purchaserUamiPrincipalId
    roleDefinitionId: storageBlobDataOwner
    targetResourceId: purchaserStorageId
    uniqueSuffix: 'purchaser-blob-owner'
  }
}

module purchaserStorageAccountContributor '../modules/role-assignment.bicep' = {
  name: 'purchaser-storage-account-contributor'
  scope: resourceGroup(rgPurchaser)
  params: {
    principalId: purchaserUamiPrincipalId
    roleDefinitionId: storageAccountContributor
    targetResourceId: purchaserStorageId
    uniqueSuffix: 'purchaser-account-contributor'
  }
}

module purchaserStorageQueueContributor '../modules/role-assignment.bicep' = {
  name: 'purchaser-storage-queue-contributor'
  scope: resourceGroup(rgPurchaser)
  params: {
    principalId: purchaserUamiPrincipalId
    roleDefinitionId: storageQueueDataContributor
    targetResourceId: purchaserStorageId
    uniqueSuffix: 'purchaser-queue-contributor'
  }
}

module purchaserStorageTableContributor '../modules/role-assignment.bicep' = {
  name: 'purchaser-storage-table-contributor'
  scope: resourceGroup(rgPurchaser)
  params: {
    principalId: purchaserUamiPrincipalId
    roleDefinitionId: storageTableDataContributor
    targetResourceId: purchaserStorageId
    uniqueSuffix: 'purchaser-table-contributor'
  }
}

// ============================================================================
// PURCHASER UAMI — KEY VAULT ROLES (scoped to Key Vault in rg-edi-shared)
// ============================================================================
module purchaserKvSecretsUser '../modules/role-assignment.bicep' = {
  name: 'purchaser-kv-secrets-user'
  scope: resourceGroup(rgShared)
  params: {
    principalId: purchaserUamiPrincipalId
    roleDefinitionId: keyVaultSecretsUser
    targetResourceId: keyVaultId
    uniqueSuffix: 'purchaser-secrets-user'
  }
}

module purchaserKvCertificateUser '../modules/role-assignment.bicep' = {
  name: 'purchaser-kv-certificate-user'
  scope: resourceGroup(rgShared)
  params: {
    principalId: purchaserUamiPrincipalId
    roleDefinitionId: keyVaultCertificateUser
    targetResourceId: keyVaultId
    uniqueSuffix: 'purchaser-certificate-user'
  }
}

// ============================================================================
// PURCHASER UAMI — SERVICE BUS DATA SENDER (scoped to Service Bus namespace)
// ============================================================================
module purchaserServiceBusSender '../modules/role-assignment.bicep' = {
  name: 'purchaser-servicebus-sender'
  scope: resourceGroup(rgShared)
  params: {
    principalId: purchaserUamiPrincipalId
    roleDefinitionId: serviceBusDataSender
    targetResourceId: serviceBusNamespaceId
    uniqueSuffix: 'purchaser-sb-sender'
  }
}

// ============================================================================
// PURCHASER UAMI — SERVICE BUS DATA RECEIVER (scoped to the purchase-orders.received TOPIC)
// The purchaser workflow CONSUMES PO messages from the topic (peek-lock trigger + settlement),
// so it needs Data Receiver on the topic. This durable grant is what made the live end-to-end
// round-trip work; without it the trigger cannot read messages (see .squad/decisions.md).
// ============================================================================
module purchaserServiceBusTopicReceiver '../modules/role-assignment.bicep' = {
  name: 'purchaser-servicebus-topic-receiver'
  scope: resourceGroup(rgShared)
  params: {
    principalId: purchaserUamiPrincipalId
    roleDefinitionId: serviceBusDataReceiver
    targetResourceId: serviceBusTopicId
    uniqueSuffix: 'purchaser-sb-topic-receiver'
  }
}

// ============================================================================
// SUPPLIER UAMI — STORAGE ROLES (scoped to supplier storage account)
// ============================================================================
module supplierStorageBlobDataOwner '../modules/role-assignment.bicep' = {
  name: 'supplier-storage-blob-owner'
  scope: resourceGroup(rgSupplier)
  params: {
    principalId: supplierUamiPrincipalId
    roleDefinitionId: storageBlobDataOwner
    targetResourceId: supplierStorageId
    uniqueSuffix: 'supplier-blob-owner'
  }
}

module supplierStorageAccountContributor '../modules/role-assignment.bicep' = {
  name: 'supplier-storage-account-contributor'
  scope: resourceGroup(rgSupplier)
  params: {
    principalId: supplierUamiPrincipalId
    roleDefinitionId: storageAccountContributor
    targetResourceId: supplierStorageId
    uniqueSuffix: 'supplier-account-contributor'
  }
}

module supplierStorageQueueContributor '../modules/role-assignment.bicep' = {
  name: 'supplier-storage-queue-contributor'
  scope: resourceGroup(rgSupplier)
  params: {
    principalId: supplierUamiPrincipalId
    roleDefinitionId: storageQueueDataContributor
    targetResourceId: supplierStorageId
    uniqueSuffix: 'supplier-queue-contributor'
  }
}

module supplierStorageTableContributor '../modules/role-assignment.bicep' = {
  name: 'supplier-storage-table-contributor'
  scope: resourceGroup(rgSupplier)
  params: {
    principalId: supplierUamiPrincipalId
    roleDefinitionId: storageTableDataContributor
    targetResourceId: supplierStorageId
    uniqueSuffix: 'supplier-table-contributor'
  }
}

// ============================================================================
// SUPPLIER UAMI — KEY VAULT ROLES (scoped to Key Vault in rg-edi-shared)
// ============================================================================
module supplierKvSecretsUser '../modules/role-assignment.bicep' = {
  name: 'supplier-kv-secrets-user'
  scope: resourceGroup(rgShared)
  params: {
    principalId: supplierUamiPrincipalId
    roleDefinitionId: keyVaultSecretsUser
    targetResourceId: keyVaultId
    uniqueSuffix: 'supplier-secrets-user'
  }
}

module supplierKvCertificateUser '../modules/role-assignment.bicep' = {
  name: 'supplier-kv-certificate-user'
  scope: resourceGroup(rgShared)
  params: {
    principalId: supplierUamiPrincipalId
    roleDefinitionId: keyVaultCertificateUser
    targetResourceId: keyVaultId
    uniqueSuffix: 'supplier-certificate-user'
  }
}

// ============================================================================
// SUPPLIER UAMI — SERVICE BUS DATA RECEIVER (scoped to Service Bus namespace)
// ============================================================================
module supplierServiceBusReceiver '../modules/role-assignment.bicep' = {
  name: 'supplier-servicebus-receiver'
  scope: resourceGroup(rgShared)
  params: {
    principalId: supplierUamiPrincipalId
    roleDefinitionId: serviceBusDataReceiver
    targetResourceId: serviceBusNamespaceId
    uniqueSuffix: 'supplier-sb-receiver'
  }
}

// ============================================================================
// AZURE LOGIC APPS FIRST-PARTY SERVICE PRINCIPAL — KEY VAULT ROLES
// (Integration Account private AS2 certificate → Key Vault key binding, design §5.5)
// Scoped to the shared Key Vault. Only deployed when the SP object ID is supplied.
// ============================================================================
module logicAppsSpKvCryptoUser '../modules/role-assignment.bicep' = if (!empty(logicAppsServicePrincipalObjectId)) {
  name: 'logicapps-sp-kv-crypto-user'
  scope: resourceGroup(rgShared)
  params: {
    principalId: logicAppsServicePrincipalObjectId
    roleDefinitionId: keyVaultCryptoUser
    targetResourceId: keyVaultId
    uniqueSuffix: 'logicapps-sp-crypto-user'
  }
}

module logicAppsSpKvSecretsUser '../modules/role-assignment.bicep' = if (!empty(logicAppsServicePrincipalObjectId)) {
  name: 'logicapps-sp-kv-secrets-user'
  scope: resourceGroup(rgShared)
  params: {
    principalId: logicAppsServicePrincipalObjectId
    roleDefinitionId: keyVaultSecretsUser
    targetResourceId: keyVaultId
    uniqueSuffix: 'logicapps-sp-secrets-user'
  }
}

// ============================================================================
// OUTPUTS
// ============================================================================
output rbacComplete bool = true
