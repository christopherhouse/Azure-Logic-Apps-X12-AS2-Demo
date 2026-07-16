// Diagnostics Helper Module
// Provides standardized diagnostic settings pattern for sending allLogs + AllMetrics to LAW.
//
// RECOMMENDED USAGE:
// Define diagnostic settings INLINE within each resource module using this pattern:
//
// resource myResourceDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
//   name: 'send-to-law'
//   scope: myResource
//   properties: {
//     workspaceId: logAnalyticsWorkspaceId
//     logs: [
//       {
//         categoryGroup: 'allLogs'
//         enabled: true
//       }
//     ]
//     metrics: [
//       {
//         category: 'AllMetrics'
//         enabled: true
//       }
//     ]
//   }
// }
//
// This module exists primarily as a reference pattern and to centralize the standard config.
// For resources that support diagnostics, apply this pattern inline after resource creation.

targetScope = 'resourceGroup'

output diagnosticsPattern object = {
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
