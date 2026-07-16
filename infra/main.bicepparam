// Parameter file for main.bicep
// Azure Logic Apps Standard EDI Demo — Subscription-scoped deployment
//
// Environment: dev
// Subscription: 8bd05b2f-62c5-4def-9869-f0617ebb3970
// Tenant: 76de2d2d-77f8-438d-9a87-01806f2345da

using './main.bicep'

param namingToken = 'jci'
param environmentName = 'dev'
param sharedLocation = 'centralus'
param purchaserLocation = 'eastus2'
