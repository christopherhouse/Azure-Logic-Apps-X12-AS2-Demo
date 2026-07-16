// Azure Logic Apps Standard EDI Demo
// Infrastructure Orchestration (Subscription-scoped)
//
// Creates three resource groups:
// - rg-edi-shared (Central US) — shared services (LAW, App Insights, Key Vault, SQL, Service Bus)
// - rg-edi-supplier (Central US) — supplier Logic App Standard, storage, integration account
// - rg-edi-purchaser (East US 2) — purchaser Logic App Standard, storage, integration account
//
// Orchestrates Bicep modules to provision resources, configure RBAC, and wire runtime settings.

targetScope = 'subscription'

@description('Naming token for deterministic resource names (e.g., jci)')
param namingToken string = 'jci'

@description('Environment name (dev, test, prod)')
param environmentName string = 'dev'

// TODO (#5): resource groups + module wiring
