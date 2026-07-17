# Purchaser PO → X12 850 (006030) — QA Samples & Test Catalog

> Owner: **Jayne (QA)** · Branch: `feature/purchaser-po-to-as2-850-workflow` · **Do NOT merge.**
> Authoritative design: [`docs/purchaser-workflow-epic-design.md`](../docs/purchaser-workflow-epic-design.md)
> X12 version for this epic is **006030** (root `X12_00603_850`), **not** 004010.

These are **non-sensitive demo fixtures** and test harnesses for the purchaser workflow
(`logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json`). They exercise the
JSON-schema gate and the JSON→canonical-XML→X12-850 transform pipeline **offline** — the parts
that can be validated without a deployed Azure environment.

## Files

| File | Purpose |
|------|---------|
| `purchase-order.sample.json` | **Valid** canonical PO (design §2.1): header + ship-to/bill-to + 3 line items. Happy path. |
| `purchase-order.invalid.json` | **Invalid** PO — 10 independent schema violations. Dead-letter negative path. |
| `purchase-order.schema.json` | Canonical PO JSON Schema (draft 2020-12, design §2.2). Same schema embedded in the workflow's `Parse_Purchase_Order`. |
| `expected/purchase-order.sample.canonical.xml` | Intermediate canonical XML — mirrors workflow step 5a `@xml(body('Parse_Purchase_Order'))`. Input to the XSLT. Validates against `PurchaseOrder_Canonical.xsd`. |
| `expected/purchase-order.sample.850.xml` | **Machine-generated** expected X12 850 XML — the real output of running `PO_Canonical_to_X12_850_006030.xslt` over the canonical XML. Validates against the official `X12_00603_850.xsd`. |
| `validate-json.py` | Asserts the valid sample passes and the invalid sample fails the JSON Schema. |
| `transform-and-validate.ps1` | Validates canonical XML → XSD, runs the real XSLT, validates the 850 output → official 006030 XSD. |

## How to run the automatable tests

```powershell
# 1. JSON-schema gate (requires: pip install jsonschema)
python samples/validate-json.py

# 2. Transform + XSD validation (uses .NET System.Xml; XSLT 1.0)
pwsh -File samples/transform-and-validate.ps1
```

Both exit `0` on success, non-zero on failure — CI-ready.

## Machine-verification status (this run, 2026-07-17)

| Check | Tool | Result |
|-------|------|--------|
| `purchase-order.sample.json` conforms to schema | Python `jsonschema` (Draft 2020-12 + format) | ✅ **PASS** (0 errors) |
| `purchase-order.invalid.json` rejected by schema | Python `jsonschema` | ✅ **PASS** (10 violations detected) |
| Canonical XML conforms to `PurchaseOrder_Canonical.xsd` | .NET `XmlReader`+`XmlSchema` | ✅ **PASS** |
| XSLT map runs (canonical XML → 850 XML) | .NET `XslCompiledTransform` (XSLT 1.0) | ✅ **PASS** |
| 850 output validates against official `X12_00603_850.xsd` (2.15 MB, 006030) | .NET `XmlReader`+`XmlSchema` | ✅ **PASS** |

**Independent confirmation:** Simon reported the map validates against the 006030 schema.
Jayne independently re-ran the real map through the official Microsoft `X12_00603_850.xsd` and
**confirms PASS**. Key spot-checks in the output: `BEG05=20260717`, `DTM02=20260731`, both
`N1Loop1` (ST + BT), 3× `PO1Loop1` each with `PID_2`, `CTT01=3`, `CTT02=660` (hash total of
120+40+500). Note `PO104=2.5` (JSON `2.50` parses to `2.5`; the trailing zero is dropped by
`xml(json())`).

## Test-case catalog

Legend — **Automatable now** = runnable offline against repo artifacts (above harnesses).
**Needs env** = requires a deployed purchaser/supplier stack (Service Bus, SQL, IA, AS2 certs).

### TC-1 — Happy path (valid PO → 850 sent, message completed)
- **Input:** `purchase-order.sample.json` onto SB topic `purchase-orders.received` / sub `all-messages`.
- **Expected:** `Parse_Purchase_Order` succeeds → `Persist_Purchase_Order` succeeds → canonical XML →
  Transform → X12 Encode → AS2 Encode (sign+encrypt) → HTTP POST to supplier → **`Complete_Message`**.
  The transform output matches `expected/purchase-order.sample.850.xml`. SB message **completed** (not dead-lettered).
- **Transform portion:** ✅ **Automatable now** (`transform-and-validate.ps1`) — **PASS**.
- **SQL persist:** ✅ Contract aligned — `Persist_Purchase_Order` succeeds (see RESOLVED B-1 below); live
  execution ⏳ **Needs env.**
- **End-to-end (encode/AS2/POST/settlement):** ⏳ **Needs env.**

### TC-2 — MDN absent / negative (send still succeeds, message completed)
- **Setup:** Supplier returns 200 with **no** MDN body, or a negative/unsigned MDN.
- **Expected:** MDN is **non-fatal** (design §1, §5.3). `POST_AS2_to_supplier` succeeds, `mdnReceived`
  tracked property is `false`, the scope still succeeds → **`Complete_Message`** runs. **No dead-letter.**
- **Status:** ⏳ **Needs env** (requires the supplier HTTP endpoint + AS2 round-trip).

### TC-3 — Schema-invalid payload (dead-lettered, nothing persisted/sent)
- **Input:** `purchase-order.invalid.json` onto the topic.
- **Expected:** `Parse_Purchase_Order` **fails** → `Process_Purchase_Order` scope fails →
  `Dead_Letter_Message` runs with `deadLetterReason = PurchaseOrderProcessingFailed`.
  **No** SQL row, **no** X12/AS2 emitted, **no** POST. SB message **dead-lettered**.
- **Schema-rejection portion:** ✅ **Automatable now** (`validate-json.py`) — **PASS** (10 violations).
- **Dead-letter settlement:** ⏳ **Needs env.**
- **Violations exercised:** missing `poNumber`; missing `seller`; `currency:"usd"` (fails `^[A-Z]{3}$`);
  `orderDate:"07/17/2026"` (not `date`); `shipTo.state:"Washington"` (fails `^[A-Z]{2}$`);
  `lines[0].lineNumber:0` (< 1); `lines[0].quantity:0` (not > 0); `lines[0].unitPrice:-1` (< 0);
  `lines[0].uom:"EACH"` (maxLength 2); extra `unexpectedField` (`additionalProperties:false`).

### TC-4 — SQL redelivery idempotency (no duplicate rows on re-delivery)
- **Setup:** Deliver the **same** `PoNumber` (`PO-2026-0001`) twice (simulates SB peek-lock expiry / retry).
- **Expected:** `dbo.usp_UpsertPurchaseOrder` is **idempotent on `PoNumber`** (design §3.2): first call inserts
  1 header + 3 lines + 2 addresses; second call is a **no-op** and returns the existing `PurchaseOrderId`.
  Row counts unchanged after the 2nd call. `UQ_PurchaseOrder_PoNumber` guarantees uniqueness.
- **Status:** ⏳ **Needs env** (live Azure SQL). SQL-only test: run `020-usp-upsert.sql`, `EXEC` twice with the
  same `@PoNumber`, assert `SELECT COUNT(*)` on all three tables is stable.

### TC-5 — SQL persist shape (header + N lines + 2 addresses)
- **Setup:** One successful persist of `purchase-order.sample.json`.
- **Expected:** `dbo.PurchaseOrder` = 1 row; `dbo.PurchaseOrderLine` = **3** rows (LineNumber 1/2/3);
  `dbo.[Address]` = **2** rows (ship-to + bill-to), referenced by `ShipToAddressId` / `BillToAddressId`.
  `CTT01` in the 850 (=3) equals the persisted line count — a useful cross-check.
- **Status:** ⏳ **Needs env** (live Azure SQL).

---

## ✅ RESOLVED B-1 — camelCase/PascalCase key mismatch in SQL persist (fixed 2026-07-17)

**Status: RESOLVED by Simon.** Originally High severity — a valid PO would have dead-lettered at
`Persist_Purchase_Order`. Now fixed; the happy path flows through the SQL persist as designed.

- The workflow builds the lines JSON from the **camelCase** canonical PO:
  `"LinesJson": "@{string(body('Parse_Purchase_Order')?['purchaseOrder']?['lines'])}"`
  → `[{"lineNumber":1,"sku":"SKU-1001","description":"Widget, 10mm","quantity":120,"uom":"EA","unitPrice":2.5}, ...]`
  (`workflow.json`, `Persist_Purchase_Order.inputs.parameters.storedProcedureParameters.LinesJson`).
- `infra/sql/schema/020-usp-upsert.sql` now shreds it with matching **camelCase** paths:
  `OPENJSON(@LinesJson) WITH (LineNumber INT '$.lineNumber', Sku ... '$.sku', '$.description', '$.quantity', '$.uom', '$.unitPrice')`.
  Verified in the file. This matches the workflow payload and the authoritative design **§3.2**.
- **Why it mattered:** OPENJSON `WITH` path property names are case-sensitive (independent of DB collation),
  so the previous PascalCase paths (`'$.LineNumber'`, …) resolved every column to `NULL` and the `NOT NULL`
  inserts failed (error 515). With camelCase paths the shred succeeds and TC-4 / TC-5 are the real gates
  (still ⏳ **Needs env** for live execution).

## 📝 NIT N-1 — stale filename in a comment (non-blocking)
`PurchaseOrder_Canonical.xsd`'s header comment references `PO_Canonical_to_X12_850_004010.xslt`; the actual
map is `...006030.xslt`. Cosmetic; does not affect validation. Route to the XSD author.
