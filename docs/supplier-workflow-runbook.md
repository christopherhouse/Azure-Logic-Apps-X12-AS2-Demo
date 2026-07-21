# Supplier Workflow Runbook — Inbound 850 Receive + 997 Return

> **Status (2026-07-21):** AUTHORED on branch `feature/supplier-inbound-997-workflow`; not yet deployed or live-verified. This runbook describes the authored design. Verify each step against the actual Azure environment once the epic is deployed.
>
> **Related docs:**
> - Architecture and flow: [`docs/end-to-end-flow.md §2`](end-to-end-flow.md)
> - Authoritative design: [`docs/supplier-workflow-epic-design.md`](supplier-workflow-epic-design.md)
> - Trading-partner configuration: [`docs/trading-partner-onboarding.md §10–14`](trading-partner-onboarding.md)
> - Purchaser send runbook: [`docs/purchaser-workflow-runbook.md`](purchaser-workflow-runbook.md)
> - Test plan (being authored in parallel): [`docs/supplier-roundtrip-test-plan.md`](supplier-roundtrip-test-plan.md)

---

## What this epic adds

Two new or reworked workflows:

| Workflow | App | File | What it does |
|----------|-----|------|--------------|
| `supplier-inbound-ack` | Supplier (`rg-edi-supplier`) | `logicapps/supplier/workflows/supplier-inbound-ack/workflow.json` | Receives the purchaser's AS2/850 POST; AS2-decodes (signed MDN); X12-decodes; persists to `sup.*` SQL tables; generates, X12-encodes, AS2-encodes, and POSTs a 997 functional ACK to the purchaser. |
| `purchaser-inbound-997` | Purchaser (`rg-edi-purchaser`) | `logicapps/purchaser/workflows/purchaser-inbound-997/workflow.json` | Receives the supplier's AS2/997 POST; AS2-decodes (signed MDN); X12-decodes the 997; records the functional-ack status as tracked properties. |

The supplier `supplier-inbound-ack` workflow keeps the same name and `manual` trigger as the original 200-stub — CI relies on that name to extract the callback URL.

---

## App settings required

### Supplier app — new settings this epic

| Setting key | KV secret / value | Notes |
|-------------|-------------------|-------|
| `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` | KV-ref → `supplier-ia-callback-url` | Links the supplier app to the supplier IA (same mechanism as the purchaser app). |
| `Purchaser997EndpointUrl` | KV-ref → `purchaser-997-endpoint-url` | The SAS-signed `manual` trigger URL of `purchaser-inbound-997`. Written by CI's dual callback-URL injection step after both workflows are deployed. |
| `X12SendAgreementName` | `Supplier-Purchaser-X12-997` | Literal string; the X12 Encode (997) action uses `@appsetting('X12SendAgreementName')` to select the 997 send agreement. |
| `X12ReceiveAgreementName` | `Supplier-Purchaser-X12-850` | Built by Kaylee; **redundant at runtime** — X12 Decode auto-resolves by ISA/GS identities and ignores this setting. Present but unused. |

The SQL and Service Bus connection settings (`sql__serverFqdn`, `sql__databaseName`, `sql__clientId`, `sql__credential`) come from the existing supplier `connections.json` managed-identity shape (fixed in this epic — same bug as the purchaser fix on 2026-07-20).

### Purchaser app — no new outbound settings

The `purchaser-inbound-997` workflow is a receive endpoint only; it uses no outbound app settings. AS2 and X12 Decode both auto-resolve agreements from the linked purchaser IA. Existing settings (`SupplierAs2EndpointUrl`, `X12AgreementName`) are unchanged.

---

## Callback-URL injection ordering (dual injection)

This epic introduces a second SAS-signed callback URL (`purchaser-997-endpoint-url`) alongside the existing `supplier-as2-endpoint-url`. There is a circular dependency if injection is serialized — the purchaser send needs the supplier URL (supplier-first), and the supplier 997-send needs the purchaser-997 URL (purchaser-first). CI breaks the deadlock with a **non-interleaved dual injection**:

1. Deploy **both** workflows (`supplier-inbound-ack` full pipeline + `purchaser-inbound-997`).
2. Read **both** trigger callback URLs (`listCallbackUrl` on each `manual` trigger — depends only on the trigger *existing*, not on any downstream app setting).
3. Write **both** KV secrets (`supplier-as2-endpoint-url`, `purchaser-997-endpoint-url`) in one CI step.
4. Set **both** app settings and restart **both** apps.

Do not interleave deploy → inject → deploy → inject. That order deadlocks.

---

## SQL persist target (`sup.*` schema)

The supplier persists inbound 850 POs to its own schema, isolated from the purchaser's `dbo` tables:

| Table/proc | Schema | Idempotency key |
|-----------|--------|-----------------|
| `sup.PurchaseOrder` | `sup` | `PoNumber` |
| `sup.Address` | `sup` | FK to `PurchaseOrder` |
| `sup.PurchaseOrderLine` | `sup` | FK to `PurchaseOrder` |
| `sup.usp_UpsertPurchaseOrder` | `sup` | `PoNumber` (same OPENJSON `@LinesJson` contract as `dbo` version) |

DDL files: `infra/sql/schema/030-sup-tables.sql`, `040-usp-upsert-supplier.sql`. The `SupplierRole` is granted INSERT + EXECUTE on `SCHEMA::sup` only.

---

## How to run the round-trip (once deployed)

**Prerequisites:**

- `deploy.yml` has completed through the `supplierEdiReady`-gated steps: supplier IA content deployed, both workflows deployed, both KV secrets written, both apps restarted.
- `infra/scripts/generate-certificates.ps1` has published all four leaf certs to Key Vault.
- Purchaser app setting `Purchaser997EndpointUrl` resolves (KV-ref → `purchaser-997-endpoint-url`).
- Supplier SQL: `030-sup-tables.sql` + `040-usp-upsert-supplier.sql` have been run.
- Supplier UAMI is a member of `SupplierRole`.

**Steps:**

1. Publish a test PO to the Service Bus topic `purchase-orders.received` (same as the purchaser send runbook step 2 in [`docs/purchaser-workflow-runbook.md`](purchaser-workflow-runbook.md)).
2. The purchaser workflow encodes and posts the AS2/850 to the supplier — confirm `POST_AS2_to_supplier` succeeds with HTTP 200 (this is the live-verified send path).
3. Open supplier run history for `supplier-inbound-ack`. Confirm:
   - `Decode_AS2` — `Succeeded`
   - `Respond_With_MDN` — `Succeeded` (check body contains MDN headers)
   - `Decode_X12_850` — `Succeeded`; `goodMessages` count = 1
   - `Transform_850_to_PO_Canonical` — `Succeeded`
   - `Parse_Canonical`, `Normalize_Lines`, `Persist_Purchase_Order` — `Succeeded`
   - `Build_997_Xml` — `Succeeded`; inspect the XML for correct `AK102`/`AK202` values
   - `Encode_997_to_X12`, `Encode_997_to_AS2` — `Succeeded`
   - `POST_997_to_purchaser` — `Succeeded`, status code `200`
4. Verify SQL: `SELECT * FROM sup.PurchaseOrder WHERE PoNumber = '<test-PO-number>'` returns one row.
5. Open purchaser run history for `purchaser-inbound-997`. Confirm:
   - `Decode_AS2` — `Succeeded`
   - `Respond_With_MDN` — `Succeeded`
   - `Decode_X12_997` — `Succeeded`
   - `Record_997_Status` — `Succeeded`; inspect tracked properties for `functionalAckReceived = true`
6. Check Jayne's test plan ([`docs/supplier-roundtrip-test-plan.md`](supplier-roundtrip-test-plan.md)) for edge-case runs (rejected 850, repeat PO, multi-line PO).

---

## Known flags — items to health-check at first live run

These are unverified design choices flagged by Wash. None is a blocker for authoring; all should be confirmed before claiming live-verification of the round-trip.

| # | Flag | Action at first run |
|---|------|---------------------|
| **W-1** | **997 control-number echoes positional parsing.** `AK102`/`AK202` extracted by splitting `Decoded_850_FlatFile` on `~`/`*` at fixed positions (ISA=seg[0], GS=[1], ST=[2]). Assumes single ISA/GS/ST interchange and no newline suffixes on segment terminators. | Inspect the raw 850 flat file in `Decoded_850_FlatFile` to confirm segment layout. If multi-set batches are ever in scope, replace with a loop. |
| **W-2** | **`goodMessages[0].body` per-item accessor (X12 Decode output) is NOT Learn-documented.** Used as the input to `Transform_850_to_PO_Canonical`. Candidate alternates: `messageJsonBody`, `Message`, `Payload`. | Check `Decode_X12_850` output in the run inspector. If the transform fails with a null/empty input, switch to the correct property name. |
| **W-3** | **AS2 (v2) built-in output JSON casing.** Output accessors use camelCase (`messageHeaders`, `messageContent.$content`) per the repo's verified AS2 Encode shape. The AS2 Decode `outgoingMdnContent` shape is Learn-cited. If MDN or AS2 headers come back empty on the first run, switch to PascalCase (`AS2Message`, `Content`, `OutgoingMDN`). | Inspect `Decode_AS2` / `Encode_997_to_AS2` raw output on first run. |
| **W-4** | **Persist depends on Simon's map.** `X12_850_006030_to_PO_Canonical.xslt` is authored and XSLT-1.0-compile-verified with a round-trip test (Simon D-RCVMAP-5). The `goodMessages` item shape (FLAG W-2) is a dependency. | If W-2 resolves cleanly, persist should follow. Check `Parse_Canonical` output for canonical field names. |
| **W-5** | **AS2 Decode input JSON names `messageToDecode`/`messageHeaders`** inferred by symmetry with AS2 Encode. Low risk. | Confirm at designer inspect. If `Decode_AS2` fails to parse the request, these are the first names to check. |

---

## Offline validation

```powershell
# Validate the XSLT map compiles and round-trips (no Azure needed)
# Simon performed this check (D-RCVMAP-5): XSLT-1.0 compile OK; canonical output matches design §2.1 shape.
# Command used by Simon: XslCompiledTransform.Load on
#   logicapps/supplier/Artifacts/Maps/X12_850_006030_to_PO_Canonical.xslt
```

No Azure-side offline validation is available for the workflow actions; health-check FLAGS W-1 to W-5 require a live run.
