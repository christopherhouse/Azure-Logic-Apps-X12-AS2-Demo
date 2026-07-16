// Naming Module
// Generates deterministic, CAF-compliant resource names using Microsoft resource abbreviations.
// Uses uniqueString for global-uniqueness requirements (e.g., Key Vault, storage, SQL).

targetScope = 'subscription'

@description('Naming token (e.g., jci)')
param namingToken string = 'jci'

@description('Environment name (dev, test, prod)')
param environmentName string = 'dev'

@description('Base string for uniqueString generation (typically subscription ID)')
param uniqueBase string = subscription().subscriptionId

// Generate a short deterministic suffix for globally unique names (8 chars)
var uniqueSuffix = substring(uniqueString(uniqueBase, namingToken, environmentName), 0, 8)

// Shared resources (rg-edi-shared)
output logAnalyticsWorkspace string = 'law-${namingToken}-edi-${environmentName}-${uniqueSuffix}'
output applicationInsights string = 'appi-${namingToken}-edi-${environmentName}-${uniqueSuffix}'
output keyVault string = take('kv-${namingToken}-edi-${environmentName}-${uniqueSuffix}', 24) // ≤24 chars
output sqlServer string = 'sql-${namingToken}-edi-${environmentName}-${uniqueSuffix}'
output sqlDatabase string = 'sqldb-${namingToken}-edi-${environmentName}'
output serviceBusNamespace string = 'sb-${namingToken}-edi-${environmentName}-${uniqueSuffix}'

// Purchaser resources (rg-edi-purchaser)
output purchaserUami string = 'id-${namingToken}-purchaser-${environmentName}'
output purchaserPlan string = 'asp-${namingToken}-purchaser-${environmentName}'
output purchaserLogicApp string = 'logic-${namingToken}-purchaser-${environmentName}'
output purchaserStorage string = toLower(replace('st${namingToken}purchaser${environmentName}${uniqueSuffix}', '-', '')) // storage: lowercase, no hyphens, ≤24
output purchaserIntegrationAccount string = 'ia-${namingToken}-purchaser-${environmentName}'

// Supplier resources (rg-edi-supplier)
output supplierUami string = 'id-${namingToken}-supplier-${environmentName}'
output supplierPlan string = 'asp-${namingToken}-supplier-${environmentName}'
output supplierLogicApp string = 'logic-${namingToken}-supplier-${environmentName}'
output supplierStorage string = toLower(replace('st${namingToken}supplier${environmentName}${uniqueSuffix}', '-', '')) // storage: lowercase, no hyphens, ≤24
output supplierIntegrationAccount string = 'ia-${namingToken}-supplier-${environmentName}'
