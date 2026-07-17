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

### 2026-07-17: Purchaser PO→AS2/X12 850 epic — end-to-end design locked
**By:** Mal (Lead / Integration Architect)
**Status:** Locked design (dev). Branch `feature/purchaser-po-to-as2-850-workflow`. **DO NOT MERGE** (owner directive).
**Artifact:** `docs/purchaser-workflow-epic-design.md`
**What:** Locked the application-layer contract for the purchaser workflow: Service Bus (`all-messages`, peek-lock) → JSON Schema validation → normalized SQL persist (`dbo.usp_UpsertPurchaseOrder`, idempotent on `PoNumber`) → JSON→XML → XSLT transform → X12 850 encode → AS2 encode (sign SHA-256 + encrypt AES-256, sync signed MDN non-fatal) → HTTPS POST to supplier's callback trigger (supplier returns 200; MDN deferred). Canonical PO JSON (draft-2020-12 schema, field lengths capped to X12 limits) normalizes into `dbo.Address` + `dbo.PurchaseOrder` + `dbo.PurchaseOrderLine`. Deploy ordering extended: IA content (KV grant → certs → schema via contentLink → partners → agreements → app link) before any workflow; supplier workflow → callback URL → KV → purchaser setting → purchaser workflow; SQL DDL/proc before first purchaser run. Supplier is HTTP-200-only this epic (no IA link).
**Why:** Resolves every ambiguous Logic Apps Standard mechanism to the verified-correct one and keeps the managed-identity-only, built-in-connectors-only, no-`Microsoft.Web/connections` constraints intact while extending the locked deploy ordering so IA content and supplier-first URL injection cannot race the first run.
**References:** `docs/purchaser-workflow-epic-design.md`, `docs/infra-deploy-ordering.md`, `docs/purchaser-workflow-runbook.md`, `docs/trading-partner-onboarding.md`.

### 2026-07-17: X12 850 version is 006030 (product-owner choice)
**By:** Christopher-House (owner), Simon (EDI Analyst)
**What:** The product owner selected **X12 850 version 006030** (not 004010). Microsoft's official schema is committed at `infra/integration-account/schemas/X12_00603_850.xsd` (root `X12_00603_850`, namespace `http://schemas.microsoft.com/BizTalk/EDI/X12/2006`, ~2.15 MB, DO NOT EDIT). Envelope values: ISA12=`00603`, GS08=`006030`, `controlVersionNumber`/`schemaVersion`=`00603`, ISA11=`U`, usage indicator `T` (test), `ZZ`/`PURCHASER01`/`SUPPLIER01`. The XSLT map was retargeted to the official schema's exact element names/nesting and renamed `PO_Canonical_to_X12_850_006030.xslt` (the 004010 map was deleted). Schema `elementFormDefault` is unqualified → global elements (root, ref'ed segments, loop wrappers `N1Loop1`/`PO1Loop1`/`PIDLoop1`/`CTTLoop1`) are `x12:`-prefixed; local elements (inline `ST`/`SE` and all data fields) are unprefixed. Detail item-description segment is the global `PID_2`.
**Why:** Owner requirement. Map output schema-validates against the official 006030 xsd (see verification decision below).
**References:** `infra/integration-account/schemas/X12_00603_850.xsd`, `logicapps/purchaser/Artifacts/Maps/PO_Canonical_to_X12_850_006030.xslt`, `infra/integration-account/agreements/README.md`, `infra/integration-account/ia-content.bicep`.

### 2026-07-17: Built-in AS2/X12 EDI operations with a linked Integration Account (no connections)
**By:** Mal, Wash
**What:** AS2 (v2) and X12 are **built-in service-provider operations** — NO connection, NO `Microsoft.Web/connections`, empty `managedApiConnections`. Each app links to its per-app Free Integration Account via app setting `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` (SAS callback URL, treated as a secret → Key Vault reference resolved via `keyVaultReferenceIdentity` = app UAMI). **Artifact split:** the X12 850 `.xsd` lives in the **Integration Account** (X12 send agreement resolves it by name); the PO→850 **XSLT map** + canonical `.xsd` live in the app's **`Artifacts/Maps` + `Artifacts/Schemas`** (Transform XML reads `map.source: LogicApp`, repo-versioned, deploys with the app). Because XSLT needs XML input, the pipeline converts PO JSON→canonical XML first. X12 Encode reads `agreementName` from app setting `X12AgreementName` = `Purchaser-Supplier-X12`; AS2 Encode resolves by partner identities (`as2From`/`as2To`), so no AS2 app setting. `connections.json` = `serviceBus` + `sql` service-provider connections only.
**Why:** This is the verified-correct Logic Apps Standard EDI mechanism (checked against Microsoft Learn and real workflow.json samples) and preserves the managed-identity-only / built-in-connectors-only / no-`Microsoft.Web/connections` contract.
**References:** `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json`, `logicapps/purchaser/connections.json`, `infra/compute/logicapp-bundle.bicep`, Microsoft Learn (B2B AS2/X12 in Logic Apps; create/link integration account).

### 2026-07-17: Built-in SQL connector cannot pass a TVP — lines shredded from JSON via OPENJSON
**By:** Wash, Simon, Zoe
**What:** The built-in Logic Apps SQL `executeStoredProcedure` action **cannot pass a table-valued parameter**, so the earlier TVP design is dropped: `dbo.PurchaseOrderLineType` no longer exists. `dbo.usp_UpsertPurchaseOrder` now takes `@LinesJson NVARCHAR(MAX)` and shreds lines with `OPENJSON(@LinesJson) WITH (...)` (still `CREATE OR ALTER`, idempotent on `PoNumber`, `SET XACT_ABORT ON`; needs DB compat level ≥ 130). The workflow passes `LinesJson = @{string(...['lines'])}`. **No new SQL grant needed** — PurchaserRole's existing `GRANT EXECUTE/SELECT ON SCHEMA::dbo` covers the scalar-param proc; the `GRANT EXECUTE ON TYPE::dbo.PurchaseOrderLineType` line was removed from `create-users-roles.sql` (now byte-identical to committed). **OPENJSON `WITH` JSON paths are case-sensitive:** paths are camelCase (`$.lineNumber`, `$.sku`, `$.description`, `$.quantity`, `$.uom`, `$.unitPrice`) to match the workflow and design §3.2 (QA blocker B-1 caught an interim PascalCase deviation; the committed SQL is camelCase and correct).
**Why:** Removes the connector limitation as a build blocker without weakening least-privilege SQL access (ownership chaining; purchaser never gets direct table INSERT).
**References:** `infra/sql/schema/020-usp-upsert.sql`, `infra/sql/create-users-roles.sql`, `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json`, `docs/purchaser-workflow-epic-design.md` §3.2.

### 2026-07-17: >2 MB X12 schema registered via REST contentLink, not inline Bicep
**By:** Kaylee
**What:** The 006030 schema xsd is 2,253,563 bytes (2.15 MB), over the 2 MB inline limit. `Microsoft.Logic/integrationAccounts/schemas` in Bicep/ARM exposes only inline `content` (string) — `contentLink` is **not a writable Bicep input** (verified against Microsoft Learn). Mechanism (deploy.yml step): upload the xsd to purchaser storage container `ia-artifacts` (account-key SAS; storage keeps `allowSharedKeyAccess:true`), generate a short-lived read SAS, then `az rest --method put` to `.../integrationAccounts/{ia}/schemas/X12_00603_850?api-version=2019-05-01` with `properties.contentLink.uri` = blob SAS. The Logic service downloads content at PUT time. The rest of the IA content (partners, cert artifacts, X12+AS2 send agreements) is Bicep-native in `infra/integration-account/ia-content.bicep`, deployed by CI post-`main.bicep` and guarded on `ediReady` (skips gracefully if the supplier public cert is absent, keeping infra-only runs green).
**Why:** ARM/Bicep cannot register a schema above the inline limit; the REST `contentLink` path is the only supported mechanism for large schemas.
**References:** `infra/integration-account/ia-content.bicep`, `.github/workflows/deploy.yml`, `.github/workflows/validate.yml`, Microsoft Learn (integration account schemas ARM reference).

### 2026-07-17: AS2 private-cert Key Vault access via Logic Apps first-party service principal
**By:** Zoe (Security Engineer)
**What:** The IA AS2 private-cert artifact (`purchaser-signing`) binds to a Key Vault **key** (`demo-as2-purchaser-signing`), which introduces one new RBAC edge. Verified against Microsoft Learn ("Add certificates to secure B2B messages"): access is granted to the **Azure Logic Apps first-party service principal** (well-known app ID `7cd684f4-8a78-49b0-91ec-6a35d38739ba`), **NOT** the Integration Account's managed identity — so the IA resource needs no identity change and stays `properties: {}`. Granted that SP **Key Vault Crypto User** + **Key Vault Secrets User** on the shared vault via `infra/rbac/role-assignments.bicep`, guarded `if (!empty(logicAppsServicePrincipalObjectId))`. CI (`deploy.yml`) resolves the object id at deploy time (`az ad sp show --id 7cd684f4-...`) and passes it to the subscription-scoped deployment; until supplied, the grants no-op safely. The supplier public-encryption cert is uploaded directly (base64) as a public-cert artifact.
**Why:** Least-privilege, first-party-SP-only; avoids enabling and RBAC-ordering an IA system-assigned identity for the single new cert→vault edge.
**References:** `infra/rbac/role-assignments.bicep`, `infra/modules/role-assignment.bicep`, `infra/main.bicep`, Microsoft Learn `logic-apps-enterprise-integration-certificates`, first-party SP app ID `7cd684f4-8a78-49b0-91ec-6a35d38739ba`.

### 2026-07-17: Service Bus peek-lock settled by lockToken, not messageId
**By:** Mal (reviewer), Wash
**What:** The purchaser workflow's peek-lock topic trigger (`peekLockTopicMessages`, `splitOn` one run per message) settles the broker lock in both `Complete_Message` (`completeMessage`) and `Dead_Letter_Message` (`deadLetterMessage`) using `"lockToken": "@triggerBody()?['lockToken']"`. An interim build settled by `messageId` (a producer-set dedup value that does not settle the lock) — final cross-artifact review flagged this as a hard blocker; per reviewer protocol the coordinator (not the original author) applied the one-line fix. Dead-letter carries `deadLetterReason="PurchaseOrderProcessingFailed"` + truncated failing-action error. **MDN presence does not gate settlement** — recorded only as a tracked property. Success → complete; validation/processing/transport failure → dead-letter.
**Why:** Built-in Service Bus settlement operations resolve the lock by `lockToken`; settling by `messageId` fails, the lock expires, and the message is redelivered.
**References:** `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json` (`Complete_Message`, `Dead_Letter_Message`), `docs/purchaser-workflow-epic-design.md` §1/§7.

### 2026-07-17: Purchaser epic — GO / PR-ready; nothing merged (owner directive)
**By:** Mal (Lead / reviewer), verified by Jayne (QA)
**What:** Final cross-artifact review verdict: **GO — ready for PR.** The sole hard blocker (Service Bus settlement key) was cleared by the coordinator per reviewer lockout protocol. QA independently confirmed the map transform + 006030 XSD validation **PASS** and the JSON-schema gate (valid accepted, invalid rejected) **PASS**; AS2/HTTP/MDN/live-SQL cases need a deployed environment (offline harnesses are CI-ready and exit 0). `az bicep build` on `main.bicep` and `ia-content.bicep` both exit 0 (0 warnings). **Still no merge** — clearance is for PR readiness only; the owner directive keeps `main` untouched and the branch `feature/purchaser-po-to-as2-850-workflow` unmerged. Advisory (verify at first runtime, non-blocking): confirm the built-in `as2Encode` output shape (`outboundHeaders`/`content` accessors).
**Why:** The epic is consistent and complete across architecture, infra/CI, EDI artifacts, workflows, tests, and docs; the owner controls the merge decision.
**References:** `docs/purchaser-workflow-epic-design.md`, `samples/README.md`, `.github/workflows/deploy.yml`, `.github/workflows/validate.yml`.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
