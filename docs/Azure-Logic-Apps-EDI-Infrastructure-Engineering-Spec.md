
# Azure Logic Apps Standard EDI Demo
## Engineering Design Specification (Infrastructure v1.0)

> **Purpose**: This specification defines the complete infrastructure required for a future Azure Logic Apps Standard EDI demonstration. It is written for implementation by a coding agent.

## Implementation Constraints

The implementation SHALL:

- Be deployable from a fresh Azure subscription.
- Use a single subscription-scoped Bicep deployment (`targetScope='subscription'`).
- Create all resource groups and resources.
- Require no Azure Portal configuration after deployment.
- Be idempotent.
- Produce a clean `what-if`.
- Produce a clean Bicep linter run.
- Prefer Azure Verified Modules (AVM) wherever feasible.
- Fall back to native Bicep only when an AVM cannot satisfy a material requirement.
- Never use Deployment Scripts unless there is no native Azure/Bicep alternative. Any Deployment Script requires explicit approval.
- Prefer platform-native Azure capabilities over custom scripting.
- Never deploy `Microsoft.Web/connections`.
- Use only Logic Apps Standard built-in connectors, `connections.json`, and `parameters.json`.

## Repository Layout

```
/
├── .github/workflows/
│   ├── validate.yml
│   ├── deploy.yml
│   └── destroy.yml
├── infra/
│   ├── main.bicep
│   ├── main.bicepparam
│   ├── modules/
│   ├── naming/
│   ├── diagnostics/
│   ├── sql/
│   ├── scripts/
│   └── environments/
├── logicapps/
│   ├── purchaser/
│   │   ├── host.json
│   │   ├── connections.json
│   │   ├── parameters.json
│   │   └── workflows/
│   └── supplier/
│       ├── host.json
│       ├── connections.json
│       ├── parameters.json
│       └── workflows/
├── docs/
└── README.md
```

## Resource Groups

- rg-edi-shared (Central US)
- rg-edi-supplier (Central US)
- rg-edi-purchaser (East US 2)

## Naming

- Follow Microsoft Cloud Adoption Framework naming guidance.
- Use Microsoft resource abbreviations.
- Deterministic, parameterized names.
- Storage accounts follow Azure naming constraints.

## Common Standards

Every supported resource SHALL:

- Tag: `SecurityControl=Ignore`
- Enable Public Network Access.
- Export `allLogs` or all available individual log categories to the shared Log Analytics Workspace.
- Export metrics only where required by AVM/platform.
- Use HTTPS and TLS 1.2+ where applicable.
- Prefer User Assigned Managed Identity.

No private endpoints, VNets, Private DNS, or network isolation are part of this demo.

## Shared Resources

Deploy:

- Log Analytics Workspace
- Workspace-based Application Insights
- Azure Key Vault
- Azure SQL Server + lowest-cost Serverless database
- Azure Service Bus Standard namespace

### Service Bus

Create:

- Topic: `purchase-orders.received`
- Subscription: `all-messages`

The subscription receives every message.

RBAC:

- Purchaser UAMI → Azure Service Bus Data Sender
- Supplier UAMI → Azure Service Bus Data Receiver

## Purchaser Resources

Deploy:

- WS1 Workflow Standard Plan (Windows)
- Logic Apps Standard (empty)
- User Assigned Managed Identity
- Storage Account
- Free Integration Account

Permissions:

- SQL custom role: PurchaserRole (SELECT, EXECUTE)
- Storage runtime data-plane
- Key Vault Secrets User
- Key Vault Certificate User
- Service Bus Data Sender

## Supplier Resources

Deploy:

- WS1 Workflow Standard Plan (Windows)
- Logic Apps Standard (empty)
- User Assigned Managed Identity
- Storage Account
- Free Integration Account

Permissions:

- SQL custom role: SupplierRole (INSERT, EXECUTE)
- Storage runtime data-plane
- Key Vault Secrets User
- Key Vault Certificate User
- Service Bus Data Receiver

## SQL

- Microsoft Entra authentication.
- Public Network Access enabled.
- Optimize for lowest-cost Serverless SKU.
- Deployment shall automatically create:
  - Contained users for both UAMIs.
  - PurchaserRole (SELECT, EXECUTE)
  - SupplierRole (INSERT, EXECUTE)
- No db_owner.

## Key Vault

Deploy with:

- Azure RBAC authorization
- Public Network Access
- Soft Delete
- Purge Protection (parameterized)

Deployment shall generate and publish:

- Demo Root CA
- Purchaser Signing certificate
- Purchaser Encryption certificate
- Supplier Signing certificate
- Supplier Encryption certificate

## Logic Apps Runtime

Configure:

- APP_KIND=workflowApp
- FUNCTIONS_EXTENSION_VERSION=~4
- FUNCTIONS_WORKER_RUNTIME=dotnet
- WEBSITE_NODE_DEFAULT_VERSION=<supported>
- APPLICATIONINSIGHTS_CONNECTION_STRING
- Always On
- HTTPS Only

Host storage shall use managed identity where supported:

- AzureWebJobsStorage__accountName
- AzureWebJobsStorage__credential=managedidentity
- AzureWebJobsStorage__clientId

Azure Files connection-string usage is permitted only if required by the Windows hosting model.

## Built-in Connections

Do not deploy Microsoft.Web/connections.

Provide:

- connections.json
- parameters.json

Use built-in connectors exclusively.

Service Bus identity configuration shall use the connection-prefix model discussed for this project (for example `<connectionName>__fullyQualifiedNamespace`, `<connectionName>__credential=managedidentity`, `<connectionName>__clientId`) and be consumed by `connections.json`.

SQL shall use managed identity with environment-specific values externalized and consumed by `connections.json`.

No manual connection authorization shall be required.

## GitHub Actions

Provide:

- validate.yml
- deploy.yml
- destroy.yml

The workflows shall validate, deploy, and destroy the complete environment.

## Acceptance Criteria

The implementation is complete when:

1. One subscription-scoped deployment provisions the complete environment.
2. All three resource groups are created.
3. AVMs are used wherever feasible.
4. Public Network Access is enabled.
5. CAF naming is followed.
6. All resources are tagged.
7. Shared LAW/App Insights are configured.
8. Service Bus Standard namespace exists.
9. Topic `purchase-orders.received` exists.
10. Subscription `all-messages` exists.
11. Purchaser UAMI can send.
12. Supplier UAMI can receive.
13. SQL users and custom roles are created automatically.
14. Host storage uses managed identity where supported.
15. Logic Apps use built-in connectors only.
16. No `Microsoft.Web/connections` resources are deployed.
17. No manual Azure Portal steps are required.
18. Repository structure matches this specification.
19. GitHub Actions are included.
20. Empty Logic Apps and Integration Accounts are ready for future EDI artifacts.

## Deferred

Future specifications will cover:

- Workflow implementation
- SQL schema
- X12
- AS2
- Trading partners
- Agreements
- Maps
- Blob persistence
- Retry/dead-letter strategy
- Demo walkthrough
