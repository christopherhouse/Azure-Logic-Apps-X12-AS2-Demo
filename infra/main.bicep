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
// TODO: SHARED TIER — LOG ANALYTICS WORKSPACE (#6)
// ============================================================================
// module logAnalyticsWorkspace 'shared/law.bicep' = {
//   name: 'deploy-law'
//   scope: resourceGroup(rgShared)
//   params: {
//     name: names.outputs.logAnalyticsWorkspace
//     location: sharedLocation
//     tags: commonTags
//   }
//   dependsOn: [
//     rgSharedResource
//   ]
// }

// ============================================================================
// TODO: SHARED TIER — APPLICATION INSIGHTS (#7)
// ============================================================================
// module applicationInsights 'shared/appinsights.bicep' = {
//   name: 'deploy-appinsights'
//   scope: resourceGroup(rgShared)
//   params: {
//     name: names.outputs.applicationInsights
//     location: sharedLocation
//     workspaceResourceId: logAnalyticsWorkspace.outputs.id
//     tags: commonTags
//   }
//   dependsOn: [
//     logAnalyticsWorkspace
//   ]
// }

// ============================================================================
// TODO: KEY VAULT (#8)
// ============================================================================
// module keyVault 'shared/keyvault.bicep' = {
//   name: 'deploy-keyvault'
//   scope: resourceGroup(rgShared)
//   params: {
//     name: names.outputs.keyVault
//     location: sharedLocation
//     tags: commonTags
//     logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
//   }
//   dependsOn: [
//     logAnalyticsWorkspace
//   ]
// }

// ============================================================================
// TODO: SQL SERVER + DATABASE (#9)
// ============================================================================
// module sqlServer 'shared/sql.bicep' = {
//   name: 'deploy-sql'
//   scope: resourceGroup(rgShared)
//   params: {
//     serverName: names.outputs.sqlServer
//     databaseName: names.outputs.sqlDatabase
//     location: sharedLocation
//     tags: commonTags
//     entraAdminGroupObjectId: 'b9dac399-abc0-479d-9900-f2115a98297d'
//     logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
//   }
//   dependsOn: [
//     logAnalyticsWorkspace
//   ]
// }

// ============================================================================
// TODO: SERVICE BUS NAMESPACE (#10)
// ============================================================================
// module serviceBus 'shared/servicebus.bicep' = {
//   name: 'deploy-servicebus'
//   scope: resourceGroup(rgShared)
//   params: {
//     namespaceName: names.outputs.serviceBusNamespace
//     location: sharedLocation
//     tags: commonTags
//     logAnalyticsWorkspaceId: logAnalyticsWorkspace.outputs.id
//     topicName: 'purchase-orders.received'
//     subscriptionName: 'all-messages'
//   }
//   dependsOn: [
//     logAnalyticsWorkspace
//   ]
// }

// ============================================================================
// TODO: USER-ASSIGNED MANAGED IDENTITIES (#11, #12)
// ============================================================================
// module purchaserUami 'identity/uami.bicep' = {
//   name: 'deploy-purchaser-uami'
//   scope: resourceGroup(rgPurchaser)
//   params: {
//     name: names.outputs.purchaserUami
//     location: purchaserLocation
//     tags: commonTags
//   }
//   dependsOn: [
//     rgPurchaserResource
//   ]
// }

// module supplierUami 'identity/uami.bicep' = {
//   name: 'deploy-supplier-uami'
//   scope: resourceGroup(rgSupplier)
//   params: {
//     name: names.outputs.supplierUami
//     location: sharedLocation
//     tags: commonTags
//   }
//   dependsOn: [
//     rgSupplierResource
//   ]
// }

// ============================================================================
// TODO: PURCHASER COMPUTE BUNDLE (#13)
// ============================================================================
// module purchaserCompute 'compute/logicapp-bundle.bicep' = {
//   name: 'deploy-purchaser-compute'
//   scope: resourceGroup(rgPurchaser)
//   params: {
//     planName: names.outputs.purchaserPlan
//     logicAppName: names.outputs.purchaserLogicApp
//     storageName: names.outputs.purchaserStorage
//     integrationAccountName: names.outputs.purchaserIntegrationAccount
//     location: purchaserLocation
//     tags: commonTags
//     uamiId: purchaserUami.outputs.id
//     uamiClientId: purchaserUami.outputs.clientId
//   }
//   dependsOn: [
//     purchaserUami
//     keyVault
//     sqlServer
//     serviceBus
//   ]
// }

// ============================================================================
// TODO: SUPPLIER COMPUTE BUNDLE (#14)
// ============================================================================
// module supplierCompute 'compute/logicapp-bundle.bicep' = {
//   name: 'deploy-supplier-compute'
//   scope: resourceGroup(rgSupplier)
//   params: {
//     planName: names.outputs.supplierPlan
//     logicAppName: names.outputs.supplierLogicApp
//     storageName: names.outputs.supplierStorage
//     integrationAccountName: names.outputs.supplierIntegrationAccount
//     location: sharedLocation
//     tags: commonTags
//     uamiId: supplierUami.outputs.id
//     uamiClientId: supplierUami.outputs.clientId
//   }
//   dependsOn: [
//     supplierUami
//     keyVault
//     sqlServer
//     serviceBus
//   ]
// }

// ============================================================================
// TODO: RBAC ASSIGNMENTS (#14)
// ============================================================================
// module rbac 'rbac/role-assignments.bicep' = {
//   name: 'deploy-rbac'
//   params: {
//     purchaserUamiPrincipalId: purchaserUami.outputs.principalId
//     supplierUamiPrincipalId: supplierUami.outputs.principalId
//     keyVaultId: keyVault.outputs.id
//     serviceBusId: serviceBus.outputs.id
//     purchaserStorageId: purchaserCompute.outputs.storageId
//     supplierStorageId: supplierCompute.outputs.storageId
//   }
//   dependsOn: [
//     purchaserUami
//     supplierUami
//     purchaserCompute
//     supplierCompute
//     keyVault
//     serviceBus
//   ]
// }

// ============================================================================
// OUTPUTS
// ============================================================================

output resourceGroupShared string = rgShared
output resourceGroupSupplier string = rgSupplier
output resourceGroupPurchaser string = rgPurchaser

output namingOutputs object = names
