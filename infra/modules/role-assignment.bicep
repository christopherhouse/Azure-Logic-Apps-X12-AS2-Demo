// Reusable RBAC role assignment module
// Deploys a single role assignment scoped to a specific target resource.
//
// This module is deployed at the resource group level and creates a role assignment
// that targets a specific resource within that group.

targetScope = 'resourceGroup'

@description('Principal ID (object ID) of the managed identity to grant access to')
param principalId string

@description('Role definition ID (GUID only, not full resource ID)')
param roleDefinitionId string

@description('Full resource ID of the target resource')
param targetResourceId string

@description('Unique suffix for deterministic GUID generation')
param uniqueSuffix string

// Build the deterministic GUID name for the assignment
var assignmentName = guid(targetResourceId, principalId, roleDefinitionId, uniqueSuffix)

// Role assignment scoped to the target resource
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: assignmentName
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

output assignmentId string = roleAssignment.id
