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

### 2026-07-20T10:48:22-05:00: Book — Purchaser Workflow Epic documentation

**By:** Book (Technical Writer), requested by Christopher-House
**When:** 2026-07-17
**Branch:** `feature/purchaser-po-to-as2-850-workflow` — not merged (owner directive).

## What
Documented the built purchaser-workflow epic (docs only — no code touched). All file paths,
setting names, and resource names were verified against the actual repo files before writing.

**Files updated/created:**
- `README.md` — extended (not rewritten): added a prominent "📦 Update" callout to the stale
  "deferred EDI" block; added a new `## Purchaser Workflow Epic` section (end-to-end mermaid flow,
  canonical PO message contract, component table, offline + deployed "try it"); corrected the
  Repository Structure tree and Documentation list to reflect the epic artifacts. Existing infra
  content left intact.
- `docs/trading-partner-onboarding.md` — replaced the placeholder with the concrete, as-built
  config: partners (`Purchaser`/`Supplier`, ZZ `PURCHASER01`/`SUPPLIER01`), AS2 send agreement
  `Purchaser-Supplier-AS2` (SHA-256 sign, AES-256 encrypt, sync non-fatal MDN), X12 send agreement
  `Purchaser-Supplier-X12` (006030/850, ZZ, usage `T`), cert binding (private purchaser-signing → KV
  key + first-party SP RBAC; public supplier-encryption), 850 schema `X12_00603_850` via contentLink,
  deploy ordering, verification commands, and a "new partner" extension guide.
- `docs/purchaser-workflow-runbook.md` — new runbook: component map, end-to-end flow + settlement,
  full epic deploy ordering (deploy.yml step names in order), out-of-band cert prerequisite (R1),
  telemetry enablement, purchaser EDI app settings, how to run the demo (drop PO → 850 AS2 send →
  supplier 200), known limitations, and open risks R1/R2.

## Verified facts (against real files)
- Purchaser workflow `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json` — Stateful;
  SB `peekLockTopicMessages` trigger on `purchase-orders.received`/`all-messages` with `splitOn`;
  Scope `Process_Purchase_Order` (Parse JSON w/ embedded schema → SQL `executeStoredProcedure`
  `[dbo].[usp_UpsertPurchaseOrder]`, `LinesJson=@{string(...lines)}` → `Compose_Canonical_Xml`
  `@xml(body('Parse_Purchase_Order'))` → `Transform_to_X12_850_Xml` (Xslt, map source `LogicApp`) →
  `Encode_to_X12_850` (`x12Encode`, `agreementName=@appsetting('X12AgreementName')`) → `Encode_to_AS2`
  (`as2Encode`, as2From `PURCHASER01`/as2To `SUPPLIER01`) → `POST_AS2_to_supplier` (Http POST to
  `@appsetting('SupplierAs2Endpoint__url')`, tracked props poNumber/supplierResponseStatusCode/
  mdnReceived)); `Complete_Message` on SUCCEEDED; `Dead_Letter_Message` on FAILED/TIMEDOUT
  (reason `PurchaseOrderProcessingFailed`).
- Supplier workflow `.../supplier-inbound-ack/workflow.json` — `manual` HTTP trigger → 200
  "AS2 message received." Confirms MDN deferred.
- host.json (both apps) — `extensions.workflow.Settings.Runtime.ApplicationInsightTelemetryVersion=v2`
  (NOTE: actual key uses capital `Settings`, not lowercase `settings` as shown in design §7.1).
- App settings verified in bicep: `X12AgreementName=Purchaser-Supplier-X12` (main.bicep:67);
  `AzureFunctionsJobHost__telemetryMode`, `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL`,
  `SupplierAs2Endpoint__url` (logicapp-bundle.bicep); KV secret `supplier-as2-endpoint-url`.
- IA content `infra/integration-account/ia-content.bicep` — partners, `purchaser-signing` (private→KV
  key `demo-as2-purchaser-signing`), `supplier-encryption` (public), X12 agreement
  `Purchaser-Supplier-X12`, AS2 agreement `Purchaser-Supplier-AS2`, schema name `X12_00603_850`.
- RBAC `infra/rbac/role-assignments.bicep` — first-party SP `7cd684f4-8a78-49b0-91ec-6a35d38739ba`
  granted KV Crypto User + Secrets User, param `logicAppsServicePrincipalObjectId` (conditional on
  non-empty), resolved in deploy.yml step "Resolve Logic Apps first-party service principal object id".
- deploy.yml epic steps confirmed in order: resolve SP → deploy bicep → SQL users/roles → SQL DDL
  (010+020) → register X12 schema via REST contentLink (blob upload + SAS + `az rest put`) → deploy IA
  content (guarded by `ediReady`) → publish IA callback URL to KV → supplier workflow → purchaser
  workflow → supplier-URL injection (listCallbackUrl → KV secret → `functionapp restart`).

## Inconsistencies found while documenting
1. **RESOLVED — BLOCKER B-1 (samples/README.md).** The QA README flags a camelCase/PascalCase
   OPENJSON mismatch between the workflow (`lineNumber`/`sku`/…) and `020-usp-upsert.sql`. The current
   `020-usp-upsert.sql` uses **camelCase** paths (`'$.lineNumber'`, `'$.sku'`, `'$.description'`,
   `'$.quantity'`, `'$.uom'`, `'$.unitPrice'`) — matching the workflow and design §3.2. The blocker is
   fixed in the SQL file. The `samples/README.md` BLOCKER B-1 note and its comment about a PascalCase
   `@LinesJson` shape are now **stale** and should be cleared by the QA owner (Jayne) so the catalog
   doesn't imply a live defect. (Not fixed by Book — not my file; flagging for routing.)
2. **Design vs build — telemetry key casing.** Design §7.1 shows `extensions.workflow.settings`
   (lowercase); the delivered host.json uses `Settings` (capital). I documented the real value
   (`Settings`). Non-blocking; worth reconciling the design doc text if it's ever normative.
3. **Design vs build — X12 agreement name example.** Design §7 example uses
   `X12AgreementName = Purchaser-to-Supplier-850`; the actual value everywhere (main.bicep,
   ia-content.bicep) is `Purchaser-Supplier-X12`. I documented the real value.
4. **NIT N-1 (samples/README.md) — still open.** `PurchaseOrder_Canonical.xsd` header comment
   references `PO_Canonical_to_X12_850_004010.xslt`; the actual map is `...006030.xslt`. Cosmetic;
   route to the XSD author (Simon).

### 2026-07-17T13-59-02: Deep-dive fixed the deploy: correct KV Certificate User role id (db79e9a7-68ee-...), removed broken/unused content-share KV step, and rewrote the SQL step (pwsh + Invoke-Sqlcmd -AccessToken + temp firewall rule). Verified live: full deploy Succeeded + SQL users/roles created.
**By:** Christopher-House
**What:** Deep-dive fixed the deploy: correct KV Certificate User role id (db79e9a7-68ee-...), removed broken/unused content-share KV step, and rewrote the SQL step (pwsh + Invoke-Sqlcmd -AccessToken + temp firewall rule). Verified live: full deploy Succeeded + SQL users/roles created.
**References:** infra/rbac/role-assignments.bicep, deploy.yml, infra/sql/create-users-roles.sql, PR #5, run 29584552676, Kaylee, Zoe
**Why:** Deep-dive to get the first deploy fully working (per user request). Findings/fixes verified against the live subscription 8bd05b2f: (1) Root blocker was a wrong RBAC role id — Key Vault Certificate User is db79e9a7-68ee-4b58-9aeb-b90e7c24fcba (not db79e9a7-68d1-49b9-a4b5-11d1b83f8b93). Authoritative role ids should always be sourced via `az role definition list --name "<role>"`. (2) deploy.yml content-share post-deploy step (az keyvault secret set) was both unused (content share is now inline via listKeys) and would 403 — the deploy SP has management-plane roles (Contributor + UAA) but NO Key Vault data-plane RBAC. Removed it + the dependent restart. (3) SQL post-deploy step must run on a GitHub-hosted runner, which is NOT covered by the SQL server's AllowAllWindowsAzureIps rule — the step now adds a temporary SQL firewall rule for the runner's public IP (removed in finally). (4) Working SQL execution method: pwsh + Install-Module SqlServer + Invoke-Sqlcmd -AccessToken with an Entra token from `az account get-access-token --resource https://database.windows.net`; the deploy SP authenticates as SQL admin via membership in Entra group b9dac399. The classic `sqlcmd -G -P <token>` approach does not work. Whole template deploys idempotently (Succeeded twice) and SQL users/roles were created live. Consolidated in PR #5. LEARNING: chhouse (and the deploy SP) are members of the SQL admin group, so SQL post-deploy can be tested locally with a temporary firewall rule.

### 2026-07-16T18-40-46: Directive: every merge to main triggers deploy (add push:main to deploy.yml). Also: fix content-share to use inline listKeys() at create time (KV-reference/post-deploy approach fails preflight).
**By:** Christopher-House
**What:** Directive: every merge to main triggers deploy (add push:main to deploy.yml). Also: fix content-share to use inline listKeys() at create time (KV-reference/post-deploy approach fails preflight).
**References:** deploy.yml, infra/compute/logicapp-bundle.bicep, run 29524702062, Kaylee
**Why:** User directive: every merge to main MUST trigger a deployment to Azure. deploy.yml will add a push trigger on branches [main] (in addition to workflow_dispatch). Quote: "I want every merge to hit Azure". Also captured: the Windows Logic Apps Standard content share requires WEBSITE_CONTENTAZUREFILECONNECTIONSTRING at site-create time; the Key-Vault-reference/post-deploy-secret approach fails ARM preflight with CouldNotAccessStorageAccount. Fix: set the content-share connection string inline via listKeys() in infra/compute/logicapp-bundle.bicep (the sanctioned Azure Files connection-string exception the spec explicitly permits for the Windows hosting model) and remove the post-deploy content-share secret step from deploy.yml.

### 2026-07-17T15-31-24: SQL step fixed for real: UAMI names were null (wrong output path) and FROM EXTERNAL PROVIDER can't resolve for an SP with no server identity. Switched to SID-literal user creation (SID from client id via [guid].ToByteArray). Verified live: fresh create + idempotent, SIDs match Azure's.
**By:** Christopher-House
**What:** SQL step fixed for real: UAMI names were null (wrong output path) and FROM EXTERNAL PROVIDER can't resolve for an SP with no server identity. Switched to SID-literal user creation (SID from client id via [guid].ToByteArray). Verified live: fresh create + idempotent, SIDs match Azure's.
**References:** infra/sql/create-users-roles.sql, infra/main.bicep, deploy.yml, PR #6, run 29586594592, Kaylee, Zoe
**Why:** SQL post-deploy step: definitive fix, verified live. Two root causes: (1) UAMI names came through as 'null' — deploy.yml read a nonexistent output path (namingOutputs.value.purchaserUami); main.bicep never exposed UAMI names as strings. Fixed by adding purchaserUamiName/supplierUamiName outputs and reading them + the client ids. (2) CREATE USER ... FROM EXTERNAL PROVIDER cannot resolve UAMI display names on this server because the SQL server has NO managed identity (identity: null) and no Directory Reader, and the deploy SP's access token is scoped to database.windows.net only. An earlier local success was misleading — it ran as an interactive user (chhouse), not the SP. THE FIX: create Entra users by SID literal — CREATE USER [name] WITH SID = 0x..., TYPE = E — which needs no directory lookup and no server identity. The SID is computed from the UAMI CLIENT ID via [guid].ToByteArray() (this .NET byte order equals SQL's uniqueidentifier->varbinary order). Verified live: computed SIDs (purchaser 0x55232D8A3AEC1F42AB1D50EA89F15F83, supplier 0x89DAF22D4D2F9C41856D57EEC412054F) EXACTLY equal the SIDs Azure assigned via FROM EXTERNAL PROVIDER, so the UAMIs authenticate correctly. Dropped + recreated both users via SID literal successfully; roles + memberships created; idempotent re-run is a clean no-op. IMPORTANT: CREATE USER WITH SID requires a binary LITERAL, not a T-SQL variable. PR #6. LEARNING for future Entra-SQL work: prefer SID-based user creation over FROM EXTERNAL PROVIDER when the caller is a service principal and the server has no Directory-Reader identity.

### 2026-07-20T10:48:22-05:00: Jayne — QA on purchaser PO → X12 850 (006030) samples + transform

**By:** Jayne (Tester/QA) · via Coordinator · Requested by: Christopher-House
**Date:** 2026-07-17T12:48:31-05:00
**Branch:** `feature/purchaser-po-to-as2-850-workflow` (NOT merged — owner directive)

## What I delivered (samples/tests only — no workflow/infra/xsd/xslt/SQL edits)
- `samples/purchase-order.sample.json` — valid canonical PO (design §2.1): header + ship-to/bill-to + 3 lines.
- `samples/purchase-order.invalid.json` — invalid PO with 10 independent schema violations (dead-letter path).
- `samples/purchase-order.schema.json` — canonical PO JSON Schema (draft 2020-12, design §2.2).
- `samples/expected/purchase-order.sample.canonical.xml` — intermediate `xml(json(...))` XML (step 5a).
- `samples/expected/purchase-order.sample.850.xml` — **machine-generated** real XSLT output.
- `samples/validate-json.py` — asserts valid passes / invalid fails the schema.
- `samples/transform-and-validate.ps1` — validates canonical→XSD, runs the real map, validates 850→006030 XSD.
- `samples/README.md` — full test-case catalog (TC-1..TC-5) with automatable-now vs needs-env flags.

## Machine validation — PASS (independently confirmed Simon's claim)
Ran the **real** map `PO_Canonical_to_X12_850_006030.xslt` (via .NET `XslCompiledTransform`, XSLT 1.0) over the
canonical XML and validated the output against the official Microsoft `X12_00603_850.xsd` (2.15 MB, 006030):
- canonical XML → `PurchaseOrder_Canonical.xsd`: **PASS**
- XSLT transform runs: **PASS**
- 850 output → `X12_00603_850.xsd`: **PASS**
- JSON: valid sample conforms (0 errors), invalid sample rejected (10 violations): **PASS**

Output spot-checks: `BEG05=20260717`, `DTM02=20260731`, both `N1Loop1` (ST+BT), 3× `PO1Loop1`+`PID_2`,
`CTT01=3`, `CTT02=660`. `PO104=2.5` (JSON `2.50`→`2.5`; trailing zero dropped by `xml(json())`).

## 🔴 BLOCKER B-1 (High) — camelCase/PascalCase mismatch breaks SQL persist on the HAPPY path
- `workflow.json` `Persist_Purchase_Order` sends `LinesJson = @{string(...['lines'])}` → **camelCase** keys
  (`lineNumber,sku,description,quantity,uom,unitPrice`).
- `infra/sql/schema/020-usp-upsert.sql` shreds with **PascalCase** `OPENJSON ... WITH` paths
  (`'$.LineNumber','$.Sku','$.Description','$.Quantity','$.Uom','$.UnitPrice'`).
- OPENJSON `WITH` JSON paths are **case-sensitive** → every column resolves NULL → INSERT NULL into NOT NULL
  `LineNumber/Sku/Quantity/Uom/UnitPrice` → error 515 → proc fails → scope fails → **valid PO gets dead-lettered.**
- Authoritative design **§3.2 specifies camelCase paths** and matches the workflow. **The SQL file deviated** and
  is the one out of step.
- **Fix (SQL author, not Jayne):** change the `OPENJSON ... WITH` paths in `020-usp-upsert.sql` to camelCase to
  match workflow/design §3.2; also fix the file's comment block that documents a PascalCase `@LinesJson` shape.
  Route to Mal to adjudicate/assign a builder (lockout: original SQL author does not self-revise if rejected).
- Until fixed, TC-4 (idempotency) and TC-5 (persist shape) fail at the *first* insert, not the second.

## 📝 NIT N-1 (non-blocking) — `PurchaseOrder_Canonical.xsd` header comment references the old
`PO_Canonical_to_X12_850_004010.xslt`; actual map is `...006030.xslt`. Cosmetic. Route to XSD author.

## Coverage summary
- **Automatable now (offline, CI-ready):** JSON-schema gate (TC-3 reject portion), transform + 006030 XSD
  validation (TC-1 transform portion). Both harnesses exit 0.
- **Needs deployed env:** AS2 encode/sign+encrypt, HTTP POST, MDN-absent non-fatal settlement (TC-2), SB
  complete/dead-letter settlement, live SQL idempotency (TC-4) and persist-shape (TC-5).

### Kaylee — Infra/DevOps decisions: purchaser PO→AS2 850 epic (infra + CI layer)

**Branch:** `feature/purchaser-po-to-as2-850-workflow` (NOT merged). **Author:** Kaylee.

#### D1. Integration Account content: Bicep-native for everything EXCEPT the >2 MB schema
- **Bicep-native** (`infra/integration-account/ia-content.bicep`, new, RG-scoped module deployed by CI post-main):
  partners (Purchaser/Supplier, ZZ/PURCHASER01/SUPPLIER01), AS2 cert **artifacts** (purchaser-signing = private cert bound to the KV **key** `demo-as2-purchaser-signing` via `properties.key.{keyName,keyVault.id,keyVersion}`; supplier-encryption = public cert via `properties.publicCertificate` base64), and the **X12 + AS2 SEND agreements** (content transcribed verbatim from Simon's `agreements/README.md`).
- **NOT part of main.bicep** because: (a) the schema must be registered via REST first (agreements resolve it by name), (b) the supplier public-cert base64 is only readable from Key Vault at deploy time, (c) cert artifacts depend on the out-of-band cert-gen script (§8 #8) having populated KV.

#### D2. >2 MB X12_00603_850 schema → REST `contentLink`, NOT Bicep
- **VERIFIED against Microsoft Learn**: `Microsoft.Logic/integrationAccounts/schemas` (ARM/Bicep) exposes only inline `content` (string); `contentLink` is **not a writable Bicep input**. The xsd is 2,253,563 bytes (2.15 MB) > the 2 MB inline limit (schema hard limit 8 MB).
- **Mechanism** (deploy.yml step): upload xsd to purchaser storage container `ia-artifacts` (account-key SAS; storage has `allowSharedKeyAccess:true`), generate a 2h read SAS, then `az rest --method put` to `.../integrationAccounts/{ia}/schemas/X12_00603_850?api-version=2019-05-01` with body `{location, properties:{schemaType:'Xml', contentType:'application/xml', contentLink:{uri:<blob SAS>}}}`. The Logic service downloads content at PUT time, so the SAS only needs to be valid then.

#### D3. ARM-envelope reconciliation of Simon's agreement bodies (⚠ needs Simon/Mal review)
Simon's README bodies are semantically correct but omitted several **ARM-required** envelope fields and used a few wrong property spellings. Per README §4 ("ARM envelope property spelling should be reconciled against api-version 2019-05-01"), I reconciled them to make `az bicep build` clean (0 warnings) and avoid deploy-time RP rejection. Changes (envelope-only, no EDI semantics changed):
- **X12 `envelopeSettings`**: added required `groupHeaderAgencyCode:'X'`, `groupHeaderVersion:'006030'`, `groupHeaderDateFormat:'CCYYMMDD'`, `groupHeaderTimeFormat:'HHMM'` (standard 006030 GS-segment defaults).
- **X12 `acknowledgementSettings`**: added required `needImplementationAcknowledgement:false`, `batchImplementationAcknowledgements:false`.
- **X12 `securitySettings`**: replaced invalid `{authorizationRequired,passwordValue}` with the required `{authorizationQualifier:'00', securityQualifier:'00', passwordValue:''}` (ISA01/ISA03 = no-auth/no-security, standard demo values).
- **X12 `schemaReferences`**: dropped `receiverApplicationId` (not allowed on `X12SchemaReference`; only messageId/schemaName/schemaVersion/senderApplicationId are valid).
- **AS2 `content` key**: `as2` → **`aS2`** (ARM `AgreementContent` casing).
- **AS2 `mdnSettings`/`securitySettings`/`errorSettings`**: fixed casing `needMdn→needMDN`, `signMdn→signMDN`, `sendMdnAsynchronously→sendMDNAsynchronously`, `signOutboundMdnIfOptional→signOutboundMDNIfOptional`, `sendInboundMdnToMessageBox→sendInboundMDNToMessageBox`, `enableNrrFor*→enableNRRFor*` (6), `resendIfMdnNotReceived→resendIfMDNNotReceived`.
> Verified each against the Learn ARM template reference for `.../agreements` (X12EnvelopeSettings, X12AcknowledgementSettings, X12SecuritySettings, X12SchemaReference, AS2MdnSettings, AS2SecuritySettings, AS2ErrorSettings, AgreementContent).

#### D4. v2 telemetry — casing override (⚠ deviates from design §7 lowercase)
- **host.json is the version switch** (both apps): `extensions.workflow.**Settings**.Runtime.ApplicationInsightTelemetryVersion = "v2"` — **VERIFIED against Learn**: the key is capital-**S** `Settings`, not the lowercase `settings` written in design §7. Charter authorized me to verify casing; used capital-S.
- **App setting** `AzureFunctionsJobHost__telemetryMode = OpenTelemetry` added to **both** apps via Bicep (`enableOpenTelemetry` param, default `true`). This is the host-level OTel export (separate feature from the AI version switch). Both apps are OTel-compatible (OTel supports HTTP/Service Bus/Event Hubs triggers; purchaser=Service Bus, supplier=HTTP).
- `APPLICATIONINSIGHTS_CONNECTION_STRING` already set by the bundle — not duplicated.

#### D5. New purchaser app settings (Key Vault references only — no secrets in code)
Added conditionally in `infra/compute/logicapp-bundle.bicep` (`concat` of `baseAppSettings` + conditional arrays), wired from `main.bicep`:
- `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` = `@Microsoft.KeyVault(SecretUri=${keyVaultUri}secrets/purchaser-ia-callback-url)`
- `SupplierAs2Endpoint__url` = `@Microsoft.KeyVault(SecretUri=${keyVaultUri}secrets/supplier-as2-endpoint-url)`
- `X12AgreementName` = `Purchaser-Supplier-X12` (plain value; matches Simon's X12 agreement resource name + Wash's `@appsetting('X12AgreementName')`).
- Resolved via existing `keyVaultReferenceIdentity` = app UAMI pattern.
- **Supplier gets NONE of these** (HTTP-200-only this epic; no IA link). Supplier bundle gets telemetry only.
- AS2 agreement is resolved by `as2From/as2To` (partner identities), so **no AS2 app setting** is needed.

#### D6. deploy.yml ordered steps (§8 DAG, locked ordering preserved)
1. **Resolve Logic Apps first-party SP object id** — `az ad sp show --id 7cd684f4-8a78-49b0-91ec-6a35d38739ba --query id -o tsv` → passed as `logicAppsServicePrincipalObjectId` to the main sub-deploy (activates Zoe's guarded IA→KV grants).
2. main.bicep sub-deploy (captures EDI outputs).
3. SQL users/roles (existing) → **SQL DDL** `010-tables.sql` then `020-usp-upsert.sql` (mirrors existing token+temp-firewall mechanism).
4. **Schema blob upload + REST PUT** contentLink (D2).
5. **IA content deploy** (`ia-content.bicep`) — reads supplier public cert from KV; **guarded**: if `demo-as2-supplier-encryption` absent, emits a warning + `ediReady=false` and skips IA content + downstream EDI steps (infra-only run stays green).
6. **IA callback URL → KV** — `listCallbackUrl` on the IA → secret `purchaser-ia-callback-url` (guarded on `ediReady`).
7. **Deploy SUPPLIER workflow first**, then **PURCHASER workflow** (zip deploy incl. `Artifacts/Maps` + `Artifacts/Schemas`).
8. **Supplier-URL injection (§6)** — `listCallbackUrl` on trigger `manual` of `supplier-inbound-ack` (Logic App Standard runtime API) → KV secret `supplier-as2-endpoint-url` → **restart purchaser** (so the KV-ref app setting resolves). Guarded on `ediReady`.
- `validate.yml`: added `az bicep build` for `ia-content.bicep` (can't what-if standalone — needs live IA + cert param).

#### D7. Validation results
- `az bicep build infra/main.bicep` → **exit 0, 0 warnings**.
- `az bicep build infra/integration-account/ia-content.bicep` → **exit 0, 0 warnings** (all BCP035/037/089 resolved via D3).
- `deploy.yml` + `validate.yml` parse clean (yaml.safe_load). Both `host.json` parse clean.

#### Open risks
- **R1 (cert-gen prerequisite):** IA cert artifacts + AS2 agreement + supplier-URL injection all require the out-of-band cert-gen script (§8 #8) to have populated KV with `demo-as2-purchaser-signing` (key) and `demo-as2-supplier-encryption` (cert). CI **guards gracefully** (skips EDI content, stays green) but full E2E needs certs present.
- **R2 (CI SP KV cert read):** the `az keyvault certificate show` for the supplier public cert needs the CI SP to have KV data-plane cert read. If RBAC denies it, the guard treats it as "absent" and skips — verify the CI SP has Key Vault Certificate User on the shared KV for a real EDI run.
- **R3 (Simon/Mal review of D3):** the envelope reconciliation added standard 006030 defaults (`groupHeaderAgencyCode:'X'`, no-auth qualifiers `'00'`). Requesting EDI sign-off that these match the intended 006030 envelope; they are ARM-required and semantically neutral, but Simon owns the EDI content of record.
- **R4 (workflow zip deploy):** used `az functionapp deployment source config-zip` (Logic App Standard = functionapp kind). If the repo later standardizes on a different packaging (e.g., `Azure/logicapps-*` action), align.

### 2026-07-17T11-27-24: Purchaser PO→AS2/X12-850 workflow epic — authoritative design locked
**By:** Mal (Lead / Integration Architect) — via Coordinator, requested by Christopher-House
**Status:** Locked design (dev). Branch `feature/purchaser-po-to-as2-850-workflow`. DO NOT MERGE (owner directive).
**Updated:** 2026-07-17T12:24 — ratified 3 design changes (X12 006030, >2 MB contentLink, TVP→JSON/OPENJSON).
**Artifact:** `docs/purchaser-workflow-epic-design.md`

**What:** Authored the end-to-end design for the purchaser workflow epic: Service Bus (`all-messages`
subscription, peek-lock) → JSON Schema validation → normalized SQL persist via stored proc → JSON→XML →
XSLT transform → X12 850 (004010) encode → AS2 encode (sign+encrypt, sync MDN non-fatal) → HTTPS POST to the
supplier's SAS-signed HTTP trigger; supplier returns 200 (MDN deferred). Settlement: dead-letter on any
validation/processing/transport failure, complete on success (MDN presence does not gate settlement).

Key locked architecture decisions:
1. **Canonical PO JSON** designed (header: poNumber, orderDate, requestedDeliveryDate, currency, buyer/seller
   ids+names; ship-to + bill-to addresses; line items: lineNumber, sku, description, quantity, uom, unitPrice)
   with a draft-2020-12 JSON Schema; field lengths capped to fit X12 element limits.
2. **SQL normalized**: `dbo.Address` + `dbo.PurchaseOrder` + `dbo.PurchaseOrderLine`, surrogate identity PKs,
   `PoNumber` UNIQUE business key. Persisted by idempotent `dbo.usp_UpsertPurchaseOrder`. **Lines are passed
   as a JSON string (`@LinesJson NVARCHAR(MAX)`) and shredded with `OPENJSON`** — the built-in Logic Apps SQL
   connector **cannot pass a table-valued parameter** (Wash build finding), so the earlier TVP design is
   dropped: **no `dbo.PurchaseOrderLineType` type, no `GRANT EXECUTE ON TYPE`**. Idempotent on PoNumber so
   Service Bus redelivery does not duplicate. Returns PurchaseOrderId. **No new SQL grant** — existing
   `PurchaserRole` SELECT/EXECUTE cover it; purchaser never gets direct table INSERT (ownership chaining).
3. **X12 850 v006030** (MS official schema, root `X12_00603_850`, `standards_version="00603"`, committed at
   `infra/integration-account/schemas/X12_00603_850.xsd`): ZZ qualifiers, sender `PURCHASER01` / receiver
   `SUPPLIER01`, ISA12 `00603`, GS08 `006030`, ISA11 kept `U`, usage indicator T (test), control numbers from
   the IA X12 send agreement. Mapping specified (BEG, REF, DTM, N1Loop1 ST/BT, PO1Loop1 + PID per line,
   **CTT nested in CTTLoop1** per the MS schema, SE). 006030 has a richer segment set but the mapping still
   holds; the XSLT targets the suffixed loop element names. **>2 MB schema → registered on the IA via
   `contentLink` (upload to storage blob, point `contentLink.uri` at the blob URL); it CANNOT be inlined in the
   IA `schemas` Bicep `content`** (Kaylee mechanism). XSLT map renamed `PO_Canonical_to_X12_850_006030.xslt`.
4. **Logic Apps Standard EDI mechanism (verified vs Microsoft Learn):** AS2 (v2) + X12 are **built-in
   service-provider operations** — NO connection, NO `Microsoft.Web/connections`. The app links to a per-app
   **Free Integration Account** (same region/subscription — already satisfied) via app setting
   `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` (SAS URL → treated as secret → Key Vault reference resolved via
   `keyVaultReferenceIdentity`). **Artifact split (decided):** X12 850 `.xsd` lives in the **Integration
   Account** (X12 send agreement resolves schema by name, registered via contentLink); the PO→850 **XSLT map**
   + canonical `.xsd` live in the app **`Artifacts/Maps` + `Artifacts/Schemas`** (Transform XML reads from the
   app project, repo-versioned, deploys atomically). Because XSLT needs XML input, the pipeline converts PO
   JSON→canonical XML first. The X12 Encode `agreementName` is read from a new app setting **`X12AgreementName`**.
5. **AS2 send agreement:** sign (SHA-256, purchaser signing private cert), encrypt (AES-256, supplier
   encryption public cert), Request (signed) MDN synchronous, non-fatal. **Cert binding:** IA private-cert
   artifact references the **Key Vault key**; public-cert artifact uploaded directly. NEW RBAC edge: the IA's
   identity (system-assigned MI or Logic Apps first-party SP — confirm at build) needs **Key Vault Crypto User +
   Secrets User** on the shared vault.
6. **Supplier-URL injection (CI):** deploy supplier workflow first → read trigger callback URL via
   `.../triggers/{name}/listCallbackUrl` → write KV secret `supplier-as2-endpoint-url` → set purchaser app
   setting `SupplierAs2Endpoint__url` (`@Microsoft.KeyVault(...)`) → restart purchaser. Purchaser HTTP action
   reads `@appsetting('SupplierAs2Endpoint__url')`.
7. **v2 telemetry (both apps):** `host.json` `extensions.workflow.settings.Runtime.ApplicationInsightTelemetryVersion = v2`
   (source-controlled, authoritative) + existing `APPLICATIONINSIGHTS_CONNECTION_STRING` +
   `AzureFunctionsJobHost__telemetryMode = OpenTelemetry`. Do not double-declare the version. Purchaser-only
   EDI app settings collected for the same config pass: `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` (KV-ref),
   `SupplierAs2Endpoint__url` (KV-ref), `X12AgreementName`.
8. **Deploy-ordering additions:** IA content (KV grant → certs → schema via contentLink → partners →
   agreements → app link) before any workflow; app Artifacts ship with the app; supplier workflow → callback
   URL → KV → purchaser setting → purchaser workflow; SQL DDL/proc before first purchaser run.

**Handoffs:** Simon (canonical xsd + xslt + partner/agreement content + SQL DDL/OPENJSON proc; the 006030 xsd is
already committed), Kaylee (IA-content Bicep/CLI incl. blob upload + `contentLink` for the 2.15 MB schema + app
settings incl. `X12AgreementName` + CI + telemetry host.json), Wash (both workflow.json + connections/parameters;
pass lines as JSON to `@LinesJson`), Zoe (IA→KV grant; **no SQL grant needed** now that TVP is dropped),
Jayne (samples + tests incl. redelivery idempotency + missing-MDN + invalid-payload), Book (docs).

**References:** `docs/purchaser-workflow-epic-design.md`, `docs/infra-deploy-ordering.md`,
`logicapps/purchaser/connections.json`, `logicapps/purchaser/host.json`,
`infra/compute/logicapp-bundle.bicep`, `infra/sql/create-users-roles.sql`, `.github/workflows/deploy.yml`,
Microsoft Learn (B2B AS2/X12 in Logic Apps; create/link integration account; add certificates to secure B2B).

**Why:** Locks the application-layer contract the specialists build from, resolving every ambiguous Logic Apps
Standard mechanism to the verified-correct one (built-in EDI ops + linked IA via callback-URL app setting;
schema-in-IA / map-in-Artifacts split; IA private-cert→Key Vault binding; SAS callback-URL injection). Keeps
the managed-identity-only, built-in-connectors-only, no-`Microsoft.Web/connections` constraints intact and
extends the locked deploy ordering so IA content and the supplier-first URL injection cannot race the first run.


---

## Review Gate — Final Cross-Artifact Review (2026-07-17T14:05Z)

**Decision (Mal, Lead/reviewer): NO-GO — 1 hard blocker.** The epic on
`feature/purchaser-po-to-as2-850-workflow` is otherwise consistent and ready, but must not merge until the
Service Bus settlement key is corrected.

**BLOCKER (workflow.json).** `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json` settles the
peek-lock message by `messageId` in both `Complete_Message` (`operationId: completeMessage`) and
`Dead_Letter_Message` (`operationId: deadLetterMessage`). The built-in Service Bus service-provider
settlement operations resolve the broker lock by **`lockToken`**, which the `peekLockTopicMessages` trigger
emits. `messageId` is a producer-set dedup value and does not settle the lock → settlement fails, the lock
expires, and the message is redelivered. **Fix:** change both actions to
`"lockToken": "@triggerBody()?['lockToken']"` (drop the `messageId` parameter). Per reviewer protocol the
coordinator assigns the revision (settlement param) — a one-line change; re-review on fix.

**Advisory (non-blocking, verify at runtime).** The AS2 v2 encode output paths
`body('Encode_to_AS2')?['as2Message']?['outboundHeaders']` / `['content']` in `POST_AS2_to_supplier`
should be confirmed against the actual built-in `as2Encode` output shape during first run.

**Doc reconciliations folded into `docs/purchaser-workflow-epic-design.md` (contract now matches verified
build):**
1. §7.1 telemetry key `extensions.workflow.`**`Settings`** (capital S — lowercase is silently ignored).
2. §7 X12 agreement-name example → `Purchaser-Supplier-X12` (actual built value).
3. §1 added an explicit **settlement-key** note: settle by `lockToken`, not `messageId`.

**Verified consistent (GO on these):** X12 006030 everywhere (schema `X12_00603_850`, map
`PO_Canonical_to_X12_850_006030.xslt`); agreement names `Purchaser-Supplier-X12` / `Purchaser-Supplier-AS2`;
AS2 identities PURCHASER01/SUPPLIER01 (workflow ↔ agreement); app settings `X12AgreementName`,
`SupplierAs2Endpoint__url`, `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` (bundle bicep); OPENJSON proc
`@LinesJson` camelCase, idempotent on `PoNumber`, no TVP/type grant; `connections.json` = serviceBus+sql
only (built-in EDI needs none); host.json v2 telemetry; big schema via blob+`contentLink`; supplier-first URL
injection ordering; `az bicep build` main + ia-content exit 0; supplier workflow HTTP→200.


---

## Review Gate — Re-review after settlement fix (2026-07-17T14:00Z)

**Decision (Mal, Lead/reviewer): GO — ready for PR.** The blocker is cleared. Coordinator applied the fix
(not the original author, per reviewer protocol). `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json`
now settles the peek-lock by `lockToken` in both actions: `Complete_Message` (`completeMessage`, line 231)
and `Dead_Letter_Message` (`deadLetterMessage`, line 248) → `"lockToken": "@triggerBody()?['lockToken']"`.
No `messageId` remains in either settle action; `deadLetterReason`/`deadLetterErrorDescription` unchanged;
JSON parses clean. Settlement contract (§1, §7) now correct. AS2 encode output-path stays a first-run advisory,
not a merge gate. **Still no merge** (owner directive) — clearance is for PR readiness only.

### 2026-07-20T10:48:22-05:00: Decision — EDI artifacts for the purchaser 850/AS2 workflow

**By:** Simon (EDI Analyst)
**Date:** 2026-07-17T11:38:27-05:00 (updated 2026-07-17T11:49:11-05:00)
**Requested by:** Christopher House (via Coordinator)
**Branch:** `feature/purchaser-po-to-as2-850-workflow` (no merge — owner directive)
**Contract:** `docs/purchaser-workflow-epic-design.md` §2–§5, §8

## UPDATE 2026-07-17 (final) — X12 850 **006030** chosen; map validated; TVP dropped

Product owner selected **X12 850 006030** (not 004010). Microsoft's official schema is now on disk at
`infra/integration-account/schemas/X12_00603_850.xsd` (root element `X12_00603_850`, 2.1 MB, DO NOT EDIT).
Three changes made this round:

1. **Map reconciled + renamed → `PO_Canonical_to_X12_850_006030.xslt`** (old `..._004010.xslt` deleted).
   Retargeted every output element to the official schema's exact names/nesting and **schema-validated the
   transform output against `X12_00603_850.xsd` — VALIDATION: PASS** (2-line §2.1 sample; CTT01=2, CTT02=660).
   Key reconciliation facts discovered in the official schema:
   - Root `X12_00603_850`, namespace `http://schemas.microsoft.com/BizTalk/EDI/X12/2006`.
   - `elementFormDefault` is **unqualified** → GLOBAL elements (root, `ref`-ed segments `BEG/REF/DTM/N1/N3/N4/
     PO1/PID_2/CTT`, and loop wrappers `N1Loop1/PO1Loop1/PIDLoop1/CTTLoop1`) are in the x12 namespace;
     LOCAL elements (inline `ST`/`SE` segments **and every data field** `ST01/BEG01/.../CTT02/SE02`) are in
     **no namespace**. The map emits global tags prefixed `x12:` and all fields unprefixed — validated correct.
   - The detail item-description segment is the global element **`PID_2`** (not `PID`); PO1Loop1 → PIDLoop1 →
     `x12:PID_2` with `PID01=F`, `PID05=description`. Field names are **bare** (`BEG03`, not descriptive).
   - Segment/loop order matches the schema sequence (ST→BEG→REF→DTM→N1Loop1*→PO1Loop1(REQ)→CTTLoop1?→SE).
2. **Stored proc refactor — TVP removed.** The built-in SQL connector cannot bind a TVP, so
   `020-usp-upsert.sql` no longer defines `dbo.PurchaseOrderLineType`. `dbo.usp_UpsertPurchaseOrder` now takes
   `@LinesJson NVARCHAR(MAX)` and shreds lines with
   `OPENJSON(@LinesJson) WITH (LineNumber INT, Sku VARCHAR(30), [Description] NVARCHAR(80),
   Quantity DECIMAL(18,4), Uom VARCHAR(2), UnitPrice DECIMAL(18,4))`. Still `CREATE OR ALTER`, still idempotent
   on `PoNumber`, still `SELECT @PurchaseOrderId AS PurchaseOrderId`, `SET XACT_ABORT ON`. Requires DB
   compat level ≥ 130 (Azure SQL DB default).
3. **Agreement content → 006030.** `agreements/README.md` now: **GS08=`006030`**, **ISA12=`00603`**,
   `controlVersionNumber`/`schemaVersion`=`00603`, `schemaName`=`X12_00603_850`, schema file
   `X12_00603_850.xsd`. Unchanged: ISA11=`U`, usage indicator `T`/Test, `ZZ` / `PURCHASER01` / `SUPPLIER01`,
   all AS2 settings (sign SHA-256 / encrypt AES-256 / sync signed MDN non-fatal).

#### Revised dependency notes (supersede the older ones below)
- **Zoe — TVP grant is now REMOVED, not added.** Because the TVP is gone, `create-users-roles.sql` should
  **drop** the `GRANT EXECUTE ON TYPE::dbo.PurchaseOrderLineType TO PurchaserRole` line. The existing
  `GRANT EXECUTE ON SCHEMA::dbo` + `GRANT SELECT ON SCHEMA::dbo` are sufficient for the new JSON proc.
- **Kaylee — IA schema artifact is `X12_00603_850`** (from `infra/integration-account/schemas/X12_00603_850.xsd`);
  the agreement resolves the schema by that name. All 006030 content values are in `agreements/README.md`.
- **Coordinator — reconciliation complete.** No further ping needed; the map already validates against the
  real schema on disk.

---

_(Earlier update history retained below for the Scribe's record.)_

## Contract note

## UPDATE 2026-07-17T11:49 — X12 850 schema is now product-owner-provided

Per coordinator update: **Microsoft's official X12 850 004010 `.xsd` will be supplied by the product owner**
and dropped at `infra/integration-account/schemas/X12_850_004010.xsd`. I therefore **deleted my
hand-authored `X12_850_004010.xsd`** (it no longer exists) to avoid colliding with the official drop. The
XSLT map now targets Microsoft's standard 850 structure (root `X12_00401_850`; `BEG`/`REF`/`DTM`/`N1Loop1`/
`PO1Loop1`+`PIDLoop1`/**`CTTLoop1`**/`SE`) — I moved `CTT` inside a `CTTLoop1` to match. **Element-name
reconciliation is pending:** once the official xsd is present, the coordinator will ping me to reconcile every
map output element name against it (structure is expected correct; some MS packs use bare `BEGnn` names).

## What

Authored the EDI + SQL artifacts for the purchaser Purchase-Order → X12 850 → AS2 flow, strictly per the
locked epic design. Files created:

1. ~~`infra/integration-account/schemas/X12_850_004010.xsd`~~ — **removed**; official Microsoft schema is
   product-owner-provided and will be dropped in at this path.
2. `logicapps/purchaser/Artifacts/Schemas/PurchaseOrder_Canonical.xsd` — canonical PO schema (no namespace)
   describing the `xml(json(...))` intermediate XML; models the repeated-`<lines>` array shape.
3. `logicapps/purchaser/Artifacts/Maps/PO_Canonical_to_X12_850_004010.xslt` — XSLT 1.0 map implementing the
   full §4.2 mapping incl. date reformat (YYYY-MM-DD→CCYYMMDD via `translate`), N1 ST/BT loops, PO1-per-line
   with PID, `CTTLoop1`/CTT count + quantity hash. Targets Microsoft's official 850 structure.
4. `infra/sql/schema/010-tables.sql` — `Address`, `PurchaseOrder`, `PurchaseOrderLine` per §3.1; idempotent
   (`IF OBJECT_ID(...) IS NULL`).
5. `infra/sql/schema/020-usp-upsert.sql` — `dbo.PurchaseOrderLineType` TVP (`IF TYPE_ID(...) IS NULL`) +
   `dbo.usp_UpsertPurchaseOrder` (`CREATE OR ALTER`), idempotent on `PoNumber` per §3.2.
6. `infra/integration-account/agreements/README.md` — build-ready partner + X12 send + AS2 send agreement
   content (ARM `content` JSON bodies), envelope/delimiter/control-number strategy (§4.1), AS2
   sign-SHA256/encrypt-AES256/sync-signed-MDN-non-fatal (§5.3), cert binding table (§5.5).

## Verification performed

- Canonical XSD compiles in `XmlSchemaSet`; XSLT loads in `XslCompiledTransform`; transform runs clean.
- Structure spot check on 2-line sample: `CTTLoop1/CTT` nesting present, CTT01=2, CTT02=160 (120+40),
  2 `PO1Loop1`. (Full schema-validation of map output is **deferred** until the official
  `X12_850_004010.xsd` lands — will run at reconciliation.)
- Sample canonical XML validates against `PurchaseOrder_Canonical.xsd`. ✅
- Partner + X12 agreement JSON bodies parse as valid JSON (AS2 block intentionally carries `{{ }}` cert
  placeholders).

## Caveats / assumptions (flagged, not papered over)

- **X12 850 schema is external (official Microsoft, PO-provided).** Map element names await reconciliation
  against it. The map's loop/segment structure follows Microsoft's standard 850 004010 shape.
- Map scope is the **ST…SE transaction set body**. ISA/GS enveloping and all control numbers
  (ISA13/GS06/ST02) are **agreement-generated** per §4.1; the map emits only ST01=850 plus placeholder
  ST02/SE01/SE02 that the X12 Encode action overwrites.
- Canonical schema is deliberately **namespace-free** (matches `xml(json())` output) and treats
  `requestedDeliveryDate`, address `line2`, and line `description` as optional/nillable.

## Dependencies for other members

- **Zoe (`infra/sql/create-users-roles.sql`) — TVP grant:** the purchaser role can already EXEC the proc via
  `GRANT EXECUTE ON SCHEMA::dbo`, but passing the TVP needs one added grant:
  `GRANT EXECUTE ON TYPE::dbo.PurchaseOrderLineType TO PurchaserRole;` (§3.2). I did **not** edit that file.
- **Zoe (RBAC) — new IA→Key Vault edge:** the private cert artifact (`purchaser-signing`) references a KV key,
  so the IA's KV identity needs **Key Vault Crypto User + Key Vault Secrets User** on the shared vault
  (§5.5 / §8 B0), before the private cert artifact is registered. Confirm IA identity mechanism at build.
- **Kaylee (Bicep) — IA content:** partner + agreement + certificate `content` bodies are in
  `infra/integration-account/agreements/README.md`. Upload the **official** `X12_850_004010.xsd` as IA schema
  artifact named `X12_850_004010` (agreement resolves it by name). Replace the two AS2 cert-name placeholders
  with `purchaser-signing` / `supplier-encryption`. Reconcile ARM property casing against API `2019-05-01`.
- **Coordinator/PO — official X12 xsd:** ping me once `infra/integration-account/schemas/X12_850_004010.xsd`
  is in place so I can reconcile the map's output element names and run full schema-validation of the map.
- **Wash (workflow) — MDN non-fatal:** the AS2 agreement only *requests* the sync signed MDN; non-fatal
  settlement (do not dead-letter on missing/negative MDN) is enforced in the workflow, not the agreement.

### 2026-07-17T11:38:27-05:00: Purchaser + supplier workflows authored (built-in SB/EDI, peek-lock settlement)
**By:** Wash (Logic Apps / EDI Developer)
**Branch:** feature/purchaser-po-to-as2-850-workflow (do NOT merge)
**References:** docs/purchaser-workflow-epic-design.md §1/§2.2/§3.2/§4.3/§5/§6; logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json; logicapps/supplier/workflows/supplier-inbound-ack/workflow.json

**What was built**
- **Purchaser workflow** `purchaser-po-to-as2/workflow.json` (Stateful): SB peek-lock topic trigger → `Process_Purchase_Order` scope [Parse JSON w/ inline canonical schema → SQL exec proc → JSON→XML → Transform XML → X12 Encode → AS2 Encode → HTTP POST] → `Complete_Message` on SUCCEEDED / `Dead_Letter_Message` on [FAILED, TIMEDOUT].
- **Supplier workflow** `supplier-inbound-ack/workflow.json` (Stateful): `manual` Request (Http) trigger → `Return_200_OK` Response.
- **connections.json / parameters.json**: confirmed no change needed. Purchaser references built-in `serviceBus` + `sql` service-provider connections (already present); built-in EDI needs none; `managedApiConnections` stays empty; no `Microsoft.Web/connections`. No `@parameters()` used, so both `parameters.json` remain `{}`.

**Verified against Microsoft Learn / real workflow.json on GitHub (not guessed)**
- SB peek-lock topic trigger `peekLockTopicMessages` + `splitOn: @triggerOutputs()?['body']`; settlement `completeMessage` / `deadLetterMessage` keyed by `@triggerBody()?['messageId']` (Azure/LogicAppsTemplates, Atharva20/Azure_Integration).
- X12 Encode operationId `x12Encode`, serviceProviderId `/serviceProviders/x12`, params `messageToEncode` + `agreementName` (MS Learn logic-apps-enterprise-integration-x12 "Operation ID: x12Encode").
- Built-in SQL `executeStoredProcedure` / `/serviceProviders/sql`; `storedProcedureParameters` keys have NO `@` prefix; passing a collection as a JSON string param is the idiomatic pattern (HMXCorp/HMX-VAT-Tax).
- Transform XML action `type: "Xslt"`, `map.source: "LogicApp"` reading from Artifacts/Maps (multiple real repos).

**Decisions / settlement approach**
1. **Peek-lock settlement (design §1/§7):** used V1 `peekLockTopicMessages` with `splitOn` (one run per message) + explicit `completeMessage` (success) / `deadLetterMessage` (failure). Dead-letter carries `deadLetterReason="PurchaseOrderProcessingFailed"` and `deadLetterErrorDescription` = truncated `result('Process_Purchase_Order')` so the real failing-action error is captured. MDN presence does NOT gate settlement — recorded only as a tracked property on the HTTP POST.

**Limitations / reconciliation notes for Simon + Mal**
2. **TVP NOT supported by built-in SQL connector (design §3.2).** The built-in SQL `executeStoredProcedure` action cannot pass a table-valued parameter (`dbo.PurchaseOrderLineType`). Closest working approach implemented: pass line items as a JSON string param **`LinesJson`** = `@{string(...lines)}`. **ACTION for Simon/Mal:** change `dbo.usp_UpsertPurchaseOrder`'s `@Lines dbo.PurchaseOrderLineType READONLY` to **`@LinesJson NVARCHAR(MAX)`** and shred with `OPENJSON(@LinesJson) WITH (LineNumber int, Sku varchar(30), [Description] nvarchar(80), Quantity decimal(18,4), Uom varchar(2), UnitPrice decimal(18,4))`. This removes the need for the TVP type and the `GRANT EXECUTE ON TYPE::dbo.PurchaseOrderLineType` (Zoe §3.2) — note to Zoe. Idempotency-on-PoNumber and atomic TRAN are unchanged.

**Shapes to verify at designer/deploy round-trip (could not find a public code-view example)**
3. **Built-in EDI actions carry NO `connectionName`** (design §5.1: built-in AS2/X12 need no connection, IA resolved via `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` app setting). If the runtime/designer insists a ServiceProvider action have a `connectionName`, add empty-parameter `x12` and `as2` service-provider connections to connections.json (still no managedApiConnections / no Microsoft.Web/connections).
4. **AS2 v2 built-in Encode**: params `messageToEncode` / `as2From` / `as2To` are confirmed from MS Learn; the operationId `as2Encode` + serviceProviderId `/serviceProviders/as2` and the output accessors `body('Encode_to_AS2')?['as2Message']?['content']` / `?['outboundHeaders']` are inferred by analogy to `x12Encode` (no public code-view sample exists). Verify against a designer round-trip during build.

**App settings the workflows reference (owners: Kaylee for app settings)**
- `X12AgreementName` — name of the X12 send agreement in the purchaser IA (Encode_to_X12_850). **Not yet defined — Kaylee/Simon must add.**
- `SupplierAs2Endpoint__url` — supplier callback URL as KV reference (design §6, already planned).
- SB message body assumption: reads `@triggerBody()?['contentData']` as the canonical PO JSON string. If the producer publishes base64, wrap with `base64ToString(...)`.

**Follow-up ratified changes (2026-07-17T12:24-05:00, coordinator)**
- **X12 version 004010 → 006030.** Transform XML map reference updated to `PO_Canonical_to_X12_850_006030.xslt` (Simon renaming the map). No flow change; X12 Encode still resolves via `@appsetting('X12AgreementName')`.
- **TVP → LinesJson ratified as the design.** SQL Execute stored procedure passes param **`LinesJson`** = `@{string(body('Parse_Purchase_Order')?['purchaseOrder']?['lines'])}`, matching Simon's refactored proc `@LinesJson NVARCHAR(MAX)` + OPENJSON. No TVP-shaped param remains; note item #2's `GRANT EXECUTE ON TYPE` for Zoe is now obsolete.

**Ownership boundaries respected:** did NOT touch host.json (Kaylee owns v2 telemetry), Bicep, CI, SQL scripts, or xsd/xslt (Simon). Referenced map/schema by design filenames only.

### 2026-07-20T10:48:22-05:00: Decision: Built-in X12/AS2 Encode action shapes (Logic Apps Standard)

- **Author:** Wash (Logic Apps / EDI Developer)
- **Date:** 2026-07-20T10:17:06-05:00
- **Branch:** `bugfix/x12-as2-encode-serviceprovider-shape`
- **Closes:** Hard-won-pitfall — "Built-in X12/AS2/EDIFACT actions: verify serviceProviderId + operationId; do not guess `/serviceProviders/x12`."

## Problem
`purchaser-po-to-as2` was **Unhealthy**:
`The value '/serviceProviders/x12' provided for 'serviceProviderConfiguration.serviceProviderId' for 'x12Encode' is not valid.`
The X12 Encode and AS2 Encode actions were authored as **service-provider** actions
(`type: ServiceProvider` + `serviceProviderConfiguration`). That shape is wrong for the
built-in EDI connectors.

## Ground truth (verified, not guessed)
Queried the **live runtime** operation catalog:
`GET .../hostruntime/runtime/webhooks/workflow/api/management/operationGroups?api-version=2018-11-01`

- Service-provider connectors (Service Bus, SQL) return `"type": "ServiceProvider"` and
  `"id": "/serviceProviders/<name>"`. These use `serviceProviderConfiguration`.
- **X12 and AS2 (v2) do NOT.** They return `"id": "connectionProviders/x12Operations"` /
  `"connectionProviders/as2Operations"` with **no** `type: ServiceProvider`. They are
  **native in-app built-in actions**, invoked by the action's own `type`, exactly like
  `Xslt`, `Compose`, `ParseJson`. There is **no** `serviceProviderId`/`serviceProviderConfiguration`
  and **no** `connections.json` entry for them.
- Operation catalog per group:
  - `x12Operations`: operations `x12Encode` (type `X12Encode`), `x12BatchEncode`, `x12Decode`.
  - `as2Operations`: operations `as2Encode` (type `AS2Encode`), `as2Decode`.

#### Correct X12 Encode action shape
```json
"Encode_to_X12_850": {
  "type": "X12Encode",
  "inputs": {
    "messageToEncode": "@body('Transform_to_X12_850_Xml')",
    "agreementName": "@appsetting('X12AgreementName')"
  }
}
```
Input JSON names (Learn `logic-apps-enterprise-integration-x12#encode-x12-messages`):
`messageToEncode` (req), `agreementName`, `senderIdentity.{qualifier,value}`,
`receiverIdentity.{qualifier,value}`, `b2bTrackingId`.

#### Correct AS2 Encode action shape
```json
"Encode_to_AS2": {
  "type": "AS2Encode",
  "inputs": {
    "messageToEncode": "@body('Encode_to_X12_850')",
    "as2From": "PURCHASER01",
    "as2To": "SUPPLIER01"
  }
}
```
Input params (Learn `logic-apps-enterprise-integration-as2#encode-as2-messages`):
**Message to encode** / **AS2 from** / **AS2 to**. JSON names
(`messageToEncode`, `as2From`, `as2To`, optional `contentType`, `fileName`, `b2bTrackingId`)
cross-checked against community connector registries.

## Sources
- Live runtime `operationGroups` catalog (authoritative for id/type/operationId).
- Learn: `logic-apps-enterprise-integration-x12` (X12 built-in JSON param names).
- Learn: `logic-apps-enterprise-integration-as2` (AS2 v2 params — display names only; no
  JSON-name or output-shape table for the built-in).
- Learn: `logic-apps-enterprise-integration-b2b` — Standard: "X12 built-in connector: No
  connection required", "AS2 (v2) connector: No connection required". Confirmed: **no**
  `connections.json` entries needed for X12/AS2.

## connections.json — a second (masked) bug was fixed
Once the EDI shapes were fixed, health surfaced a previously-masked error:
`The required value for parameter 'connectionString' is missing ... for '/serviceProviders/serviceBus'.`
The built-in **Service Bus** and **SQL** managed-identity connections were malformed:
missing `parameterSetName`, wrong auth key (`authentication` instead of `authProvider`),
and SQL used `server`/`database` instead of `serverName`/`databaseName`.

Corrected shape (verified against multiple real Standard projects incl. the customer's own
`christopherhouse/CustomerServiceLogicApp`):
```json
"serviceBus": {
  "parameterSetName": "ManagedServiceIdentity",
  "parameterValues": {
    "fullyQualifiedNamespace": "@appsetting('serviceBus__fullyQualifiedNamespace')",
    "authProvider": { "Type": "ManagedServiceIdentity" }
  },
  "serviceProvider": { "id": "/serviceProviders/serviceBus" }
},
"sql": {
  "parameterSetName": "ManagedServiceIdentity",
  "parameterValues": {
    "serverName": "@appsetting('sql__serverFqdn')",
    "databaseName": "@appsetting('sql__databaseName')",
    "authProvider": { "Type": "ManagedServiceIdentity" }
  },
  "serviceProvider": { "id": "/serviceProviders/sql" }
}
```
UAMI is selected via the infra "connection-prefix model" app settings
(`serviceBus__credential=managedidentity`, `serviceBus__clientId`, `sql__clientId`).

## Result
Zip-deployed to `logic-jci-purchaser-dev`. Workflow `purchaser-po-to-as2` health =
**Healthy** (`.properties.health.state`). Host `state: Running`, no errors.

## OPEN — needs confirmation at first real run (Step 2)
The AS2 output accessors in `POST_AS2_to_supplier` are **NOT** runtime-verified. Learn does
not document the AS2 **(v2) built-in** output JSON shape; the only authoritative sample is
the **Consumption** AS2 (v2) connector output:
`@base64ToBinary(body('Encode_to_AS2')?['AS2Message']?['Content'])` and
`@body('Encode_to_AS2')?['AS2Message']?['OutboundHeaders']` — **PascalCase**, content is
**base64-encoded**.
The workflow currently uses camelCase and no base64 decode:
`body('Encode_to_AS2')?['as2Message']?['outboundHeaders']` / `?['content']`.
`?['prop']` returns null on a case mismatch (silent, does not fail health), so at the first
real run, confirm the actual `as2Encode` output and, if headers/body come back empty, switch
to `AS2Message`/`OutboundHeaders`/`Content` and wrap content in `base64ToBinary(...)`.
A live run could not be executed here: it requires Service Bus Data Sender on the shared
namespace (`sb-jci-edi-dev-2vjolmqq` in `rg-edi-shared`) plus the full downstream (SQL proc,
IA agreements, certs, supplier endpoint), which is Step-2 scope.

## Side note (not code)
The purchaser app's identity-based `AzureWebJobsStorage` settings had reverted to the broken
set (host `state: Error`). Re-applied the RESUME-documented correct set
(`__credential`+`__credentialType=managedIdentity`, `__managedIdentityResourceId`, blob/queue/
table service URIs) to bring the host up so health could be verified. Still needs persisting
into `infra/compute/logicapp-bundle.bicep` (RESUME "live fixes not yet in code", item 1).

### 2026-07-17T11-38-27: Purchaser epic — IA→Key Vault RBAC identity decision + SQL TVP grant
**By:** Zoe (Security Engineer)
**Requested by:** Christopher-House (via Coordinator)
**Branch:** feature/purchaser-po-to-as2-850-workflow (not merged; main untouched)

**What (3 security deliverables for the purchaser PO→AS2 850 epic):**

1. **IA identity decision — Azure Logic Apps FIRST-PARTY service principal, NOT the IA managed identity.**
   Verified against Microsoft Learn "Add certificates to secure B2B messages in workflows for Azure
   Logic Apps" (https://learn.microsoft.com/azure/logic-apps/logic-apps-enterprise-integration-certificates,
   Prerequisites → "For private certificates"). The doc states: *"To grant access to the Azure Logic Apps
   service principal, use Azure role-based access control to manage access to your key vault,"* and names
   the well-known first-party SP **app ID `7cd684f4-8a78-49b0-91ec-6a35d38739ba`** needing
   **list/get/decrypt/sign** on the vault. This is a tenant-wide first-party SP — it is **NOT** the
   Integration Account's system-assigned managed identity. **Consequence: NO change to the IA resource is
   required** (no `identity: { type: 'SystemAssigned' }`). The IA `properties: {}` in
   `infra/compute/logicapp-bundle.bicep` stays as-is. **No handoff to Kaylee for an IA identity change.**

2. **Role assignments added (least-privilege, scoped to the shared Key Vault in rg-edi-shared):**
   Granted the Logic Apps first-party SP:
   - **Key Vault Crypto User** (`12338af0-0e69-4776-bea7-57ae8d297424`) — covers key get + sign/decrypt.
   - **Key Vault Secrets User** (`4633458b-17de-408a-b874-0445c86b69e6`) — covers list/get on the secret
     backing the cert (matches design §5.5's requested pair).
   Implemented in `infra/rbac/role-assignments.bicep` via the existing `infra/modules/role-assignment.bicep`
   pattern, wired from `infra/main.bicep`. Both modules are guarded `if (!empty(logicAppsServicePrincipalObjectId))`
   so they no-op until the SP object ID is supplied. New param `logicAppsServicePrincipalObjectId` (default `''`)
   added to both `role-assignments.bicep` and `main.bicep`.

3. **SQL TVP grant — REMOVED (2026-07-17T12:24).** The TVP approach was dropped from the design: the
   built-in Logic Apps SQL connector cannot pass a table-valued parameter, so Simon refactored
   `dbo.usp_UpsertPurchaseOrder` to take `@LinesJson NVARCHAR(MAX)` + `OPENJSON` and the
   `dbo.PurchaseOrderLineType` type no longer exists. The `GRANT EXECUTE ON TYPE::...` line (and its
   `TYPE_ID()` guard) has been removed from `infra/sql/create-users-roles.sql`, which is now byte-identical
   to its committed state. **No replacement grant needed:** PurchaserRole's existing
   `GRANT EXECUTE ON SCHEMA::dbo` already covers the refactored proc (which now takes a scalar NVARCHAR(MAX)
   param), and `GRANT SELECT ON SCHEMA::dbo` covers reading the returned result set. No table-level or type
   grant applies.

4. **No gap for the two new KV secrets** — `supplier-as2-endpoint-url` and the IA callback URL secret are
   read by the **purchaser UAMI** via Key Vault reference. Confirmed the purchaser UAMI already holds
   **Key Vault Secrets User** on the shared vault (`purchaserKvSecretsUser` in `role-assignments.bicep`,
   established decision 2026-07-16 "Least-privilege RBAC #14"). **No new grant added — none needed.**

**Why:** Least-privilege, managed-identity/first-party-SP only, no secrets in code, no broad Owner/Contributor.
The IA private-cert→Key Vault-key binding is the single new RBAC edge this epic introduces; using the
Learn-documented first-party SP avoids enabling and RBAC-ordering an IA system identity.

**Validation:** `az bicep build --file infra/main.bicep` → exit 0 (clean; only a Bicep-version upgrade nag).

**Handoffs:**
- **Kaylee (CI / app settings owner):** CI (`deploy.yml`) must resolve the SP object ID at deploy time —
  `az ad sp show --id 7cd684f4-8a78-49b0-91ec-6a35d38739ba --query id -o tsv` — and pass it as the
  `logicAppsServicePrincipalObjectId` parameter to the subscription-scoped deployment. Until supplied, the two
  IA→KV grants are skipped (safe no-op). **No IA resource definition change required from Kaylee.**
- **Simon (schema DDL owner):** TVP approach dropped — proc refactored to `@LinesJson NVARCHAR(MAX)` + `OPENJSON`.
  No SQL grant change is required from Zoe; PurchaserRole's existing schema-level EXECUTE/SELECT grants cover the
  refactored proc.

**References:** `infra/rbac/role-assignments.bicep`, `infra/modules/role-assignment.bicep`, `infra/main.bicep`,
`infra/sql/create-users-roles.sql`, `docs/purchaser-workflow-epic-design.md` §3.2 & §5.5,
Microsoft Learn `logic-apps-enterprise-integration-certificates`, first-party SP app ID
`7cd684f4-8a78-49b0-91ec-6a35d38739ba`.

### 2026-07-16T18-35-56: Key Vault deploy failed on explicit enablePurgeProtection:false; Azure only accepts true or omitted. Fixed via ternary-to-null in keyvault.bicep (PR #2). Never bind a bool straight to enablePurgeProtection.
**By:** Zoe-via-Coordinator
**What:** Key Vault deploy failed on explicit enablePurgeProtection:false; Azure only accepts true or omitted. Fixed via ternary-to-null in keyvault.bicep (PR #2). Never bind a bool straight to enablePurgeProtection.
**References:** infra/shared/keyvault.bicep, PR #2, run 29524193047, Zoe, Kaylee
**Why:** First live deploy (run 29524193047) failed at the Key Vault resource with: BadRequest 'The property enablePurgeProtection cannot be set to false. Enabling the purge protection for a vault is an irreversible action.' Azure Key Vault's ARM API only accepts enablePurgeProtection = true or the property omitted entirely; sending an explicit false is invalid. Fix (PR #2, bugfix/keyvault-purge-protection): infra/shared/keyvault.bicep now emits `enablePurgeProtection: enablePurgeProtection ? true : null` so the dev default (off) omits the property instead of sending false. LEARNING for any future Key Vault Bicep: never bind a bool param straight to enablePurgeProtection — conditionally emit true-or-null. The deployment is idempotent so re-running after merge reconciles the partial first deploy.

### 2026-07-16T17-58-43: OIDC failed because repo uses numeric-ID subject claims; recreated gh-pr/gh-main federated creds with numeric subjects and validate.yml now passes. Deploy-guide OIDC subjects need updating.
**By:** Zoe-via-Coordinator
**What:** OIDC failed because repo uses numeric-ID subject claims; recreated gh-pr/gh-main federated creds with numeric subjects and validate.yml now passes. Deploy-guide OIDC subjects need updating.
**References:** docs/deployment-guide.md, .github/workflows/validate.yml, app 923efbd9-17d1-468c-bc7c-5828856848c6, Zoe, Book
**Why:** The validate.yml OIDC login failed with AADSTS700213 (no matching federated identity). Root cause: this repo presents the GitHub *immutable numeric-ID* OIDC subject claim format, not the human-readable form. Actual presented subject: repo:christopherhouse@748998/Azure-Logic-Apps-X12-AS2-Demo@1302864534:pull_request (format repo:{ownerLogin}@{ownerId}/{repoName}@{repoId}:{claim}). The federated credentials were originally created with the human-readable subject (repo:christopherhouse/Azure-Logic-Apps-X12-AS2-Demo:pull_request) and did not match. Fix: recreated both federated credentials on app 923efbd9-17d1-468c-bc7c-5828856848c6 (gh-pr, gh-main) using the numeric-ID subjects (pull_request and ref:refs/heads/main). Numeric IDs are immutable (survive repo/owner rename), so this is the more robust form. Validate.yml re-run succeeded. FOLLOW-UP: docs/deployment-guide.md OIDC section still shows the human-readable federated-credential subjects and must be updated to the numeric-ID format.

# Jayne E2E round-trip prep

- Date: 2026-07-20T10:52:00-05:00
- Requested by: chhouse_microsoft (Christopher House)
- Subscription checked: `8bd05b2f-62c5-4def-9869-f0617ebb3970` (`ME-MngEnvMCAP064264-chhouse-2`, user `chhouse@microsoft.com`)

## Supplier health

Result: **NOT READY**.

Evidence:
- Supplier app resource `logic-jci-supplier-dev` in `rg-edi-supplier` reports `state=Running` from `az webapp show`.
- Hostruntime status API `.../hostruntime/admin/host/status?api-version=2022-03-01` reports `state=Error`, version `4.851.100.26305`.
- Hostruntime error: `Microsoft.Azure.Workflows.Data.Edge: The authentication credential type for the storage account isn't valid. To authenticate with a user-assigned identity, check that the 'AzureWebJobsStorage__credentialType' app setting is set to 'managedIdentity' and that the 'AzureWebJobsStorage__managedIdentityResourceId' app setting is set to a valid managed identity resource ID.`
- Workflow management list API failed with `BadRequest` / `ServiceUnavailable` from host runtime.
- Specific workflow health query for repo workflow name `supplier-inbound-ack` also failed with `BadRequest` / `ServiceUnavailable`.

Blunt verdict: the Azure site is started, but the Logic Apps host is not healthy enough to list/query workflows. Do not claim supplier receive health is green.

## Staged payload

- Path: `samples/purchase-order-e2e-test.json`
- `poNumber`: `PO-E2E-07201052`
- Payload: fake Contoso/Fabrikam test data, two line items, non-sensitive.
- Validation: `samples/purchase-order-e2e-test.json` validated **VALID (0 errors)** against the embedded `Parse_Purchase_Order` schema in `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json`.
- Existing `samples/purchase-order.sample.json` also validates, but its `poNumber` is not unique enough for this live run.

## Prepared send command — DO NOT RUN until RBAC go-ahead

AAD token + Service Bus REST data-plane send; no connection string. This sends raw JSON as the Service Bus message body. The built-in Service Bus trigger is expected to expose that message to the workflow under `triggerBody()?['contentData']`; if the run proves `contentData` is base64 rather than JSON text, the workflow parse action will be the failure point and the evidence routes to Wash.

```powershell
$payload = 'C:\Projects\AzLogicAppsAS2X12Demo\samples\purchase-order-e2e-test.json'
$token = az account get-access-token --resource 'https://servicebus.azure.net' --query accessToken -o tsv
curl.exe --fail-with-body -i -X POST 'https://sb-jci-edi-dev-2vjolmqq.servicebus.windows.net/purchase-orders.received/messages?timeout=60' `
  -H "Authorization: Bearer $token" `
  -H 'Content-Type: application/json' `
  -H 'BrokerProperties: {"MessageId":"PO-E2E-07201052","CorrelationId":"PO-E2E-07201052","Label":"JayneE2E"}' `
  --data-binary "@$payload"
```

## Stop point

Prep is complete. I did **not** publish the message. Current blocker is supplier hostruntime `state=Error`; publishing after RBAC propagation would still be a bad E2E signal until supplier host health is fixed or explicitly accepted as the expected failure under test.

## Round-trip execution after GO

- Publish time: 2026-07-20T11:34:14-05:00 approx (`2026-07-20T16:34:14Z`).
- Publish result: Service Bus REST data-plane send returned **HTTP/1.1 201 Created**.
- Message identity: `MessageId=PO-E2E-07201052`, `CorrelationId=PO-E2E-07201052`, label `JayneE2E`.

## Purchaser run verdict

Result: **FAILED before SQL/X12/AS2. No round trip occurred.**

Primary run:
- Workflow: `purchaser-po-to-as2`
- Run id: `08584170416309744319506129303CU00`
- Start: `2026-07-20T16:34:15.0619554Z`
- End: `2026-07-20T16:34:16.7409506Z`
- Status/code: `Failed` / `ActionFailed`

The trigger delivered the correct payload to `Parse_Purchase_Order`; action inputs show `purchaseOrder.poNumber = PO-E2E-07201052` and the JSON object was not base64 text. So publishing raw JSON through Service Bus REST was correct for this trigger shape.

Per-action status from the purchaser run:

| Action | Status | Code / evidence |
|---|---:|---|
| `Parse_Purchase_Order` | **Failed** | `ActionSchemaNotSupported`: `The 'schema' property of action 'ParseJson' inputs contains 'pattern' or 'patternProperties' properties. 'Pattern' or 'patternProperties' properties are not supported in the action json schema.` |
| `Persist_Purchase_Order` | Skipped | `Parse_Purchase_Order` failed |
| `Compose_Canonical_Xml` | Skipped | `Persist_Purchase_Order` skipped |
| `Transform_to_X12_850_Xml` | Skipped | upstream skipped |
| `Encode_to_X12_850` | Skipped | `Transform_to_X12_850_Xml` skipped |
| `Encode_to_AS2` | Skipped | `Encode_to_X12_850` skipped |
| `POST_AS2_to_supplier` | Skipped | `Encode_to_AS2` skipped |
| `Complete_Message` | Skipped | `Process_Purchase_Order` failed |
| `Dead_Letter_Message` | **Failed** | Service provider returned `BadRequest` / `VNetPrivatePortsNotConfigured`: `Using this service provider action in stateful workflows requires VNet integration and the site configuration vnetPrivatePortsCount to be set to a value greater than or equal to 2.` |

Observed retries after the first failure:
- `08584170415711167679946486528CU00` at `2026-07-20T16:35:14Z` — Failed with same `ParseJson` schema failure.
- `08584170415111495997669364739CU00` at `2026-07-20T16:36:14Z` — Failed with same pattern.

## AS2 output shape check

No actual AS2 output shape could be captured in this run because `Encode_to_AS2` was **Skipped** and had no `outputsLink`. The suspected camelCase/PascalCase accessor bug is still untested. Evidence is clean: the run never reached `Encode_to_X12_850`, `Encode_to_AS2`, or `POST_AS2_to_supplier`.

## Supplier side

Supplier host check after GO:
- `hostruntime/admin/host/status`: `state=Running`, `errors=null`.

Supplier workflow runs:
- `supplier-inbound-ack` run list after the purchaser failure: `[]`.
- Verdict: supplier did **not** receive an AS2 POST, because purchaser never reached `POST_AS2_to_supplier`.

## Settlement result

Service Bus subscription `purchase-orders.received` / `all-messages` after observation:
- `activeMessageCount = 1`
- `deadLetterMessageCount = 0`
- `transferDeadLetterMessageCount = 0`

Settlement verdict: **NOT Completed, NOT dead-lettered**. The message remains active and is being retried because `Complete_Message` was skipped and `Dead_Letter_Message` itself failed.

## Blunt routing

This is not an AS2 supplier problem and not a Service Bus publish/RBAC problem. The first blocker is the purchaser workflow's `ParseJson` schema: Logic Apps Standard rejects `pattern` / `patternProperties` in Parse JSON schemas at runtime. Secondary blocker: explicit Service Bus dead-letter settlement fails in a stateful workflow due missing VNet private ports configuration. AS2 output accessor validation remains pending until the ParseJson blocker is fixed.

# 2026-07-20T12:50:04.837-05:00 — IA schema registration and VNet private-ports settlement check

**By:** Kaylee (Infra / DevOps Engineer)  
**Requested by:** Christopher House  
**Scope:** Live Azure investigation/remediation for IA schema registration and purchaser settlement actions. No Bicep edits.

## Course correction

Christopher corrected the VNet-private-ports direction at `2026-07-20T13:01:05.925-05:00`:

- These Logic Apps have **no VNet integration** (`virtualNetworkSubnetId = null`).
- Therefore `vnetPrivatePortsCount` is irrelevant for the current topology.
- The earlier `vnetPrivatePortsCount = 2` live change was a wrong lead and must not be persisted to Bicep.

I reverted `siteConfig.vnetPrivatePortsCount` to `0` on both:

- `logic-jci-purchaser-dev`
- `logic-jci-supplier-dev`

## BUG E — X12 schema registration

### Initial finding

Checked live Integration Account `ia-jci-purchaser-dev` in `rg-edi-purchaser`.

Contrary to the initial hypothesis, schema `X12_00603_850` was already present before this task:

- `schemaType = Xml`
- `documentName = X12_00603_850`
- `targetNamespace = http://schemas.microsoft.com/BizTalk/EDI/X12/2006`
- `contentLink.contentSize = 2253560`
- existing `changedTime = 2026-07-20T15:20:14.7560612Z`

### Action taken

Re-ran the same out-of-band mechanism used by `.github/workflows/deploy.yml`:

1. Uploaded `infra/integration-account/schemas/X12_00603_850.xsd` to purchaser storage container `ia-artifacts`.
2. Generated a short-lived read SAS.
3. PUT the schema resource via Logic REST API with `properties.contentLink.uri`.

Post-register evidence:

- schema `X12_00603_850` still present
- `targetNamespace = http://schemas.microsoft.com/BizTalk/EDI/X12/2006`
- `contentLink.contentSize = 2253560`
- `changedTime = 2026-07-20T17:51:27.6110484Z`

Then redeployed `infra/integration-account/ia-content.bicep` live so agreements were written after the schema was refreshed. Deployment `ia-content` succeeded at `2026-07-20T17:55:53Z`.

Agreement `Purchaser-Supplier-X12` still references the schema:

- send schema ref: `messageId = 850`, `schemaVersion = 00603`, `schemaName = X12_00603_850`, `senderApplicationId = PURCHASER01`
- receive schema ref: `messageId = 850`, `schemaVersion = 00603`, `schemaName = X12_00603_850`, `senderApplicationId = SUPPLIER01`

Restarted the purchaser app after IA/schema updates to clear any runtime IA metadata cache.

### Verification result

New run `08584170365484091288995815187CU00`:

- `Parse_Purchase_Order`: `Succeeded / OK`
- `Persist_Purchase_Order`: `Succeeded / OK`
- `Transform_to_X12_850_Xml`: `Succeeded / OK`
- `Encode_to_X12_850`: `Failed / X12MessageEncodingFailed`

Error remains:

`EdiMatchingSchemaNotFound`: no matching schema references found in agreement `Purchaser-Supplier-X12` with message Id `850`, schema version `00603`, and target namespace `http://schemas.microsoft.com/BizTalk/EDI/X12/2006`.

Additional verification through the IA callback URL (`WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL`) also lists the schema as visible to the runtime:

- `name = X12_00603_850`
- `documentName = X12_00603_850`
- `targetNamespace = http://schemas.microsoft.com/BizTalk/EDI/X12/2006`
- `contentLink.contentSize = 2253560`

After the latest schema visibility check, a new run `08584170362069495964781720613CU00` still failed at `Encode_to_X12_850` with the same `EdiMatchingSchemaNotFound` error. This confirms the blocker is not absence of the IA schema artifact. The next investigation should focus on X12 Encode input shape or agreement/schema matching semantics.

## BUG F — Service Bus settlement corrected investigation

### State checked

Purchaser `logic-jci-purchaser-dev` currently reports after revert:

- `siteConfig.vnetPrivatePortsCount = 0`
- `virtualNetworkSubnetId = null`
- hostruntime `state = Running`
- workflow `purchaser-po-to-as2` health `Healthy`

Supplier `logic-jci-supplier-dev` also reports:

- `siteConfig.vnetPrivatePortsCount = 0`
- `virtualNetworkSubnetId = null`
- hostruntime `state = Running`

### Extension bundle state

Repo and live `host.json` match for both apps:

```json
"extensionBundle": {
  "id": "Microsoft.Azure.Functions.ExtensionBundle.Workflows",
  "version": "[1.*, 2.0.0)"
}
```

Both apps have this `host.json` deployed at the app root. Runtime resolved:

- purchaser: `Microsoft.Azure.Functions.ExtensionBundle.Workflows` version `1.170.37`
- supplier: `Microsoft.Azure.Functions.ExtensionBundle.Workflows` version `1.170.42`

There are no `AzureFunctionsJobHost__extensionBundle__*` app-setting overrides on either app.

### Verification result

The failure path still fails at `Dead_Letter_Message`, but the VNet-private-ports remediation is now recorded as the wrong fix for this topology:

`VNetPrivatePortsNotConfigured`: using this service provider action in stateful workflows requires **VNet integration** and `siteConfig.vnetPrivatePortsCount >= 2`.

Microsoft Learn grounding did not identify a minimum Workflows extension bundle version for Service Bus `completeMessage` / `deadLetterMessage`, and the loaded bundle is present and in the configured range. The stronger evidence is the current Service Bus built-in connector reference: for topic subscriptions, the current settlement operation IDs are `completeTopicMessageV2` and `deadLetterTopicMessageV2`, with required `topicName`, `subscriptionName`, and `lockToken` parameters. The workflow currently uses older/generic operation IDs `completeMessage` and `deadLetterMessage` with only `lockToken`.

Best hypothesis: settlement is not a host/bundle deployment problem; it is a workflow action shape/operationId problem. The current operation IDs appear to route to the stateful-affinity path that emits the misleading VNet-private-ports error in a non-VNet app. The likely workflow fix is to switch settlement to the documented topic-subscription V2 operations:

- `completeTopicMessageV2`
- `deadLetterTopicMessageV2`
- include `topicName = purchase-orders.received`
- include `subscriptionName = all-messages`
- keep `lockToken = @triggerBody()?['lockToken']`

This should be routed to Wash because it is a workflow definition change.

## Reproducibility notes

- Schema registration is already covered by `.github/workflows/deploy.yml` in the step `Post-Deploy - Register X12 schema via REST contentLink (>2 MB)`.
- The subsequent IA content deployment is also covered by `.github/workflows/deploy.yml`.
- No Bicep edit is needed for the large schema because the REST `contentLink` path is intentional.
- Do **not** persist `vnetPrivatePortsCount = 2`; it was reverted to `0` and is not applicable without VNet integration.

## Reference-app comparison update — 2026-07-20T10:58:00-05:00

Christopher provided working reference Logic App Standard app:

`/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970/resourceGroups/RG-CLARIOS-AIS/providers/Microsoft.Web/sites/la-clarios-ais`

Key confirmed differences versus `logic-jci-purchaser-dev`:

- Reference has **no VNet** and `siteConfig.vnetPrivatePortsCount = 0`, confirming private ports are not required for this topology.
- Reference has identity type `SystemAssigned, UserAssigned`; purchaser originally had only `UserAssigned`.
- Reference Service Bus `connections.json` uses:
  - `parameterSetName = ManagedServiceIdentity`
  - `fullyQualifiedNamespace = @appsetting('serviceBus_fullyQualifiedNamespace')`
  - `authProvider.Type = ManagedServiceIdentity`
  - no explicit `authProvider.Identity`
- Reference `host.json` includes the same Workflows extension bundle range plus:
  - `Runtime.ApplicationInsightTelemetryVersion = v2`
  - `Runtime.ApplicationInsights.PreserveIncomingOperationId = true`
- Reference workflow uses topic-subscription V2 Service Bus operations:
  - trigger `peekLockTopicMessagesV2`
  - settlement `completeTopicMessageV2`
  - failure handling uses topic V2 settlement (`abandonTopicMessageV2` in reference; purchaser uses `deadLetterTopicMessageV2`)
  - parameters include `topicName`, `subscriptionName`, and `lockToken`.

Applied live/repo changes on branch `bugfix/edi-e2e-live-fixes`:

- Added purchaser runtime settings to match reference where applicable:
  - `AzureFunctionsJobHost__extensionBundle__id = Microsoft.Azure.Functions.ExtensionBundle.Workflows`
  - `AzureFunctionsJobHost__extensionBundle__version = [1.*, 2.0.0)`
  - `FUNCTIONS_INPROC_NET8_ENABLED = 1`
  - `WEBSITE_NODE_DEFAULT_VERSION = ~20`
  - siteConfig `.NET v8.0`, 64-bit worker
- Added single-underscore Service Bus app setting:
  - `serviceBus_fullyQualifiedNamespace = sb-jci-edi-dev-2vjolmqq.servicebus.windows.net`
- Enabled purchaser system-assigned managed identity and granted it `Azure Service Bus Data Receiver` on namespace `sb-jci-edi-dev-2vjolmqq`.
- Changed `logicapps/purchaser/connections.json` Service Bus block to match the reference system-assigned MI shape (`authProvider.Type` only).
- Changed purchaser workflow Service Bus operations to the topic V2 operation IDs and parameters.
- Matched reference trigger metadata and host telemetry setting.

Relevant commits now on `bugfix/edi-e2e-live-fixes`:

- `4a9b32e` — use Service Bus topic V2 settlement
- `29d7c31` — align Service Bus FQN setting with V2 connector
- `ad5d1b0` — use system identity for Service Bus
- `311bab3` — match reference Service Bus trigger metadata

Verification:

- Purchaser hostruntime is `Running`; workflow `purchaser-po-to-as2` is `Healthy`.
- Live `connections.json` at app root matches the final reference-aligned shape.
- Earlier V2 runs advanced past the original misleading `VNetPrivatePortsNotConfigured` and then exposed the true identity selection problem (`Unable to load the proper Managed Identity`), which is why the system-assigned identity/reference shape was applied.
- After the system-assigned identity/reference-shape deploy, the Service Bus trigger has not yet picked up new active subscription messages during the verification window (`activeMessageCount = 2`, `deadLetterMessageCount = 10`). No new workflow run was created after `18:26:50Z`; App Insights showed no new trigger/listener errors after the latest deploy. This may be RBAC/host listener propagation after identity changes, but it is not yet proven GREEN.

Current status:

- **Bug E remains BLOCKED**: `X12_00603_850` is registered and visible; agreement references are correct; latest verified runs still fail `Encode_to_X12_850` with `EdiMatchingSchemaNotFound`. The schema-registration hypothesis is disproven.
- **Bug F is partially remediated but not yet GREEN**: VNet/private-ports was incorrect and reverted; reference-app diff points to topic V2 operations plus system-assigned MI. Those changes are applied, but a fresh settlement run has not yet been observed after the final deploy.

## Stabilization correction — 2026-07-20T14:13:08.276-05:00

Christopher approved rolling back the speculative Service Bus V2/identity rewiring. I restored `logicapps/` to known-good commit `32efe61` and committed:

- `0d98c41` — `revert speculative SB V2/identity rewiring to known-good 32efe61`

I redeployed `logicapps/purchaser` from that restored known-good state. Purchaser host is `Running`; workflow `purchaser-po-to-as2` is `Healthy`. The trigger is working again: fresh runs appeared after publishing PO messages.

Live rollback notes:

- Removed the Service Bus Data Receiver role assignment that I had granted to the system-assigned principal.
- Removed reference-mimic settings:
  - `AzureFunctionsJobHost__extensionBundle__id`
  - `AzureFunctionsJobHost__extensionBundle__version`
  - `FUNCTIONS_INPROC_NET8_ENABLED`
  - `serviceBus_fullyQualifiedNamespace`
  - `serviceBus__managedIdentityResourceId`
- Restored:
  - `WEBSITE_NODE_DEFAULT_VERSION = ~22`
  - `siteConfig.netFrameworkVersion = v4.0`
  - `siteConfig.use32BitWorkerProcess = true`
- Left the corrected identity-based `AzureWebJobsStorage__*` settings intact.
- Azure did not accept removing the system-assigned identity cleanly; the current system-assigned principal has no Service Bus Data Receiver assignment. The restored known-good `connections.json` and trigger are working.

Applied Simon's real Bug E fix in `infra/integration-account/ia-content.bicep`: removed `senderApplicationId: 'PURCHASER01'` from the X12 **sendAgreement** `schemaReferences` only. Committed:

- `0b6d93e` — `fix(ia): relax X12 send schema matching`

Redeployed IA content live. Verified send agreement schema reference is now only:

```json
[
  {
    "messageId": "850",
    "schemaName": "X12_00603_850",
    "schemaVersion": "00603"
  }
]
```

Verification run `08584170312716986831403343499CU00`:

- `Parse_Purchase_Order`: `Succeeded / OK`
- `Persist_Purchase_Order`: `Succeeded / OK`
- `Compose_Canonical_Xml`: `Succeeded / OK`
- `Transform_to_X12_850_Xml`: `Succeeded / OK`
- `Encode_to_X12_850`: `Succeeded / OK` — Bug E fixed.
- `Encode_to_AS2`: `Succeeded / OK`
- `POST_AS2_to_supplier`: `Failed / BadRequest` before HTTP send because `@appsetting('SupplierAs2Endpoint__url')` resolved null even though the Key Vault reference status is `Resolved`.
- Settlement remains out of scope and still fails on the failure path.

Real `Encode_to_AS2` output shape from the run:

- top-level `body`
- `body.messageContent`
  - `$content-type = application/pkcs7-mime; smime-type=enveloped-data; name="smime.p7m"`
  - `$content = <base64 PKCS7 payload>`
- `body.messageHeaders`
  - `Content-Type`
  - `AS2-From`
  - `AS2-To`
  - `AS2-Version`
  - `Message-ID`
  - `EDIINT-Features`
  - `Disposition-Notification-To`
  - `Disposition-Notification-Options`
  - `Content-Transfer-Encoding`
  - `Mime-Version`
- `body.messageId`
- `body.agreementName`
- `body.senderPartnerName`
- `body.receiverPartnerName`
- `body.micHash`
- `body.isMessageCompressed`
- `body.isMessageEncrypted`
- `body.isMessageSigned`
- `body.isMdnExpected`
- `body.mdnType`

The existing `POST_AS2_to_supplier` accessors (`as2Message.outboundHeaders` / `as2Message.content`) do not match this real shape; that is now the next workflow accessor issue after Bug E.

## Supplier endpoint URL stabilization — 2026-07-20T14:32:58.592-05:00

Bounded check/fix for `SupplierAs2Endpoint__url` after run `08584170312716986831403343499CU00` reported a null URI.

Findings:

- Purchaser app setting `SupplierAs2Endpoint__url` is present:
  - `@Microsoft.KeyVault(SecretUri=https://kv-jci-edi-dev-2vjolmqq.vault.azure.net/secrets/supplier-as2-endpoint-url)`
- App Service Key Vault reference status is `Resolved` using `identityType = UserAssigned`.
- Purchaser UAMI `id-jci-purchaser-dev` has `Key Vault Secrets User` at resource group scope `/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970/resourcegroups/rg-edi-shared`.
- Key Vault secret `supplier-as2-endpoint-url` value exactly matches the live supplier workflow callback URL returned from:
  - `logic-jci-supplier-dev`
  - workflow `supplier-inbound-ack`
  - trigger `manual`

Action:

- Re-set `SupplierAs2Endpoint__url` to the Key Vault reference for `supplier-as2-endpoint-url`.
- Refreshed App Service Key Vault references through the configreferences refresh API.

Post-refresh evidence:

- `SupplierAs2Endpoint__url` remains present as the Key Vault reference.
- Config reference status remains `Resolved`.
- Secret value/current callback URL:
  - `https://logic-jci-supplier-dev.azurewebsites.net:443/api/supplier-inbound-ack/triggers/manual/invoke?api-version=2022-05-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=iHUMi7SX-p2oYAQGEgXPjvpxWsSRxoosQmIF7e7BZCc`

Conclusion:

- The setting was not missing, clobbered, stale, or blocked by Key Vault RBAC.
- It is now refreshed and confirmed resolved to the current supplier trigger URL.

# 2026-07-20T12:08:28.826-05:00 — Purchaser built-in SQL managed-identity connection fix

**By:** Kaylee (Infra / DevOps Engineer)  
**Requested by:** Christopher House  
**Scope:** Purchaser Logic App Standard built-in SQL connection, live verification, and repo persistence for the app artifact.

## Root cause

`Persist_Purchase_Order` failed with:

`ServiceOperationFailed: Value cannot be null. (Parameter 'Data Source')`

The SQL built-in service-provider connection used the correct `ManagedServiceIdentity` parameter set names, but `serverName` and `databaseName` were supplied as `@appsetting(...)` expressions:

- `serverName: @appsetting('sql__serverFqdn')`
- `databaseName: @appsetting('sql__databaseName')`

In the live SQL operation-group manifest, the SQL `ManagedServiceIdentity` connection parameters `serverName`, `databaseName`, `managedIdentityType`, and `managedIdentityClientId` have `parameterSource = NotSpecified`; only the connection-string auth parameter set uses `parameterSource = AppConfiguration`. By contrast, the Service Bus built-in `fullyQualifiedNamespace` has `parameterSource = AppConfiguration`, which is why the Service Bus `@appsetting(...)` pattern works here but SQL's server/database values resolved to null at runtime.

## Correct SQL MI binding shape verified

For this Workflows extension bundle, the SQL built-in managed-identity connection must provide concrete SQL connection parameters in `connections.json`:

```json
"sql": {
  "parameterSetName": "ManagedServiceIdentity",
  "parameterValues": {
    "serverName": "sql-jci-edi-dev-2vjolmqq.database.windows.net",
    "databaseName": "sqldb-jci-edi-dev",
    "managedIdentityType": "UserAssigned",
    "managedIdentityClientId": "8a2d2355-ec3a-421f-ab1d-50ea89f15f83",
    "authProvider": {
      "Type": "ManagedServiceIdentity"
    }
  },
  "serviceProvider": {
    "id": "/serviceProviders/sql"
  },
  "displayName": "SQL Database (Managed Identity)"
}
```

No `sql__credential` app setting was required for the verified fix.

## What changed

### Repo

Updated `logicapps/purchaser/connections.json` to use the concrete SQL server, database, purchaser UAMI type, and purchaser UAMI clientId in the SQL built-in connection.

### Live Azure

Zip-deployed the updated `logicapps/purchaser` artifact to:

- app: `logic-jci-purchaser-dev`
- resource group: `rg-edi-purchaser`
- subscription: `8bd05b2f-62c5-4def-9869-f0617ebb3970`

Then restarted the app. Workflow health returned `Healthy`.

Live `connections.json` confirmed the SQL parameter values as concrete strings, not `@appsetting(...)` expressions.

## Verification evidence

Sent `samples/purchase-order-e2e-test.json` (`poNumber = PO-E2E-07201052`) to Service Bus topic `purchase-orders.received`.

Verification run:

- workflow: `purchaser-po-to-as2`
- run id: `08584170385302676265325227100CU00`
- `Parse_Purchase_Order`: `Succeeded`
- `Persist_Purchase_Order`: `Succeeded`, `code = OK`, start `2026-07-20T17:25:57.5023664Z`, end `2026-07-20T17:25:59.6702113Z`

This proves the purchaser UAMI can connect to the live SQL DB and execute `dbo.usp_UpsertPurchaseOrder`. A direct `sqlcmd -G` metadata query was blocked by MFA for the interactive operator identity, but the managed-identity workflow execution is the authoritative runtime access check.

## Follow-up / non-SQL observations

The same verification run advanced past SQL and then failed later at `Transform_to_X12_850_Xml`:

`Required property 'content' expects a value but got null.`

Therefore no `Encode_to_AS2` output shape was captured in this task.

The failure path then attempted `Dead_Letter_Message`, which still returned `VNetPrivatePortsNotConfigured` with the message that stateful service-provider actions require both VNet integration and `vnetPrivatePortsCount >= 2`. `vnetPrivatePortsCount` is already `2`, but the apps currently have no regional VNet integration configured.

## Persistence note

Because this fix is in the app artifact, it is persisted by committing `logicapps/purchaser/connections.json`. If future IaC/content generation reintroduces SQL app-setting indirection for `serverName`/`databaseName`, CI can re-break the SQL connection. The VNet private-ports setting remains a separate infra persistence item for `infra/compute/logicapp-bundle.bicep`.

# 2026-07-20T10:58:00-05:00 — Supplier Logic App identity storage live fix

**By:** Kaylee (Infra / DevOps Engineer)  
**Requested by:** Christopher House  
**Scope:** Live Azure fix only; no Bicep edits and no commit.

## What changed live

Confirmed Azure subscription `8bd05b2f-62c5-4def-9869-f0617ebb3970`, then corrected `logic-jci-supplier-dev` in `rg-edi-supplier` to use the same identity-based `AzureWebJobsStorage` shape Wash verified on the purchaser app:

- `AzureWebJobsStorage__credential = managedIdentity`
- `AzureWebJobsStorage__credentialType = managedIdentity`
- `AzureWebJobsStorage__managedIdentityResourceId = /subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970/resourcegroups/rg-edi-supplier/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-jci-supplier-dev`
- `AzureWebJobsStorage__blobServiceUri = https://stjcisupplierdev2vjolmqq.blob.core.windows.net`
- `AzureWebJobsStorage__queueServiceUri = https://stjcisupplierdev2vjolmqq.queue.core.windows.net`
- `AzureWebJobsStorage__tableServiceUri = https://stjcisupplierdev2vjolmqq.table.core.windows.net`
- `AzureFunctionsJobHost__telemetryMode = OpenTelemetry`

Removed the broken keys:

- `AzureWebJobsStorage__accountName`
- `AzureWebJobsStorage__clientId`

No plain `AzureWebJobsStorage` key was present in the inspected relevant setting set.

## RBAC observed

Supplier UAMI `id-jci-supplier-dev`:

- clientId: `2df2da89-2f4d-419c-856d-57eec412054f`
- principalId: `8c7dd97e-0be0-4e91-b2dd-e6129b6e325b`

Inherited at `rg-edi-supplier` and effective for storage account `stjcisupplierdev2vjolmqq`:

- `Storage Blob Data Owner`
- `Storage Queue Data Contributor`
- `Storage Table Data Contributor`
- `Storage Account Contributor`

The required blob + queue data-plane grants were already present; no RBAC changes were made.

## Verification

Restarted `logic-jci-supplier-dev`.

Final hostruntime status:

- host `state = Running`
- no host errors returned
- runtime extension bundle reported by host: `Microsoft.Azure.Functions.ExtensionBundle.Workflows` version `1.170.42`

Workflow management list returned:

- `supplier-inbound-ack`
- `health.state = Healthy`
- `isDisabled = false`
- `kind = Stateful`

## Follow-up required

These live settings still need persisting into `infra/compute/logicapp-bundle.bicep` for **both** purchaser and supplier apps. If Bicep/CI redeploys before that step, it can revert the app settings back to the broken shape.

## Extension bundle app-setting check

Per follow-up request, checked both Logic Apps for app settings named `AzureFunctionsJobHost__extensionBundle__version` and `AzureFunctionsJobHost__extensionBundle__id`. Neither setting is currently present on either app:

- `logic-jci-supplier-dev`: no `AzureFunctionsJobHost__extensionBundle__version`; no `AzureFunctionsJobHost__extensionBundle__id`; host remains `Running`.
- `logic-jci-purchaser-dev`: no `AzureFunctionsJobHost__extensionBundle__version`; no `AzureFunctionsJobHost__extensionBundle__id`; host `Running`.

Observed runtime bundle from host status:

- supplier: `Microsoft.Azure.Functions.ExtensionBundle.Workflows` version `1.170.42`
- purchaser: `Microsoft.Azure.Functions.ExtensionBundle.Workflows` version `1.170.37`

# 2026-07-20T12:05:07.752-05:00 — SUPERSEDED / incorrect VNet private ports lead

> **SUPERSEDED at 2026-07-20T13:01:05.925-05:00 by repo owner direction.**
>
> These apps have no VNet integration (`virtualNetworkSubnetId = null`), so `vnetPrivatePortsCount`
> is irrelevant for the current topology. The live setting was reverted to `0` on both purchaser and
> supplier. Do **not** persist this setting into Bicep.

**By:** Kaylee (Infra / DevOps Engineer)  
**Requested by:** Christopher House  
**Scope:** Live Azure apply only; no Bicep edits and no commit.

## What changed live

Applied `siteConfig.vnetPrivatePortsCount = 2` to both Logic App Standard resources:

- `logic-jci-purchaser-dev` in `rg-edi-purchaser`
- `logic-jci-supplier-dev` in `rg-edi-supplier`

Implementation used the Microsoft.Web site `config/web` resource:

`/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970/resourceGroups/<rg>/providers/Microsoft.Web/sites/<app>/config/web`

Both apps were restarted after the siteConfig update.

## Verification

Before apply:

- purchaser `vnetPrivatePortsCount = 0`
- supplier `vnetPrivatePortsCount = 0`

After apply:

- purchaser `az functionapp show --query siteConfig.vnetPrivatePortsCount` returned `2`
- supplier `az functionapp show --query siteConfig.vnetPrivatePortsCount` returned `2`
- purchaser hostruntime returned `state = Running`, no errors
- supplier hostruntime returned `state = Running`, no errors

## Why

The purchaser workflow run `08584170416309744319506129303CU00` hit `VNetPrivatePortsNotConfigured` in the built-in Service Bus settlement action `Dead_Letter_Message`. Microsoft Learn documents that Logic Apps Standard built-in service-provider connectors such as Service Bus require VNet private ports for stateful connector operations, with `vnetPrivatePortsCount = 2` as the remediation.

## Follow-up required

This live setting must be persisted into `infra/compute/logicapp-bundle.bicep` under the Logic App `siteConfig` for both apps. If CI redeploys before that persistence step, it can revert `vnetPrivatePortsCount` back to `0` and reintroduce `VNetPrivatePortsNotConfigured`.

# Simon X12 Agreement Matching Diagnosis — Bug E

**Recorded:** 2026-07-20T13:50:05.350-05:00  
**Agent:** Simon — EDI Analyst  
**Scope:** Read-only diagnosis; no commit and no deploy.

## Live failure inspected

Latest failed purchaser run inspected:

- Workflow: `purchaser-po-to-as2`
- Run: `08584170348745851267969702332CU00`
- Failed action: `Encode_to_X12_850`
- Code: `X12MessageEncodingFailed`

Exact action error:

```text
An error occurred while encoding the X12 message. Error code: 'EdiMatchingSchemaNotFound'. Error description: 'No matching schema references found in the agreement 'Purchaser-Supplier-X12' with message Id '850', schema version '00603' and target namespace 'http://schemas.microsoft.com/BizTalk/EDI/X12/2006'.'
```

`Transform_to_X12_850_Xml` succeeded in that run. `Encode_to_X12_850` input was the transformed X12 XML content plus agreement name `Purchaser-Supplier-X12`.

## Live agreement inspected

Integration Account:

```text
rg-edi-purchaser / ia-jci-purchaser-dev
```

Agreements listed:

```text
Purchaser-Supplier-AS2
Purchaser-Supplier-X12
```

Live X12 agreement identity fields:

```text
hostPartner: Purchaser
hostIdentity: ZZ / PURCHASER01
guestPartner: Supplier
guestIdentity: ZZ / SUPPLIER01
```

Live send agreement identities:

```text
senderBusinessIdentity:   ZZ / PURCHASER01
receiverBusinessIdentity: ZZ / SUPPLIER01
```

These align with the workflow's outbound purchaser→supplier path and the action's explicit agreement name.

Live send envelope fields:

```text
controlVersionNumber: 00603
senderApplicationId:  PURCHASER01
receiverApplicationId: SUPPLIER01
groupHeaderAgencyCode: X
groupHeaderVersion: 006030
functionalGroupId: PO
usageIndicator: Test
```

Live send schema reference:

```json
{
  "messageId": "850",
  "schemaName": "X12_00603_850",
  "schemaVersion": "00603",
  "senderApplicationId": "PURCHASER01"
}
```

Live receive schema reference mirrors the inbound supplier→purchaser direction:

```json
{
  "messageId": "850",
  "schemaName": "X12_00603_850",
  "schemaVersion": "00603",
  "senderApplicationId": "SUPPLIER01"
}
```

## Schema and transform-output match matrix

Registered IA schema metadata:

```text
name: X12_00603_850
schemaType: Xml
targetNamespace: http://schemas.microsoft.com/BizTalk/EDI/X12/2006
contentSize: 2253560
documentName: X12_00603_850
```

Live schema content header confirms:

```xml
<xs:schema targetNamespace="http://schemas.microsoft.com/BizTalk/EDI/X12/2006" ...>
  ...
  <b:schemaInfo document_type="850" standards_version="00603" root_reference="X12_00603_850" ... />
  ...
  <xs:element name="X12_00603_850">
```

Repo schema confirms the same in `infra/integration-account/schemas/X12_00603_850.xsd`.

Transform output root passed to X12 Encode:

```xml
<x12:X12_00603_850 xmlns:x12="http://schemas.microsoft.com/BizTalk/EDI/X12/2006">
```

Therefore these keys match correctly:

| Key | Transform output | IA schema | Agreement schemaReference | Verdict |
|---|---|---|---|---|
| messageId / document type | `850` from root/schema | `document_type="850"` | `messageId: "850"` | Match |
| schema version | `00603` from root/schema | `standards_version="00603"` | `schemaVersion: "00603"` | Match |
| target namespace | `http://schemas.microsoft.com/BizTalk/EDI/X12/2006` | same | resolved through schema `X12_00603_850` | Match |
| root/schemaName | `X12_00603_850` | root + documentName `X12_00603_850` | `schemaName: "X12_00603_850"` | Match |

## Version-string conclusion

The version strings are not the bug.

For the Microsoft BizTalk/Logic Apps X12 006030 schema, the actual schema metadata is:

```text
standards_version="00603"
root_reference="X12_00603_850"
```

Microsoft Learn's X12 message settings distinguish:

- send schema `Version` / agreement `schemaVersion`: X12 schema version used for ST01 schema selection;
- `Control Version Number (ISA12)`: X12 standard version;
- `GS8`: schema document/group header version.

For this schema, the correct values are:

```text
schemaReferences[].schemaVersion = 00603
controlVersionNumber (ISA12)     = 00603
groupHeaderVersion (GS08)        = 006030
```

Do not change `schemaVersion` to `006030`; that would diverge from the registered schema's `standards_version="00603"` and the runtime error's own extracted schema version `00603`.

## Root cause

The outbound **send** `schemaReferences` row includes a receive-side discriminator:

```json
"senderApplicationId": "PURCHASER01"
```

Microsoft Learn's X12 message settings define the receive-side schema row as selected by `Version`, `Transaction Type (ST01)`, and `Sender Application (GS02)`, but the send-side schema row as selected by only `Version`, `Transaction Type (ST01)`, and `Schema`. In other words: `senderApplicationId` is appropriate for the receive agreement schema row, but it should not be present in the send agreement schema row.

With `senderApplicationId` present in the outbound send schema reference, the encoder fails to match the otherwise-present schema reference for the XML transaction set. The error reports the matching keys it extracted — message `850`, schema version `00603`, namespace `http://schemas.microsoft.com/BizTalk/EDI/X12/2006` — and those all exist. The extra send-side `senderApplicationId` is the mismatching discriminator.

This is agreement content, not transform output. The transform root/namespace are correct.

## Precise fix and owner

**Owner: Kaylee** — IA agreement config in `infra/integration-account/ia-content.bicep`, then redeploy IA content.

Change the **sendAgreement** schema reference from:

```bicep
schemaReferences: [
  {
    messageId: '850'
    senderApplicationId: 'PURCHASER01'
    schemaVersion: '00603'
    schemaName: schemaName
  }
]
```

to:

```bicep
schemaReferences: [
  {
    messageId: '850'
    schemaVersion: '00603'
    schemaName: schemaName // X12_00603_850
  }
]
```

Keep the **receiveAgreement** row as-is for the reverse inbound direction:

```bicep
schemaReferences: [
  {
    messageId: '850'
    senderApplicationId: 'SUPPLIER01'
    schemaVersion: '00603'
    schemaName: schemaName
  }
]
```

Keep these envelope/version values:

```bicep
controlVersionNumber: '00603' // ISA12
groupHeaderVersion: '006030'  // GS08
schemaVersion: '00603'        // schemaReferences version matching b:schemaInfo standards_version
senderApplicationId: 'PURCHASER01'   // GS02 envelope, not schemaReference discriminator
receiverApplicationId: 'SUPPLIER01'  // GS03 envelope
functionalGroupId: 'PO'              // GS01 for 850 purchase order
```

No change is recommended to the XSLT root or namespace.

## Assumptions / limits

- Partner-specific 850 implementation-guide requirements beyond the demo agreement were not provided; I did not invent additional schema/envelope overrides.
- This diagnosis is based on the live agreement, live registered schema metadata/content header, live run inputs, repo schema, and Microsoft Learn's receive-vs-send schema selection semantics.

# Simon X12 Transform Diagnosis — purchaser-po-to-as2

**Recorded:** 2026-07-20T13:05:00-05:00  
**Agent:** Simon — EDI Analyst  
**Scope:** Read-only diagnosis; no commit and no deploy.

## Azure account / run inspected

`az account show` is on the expected subscription:

- Subscription: `8bd05b2f-62c5-4def-9869-f0617ebb3970`
- Name: `ME-MngEnvMCAP064264-chhouse-2`
- User: `chhouse@microsoft.com`

Recent purchaser runs listed from the workflow management API were all failed. The latest returned run was:

- Workflow: `purchaser-po-to-as2`
- Run: `08584170379904803891596701504CU00`
- Start/end: `2026-07-20T17:34:55Z`
- Overall status: `Failed`

Known run `08584170385302676265325227100CU00` also appeared failed at `2026-07-20T17:25:56Z`.

## Exact failed action error

Action: `Transform_to_X12_850_Xml`  
Status: `Failed`  
Code: `BadRequest`  
Error code: `InvalidTemplate`

Exact message from the action record:

```text
Unable to process template language expressions in action 'Transform_to_X12_850_Xml' inputs at line '0' and column '0': 'Required property 'content' expects a value but got null. Path ''.'.
```

Neighboring action status in the same latest run:

- `Parse_Purchase_Order`: `Succeeded`
- `Persist_Purchase_Order`: `Succeeded`
- `Compose_Canonical_Xml`: `Succeeded`
- `Transform_to_X12_850_Xml`: `Failed`
- `Encode_to_X12_850`: `Skipped`

## Map and schema inspection

Map path found:

```text
logicapps/purchaser/Artifacts/Maps/PO_Canonical_to_X12_850_006030.xslt
```

Canonical schema found:

```text
logicapps/purchaser/Artifacts/Schemas/PurchaseOrder_Canonical.xsd
```

X12 target schema found:

```text
infra/integration-account/schemas/X12_00603_850.xsd
```

Packaging check: the map is inside the purchaser Logic App deployment root (`logicapps/purchaser/Artifacts/Maps`). `.github/workflows/deploy.yml` packages the purchaser app with:

```bash
( cd logicapps/purchaser && zip -r ../../purchaser-app.zip . -x '*.git*' 1>/dev/null )
az functionapp deployment source config-zip -g "$RG" -n "$APP" --src purchaser-app.zip 1>/dev/null
```

There is no `.funcignore` in the repo. Therefore this map should ship in the app zip with the workflow.

The XSLT expects no-namespace canonical XML rooted at `<purchaseOrder>` with repeated `<lines>` elements. That matches `PurchaseOrder_Canonical.xsd` and the intended `xml()` output shape.

I ran the existing local harness:

```text
pwsh -File samples/transform-and-validate.ps1
```

Result:

```text
ALL PASS — canonical valid, transform ran, 850 output validates against 006030 schema.
```

This proves the checked-in map can transform the repo sample and the result validates against `X12_00603_850.xsd`.

## Root cause

This is not an XSLT map-content failure and not a map-not-found failure. The runtime did not get as far as loading or executing the map. It failed while evaluating the Transform XML action input because `inputs.content` evaluated to null.

Current workflow wiring:

```json
"Compose_Canonical_Xml": {
  "type": "Compose",
  "inputs": "@xml(body('Parse_Purchase_Order'))"
},
"Transform_to_X12_850_Xml": {
  "type": "Xslt",
  "inputs": {
    "content": "@body('Compose_Canonical_Xml')",
    "map": {
      "source": "LogicApp",
      "name": "PO_Canonical_to_X12_850_006030.xslt"
    }
  }
}
```

For a Compose action, the value is the action output itself. `body('Compose_Canonical_Xml')` resolves as null here, which exactly matches the observed runtime error. The Transform XML action should consume `outputs('Compose_Canonical_Xml')`, not `body('Compose_Canonical_Xml')`.

## Proposed exact fix and owner

**Owner: Wash** — workflow action wiring, not Simon map content.

Change only the Transform action content expression:

```diff
 "Transform_to_X12_850_Xml": {
   "type": "Xslt",
   "inputs": {
-    "content": "@body('Compose_Canonical_Xml')",
+    "content": "@outputs('Compose_Canonical_Xml')",
     "map": {
       "source": "LogicApp",
       "name": "PO_Canonical_to_X12_850_006030.xslt"
     }
   }
 }
```

No XSLT correction is proposed for this failure. After Wash applies the wiring fix, the map should execute. If the next live run then fails in `Transform_to_X12_850_Xml` with an actual XSLT/schema error, Simon should re-open map diagnosis with the new error.

## Expected X12 850 XML for Jayne validation

For sample PO `PO-E2E-07201052` from `samples/purchase-order-e2e-test.json`, the map produces this X12 850 XML before X12 Encode serializes it to flat EDI:

```xml
<?xml version="1.0" encoding="utf-8"?>
<x12:X12_00603_850 xmlns:x12="http://schemas.microsoft.com/BizTalk/EDI/X12/2006">
  <ST>
    <ST01>850</ST01>
    <ST02>0001</ST02>
  </ST>
  <x12:BEG>
    <BEG01>00</BEG01>
    <BEG02>NE</BEG02>
    <BEG03>PO-E2E-07201052</BEG03>
    <BEG05>20260720</BEG05>
  </x12:BEG>
  <x12:REF>
    <REF01>CO</REF01>
    <REF02>PURCHASER01</REF02>
  </x12:REF>
  <x12:DTM>
    <DTM01>002</DTM01>
    <DTM02>20260803</DTM02>
  </x12:DTM>
  <x12:N1Loop1>
    <x12:N1>
      <N101>ST</N101>
      <N102>Contoso Test Dock</N102>
    </x12:N1>
    <x12:N3>
      <N301>100 Test Dock Rd</N301>
    </x12:N3>
    <x12:N4>
      <N401>Tacoma</N401>
      <N402>WA</N402>
      <N403>98402</N403>
      <N404>US</N404>
    </x12:N4>
  </x12:N1Loop1>
  <x12:N1Loop1>
    <x12:N1>
      <N101>BT</N101>
      <N102>Contoso AP Test</N102>
    </x12:N1>
    <x12:N3>
      <N301>1 Contoso Plaza</N301>
      <N302>Suite 400</N302>
    </x12:N3>
    <x12:N4>
      <N401>Redmond</N401>
      <N402>WA</N402>
      <N403>98052</N403>
      <N404>US</N404>
    </x12:N4>
  </x12:N1Loop1>
  <x12:PO1Loop1>
    <x12:PO1>
      <PO101>1</PO101>
      <PO102>2</PO102>
      <PO103>EA</PO103>
      <PO104>10.5</PO104>
      <PO106>BP</PO106>
      <PO107>QA-850-001</PO107>
    </x12:PO1>
    <x12:PIDLoop1>
      <x12:PID_2>
        <PID01>F</PID01>
        <PID05>QA widget</PID05>
      </x12:PID_2>
    </x12:PIDLoop1>
  </x12:PO1Loop1>
  <x12:PO1Loop1>
    <x12:PO1>
      <PO101>2</PO101>
      <PO102>5</PO102>
      <PO103>EA</PO103>
      <PO104>3.25</PO104>
      <PO106>BP</PO106>
      <PO107>QA-850-002</PO107>
    </x12:PO1>
    <x12:PIDLoop1>
      <x12:PID_2>
        <PID01>F</PID01>
        <PID05>QA bracket</PID05>
      </x12:PID_2>
    </x12:PIDLoop1>
  </x12:PO1Loop1>
  <x12:CTTLoop1>
    <x12:CTT>
      <CTT01>2</CTT01>
      <CTT02>7</CTT02>
    </x12:CTT>
  </x12:CTTLoop1>
  <SE>
    <SE01>1</SE01>
    <SE02>0001</SE02>
  </SE>
</x12:X12_00603_850>
```

Assumption flagged: partner-specific 850 requirements beyond the locked demo mapping (for example extra REF/CUR/FOB/SAC terms) are not specified. I did not invent them.

# Decision: AS2 Encode output accessors + KV uri app-setting fix (POST_AS2_to_supplier)

- **Author:** Wash (Logic Apps / EDI Developer)
- **Date:** 2026-07-20T10:17:06-05:00
- **Branch/commit:** `bugfix/edi-e2e-live-fixes` @ `8483a66`
- **File:** `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json` (`POST_AS2_to_supplier`)
- **Status:** VERIFIED LIVE — closes the long-open "AS2 output shape" Hard-won-pitfall.

## The verified AS2 v2 (Standard built-in) Encode output shape

Captured from live run `08584170312716986831403343499CU00` and reconfirmed on the
green run `08584170296825929605950043344CU00`:

- `body('Encode_to_AS2')?['messageContent']` → a **binary envelope object**
  `{ "$content-type": "...", "$content": "<base64>" }`.
- `body('Encode_to_AS2')?['messageHeaders']` → the AS2 outbound headers object
  (AS2-From/AS2-To, Message-Id, MIME/Content-Type, MIC, etc.).

This is the Standard **built-in AS2 (v2)** shape and DIFFERS from Consumption/managed
AS2, which uses PascalCase `['AS2Message']?['Content']` / `['OutboundHeaders']`.
The workflow previously (wrongly) read `['as2Message']?['content']` /
`['as2Message']?['outboundHeaders']` → both resolved null.

## Correct expressions applied

```jsonc
"method": "POST",
"uri":     "@appsetting('SupplierAs2EndpointUrl')",
"headers": "@body('Encode_to_AS2')?['messageHeaders']",
"body":    "@base64ToBinary(body('Encode_to_AS2')?['messageContent']?['$content'])"
```

- **body:** decode the base64 `$content` to raw MIME bytes with `base64ToBinary(...)`.
  `messageHeaders` supplies the correct Content-Type, so we send the raw AS2 MIME body
  rather than re-wrapping the binary envelope (avoids a Content-Type conflict).
- Grounding: Microsoft Learn AS2 send pattern uses `base64ToBinary` on the encoded
  content; confirmed against the captured live output shape.

## Gotcha that also blocked this: `__` in a Key Vault-reference app-setting name

**Root cause of the null `uri`:** the app setting `SupplierAs2Endpoint__url` is a Key Vault
reference. Even though `config/configreferences/appsettings` reported
`status: "Resolved"` (UserAssigned identity, `keyVaultReferenceIdentity` correctly set to
UAMI `id-jci-purchaser-dev`), `@appsetting('SupplierAs2Endpoint__url')` still resolved
**null** at workflow runtime → `InvalidTemplate: Required property 'uri' ... got null`.

The **double underscore `__`** (nested-config separator) breaks `@appsetting()` Key Vault
reference resolution in Logic Apps Standard. Proof by contrast on the SAME app / identity /
vault: `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` (a KV reference with NO `__`) resolves
fine and the Integration Account encode actions succeed.

**Fix:** added a clean-named KV-reference app setting `SupplierAs2EndpointUrl` (same secret
`supplier-as2-endpoint-url`, still in Key Vault — no secret exposed) and pointed the
workflow `uri` at it. After an app restart the reference injected and `uri` resolved.

Grounding: Microsoft Learn "Use Key Vault references as app settings" +
"Edit app & host settings for Standard Logic Apps"; corroborated by community reports that
`__`-named settings + KV references fail to resolve via `appsetting()`.

## connections.json

No change needed. Built-in AS2/X12/SQL/Service Bus service-provider connectors do not use a
`connectionName`/`connections.json` entry for this action.

## Live verification (evidence)

- Workflow `purchaser-po-to-as2` health = **Healthy** after redeploy + restart.
- Run `08584170296825929605950043344CU00`: Parse → Persist → Compose → Transform →
  Encode_to_X12_850 → Encode_to_AS2 → **POST_AS2_to_supplier: Succeeded (statusCode 200)**.
- POST response body: `"AS2 message received."`; response headers show
  `x-ms-workflow-name: supplier-inbound-ack`, `x-ms-workflow-run-id:
  08584170296763384358060012589CU00` → **supplier-inbound-ack fired on receipt**.
- Supplier run `...012589CU00` action: `Return_200_OK: Succeeded`. NOTE: the supplier
  `supplier-inbound-ack` workflow is currently a **minimal stub** that only returns 200 — it
  does NOT yet AS2-decode / X12-decode. That decode build is a separate supplier task.

## ACTION REQUIRED — infra drift for Kaylee (Bicep persistence)

To unblock the live 200 I added a **live** app setting NOT yet in IaC:

- `SupplierAs2EndpointUrl = @Microsoft.KeyVault(SecretUri=https://kv-jci-edi-dev-2vjolmqq.vault.azure.net/secrets/supplier-as2-endpoint-url)`

The committed `workflow.json` now references `@appsetting('SupplierAs2EndpointUrl')`. **Bicep
must add this clean-named KV-reference app setting** (and can retire the `__` variant
`SupplierAs2Endpoint__url`), or a fresh-from-Bicep deploy will regress the `uri` to null.
Recommend renaming any other `__`-style KV-reference settings that are read via
`@appsetting()` for the same reason.

## Remaining (not mine)

- `Complete_Message` (SB settlement) still fails `BadRequest` — the deferred
  `VNetPrivatePortsNotConfigured` infra issue (Kaylee).
- Supplier-side AS2/X12 decode build (supplier team) — currently a 200 stub.

# Decision / Question: Parse JSON schema — regex `pattern` removed (validation gap)

- **Author:** Wash (Logic Apps / EDI Developer)
- **Date:** 2026-07-20T11:39:43-05:00
- **Branch:** `bugfix/x12-as2-encode-serviceprovider-shape`
- **For review by:** Mal (coordinator), Simon (design owner)
- **Trigger:** Jayne's live round-trip run failed at `Parse_Purchase_Order` with
  `ActionSchemaNotSupported`.

## What happened
The `Parse_Purchase_Order` (ParseJson / Data Operations) action embeds the canonical PO
JSON Schema (design 2.2) to validate the payload and route invalid POs to dead-letter. That
schema used JSON-Schema `pattern` (regex) constraints, which the Logic Apps **Parse JSON**
action does not support — it raised `ActionSchemaNotSupported`, failing Parse and Skipping
everything downstream (X12 Encode, AS2 Encode, POST).

## Ground truth — Parse JSON supported vs unsupported keywords
The Logic Apps Parse JSON action validates with a restricted JSON-Schema engine.

- **Unsupported (throw `ActionSchemaNotSupported`):** `pattern`, `patternProperties`.
- **Accepted but NOT enforced (ignored, safe to keep as annotation):** `format`
  (e.g. `format: date`) — does not error, but performs no validation.
- **Supported / enforced:** `type`, `properties`, `required`, `items`, `enum`,
  `minimum`/`maximum`, `exclusiveMinimum`/`exclusiveMaximum`, `minLength`/`maxLength`,
  `minItems`, `additionalProperties`, `$ref`/`$defs`.

**Sources:**
- Turbo360 (Logic Apps integration vendor), "Specifying JSON Schema restrictions in Logic
  Apps" — explicitly lists `pattern`/`patternProperties` as unsupported and `format` as
  ignored.
- Learn: `logic-apps-perform-data-operations#parse-json-action` (Parse JSON overview).
- The live runtime error `ActionSchemaNotSupported` with the regex patterns present.
- NOTE: the Learn search also surfaced a "`$jsonSchema` Supported Keywords" table that lists
  `additionalProperties` as "not implemented" — that page is **DocumentDB/Cosmos DB**
  (`learn.microsoft.com/documentdb/query/operators/evaluation-query/$jsonschema`), NOT Logic
  Apps. It was deliberately ignored so we do not over-strip `additionalProperties` (which
  Logic Apps Parse JSON does accept).

## What I changed (minimal / surgical)
Removed only the 3 unsupported `pattern` constraints; the schema had no `patternProperties`
and no other reject-list keyword. To preserve as much validation as possible I replaced each
regex with its length equivalent:

| Field    | Was                | Now                              | Lost |
| -------- | ------------------ | -------------------------------- | ---- |
| currency | `pattern ^[A-Z]{3}$` | `minLength: 3, maxLength: 3`     | "must be uppercase A–Z" |
| state    | `pattern ^[A-Z]{2}$` | `minLength: 2, maxLength: 2`     | "must be uppercase A–Z" |
| country  | `pattern ^[A-Z]{2}$` | `minLength: 2, maxLength: 2`     | "must be uppercase A–Z" |

Everything else (type, required, additionalProperties, minLength/maxLength, minItems,
minimum/exclusiveMinimum, `format: date`, `$ref`/`$defs`) is unchanged — all supported.

## DESIGN IMPACT — needs a decision (do not treat as silently resolved)
The length swap keeps the field-length checks but **loses the character-class validation**:
a `currency` of `"12x"`, or a `state`/`country` of `"7!"` or lowercase `"ca"`, now passes
Parse JSON where the regex would have rejected it and dead-lettered the PO (design 2.2 intent:
validate + dead-letter invalid payloads).

**Options for Mal/Simon to choose:**
- **(a) Accept as a demo limitation** — length-only validation is sufficient for the demo;
  document the reduced strictness. (Lowest effort.)
- **(b) Re-implement the regex checks as explicit workflow logic** — after Parse, add a
  Condition/`@if` (or a small inline-code/Function step) that validates
  `currency`/`state`/`country` against `^[A-Z]{n}$` and routes failures to the existing
  dead-letter path, restoring full design-2.2 validation.

I did **not** pick one — surfacing for the design owner. Recommendation if strict EDI
conformance matters downstream (X12 element data types): option (b), since X12 currency
(C001/CUR) and geographic codes are constrained sets.

## Downstream discovery (NOT part of this fix) — `Persist_Purchase_Order` SQL fails
With the Parse fix in place, the resubmitted run advanced past Parse and exposed a
**separate, pre-existing bug** at `Persist_Purchase_Order` (built-in SQL, execute stored
procedure). The SQL connection had never been runtime-exercised before (the workflow was
Unhealthy / never ran end-to-end), so this was latent. Error, on every retry:

```
ServiceProviderActionFailed / ServiceOperationFailed:
'Value cannot be null. (Parameter 'Data Source')'
```

`Data Source` (the SQL server) resolves to null even though app setting
`sql__serverFqdn = sql-jci-edi-dev-2vjolmqq.database.windows.net` exists and
`connections.json` maps `serverName: @appsetting('sql__serverFqdn')`.

**Authoritative SQL built-in MI connection param set** (from the live runtime manifest
`GET .../operationGroups/sql?api-version=2018-11-01`, param set `ManagedServiceIdentity`):
| Param | propertyPath | Required |
| ----- | ------------ | -------- |
| `serverName` | (top-level) | yes |
| `databaseName` | (top-level) | yes |
| `managedIdentityType` | (top-level) | allowedValues SystemAssigned/UserAssigned |
| `managedIdentityClientId` | (top-level) | **yes when managedIdentityType=UserAssigned** |
| `Type` | `authProvider` | yes (default `ManagedServiceIdentity`) |
| `Identity` | `authProvider` | no |

The committed `connections.json` (prior task) omitted `managedIdentityClientId` /
`managedIdentityType` — which are required because the purchaser app has ONLY a
user-assigned identity. I trialled the manifest-correct shape live (added
`managedIdentityType: "UserAssigned"` + `managedIdentityClientId: @appsetting('sql__clientId')`,
kept `serverName`/`databaseName`/`authProvider.Type`) and redeployed **plus a full app
restart** to defeat connection caching — but `Persist` STILL failed with the identical
`Data Source null`. So the manifest-correct parameterValues shape alone does **not** fix it,
and I reverted that speculative change to keep this commit to the verified Parse fix only.

**Working theory (needs a dedicated SQL work item, likely infra/Kaylee):** the app is
configured for the **connection-prefix model** (Service Bus works via
`serviceBus__fullyQualifiedNamespace` + `serviceBus__credential=managedidentity` +
`serviceBus__clientId`). SQL only has `sql__serverFqdn` / `sql__databaseName` /
`sql__clientId` — there is **no `sql__credential`** app setting, and the SQL server is not
resolving via connections.json either. Someone should determine whether the SQL built-in
here is meant to bind via connections.json parameterValues OR via `sql__*` prefix app
settings (and which exact keys the SQL provider reads for Data Source), then fix + verify
with a real run. This is **out of scope** for the Parse JSON fix and was NOT introduced by
it — Parse succeeding merely surfaced it.

Note: the live app currently still has the trialled `connections.json` (with
`managedIdentityClientId`) deployed; the repo is reverted to the prior shape. The next SQL
work item should redeploy from repo after applying the real fix.


## Result
Parse JSON schema now contains no unsupported keywords. Redeployed to
`logic-jci-purchaser-dev`; workflow health = **Healthy**. `Parse_Purchase_Order` verified
**Succeeded** on 3 real runs after the fix (auto-redelivered run
`08584170410665042449208557878CU00` and resubmitted runs
`08584170404434655264864222551CU00`, `08584170401768094350723233756CU00`) — previously it
failed with `ActionSchemaNotSupported` before the flow could proceed.

# Decision: Compose→Xslt wiring fix + AS2 output shape investigation

- **Author:** Wash (Logic Apps / EDI Developer)
- **Date:** 2026-07-20T12:40:27-05:00
- **Branch:** `bugfix/edi-e2e-live-fixes` (Kaylee's consolidated branch)
- **Closes (partial):** Hard-won-pitfall "Compose result is read via `outputs()`, not `body()`".
- **Still open:** the AS2 built-in output-shape verification (blocked downstream — see below).

## Bug D (fixed) — Transform read the Compose result with the wrong accessor
`Transform_to_X12_850_Xml` (Xslt) failed with:
`InvalidTemplate: Required property 'content' expects a value but got null`.

Root cause: a **Compose** action exposes its result via `outputs()`, not `body()`. The
transform's `inputs.content` used `@body('Compose_Canonical_Xml')`, which resolves to null.

**Fix:** `inputs.content` → `@outputs('Compose_Canonical_Xml')`. (Verified there is no other
`body('Compose_...')` misreference in the workflow.) The XSLT map itself was correct and
ships fine.

**Ground truth:** In Logic Apps, `Compose` (Data Operations) returns its value on `outputs`,
whereas connector/action bodies are read with `body()`. Confirmed empirically: after the fix
the transform Succeeded on a live run.

## Result (live evidence, run `08584170374573083889549931097CU00`)
After redeploying `logicapps/purchaser` + restart, workflow health = **Healthy** and the run
advanced much further than before:

| Action | Status |
| ------ | ------ |
| Parse_Purchase_Order | Succeeded |
| Persist_Purchase_Order | **Succeeded** (SQL MI now works — merged connections.json uses literal serverName/databaseName + managedIdentityType=UserAssigned + managedIdentityClientId) |
| Compose_Canonical_Xml | Succeeded |
| Transform_to_X12_850_Xml | **Succeeded** ← this fix |
| Encode_to_X12_850 | **Failed** — new blocker (IA config, see below) |
| Encode_to_AS2 | Skipped |
| POST_AS2_to_supplier | Skipped |
| Complete_Message | Skipped |
| Dead_Letter_Message | Failed (VNet — Kaylee) |

## NEW blocker (NOT this fix, NOT workflow wiring) — X12 Encode `EdiMatchingSchemaNotFound`
`Encode_to_X12_850` failed with:
```
X12MessageEncodingFailed / EdiMatchingSchemaNotFound:
'No matching schema references found in the agreement 'Purchaser-Supplier-X12' with
 message Id '850', schema version '00603' and target namespace
 'http://schemas.microsoft.com/BizTalk/EDI/X12/2006'.'
```
The transform output is **correct** — its root element is
`<x12:X12_00603_850 xmlns:x12="http://schemas.microsoft.com/BizTalk/EDI/X12/2006">`
(BizTalk/Logic Apps names X12 release 006030 as `00603`, matching the map
`PO_Canonical_to_X12_850_006030.xslt`). The X12 built-in Encode correctly derived
`(850, 00603, .../X12/2006)` from that root.

The failure is that the **Integration Account** agreement `Purchaser-Supplier-X12` has no
schema reference matching that root — i.e., either the 850 006030 schema is not deployed to
the IA, its root/namespace differs, or the agreement's send settings don't map the 850 to
the schema. **This is Integration Account schema/agreement configuration (Kaylee/infra +
Simon/schemas), not workflow wiring.** Owner action: ensure the IA has the 850 006030 schema
whose root element is `X12_00603_850` (namespace `http://schemas.microsoft.com/BizTalk/EDI/X12/2006`)
and that the `Purchaser-Supplier-X12` agreement's send settings reference it.

## STILL OPEN — real AS2 output shape could NOT be captured
Capturing the actual `Encode_to_AS2` output JSON (to verify/fix the accessors in
`POST_AS2_to_supplier`) requires the flow to reach AS2 Encode, which is now blocked by the
X12 IA issue above. `Encode_to_AS2` was Skipped, so there is **no run evidence** yet.

Therefore I did **not** change `POST_AS2_to_supplier`; it still reads
`body('Encode_to_AS2')?['as2Message']?['outboundHeaders']` and `?['content']`. Per the only
authoritative Learn sample (Consumption AS2 v2), the shape is likely PascalCase
`?['AS2Message']?['OutboundHeaders']` / `?['AS2Message']?['Content']` with **base64-encoded**
content (needs `base64ToBinary`). Since the task requires grounding this against real run
evidence (not a guess), it must be confirmed once the X12 IA blocker is resolved and AS2
Encode actually runs. **This remains the single open Hard-won-pitfall item.**

## Settlement / VNet (for Kaylee — capture only, not my fix)
`Dead_Letter_Message` (serviceBus `deadLetterMessage`) still failed:
```
ServiceProviderActionFailed / VNetPrivatePortsNotConfigured:
'Using this service provider action in stateful workflows requires VNet integration and the
 site configuration vnetPrivatePortsCount to be set to a value greater than or equal to 2.'
```
Kaylee reportedly set `vnetPrivatePortsCount=2`, but this run still shows the requirement —
the setting has not taken effect at runtime (may need the value re-applied + a full
restart/scale operation, or the VNet integration itself is not attached). Supplier POST HTTP
status: N/A (POST was Skipped because X12 Encode failed).

## Files changed
- `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json` — one line:
  `Transform_to_X12_850_Xml.inputs.content` `body(...)` → `outputs(...)`.

# 2026-07-20T10:52:00-05:00: Service Bus RBAC for purchaser E2E test

**By:** Zoe

**What:** Added the minimum Service Bus data-plane RBAC needed to run the dev end-to-end purchase-order test against topic `purchase-orders.received` in namespace `sb-jci-edi-dev-2vjolmqq` (`rg-edi-shared`, subscription `8bd05b2f-62c5-4def-9869-f0617ebb3970`).

- Purchaser workflow UAMI `id-jci-purchaser-dev` principalId `452730cd-6c5e-40e4-93b2-7b421a9ab4ce` now has **Azure Service Bus Data Receiver** at scope `/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970/resourceGroups/rg-edi-shared/providers/Microsoft.ServiceBus/namespaces/sb-jci-edi-dev-2vjolmqq/topics/purchase-orders.received`.
- Active CLI test publisher `chhouse@microsoft.com` principalId `2ede4c0c-360b-47f8-80b0-bdba8badea7b` now has **Azure Service Bus Data Sender** at scope `/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970/resourceGroups/rg-edi-shared/providers/Microsoft.ServiceBus/namespaces/sb-jci-edi-dev-2vjolmqq/topics/purchase-orders.received`.

**Why:** The purchaser workflow uses a peek-lock topic trigger and must listen, complete, and dead-letter messages, so it requires receiver rights, not sender rights. The active CLI principal needs sender rights only to publish a PO for the dev E2E test. The Sender grant is explicit dev-test enablement and must not be treated as production design; in prod, the real trading-system publisher identity should receive a similarly narrow topic-scoped sender grant.

**IaC status:** These two topic-scoped assignments were applied out-of-band with `az role assignment create` and are not currently expressed in Bicep. `infra/rbac/role-assignments.bicep` currently expresses namespace-scoped purchaser sender and supplier receiver assignments, so Kaylee should fold the purchaser receiver assignment and any desired dev-test publisher assignment model into Bicep/runbook without broadening scope.

**Propagation:** Azure RBAC propagation can take 1-5+ minutes after assignment creation before Service Bus data-plane operations succeed.


# 2026-07-20T14:12:00-05:00 — Persist live-only EDI fixes into Bicep (Step 3)

**By:** Kaylee (Infra / DevOps Engineer)
**Requested by:** Christopher House
**Branch:** `bugfix/edi-e2e-live-fixes` (no merge)
**Scope:** Encode the live-only fixes from the E2E round-trip into IaC/CI so a CI redeploy cannot revert them.

## What is now persisted in IaC

### 1. Identity-based `AzureWebJobsStorage` (BOTH apps) — `infra/compute/logicapp-bundle.bicep`
`baseAppSettings` now emits the correct identity-based set for every app:
- `AzureWebJobsStorage__credential = managedIdentity` (was lowercase `managedidentity`)
- `AzureWebJobsStorage__credentialType = managedIdentity` (was missing — Workflows Data.Edge requires it)
- `AzureWebJobsStorage__managedIdentityResourceId = <that app's UAMI resourceId>` (`uamiId` param; was missing)
- `AzureWebJobsStorage__blobServiceUri` / `__queueServiceUri` / `__tableServiceUri` = `https://<sa>.<svc>.core.windows.net` (were missing)
- REMOVED / no longer emitted: `AzureWebJobsStorage__accountName`, `AzureWebJobsStorage__clientId`, plain `AzureWebJobsStorage`.

Verified against live (`az functionapp config appsettings list`): the emitted names+values match both
`logic-jci-purchaser-dev` and `logic-jci-supplier-dev` exactly.

### 2. Clean `SupplierAs2EndpointUrl` app setting (purchaser) — `logicapp-bundle.bicep`
`supplierEndpointAppSettings` now emits `SupplierAs2EndpointUrl` (no double underscore) as the Key Vault
reference to secret `supplier-as2-endpoint-url`. The `__` variant `SupplierAs2Endpoint__url` is no longer
emitted (the `__` made the host treat it as a nested path so `@appsetting('SupplierAs2EndpointUrl')` resolved
null — the real POST blocker). The workflow already reads `@appsetting('SupplierAs2EndpointUrl')`
(`logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json:199`). On the next Bicep deploy the stale
live `SupplierAs2Endpoint__url` key is dropped (inline appSettings are a full replace) — intended retirement.

### 3. Supplier telemetry consistency
`AzureFunctionsJobHost__telemetryMode = OpenTelemetry` is emitted for BOTH apps: `enableOpenTelemetry`
defaults to `true`, purchaser passes `true` explicitly, supplier inherits the default. Matches live on both.
No code change was required — confirmed consistent.

### 4. IA `senderApplicationId` removal — `infra/integration-account/ia-content.bicep` (commit 0b6d93e)
Confirmed (verify-only, no duplicate edit): the X12 **sendAgreement** `schemaReferences` row (lines ~324-329)
has NO `senderApplicationId`. The remaining `senderApplicationId` occurrences are legitimate: envelope GS02
values (`PURCHASER01`/`SUPPLIER01`) and the **receiveAgreement** schemaReference discriminator (`SUPPLIER01`),
both of which must stay.

### 6. RBAC — `infra/rbac/role-assignments.bicep` + `infra/main.bicep`
- **Purchaser UAMI → Azure Service Bus Data Receiver on topic `purchase-orders.received`** — ADDED
  (`purchaserServiceBusTopicReceiver`, scoped to the topic resource id, new `serviceBusTopicId` param wired
  from `main.bicep` as `${namespaceId}/topics/${topicName}`). This is the durable grant that made the live
  trigger read messages. Verified live: the purchaser UAMI holds Data Receiver on that exact topic scope.
- Purchaser UAMI → Key Vault Secrets User: already present (`purchaserKvSecretsUser`). Confirmed live.
- Supplier UAMI → Storage Blob Data Owner + Storage Queue Data Contributor: already present. Confirmed.
- The pre-existing purchaser Data **Sender** (`purchaserServiceBusSender`) was left in place (it is also
  present live); it is not used by the consume-only purchaser but removing it was out of scope and would be
  destructive drift.

### 8. Purchaser identity = UAMI-only — `logicapp-bundle.bicep` (already correct)
Bicep declares `identity.type = 'UserAssigned'` only. The what-if confirms the redeploy removes the stray
live system-assigned identity (`identity.type` before `SystemAssigned, UserAssigned` → after `UserAssigned`).

## What stays OUT of Bicep (by design / documented)

- **CI schema registration (item 5)** — `X12_00603_850.xsd` (2.15 MB) is registered out-of-band via REST
  `contentLink`. Confirmed `.github/workflows/deploy.yml` step *"Post-Deploy - Register X12 schema via REST
  contentLink (>2 MB)"* (§8-C) uploads the xsd to blob, generates a read SAS, and PUTs the schema BEFORE the
  IA-content deploy. CI reproduces this on a fresh deploy — **no gap, no change needed.**
- **`vnetPrivatePortsCount` (item 7)** — deliberately NOT set anywhere in Bicep (grep-confirmed clean). It was
  a wrong lead (no VNet integration) and was reverted live to `0`.
- **CLI publisher Data Sender** (`chhouse@microsoft.com` → topic) — TEST-ONLY dev step, not baked into Bicep.
  A real trading system publishes in prod. → runbook (Book).
- **Deploy-SP Key Vault Certificate User + Secrets Officer (data-plane)** — applied out-of-band like the OIDC
  setup; kept out of IaC. → runbook (Book).
- **Live stray system-assigned identity on the purchaser** — IaC is UAMI-only; the live system MI may need a
  one-time manual cleanup (or it is removed by the next `main.bicep` deploy, per what-if).

## Validation

- **Build:** `az bicep build --file infra\main.bicep`, `...\compute\logicapp-bundle.bicep`,
  `...\rbac\role-assignments.bicep` — all exit 0 (generated `.json` artifacts removed).
- **What-if:** `az deployment sub what-if --location centralus --template-file infra\main.bicep` (against the
  live RGs). Role assignments show as `Unsupported` (the repo's `guid()`-of-`reference()` RBAC pattern is not
  evaluable by what-if — expected). What-if does not diff `Microsoft.Web/sites` appSettings, so those were
  reconciled directly against `az functionapp config appsettings list`:
  - **Supplier:** emitted set == live set exactly (zero delta).
  - **Purchaser:** emitted set == live set exactly, EXCEPT the intended retirement of `SupplierAs2Endpoint__url`
    (dropped on redeploy) and the intended identity change (system-assigned removed). No other setting is
    added or removed → no destructive drift on the persisted keys.

**Conclusion:** IaC now reproduces the current working live state for all persisted items; a CI redeploy will
not revert the storage-identity settings, the clean supplier-endpoint setting, telemetry, the IA send-schema
relaxation, or the purchaser topic Data Receiver grant.

