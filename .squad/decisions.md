# Squad Decisions

## Active Decisions

### 2026-07-16T16-15-55: Cert generation (#8) and SQL user/role creation (#15) have no native Bicep path; approach decision + possible Deployment Script approval required before build.
**By:** Mal-via-Coordinator
**What:** Cert generation (#8) and SQL user/role creation (#15) have no native Bicep path; approach decision + possible Deployment Script approval required before build.
**References:** docs/Azure-Logic-Apps-EDI-Infrastructure-Engineering-Spec.md, work item #8, work item #15, Mal, Zoe, Kaylee
**Why:** Two operations in the Infrastructure v1.0 PRD have no native Bicep/AVM path and collide with the spec's "no Deployment Scripts without approval / no portal steps" constraints: (1) generating the Demo Root CA + 4 AS2 leaf certs into Key Vault (work item #8), and (2) creating SQL contained users + custom roles PurchaserRole/SupplierRole (work item #15). Candidate approaches for each: (a) approved Deployment Script, (b) a CI/GitHub-runner step using an Entra token, or (c) pre-generated non-sensitive demo certs committed as artifacts (certs only). Both items are marked BLOCKED pending Christopher's approach decision. This is the single largest architectural risk in the infra spec and must be locked before Kaylee/Zoe start #8 and #15.

### 2026-07-16T16-22-43: Christopher answered all 9 infra clarifications: manual-script certs, CI-step SQL roles, Entra group admin, node ~22, purge=false, token 'jci' dev-only, sub 8bd05b2f, Contrib+UAA over RGs, SecurityControl=Ignore + public network required. #8 and #15 unblocked.
**By:** Christopher-House
**What:** Christopher answered all 9 infra clarifications: manual-script certs, CI-step SQL roles, Entra group admin, node ~22, purge=false, token 'jci' dev-only, sub 8bd05b2f, Contrib+UAA over RGs, SecurityControl=Ignore + public network required. #8 and #15 unblocked.
**References:** docs/Azure-Logic-Apps-EDI-Infrastructure-Engineering-Spec.md, work item #8, work item #15, work item #18, Mal, Zoe, Kaylee, Book
**Why:** Answers to the 9 infra PRD clarifications:
1. Cert generation (#8): a manually-run script (human runs it) generates Demo Root CA + 4 AS2 leaf certs and publishes to Key Vault. NOT a Bicep Deployment Script, NOT automated in deploy. Book documents the exact CLI/script steps.
2. SQL users/roles (#15): a CI/GitHub-runner step using an Entra token executes the T-SQL to create contained users + PurchaserRole(SELECT,EXECUTE)/SupplierRole(INSERT,EXECUTE).
3. SQL Entra admin: Entra GROUP object id b9dac399-abc0-479d-9900-f2115a98297d.
4. WEBSITE_NODE_DEFAULT_VERSION: ~22.
5. Key Vault Purge Protection default: false (so destroy.yml can fully tear down).
6. Naming token = 'jci'; single environment: dev only.
7. Target subscription: 8bd05b2f-62c5-4def-9869-f0617ebb3970. Regions/RGs confirmed: rg-edi-shared (Central US), rg-edi-supplier (Central US), rg-edi-purchaser (East US 2).
8. Demo posture confirmed intentional: SecurityControl=Ignore tag and Public Network Access are required on all resources.
9. OIDC deploy identity: Contributor + User Access Administrator scoped over the RGs. Additionally: the squad will provision the deployment service principal + federated credentials and set all required GitHub repo vars/secrets using Christopher's authenticated az/gh CLI logins (not scripted into IaC). Book must serialize the exact CLI steps into docs. NOTE for build: creating the RGs is a subscription-scoped deployment, so the deploy identity needs sufficient scope to create RGs + role assignments — reconcile RG-vs-subscription scope during #18.
Both #8 and #15 are now UNBLOCKED.

### 2026-07-16: Infrastructure deploy ordering (locked)
**By:** Mal (Lead / Integration Architect)
**Status:** Locked (dev environment)
**Artifact:** `docs/infra-deploy-ordering.md`

**What:** Locked the strict deploy ordering for the subscription-scoped Bicep deployment (`targetScope='subscription'`) that provisions the AS2/X12 EDI demo:

1. naming + diagnostics primitives → 2. subscription-scoped `main.bicep` creating the 3 resource groups (`rg-edi-shared`/Central US, `rg-edi-supplier`/Central US, `rg-edi-purchaser`/East US 2) → 3. shared tier (Log Analytics Workspace → workspace-based App Insights) → 4. Key Vault → 5. SQL Server + Serverless DB → 6. Service Bus Standard (topic `purchase-orders.received`, sub `all-messages`) → 7. per-app UAMIs (purchaser, supplier) → 8. compute bundles (WS1 plan + empty Logic App + storage + Free Integration Account, per app) → 9. RBAC → 10. app settings + `connections.json`/`parameters.json` → 11. CI/CD (validate/deploy/destroy) → 12. validation → 13. docs. Destroy runs in reverse order (mind Key Vault soft delete; purge protection = false).

Two app identities with disjoint least-privilege RBAC: **purchaser UAMI = Service Bus Data Sender**, **supplier UAMI = Service Bus Data Receiver**; Key Vault Secrets/Certificate *User* only; per-app storage data-plane; SQL PurchaserRole (SELECT,EXECUTE) / SupplierRole (INSERT,EXECUTE), no `db_owner`. Managed identity only; no `Microsoft.Web/connections`; built-in connectors only.

Two operations are **out-of-band (not Bicep, not Deployment Scripts):**
- **(a) Cert generation (#8):** a manually run script generates the Demo Root CA + 4 AS2 leaf certs and publishes to Key Vault. Sits after Key Vault, before app settings/first app start. Documented by Book.
- **(b) SQL users/roles (#15):** a CI/GitHub-runner step uses an Entra token (member of admin group `b9dac399-abc0-479d-9900-f2115a98297d`) to run T-SQL creating contained users for both UAMIs and the two custom roles. Runs after SQL + both UAMIs, before app settings, as a post-`main.bicep` job in deploy.yml.

**Why:** A single deployment fans out across three RGs with hard data-plane/RBAC dependencies, so ordering is an architectural decision, not an implementation detail. Each constraint is dependency-driven: RGs must exist before anything is scoped into them; LAW before any diagnostics; Key Vault and SQL before the out-of-band cert/SQL steps; UAMIs before RBAC and compute; RBAC before app settings so runtime identity works on first start. The cert and SQL-role steps are excluded from Bicep because their inputs (private-key generation, an operator/CI Entra token) don't belong in idempotent infra, and the spec forbids Deployment Scripts without explicit approval.

**Open item (#18):** the deploy identity needs **Contributor + User Access Administrator at subscription scope** because the deployment itself creates the RGs and the role assignments — RG-scoped grants cannot authorize either. Reconcile before first `deploy.yml` run (owner: coordinator + Zoe). Does not block design; blocks first successful deploy.

### 2026-07-16: Native Bicep creates the three resource groups
**By:** Kaylee
**What:** `infra/main.bicep` uses native `Microsoft.Resources/resourceGroups@2024-03-01` resources to create `rg-edi-shared`, `rg-edi-supplier`, and `rg-edi-purchaser` from the subscription-scoped deployment.
**Why:** Resource group creation is simple enough that native Bicep is clearer and avoids unnecessary AVM registry indirection. AVM remains preferred for downstream complex resources where it adds value.
**References:** `infra/main.bicep`, work items #3/#4/#5, `docs/Azure-Logic-Apps-EDI-Infrastructure-Engineering-Spec.md`.

### 2026-07-16: Shared tier modules are native Bicep and diagnostics-first
**By:** Kaylee
**What:** The shared tier uses native modules under `infra/shared/` for Log Analytics Workspace, workspace-based Application Insights, SQL Server + serverless database, and Service Bus Standard with topic `purchase-orders.received` and subscription `all-messages`. Outputs are exposed through `infra/main.bicep` for later RBAC, app settings, and CI steps.
**Why:** Native Bicep keeps these demo-critical resources transparent: the SQL Entra-only admin and serverless settings, Service Bus topic/subscription shape, and diagnostics wiring are easier to inspect directly than through AVM wrappers. Diagnostics use LAW as the sink; public network access and `SecurityControl=Ignore` match the locked demo posture.
**References:** `infra/shared/law.bicep`, `infra/shared/appinsights.bicep`, `infra/shared/sql.bicep`, `infra/shared/servicebus.bicep`, `infra/main.bicep`, work items #6/#9/#10.

### 2026-07-16: Security tier uses RBAC Key Vault, separate UAMIs, and a manual cert script
**By:** Zoe
**What:** Key Vault is deployed in `rg-edi-shared` with Azure RBAC authorization, public network access, diagnostics to LAW, soft delete, and parameterized purge protection defaulting to `false`. Purchaser and supplier each receive separate UAMIs through `infra/modules/managed-identity.bicep`. `infra/scripts/generate-certificates.ps1` is the manually-run operator script for the Demo Root CA plus four AS2 leaf certificates; it imports certs directly to Key Vault and does not write cert files to disk.
**Why:** RBAC-only Key Vault aligns permissions across Azure resources. Separate UAMIs avoid system-assigned identity/RBAC ordering cycles and enforce purchaser/supplier separation. Certificate generation remains out of Bicep/CI because it creates private keys and the spec forbids Deployment Scripts without approval.
**References:** `infra/shared/keyvault.bicep`, `infra/modules/managed-identity.bicep`, `infra/scripts/generate-certificates.ps1`, work items #7/#8/#11/#12.

### 2026-07-16: Logic App Standard WS1 content share requires a Key Vault-referenced storage key
**By:** Kaylee
**What:** `AzureWebJobsStorage` uses managed identity settings, but the WS1/Workflow Service Plan content share uses the sanctioned storage-key exception through `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING = @Microsoft.KeyVault(SecretUri=...)` plus `WEBSITE_CONTENTSHARE`. The app sets `keyVaultReferenceIdentity` to its UAMI so the platform resolves the Key Vault reference with the correct identity.
**Why:** Microsoft guidance says Standard Logic Apps on Workflow Service Plan currently cannot disable storage account key access for the content share; managed-identity-only content storage is supported only on ASE v3. Inline keys and `listKeys()` in Bicep are rejected. A post-`main.bicep` CI/operator step must publish the purchaser and supplier content-share connection strings as Key Vault secrets, then restart both Logic Apps.
**References:** `infra/compute/logicapp-bundle.bicep`, work items #13/#14/#16, Microsoft Learn Logic Apps managed identity storage guidance.

### 2026-07-16: Built-in Service Bus and SQL connectors use managed identity app settings
**By:** Wash
**What:** Both Logic Apps have `connections.json` and valid empty `parameters.json` files. Built-in `serviceBus` and `sql` service-provider connections resolve endpoints and UAMI client IDs from app settings: `serviceBus__fullyQualifiedNamespace`, `serviceBus__credential`, `serviceBus__clientId`, `sql__serverFqdn`, `sql__databaseName`, and `sql__clientId`. Bicep passes the SQL and Service Bus outputs into both compute module invocations.
**Why:** This preserves the managed-identity-only connector contract and avoids secrets, connection strings, and `Microsoft.Web/connections`. RBAC and SQL-role CI steps supply the actual runtime authorization for purchaser/supplier.
**References:** `logicapps/purchaser/connections.json`, `logicapps/supplier/connections.json`, `logicapps/purchaser/parameters.json`, `logicapps/supplier/parameters.json`, `infra/compute/logicapp-bundle.bicep`, `infra/main.bicep`, work item #17.

### 2026-07-16: Least-privilege RBAC role assignments implemented (#14)
**By:** Zoe
**What:** Implemented all 14 least-privilege Azure RBAC role assignments for the purchaser and supplier UAMIs via `infra/rbac/role-assignments.bicep` and `infra/modules/role-assignment.bicep`, wired from `infra/main.bicep`. Each app identity receives exact resource-scoped storage host roles, Key Vault Secrets User, Key Vault Certificate User, and asymmetric Service Bus data roles: purchaser = Data Sender, supplier = Data Receiver.
**Why:** The grants keep runtime access managed-identity-only and resource-scoped, avoid broad Owner/Contributor/User Access Administrator grants for app identities, preserve purchaser/supplier separation, and allow Logic Apps Standard host storage plus AS2 certificate use without inlined secrets. SQL permissions remain outside Azure RBAC and are handled by the CI T-SQL step.
**References:** `infra/rbac/role-assignments.bicep`, `infra/modules/role-assignment.bicep`, `infra/main.bicep`, work item #14, `.squad/decisions/inbox/zoe-rbac.md`.

### 2026-07-16: CI/CD workflows and SQL user/role step implemented (#15/#19/#20/#21)
**By:** Kaylee
**What:** Implemented GitHub Actions workflows for validation, deployment, and teardown: `.github/workflows/validate.yml`, `.github/workflows/deploy.yml`, and `.github/workflows/destroy.yml`. Authentication is OIDC-only using `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID`. `deploy.yml` runs subscription-scoped Bicep, publishes Logic App content-share storage keys to Key Vault as the sanctioned WS1 exception, restarts the Logic Apps, and runs `infra/sql/create-users-roles.sql` with an Entra SQL token to create contained UAMI users plus `PurchaserRole` and `SupplierRole`.
**Why:** The pipeline keeps deploy credentials out of GitHub secrets, preserves the locked subscription-scoped deployment ordering, automates the idempotent post-deploy work that depends on deployment outputs, and keeps SQL permissions least-privilege without using `db_owner`. The deployment identity prerequisite remains Contributor + User Access Administrator at subscription scope plus membership in SQL admin group `b9dac399-abc0-479d-9900-f2115a98297d`.
**References:** `.github/workflows/validate.yml`, `.github/workflows/deploy.yml`, `.github/workflows/destroy.yml`, `infra/sql/create-users-roles.sql`, work items #15/#19/#20/#21, `.squad/decisions/inbox/kaylee-cicd.md`.

### 2026-07-16: Infrastructure documentation completed (#23)
**By:** Book
**What:** Completed infrastructure documentation in `README.md`, `docs/deployment-guide.md`, and `docs/trading-partner-onboarding.md`. The docs cover demo purpose, architecture, repository structure, prerequisites, OIDC setup, subscription-scoped deployment, manual certificate generation, verification, teardown, troubleshooting, CI/CD workflows, known limitations, and deferred EDI/trading-partner implementation details.
**Why:** The project now has an operator-ready deployment runbook and onboarding scaffold that serialize the locked decisions, including the manual cert step, CI SQL user/role step, subscription-scope OIDC deployment identity, public-network demo posture, and deferred workflow/schema/map/trading-partner implementation scope.
**References:** `README.md`, `docs/deployment-guide.md`, `docs/trading-partner-onboarding.md`, work item #23, `.squad/decisions/inbox/book-docs.md`.

### 2026-07-16T17-29-57: Christopher accepted the native-Bicep-over-AVM deviation from the spec; no AVM rework — native modules stand for this demo.
**By:** Christopher-House
**What:** Christopher accepted the native-Bicep-over-AVM deviation from the spec; no AVM rework — native modules stand for this demo.
**References:** docs/Azure-Logic-Apps-EDI-Infrastructure-Engineering-Spec.md, docs/infra-acceptance-validation.md, infra/, Jayne, Kaylee, Mal
**Why:** The Infrastructure v1.0 spec states "prefer Azure Verified Modules (AVM) wherever feasible; fall back to native Bicep only when an AVM cannot satisfy a material requirement." The team implemented all resources with native Bicep (documented rationale: transparency and simplicity for a demo). Jayne flagged the deviation during acceptance validation (#22). Christopher reviewed and elected to KEEP native Bicep and accept the documented deviation from the spec's AVM preference. No rework required; native modules stand as the implementation for this demo.

### 2026-07-16T12:36:00-05:00: GitHub OIDC deployment identity provisioned for CI/CD
**By:** Zoe
**What:** Provisioned GitHub OIDC federated authentication for repository `christopherhouse/Azure-Logic-Apps-X12-AS2-Demo` against subscription `8bd05b2f-62c5-4def-9869-f0617ebb3970`. The app registration/service principal `sp-edi-jci-dev-gh-oidc` was created with client ID `923efbd9-17d1-468c-bc7c-5828856848c6`, federated credentials for `main` and pull requests, subscription-scoped Contributor and User Access Administrator role assignments, SQL Entra admin group membership, and GitHub repo secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID`.
**References:** work item #18, `.github/workflows/validate.yml`, `.github/workflows/deploy.yml`, `.github/workflows/destroy.yml`, subscription `8bd05b2f-62c5-4def-9869-f0617ebb3970`, SQL admin group `b9dac399-abc0-479d-9900-f2115a98297d`.
**Why:** The subscription-scoped Bicep deployment creates resource groups and role assignments, so the deploy identity needs subscription-scope Contributor + User Access Administrator. SQL admin group membership allows the CI SQL step to use Entra authentication for contained users and custom roles. OIDC keeps CI/CD passwordless with no client secret.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
