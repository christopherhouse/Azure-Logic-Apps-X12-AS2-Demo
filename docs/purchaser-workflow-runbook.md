# Purchaser Workflow Epic — Runbook

> **Scope:** The application layer built on top of the locked infrastructure — the purchaser
> workflow that turns a canonical Purchase Order on Service Bus into a signed + encrypted
> **X12 850 (version 006030)** AS2 transmission to the supplier, plus the supplier's minimal
> HTTP-triggered acknowledgment endpoint.
> **Branch:** `feature/purchaser-po-to-as2-850-workflow` — **do not merge** (owner directive).
> **Authoritative design (the contract):** [`docs/purchaser-workflow-epic-design.md`](purchaser-workflow-epic-design.md).
> **Infrastructure baseline:** [`docs/infra-deploy-ordering.md`](infra-deploy-ordering.md) and
> [`docs/deployment-guide.md`](deployment-guide.md).

This runbook documents what the epic added on top of the infrastructure deployment: the new
deploy-ordering steps, the out-of-band certificate prerequisite, how to run the demo end-to-end,
and the known limitations and open risks. It complements — it does not replace — the infrastructure
deployment guide, which still covers the subscription-scoped Bicep deploy, OIDC setup, and cert
generation.

---

## 1. What this epic delivers

| Component | Location | Summary |
|-----------|----------|---------|
| **Purchaser workflow** | `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json` | Stateful. Service Bus peek-lock trigger → parse+validate → SQL upsert → JSON→XML → XSLT transform → X12 encode → AS2 encode → HTTP POST → complete/dead-letter. |
| **Supplier workflow** | `logicapps/supplier/workflows/supplier-inbound-ack/workflow.json` | Stateful. HTTP (`manual`) trigger → returns `200 OK` (`"AS2 message received."`). MDN generation deferred. |
| **X12 850 schema** | `infra/integration-account/schemas/X12_00603_850.xsd` | Microsoft's official 006030 850 schema (~2.15 MB, root `X12_00603_850`). Registered on the purchaser Integration Account via `contentLink`. |
| **Canonical PO schema** | `logicapps/purchaser/Artifacts/Schemas/PurchaseOrder_Canonical.xsd` | Governs the intermediate XML the XSLT consumes. Ships with the app. |
| **PO → 850 map** | `logicapps/purchaser/Artifacts/Maps/PO_Canonical_to_X12_850_006030.xslt` | XSLT that produces X12 850 XML. Ships with the app (`Artifacts/Maps`). |
| **SQL model** | `infra/sql/schema/010-tables.sql`, `020-usp-upsert.sql` | `Address` / `PurchaseOrder` / `PurchaseOrderLine` + `dbo.usp_UpsertPurchaseOrder` (idempotent on `PoNumber`, lines shredded from a JSON string with `OPENJSON`). |
| **IA content** | `infra/integration-account/ia-content.bicep` | Partners (Purchaser / Supplier), AS2 + X12 **send** agreements, AS2 certificate artifacts. |
| **CI** | `.github/workflows/deploy.yml` (extended), `validate.yml` | Adds the epic post-deploy ordering (see §3). |
| **Samples / tests** | `samples/` | Valid + invalid PO, expected canonical XML + 850 XML, JSON schema, offline validation harnesses, test catalog. |

See [`docs/trading-partner-onboarding.md`](trading-partner-onboarding.md) for the concrete partner
and agreement settings.

---

## 2. End-to-end flow

```
Service Bus topic 'purchase-orders.received' / sub 'all-messages'  (peek-lock)
   │
   ▼  splitOn debatches to one run per message
[Process_Purchase_Order scope]
   ├─ Parse_Purchase_Order      Parse JSON + validate against the canonical PO schema
   ├─ Persist_Purchase_Order    EXEC dbo.usp_UpsertPurchaseOrder  (lines passed as LinesJson string)
   ├─ Compose_Canonical_Xml     @xml(body('Parse_Purchase_Order'))  → canonical XML
   ├─ Transform_to_X12_850_Xml  XSLT (PO_Canonical_to_X12_850_006030.xslt) → X12 850 XML
   ├─ Encode_to_X12_850         X12 Encode (agreement 'Purchaser-Supplier-X12') → 006030 interchange
   ├─ Encode_to_AS2             AS2 Encode (sign + encrypt, request sync MDN) — as2From PURCHASER01 / as2To SUPPLIER01
   └─ POST_AS2_to_supplier      HTTP POST → @appsetting('SupplierAs2Endpoint__url')
   │
   ├─ scope SUCCEEDED → Complete_Message      (settle the Service Bus message)
   └─ scope FAILED/TIMEDOUT → Dead_Letter_Message  (reason = PurchaseOrderProcessingFailed)

Supplier: HTTP 'manual' trigger → Return_200_OK (200, "AS2 message received.")
```

**Settlement.** Any failure inside the scope — schema-invalid payload, SQL error, transform/encode
error, AS2 error, or a transport error on the POST — dead-letters the Service Bus message with a
reason. Only a fully successful send completes the message.

**MDN is non-fatal.** A synchronous MDN is *requested* on the AS2 encode, but settlement does not
gate on it. `POST_AS2_to_supplier` records `mdnReceived` (`@not(empty(body(...)))`) and
`supplierResponseStatusCode` as tracked properties only; a missing or negative MDN does **not**
dead-letter.

For the authoritative flow diagram, see §1 of the epic design doc.

---

## 3. Deploy ordering (epic additions)

The epic slots new post-deploy steps into the locked infrastructure sequence. **Rule:** IA content
before workflows; supplier before purchaser URL injection; SQL DDL/proc before the first purchaser
run. All of the steps below run automatically in `.github/workflows/deploy.yml`, in this order,
after the subscription-scoped Bicep deploy.

| # | `deploy.yml` step | What it does |
|---|-------------------|--------------|
| 1 | **Resolve Logic Apps first-party service principal object id** | Resolves the object ID of the Azure Logic Apps first-party SP (well-known app ID `7cd684f4-8a78-49b0-91ec-6a35d38739ba`) in the tenant and passes it into the Bicep deploy so the IA private-cert Key Vault grants are created (see R2). |
| 2 | **Deploy Bicep template** | Subscription-scoped `main.bicep` — infra baseline plus the purchaser EDI app settings, telemetry settings, and the first-party SP Key Vault RBAC (`infra/rbac/role-assignments.bicep`). |
| 3 | **Create SQL contained users and custom roles** | Existing infra step (`infra/sql/create-users-roles.sql`) — Entra-token T-SQL. |
| 4 | **Run SQL DDL (tables + upsert proc)** | Runs `010-tables.sql` then `020-usp-upsert.sql`. Must exist before the first purchaser run. |
| 5 | **Register X12 schema via REST contentLink (>2 MB)** | Uploads `X12_00603_850.xsd` to a blob in the purchaser storage account (`ia-artifacts` container), generates a short-lived read SAS, and registers the schema on the purchaser IA via `az rest --method put` with `properties.contentLink.uri` = blob SAS URL. The 2.15 MB schema exceeds the inline `content` limit and the ARM schema resource exposes no writable `contentLink`, so this is done out of band via the Logic REST API. |
| 6 | **Deploy Integration Account content (partners, certs, agreements)** | Deploys `infra/integration-account/ia-content.bicep`: partners, the purchaser-signing (private → KV key) and supplier-encryption (public) certificate artifacts, and the X12 + AS2 send agreements. **Guards on the cert prerequisite:** if the supplier encryption public cert is not yet in Key Vault, this step and all downstream EDI steps are skipped so an infra-only run stays green (`ediReady` flag). |
| 7 | **Publish IA callback URL to Key Vault** | Reads the purchaser IA callback URL (SAS-signed, treated as a secret) and writes it to Key Vault; the purchaser app setting `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` is a Key Vault reference to it (links the app to its IA). |
| 8 | **Deploy SUPPLIER workflow (first)** | Deploys `supplier-inbound-ack` so its HTTP trigger — and therefore its callback URL — exists before the purchaser needs it. |
| 9 | **Deploy PURCHASER workflow** | Deploys `purchaser-po-to-as2`. |
| 10 | **Supplier URL injection → Key Vault → restart purchaser** | Calls `listCallbackUrl` on the supplier `manual` trigger, writes the URL to Key Vault secret `supplier-as2-endpoint-url`, and restarts the purchaser Logic App so its `SupplierAs2Endpoint__url` Key Vault reference resolves. |

Telemetry (§5) is independent of IA content and is applied by the Bicep deploy (step 2) plus the
per-app `host.json` files; it can take effect any time before the first run.

---

## 4. Out-of-band prerequisite — AS2 certificates (R1)

**Certificate generation is a documented out-of-band prerequisite; it is not run by the deploy
pipeline.** The five demo certificates — the Demo Root CA plus four AS2 leaf certificates — are
created and published to Key Vault by the operator-run script:

```powershell
cd infra/scripts
.\generate-certificates.ps1 -KeyVaultName "kv-jci-edi-dev-<uniqueSuffix>"
```

See [`docs/deployment-guide.md` — Section 4](deployment-guide.md#4-post-deployment-generate-and-publish-certificates)
and [`infra/scripts/README.md`](../infra/scripts/README.md) for the full procedure and prerequisites.

The certificates this epic consumes:

| Key Vault certificate | Type used by the IA | Used by the AS2 send agreement for |
|-----------------------|---------------------|------------------------------------|
| `demo-as2-purchaser-signing` | **Private** (IA references the Key Vault key) | Signing outbound AS2 messages (SHA-256). |
| `demo-as2-supplier-encryption` | **Public** (public cert body uploaded to the IA) | Encrypting outbound AS2 messages (AES-256). |

`demo-as2-purchaser-encryption` and `demo-as2-supplier-signing` are reserved for the future
**receive** side (MDN verify / decrypt) and are not required for this send-only epic. `demo-as2-root-ca`
is the CA for the leaf certs.

**Impact if skipped:** the IA-content step (§3 step 6) and every downstream EDI step are skipped
gracefully — the infra deploys, but the AS2/X12 wiring is absent and the demo cannot run until the
certs exist and the deploy re-runs.

---

## 5. Telemetry enablement (both apps)

Workflows runtime telemetry **v2** (Application Insights based) is enabled on both Logic Apps via two
coordinated pieces:

1. **`host.json`** (both apps) — the version switch:

   ```jsonc
   {
     "extensions": {
       "workflow": {
         "Settings": {
           "Runtime.ApplicationInsightTelemetryVersion": "v2"
         }
       }
     }
   }
   ```

   (present in `logicapps/purchaser/host.json` and `logicapps/supplier/host.json`).

2. **App settings** (set by the compute Bicep):
   - `APPLICATIONINSIGHTS_CONNECTION_STRING` — shared App Insights connection string (already set by the compute bundle).
   - `AzureFunctionsJobHost__telemetryMode = OpenTelemetry` — host-level OpenTelemetry export.

The version switch lives only in `host.json` (source-controlled, per-app); it is **not** duplicated
in app settings.

---

## 6. Purchaser app settings (EDI)

Set on the purchaser Logic App by `infra/compute/logicapp-bundle.bicep` and CI:

| Setting | Value | Purpose |
|---------|-------|---------|
| `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` | `@Microsoft.KeyVault(...)` (IA callback URL secret) | Links the app to its Integration Account (built-in AS2/X12 operations need this). |
| `SupplierAs2Endpoint__url` | `@Microsoft.KeyVault(...)` → secret `supplier-as2-endpoint-url` | Outbound AS2 POST target; injected supplier-first by CI (§3 step 10). |
| `X12AgreementName` | `Purchaser-Supplier-X12` | X12 Encode `agreementName`, read by the workflow via `@appsetting('X12AgreementName')`. |
| `AzureFunctionsJobHost__telemetryMode` | `OpenTelemetry` | Telemetry (§5). |

Key Vault references resolve via the app's `keyVaultReferenceIdentity` (its UAMI, which already holds
Key Vault Secrets User).

---

## 7. Running the demo

**Preconditions:** infrastructure deployed, AS2 certs published to Key Vault (§4), and the deploy
pipeline completed all EDI steps (`ediReady == true`, i.e. the IA-content step did not skip).

1. **Drop a Purchase Order on the topic.** Send the canonical PO JSON as the message body to Service
   Bus topic `purchase-orders.received` (the subscription `all-messages` receives it). Use
   `samples/purchase-order.sample.json` as the payload. Any Service Bus sender with Data Sender rights
   on the namespace works (e.g. Service Bus Explorer in the portal, or `az servicebus`/SDK).

2. **Observe the purchaser run.** In the purchaser Logic App's run history, the
   `purchaser-po-to-as2` workflow should: parse the PO, upsert to SQL, build canonical XML, transform
   to X12 850 XML, X12-encode, AS2-encode (sign + encrypt), and POST to the supplier — then
   `Complete_Message`.

3. **Observe the supplier 200.** The supplier `supplier-inbound-ack` workflow receives the POST and
   returns `200 OK` (`"AS2 message received."`).

4. **Verify persistence.** Query Azure SQL: one `dbo.PurchaseOrder` row, three `dbo.PurchaseOrderLine`
   rows, two `dbo.[Address]` rows for `PO-2026-0001`.

5. **Check telemetry.** The run is visible in Application Insights (v2 workflow telemetry).

**Offline verification (no Azure needed).** The transform and validation portions can be verified
against the repo artifacts before any deploy — see [`samples/README.md`](../samples/README.md):

```powershell
python samples/validate-json.py            # JSON-schema gate (valid passes, invalid fails)
pwsh -File samples/transform-and-validate.ps1   # canonical XSD → XSLT → official 006030 XSD validation
```

---

## 8. Known limitations

- **MDN generation is deferred.** The supplier does not decode the AS2 message, verify the signature,
  decrypt, or generate a real MDN — it simply returns `200 OK`. The purchaser requests a sync MDN but
  treats its presence as non-fatal.
- **Supplier is a stub.** `supplier-inbound-ack` has no AS2 Decode / X12 Decode / persist / 997 / TA1
  logic. Inbound processing on the supplier side is future work.
- **Send-only agreements.** Only the purchaser→supplier **send** side (AS2 + X12) is configured. The
  receive side (MDN verify / decrypt, inbound 850) is not part of this epic; the purchaser-encryption
  and supplier-signing certs are reserved for it.
- **Single environment.** `dev` only, as with the infrastructure baseline.
- **Do not merge.** This epic is on `feature/purchaser-po-to-as2-850-workflow` under an owner directive
  not to merge.

---

## 9. Open risks

- **R1 — AS2 certificates are an out-of-band prerequisite.** The demo cannot exchange messages until
  `generate-certificates.ps1` has published the five certs (especially `demo-as2-supplier-encryption`
  and `demo-as2-purchaser-signing`) to Key Vault. The pipeline guards this by skipping the IA-content
  and EDI steps when the supplier encryption cert is absent, keeping an infra-only run green — but the
  operator must run the cert script and re-run the deploy to complete the EDI wiring (§4).
- **R2 — CI must resolve and grant the Logic Apps first-party SP Key Vault cert-read RBAC.** The
  purchaser-signing IA certificate is **private** and references a Key Vault key rather than embedding
  it. The identity that reads that key is the Azure Logic Apps **first-party service principal**
  (well-known app ID `7cd684f4-8a78-49b0-91ec-6a35d38739ba`), **not** the IA's managed identity. Its
  per-tenant object ID is resolved at deploy time (`deploy.yml` step 1) and passed to
  `infra/rbac/role-assignments.bicep`, which grants it **Key Vault Crypto User** + **Key Vault Secrets
  User** on the shared vault. If the object-ID resolution or the grant fails (or the object ID is left
  empty), the private-cert binding cannot read the signing key and AS2 signing fails. Confirm the exact
  IA identity mechanism against Microsoft Learn ("Add certificates to secure B2B messages in workflows
  for Azure Logic Apps") at deploy time.

---

## References

- [`docs/purchaser-workflow-epic-design.md`](purchaser-workflow-epic-design.md) — the authoritative design (contract).
- [`docs/trading-partner-onboarding.md`](trading-partner-onboarding.md) — concrete partner + agreement settings.
- [`docs/deployment-guide.md`](deployment-guide.md) — infrastructure deploy, OIDC, cert generation.
- [`docs/infra-deploy-ordering.md`](infra-deploy-ordering.md) — infrastructure deploy ordering.
- [`samples/README.md`](../samples/README.md) — sample fixtures and offline test catalog.
