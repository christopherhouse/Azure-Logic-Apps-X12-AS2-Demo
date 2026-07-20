# RESUME — Purchaser PO → X12 850 (006030) → AS2 → Supplier

Last updated: 2026-07-20. Repo: `C:\Projects\AzLogicAppsAS2X12Demo`
(christopherhouse/Azure-Logic-Apps-X12-AS2-Demo). Sub: `8bd05b2f-62c5-4def-9869-f0617ebb3970`.

## TL;DR of current state
The EDI epic (workflows + IA content + SQL + CI) was built and PR'd. Deploy then failed in a
cascade of real bugs. Most are fixed **live in Azure**, but several fixes are **NOT yet in
code**, so a CI redeploy would revert them. One workflow-definition bug remains open.

## Environment facts (verified)
- Key Vault: `kv-jci-edi-dev-2vjolmqq` (RBAC mode, shared-key enabled, public net enabled)
- Purchaser: RG `rg-edi-purchaser`, app `logic-jci-purchaser-dev`, storage `stjcipurchaserdev2vjolmq`,
  UAMI `id-jci-purchaser-dev` (clientId `8a2d2355-ec3a-421f-ab1d-50ea89f15f83`)
- Supplier: RG `rg-edi-supplier`, app `logic-jci-supplier-dev`, storage `stjcisupplierdev2vjolmqq`,
  UAMI `id-jci-supplier-dev` (clientId `2df2da89-2f4d-419c-856d-57eec412054f`)
- Integration Account: `ia-jci-purchaser-dev` (rg-edi-purchaser)
- Deploy SP: appId `923efbd9-17d1-468c-bc7c-5828856848c6`, objectId `75e3563d-d357-4707-a4d5-6610134af6ef`
- Logic Apps first-party SP objectId (this tenant): `e615dae7-e5df-44eb-a0b0-bfc13c04f05d`

## ✅ Done / working live in Azure
1. Both Logic App hosts now `state=Running` (were ServiceUnavailable). **Root cause = wrong
   identity-based `AzureWebJobsStorage` settings.** Correct set applied to BOTH apps:
   - `AzureWebJobsStorage__credential = managedIdentity`
   - `AzureWebJobsStorage__credentialType = managedIdentity`   (BOTH keys required — Functions host
     reads `__credential`, Workflows Data.Edge reads `__credentialType`)
   - `AzureWebJobsStorage__managedIdentityResourceId = <UAMI resource id>`
   - `AzureWebJobsStorage__blobServiceUri / __queueServiceUri / __tableServiceUri = https://<sa>.<svc>.core.windows.net`
   - REMOVED: plain `AzureWebJobsStorage`, `__accountName`, `__clientId`
   - Ref: Learn "Create single-tenant workflows … Set up managed identity access to your storage account".
2. Both KV secrets now exist (KV-reference app-setting error resolved):
   `purchaser-ia-callback-url` (IA callback URL) and `supplier-as2-endpoint-url` (supplier trigger URL).
3. IA content deployed (partners, X12+AS2 send agreements, cert artifacts) — `ia-content.bicep` applied live.
4. 5 AS2 demo certs published to Key Vault via `infra/scripts/generate-certificates.ps1`.
5. Deploy SP granted **Key Vault Certificate User + Secrets Officer** on the vault (data-plane).
6. Supplier: `AzureFunctionsJobHost__telemetryMode=OpenTelemetry` was REMOVED during a test (needs restore).

## ❌ Open blocker (where we stopped)
Purchaser workflow `purchaser-po-to-as2` is **Unhealthy**:
`The value '/serviceProviders/x12' provided for 'serviceProviderConfiguration.serviceProviderId'
for 'x12Encode' is not valid.`
→ The built-in **X12 Encode** (and almost certainly **AS2 Encode**) action shapes in
`logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json` use the wrong service-provider
id/operation shape. Wash flagged these as "confirm at designer round-trip." Need the correct
built-in X12/AS2 `serviceProviderId` + `operationId` (+ whether they need a `connectionName` entry
in `connections.json`). Verify against a real Logic App Standard designer export / Learn.

Check health after any workflow change:
`az rest --method get --url ".../sites/logic-jci-purchaser-dev/hostruntime/runtime/webhooks/workflow/api/management/workflows/purchaser-po-to-as2?api-version=2022-03-01"` → `.properties.health`

## ⚠️ Live fixes NOT yet in code (must be persisted before any CI redeploy, or they revert)
1. **Storage settings** — `infra/compute/logicapp-bundle.bicep` still emits the broken set
   (`__credential=managedidentity` lowercase, `__accountName`, `__clientId`, no `__credentialType`,
   no service URIs). Update it to the corrected set above for BOTH apps.
2. **Deploy-SP KV data-plane grants** (Certificate User + Secrets Officer) — applied via CLI, not IaC.
   Provisioned out-of-band like the OIDC setup; document in deploy runbook (Book) or add to CI setup.
3. **Repo variable** `LOGICAPPS_FIRSTPARTY_SP_OBJECT_ID = e615dae7-...` was set (used by PR #8's deploy.yml).
4. **Uncommitted edit:** `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json`
   (removed invalid cross-action `trackedProperties.poNumber`). On branch `bugfix/edi-content-deploy-fixes`.
5. Restore `AzureFunctionsJobHost__telemetryMode=OpenTelemetry` on supplier (or drop from both consistently).

## Git / PR state
- Current branch: `bugfix/edi-content-deploy-fixes` (has 1 uncommitted file — the trackedProperties fix)
- **PR #9** OPEN: `fix(edi): make Integration Account content deploy succeed end-to-end`
  (cert-gen KeyUsage, SHA256→SHA2256, purchaser-signing publicCertificate). Not merged.
- PR #7 (epic) and PR #8 (first-party SP objectId, deploy.yml var) already merged to main.
- Agent must NOT merge PRs.

## Next steps (in order) to resume
1. Fix the built-in **X12 Encode** + **AS2 Encode** action shapes in the purchaser workflow.json
   (correct `serviceProviderId`/`operationId`); redeploy via
   `az functionapp deployment source config-zip -g rg-edi-purchaser -n logic-jci-purchaser-dev --src <zip of logicapps/purchaser>`;
   confirm workflow health = Healthy.
2. Confirm the supplier workflow is Healthy and the end-to-end send works (drop a PO on SB topic
   `purchase-orders.received` → observe 850 AS2 POST → supplier HTTP 200).
3. Persist all live fixes into Bicep (`logicapp-bundle.bicep` storage settings) + commit the
   workflow.json fix; fold into PR #9 (or a new PR). Restore supplier telemetry setting.
4. Update docs/runbook (Book) with: the identity-storage settings, deploy-SP KV grants, cert-gen
   prerequisite, and the LOGICAPPS_FIRSTPARTY_SP_OBJECT_ID variable.

## Handy verification commands
- Host status: `az rest --method get --url ".../sites/<app>/hostruntime/admin/host/status?api-version=2022-03-01"` → `.state`, `.errors`
- Workflow health: `.../workflows/<name>?api-version=2022-03-01` → `.properties.health`
- KV secrets present: `az keyvault secret list --vault-name kv-jci-edi-dev-2vjolmqq --query "[].name" -o tsv`
