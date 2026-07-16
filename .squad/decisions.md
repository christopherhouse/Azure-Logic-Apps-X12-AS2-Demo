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

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
