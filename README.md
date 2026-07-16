# Azure Logic Apps Standard AS2/X12 EDI Demo

> **Demo Purpose:** A complete reference implementation of AS2 and X12 EDI business-document exchange using Azure Logic Apps Standard, demonstrating purchaser-supplier purchase-order flow with managed identity, least-privilege RBAC, and Infrastructure-as-Code.

---

## What This Demo Is

This repository provisions and configures a **production-ready Azure Logic Apps Standard EDI environment** that demonstrates:

- **AS2 message transport** — secure, encrypted, signed business-document exchange over HTTP with Message Disposition Notifications (MDN)
- **X12 EDI translation** — decode incoming X12 purchase orders, transform to an internal format, and encode outbound X12 acknowledgments (997/TA1)
- **Two trading partners:**
  - **Purchaser** (East US 2) — sends purchase orders; receives acknowledgments
  - **Supplier** (Central US) — receives purchase orders via Azure Service Bus; persists to Azure SQL Database; sends acknowledgments
- **Managed identity and least-privilege RBAC** — no connection strings; separate User-Assigned Managed Identities per app with disjoint permissions (Purchaser = Service Bus Data Sender; Supplier = Service Bus Data Receiver)
- **Single subscription-scoped Bicep deployment** — provisions three resource groups, shared services (Log Analytics, Application Insights, Key Vault, SQL, Service Bus), and two Logic App Standard instances with Free Integration Accounts
- **Automated CI/CD pipelines** — validate, deploy, and destroy workflows using GitHub Actions and Azure OIDC federated credentials

**What this demo is NOT (yet):**
- Workflow implementations, X12 schemas, maps, AS2 agreements, and trading-partner configurations are **DEFERRED to a future specification** (per the Infrastructure v1.0 PRD).
- The infrastructure deploys **empty Logic Apps and empty Integration Accounts**. This v1.0 deliverable establishes the foundational environment; the EDI flows will be added in subsequent work.

---

## Architecture Summary

The environment spans **three resource groups**:

| Resource Group | Location | Purpose |
|---|---|---|
| `rg-edi-shared` | Central US | Shared services: Log Analytics Workspace, Application Insights, Key Vault, Azure SQL Server + Serverless DB, Service Bus Standard (topic `purchase-orders.received`, subscription `all-messages`) |
| `rg-edi-supplier` | Central US | Supplier Logic App Standard (WS1 Windows plan), storage account, Free Integration Account, User-Assigned Managed Identity |
| `rg-edi-purchaser` | East US 2 | Purchaser Logic App Standard (WS1 Windows plan), storage account, Free Integration Account, User-Assigned Managed Identity |

**Key design principles:**
- **Managed identity only** — no connection strings or access keys in code (except for Logic App content-share storage, where required by the WS1 Windows hosting model and Key Vault-referenced)
- **Least-privilege RBAC** — Purchaser can only *send* Service Bus messages; Supplier can only *receive*. SQL custom roles limit Purchaser to SELECT/EXECUTE and Supplier to INSERT/EXECUTE.
- **Diagnostics-first** — all resources export `allLogs` to the shared Log Analytics Workspace
- **Public network access** — intentional demo posture; all resources tagged `SecurityControl=Ignore`
- **Single deployment** — one subscription-scoped `az deployment sub create` invocation provisions the complete environment

For the detailed resource-dependency DAG and deploy ordering, see [`docs/infra-deploy-ordering.md`](docs/infra-deploy-ordering.md).

---

## Repository Structure

```
/
├── .github/workflows/      # CI/CD pipelines (validate.yml, deploy.yml, destroy.yml)
├── infra/                  # Bicep infrastructure-as-code
│   ├── main.bicep          # Subscription-scoped orchestration (creates 3 RGs + all resources)
│   ├── main.bicepparam     # Parameter file
│   ├── modules/            # Reusable Bicep modules (managed identity, etc.)
│   ├── naming/             # CAF naming conventions
│   ├── diagnostics/        # Diagnostic settings helpers
│   ├── shared/             # Shared-tier modules (LAW, App Insights, Key Vault, SQL, Service Bus)
│   ├── compute/            # Compute bundles (Logic App + plan + storage + Integration Account)
│   ├── rbac/               # RBAC role assignments
│   ├── sql/                # T-SQL scripts for SQL contained users + custom roles
│   └── scripts/            # Out-of-band operational scripts (cert generation)
├── logicapps/
│   ├── purchaser/          # Purchaser Logic App Standard artifacts
│   │   ├── host.json
│   │   ├── connections.json    # Built-in Service Bus + SQL connectors (managed identity)
│   │   ├── parameters.json     # Empty parameters file
│   │   └── workflows/          # (empty — future EDI workflows)
│   └── supplier/           # Supplier Logic App Standard artifacts
│       ├── host.json
│       ├── connections.json
│       ├── parameters.json
│       └── workflows/
├── docs/                   # Documentation
│   ├── deployment-guide.md                                         # Complete deployment runbook
│   ├── infra-deploy-ordering.md                                    # Architectural deploy ordering (Mal's contract)
│   ├── trading-partner-onboarding.md                               # Placeholder for future trading-partner config
│   └── Azure-Logic-Apps-EDI-Infrastructure-Engineering-Spec.md     # Infrastructure v1.0 PRD
└── README.md               # This file
```

---

## Prerequisites

Before deploying, ensure you have:

1. **Azure subscription** with Contributor + User Access Administrator permissions at subscription scope
   - Subscription ID: `8bd05b2f-62c5-4def-9869-f0617ebb3970` (verified for this demo)
   - Tenant ID: `76de2d2d-77f8-438d-9a87-01806f2345da`

2. **Azure CLI** authenticated (`az login`)
   - Version 2.50.0 or later: [Install Azure CLI](https://aka.ms/install-azure-cli)

3. **GitHub CLI** authenticated (`gh auth login`)
   - Required for setting repository secrets: [Install GitHub CLI](https://cli.github.com/)

4. **Bicep CLI** (bundled with Azure CLI 2.20.0+; verify with `az bicep version`)

5. **PowerShell 7+** (for the certificate-generation script)
   - Windows PowerShell 5.1+ also supported: [Install PowerShell 7](https://aka.ms/powershell)

6. **Git** for cloning the repository

7. **An Entra security group** for SQL Entra-only administration
   - The demo uses group object ID `b9dac399-abc0-479d-9900-f2115a98297d`
   - The deployment service principal must be added to this group (see Deployment Guide)

**Required Azure RBAC roles for deployment:**
- **Contributor** (at subscription scope) — to create resource groups and resources
- **User Access Administrator** (at subscription scope) — to assign RBAC roles on Key Vault, Storage, Service Bus, and SQL
- **Membership in SQL admin Entra group** — so the CI pipeline can create SQL contained users

---

## Quickstart

> **Note:** This quickstart assumes you are deploying manually via Azure CLI. For automated CI/CD deployment using GitHub Actions, see the [Deployment Guide](docs/deployment-guide.md).

### 1. Set up OIDC deployment identity (one-time)

Before deploying, you must create an Entra app registration, configure a federated credential for your GitHub repository, and assign the required roles. See [Deployment Guide — Section 2: OIDC Setup](docs/deployment-guide.md#2-oidc-deployment-identity-setup).

### 2. Deploy the infrastructure

```powershell
# Authenticate to Azure
az login --tenant 76de2d2d-77f8-438d-9a87-01806f2345da

# Set the target subscription
az account set --subscription 8bd05b2f-62c5-4def-9869-f0617ebb3970

# Deploy (subscription-scoped)
az deployment sub create `
  --location centralus `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam `
  --name "edi-demo-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
```

The deployment takes **approximately 10–15 minutes** and provisions:
- 3 resource groups
- Log Analytics Workspace + Application Insights
- Key Vault (with RBAC authorization, purge protection = false)
- Azure SQL Server + Serverless database (Entra-only auth)
- Service Bus Standard namespace + topic + subscription
- 2 User-Assigned Managed Identities
- 2 Logic App Standard instances (empty)
- 2 Storage accounts
- 2 Free Integration Accounts
- RBAC role assignments (least-privilege)

### 3. Generate and publish AS2 certificates

**AFTER the deployment completes**, run the certificate-generation script to create the Demo Root CA and four AS2 leaf certificates:

```powershell
cd infra/scripts
.\generate-certificates.ps1 -KeyVaultName "kv-jci-edi-dev-<uniqueSuffix>"
```

*(Replace `<uniqueSuffix>` with the actual Key Vault name from the deployment outputs or Azure Portal.)*

See [`infra/scripts/README.md`](infra/scripts/README.md) for details.

### 4. Verify the deployment

```powershell
# Check resource groups
az group list --query "[?contains(name, 'rg-edi')].{Name:name, Location:location}" -o table

# Check Logic Apps
az logicapp list --query "[].{Name:name, ResourceGroup:resourceGroup, DefaultHostName:defaultHostName}" -o table

# Check Key Vault certificates
az keyvault certificate list --vault-name "kv-jci-edi-dev-<uniqueSuffix>" -o table
```

**Expected state after quickstart:**
- 3 resource groups exist
- 2 Logic Apps are running (but empty — no workflows yet)
- 5 certificates are in Key Vault (root CA + 4 AS2 leaf certs)
- SQL database exists with Entra-only admin group
- Service Bus namespace has topic `purchase-orders.received` and subscription `all-messages`

---

## Post-Deployment Steps (DEFERRED)

The following steps are **DEFERRED to a future EDI specification** and are documented here for completeness:

1. **Upload X12 schemas** (850, 997, TA1) to both Integration Accounts
2. **Upload XSLT maps** (X12-to-internal, internal-to-X12) to both Integration Accounts
3. **Configure trading partners** in both Integration Accounts (AS2 identifiers, qualifiers, certificates)
4. **Create AS2 agreements** (send and receive agreements per partner)
5. **Deploy Logic App workflows** (AS2 receive → decode → X12 decode → transform → persist → X12 encode → AS2 send)
6. **Test the end-to-end flow** — send a sample X12 850 purchase order from Purchaser; verify Supplier receives, persists, and sends 997/TA1 acknowledgment

See [`docs/trading-partner-onboarding.md`](docs/trading-partner-onboarding.md) for the placeholder structure.

---

## CI/CD Pipelines

Three GitHub Actions workflows automate deployment and teardown:

| Workflow | Purpose | Trigger |
|---|---|---|
| [`validate.yml`](.github/workflows/validate.yml) | Bicep linting + `what-if` analysis | Manual (`workflow_dispatch`) |
| [`deploy.yml`](.github/workflows/deploy.yml) | Full deployment (infra + SQL users + content-share secrets) | Manual (`workflow_dispatch`) |
| [`destroy.yml`](.github/workflows/destroy.yml) | Reverse-order teardown + Key Vault purge | Manual (`workflow_dispatch`) |

All workflows use **OIDC federated credentials** (no stored secrets). Required repository secrets:
- `AZURE_CLIENT_ID` — app registration client ID
- `AZURE_TENANT_ID` — `76de2d2d-77f8-438d-9a87-01806f2345da`
- `AZURE_SUBSCRIPTION_ID` — `8bd05b2f-62c5-4def-9869-f0617ebb3970`

See [Deployment Guide](docs/deployment-guide.md) for CI/CD setup details.

---

## Teardown

To fully remove the environment:

### Option 1: Automated (via GitHub Actions)
Run the `destroy.yml` workflow from the Actions tab.

### Option 2: Manual
```powershell
# Delete resource groups
az group delete --name rg-edi-shared --yes --no-wait
az group delete --name rg-edi-supplier --yes --no-wait
az group delete --name rg-edi-purchaser --yes --no-wait

# Purge Key Vault (soft delete is enabled, purge protection is false)
az keyvault purge --name "kv-jci-edi-dev-<uniqueSuffix>"
```

> **Note:** Key Vault soft delete is enabled but purge protection is **false** (default) so the vault can be fully removed for dev/test environments.

---

## Key Design Decisions

- **Managed identity only** — no connection strings; RBAC enforces least privilege
- **Separate UAMIs per app** — Purchaser and Supplier have disjoint permissions
- **Public network access** — intentional demo posture (`SecurityControl=Ignore` tag)
- **Key Vault RBAC authorization** — no access policies
- **SQL Entra-only authentication** — no SQL logins
- **Built-in connectors only** — no `Microsoft.Web/connections`; `connections.json` + `parameters.json` for Service Bus and SQL
- **Single subscription-scoped deployment** — one `az deployment sub create` invocation
- **Out-of-band cert generation** — not a Bicep Deployment Script; operator-run script after Key Vault exists
- **Out-of-band SQL user/role creation** — CI/runner T-SQL step using an Entra token (not Bicep)

For the complete rationale, see [`docs/infra-deploy-ordering.md`](docs/infra-deploy-ordering.md).

---

## Documentation

- **[Deployment Guide](docs/deployment-guide.md)** — step-by-step manual deployment instructions (OIDC setup, deploy, certs, verification)
- **[Infrastructure Deploy Ordering](docs/infra-deploy-ordering.md)** — architectural design artifact: resource-dependency DAG, trust boundaries, out-of-band operations
- **[Trading Partner Onboarding](docs/trading-partner-onboarding.md)** — placeholder for future EDI configuration (AS2 identifiers, certificates, agreements, maps)
- **[Infrastructure Engineering Spec](docs/Azure-Logic-Apps-EDI-Infrastructure-Engineering-Spec.md)** — Infrastructure v1.0 PRD (read-only)

---

## Known Limitations / Future Work

- **Logic App workflows** — empty; AS2/X12 flows deferred to future spec
- **X12 schemas, maps, agreements, trading partners** — deferred to future spec
- **SQL schema** — database exists but tables/stored procedures are not defined
- **Content-share storage key** — Logic Apps on WS1 Windows require a storage account key for the Azure Files content share; this is Key Vault-referenced but not fully managed-identity-capable (Microsoft limitation; ASE v3 would support full managed identity)
- **Single environment** — this demo provisions `dev` only; `test`/`prod` environments would require separate parameter files

---

## Support & Contributing

This is a demonstration repository provided as-is for reference. It is not an officially supported Microsoft product.

**Feedback and contributions are welcome:**
- Open an issue for bugs or feature requests
- Submit a pull request for improvements

---

## License

This project is provided as-is for demonstration purposes under the [MIT License](LICENSE).
