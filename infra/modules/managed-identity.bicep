// User-Assigned Managed Identity (UAMI)
// Creates a single UAMI with outputs for resourceId, clientId (for app settings), and principalId (for RBAC).
// Purchaser UAMI deploys to rg-edi-purchaser (East US 2); Supplier UAMI deploys to rg-edi-supplier (Central US).

targetScope = 'resourceGroup'

@description('Managed identity name')
param name string

@description('Location for the managed identity')
param location string

@description('Resource tags')
param tags object = {}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

output id string = managedIdentity.id
output clientId string = managedIdentity.properties.clientId
output principalId string = managedIdentity.properties.principalId
output name string = managedIdentity.name
