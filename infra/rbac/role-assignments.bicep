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
//   Key Vault Certificate User:      db79e9a7-68d1-49b9-a4b5-11d1b83f8b93
//   Service Bus Data Sender:         69a216fc-b8fb-44d8-bc22-1f3c2cd27a39
//   Service Bus Data Receiver:       4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0

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

@description('Name of the Purchaser resource group')
param rgPurchaser string

@description('Name of the Supplier resource group')
param rgSupplier string

@description('Name of the Shared resource group')
param rgShared string

// ============================================================================
// ROLE DEFINITION IDs
// ============================================================================
var storageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageAccountContributor = '17d1049b-9a84-46fb-8f53-869881c3d3ab'
var storageQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var keyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var keyVaultCertificateUser = 'db79e9a7-68d1-49b9-a4b5-11d1b83f8b93'
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
// OUTPUTS
// ============================================================================
output rbacComplete bool = true
