# Supplier Inbound + 997 Round-Trip Test Plan

> **Author:** Jayne (Tester / QA) · **Branch:** `feature/supplier-inbound-997-workflow`
> **Date:** 2026-07-21
>
> **SCOPE BOUNDARY:** This plan covers the full 850→997 round-trip introduced by the supplier
> inbound epic. It does **NOT** re-certify the purchaser-send path (covered by
> `docs/purchaser-workflow-runbook.md`) except where that path is the trigger for this test.
>
> **Two categories of assertions here:**
> - **Offline-validated** — JSON schema checks that can run now with no Azure environment.
> - **Runtime checklist (pending deploy)** — steps that require a deployed environment. Clearly
>   marked. Do NOT claim these green until you have run them against a live environment.

---

## 0. Fixtures (offline-validated)

Three fixtures are used in this plan. All contain non-sensitive fake Contoso/Fabrikam data.

| Fixture file | Lines | PoNumber | Purpose |
|---|---|---|---|
| `samples/purchase-order-1line.json` | 1 | `PO-E2E-1LINE-001` | Exercises `Normalize_Lines` single-object path |
| `samples/purchase-order-3line.json` | 3 | `PO-E2E-3LINE-001` | Exercises `Normalize_Lines` array path + 3 `sup.PurchaseOrderLine` rows |
| `samples/purchase-order-e2e-test.json` | 2 | `PO-E2E-07201052` | Pre-existing 2-line smoke fixture (array path, already used for purchaser send) |

**Offline validation (JSON schema):**

```powershell
python samples\validate-json.py
```

This validates all three fixtures against `samples/purchase-order.schema.json` (draft 2020-12) and
asserts each is valid. Exit code 0 = all PASS. Run before any runtime test.

---

## 1. Prerequisites (runtime)

Before starting the runtime test sequence confirm each item is green:

- [ ] `deploy.yml` has completed: IaC, IA content (both supplier and purchaser IAs with
  agreements + schemas + certs), both workflow deployments (supplier `supplier-inbound-ack` and
  purchaser `purchaser-inbound-997`), and both callback-URL injections (§K2–M2 in
  `docs/supplier-workflow-epic-design.md §5.1`).
- [ ] `infra/scripts/generate-certificates.ps1` has been run (all 4 leaf certs + root CA in KV).
- [ ] Supplier IA agreements registered: `Supplier-Purchaser-X12-850`, `Supplier-Purchaser-X12-997`,
  `Supplier-Purchaser-AS2`.
- [ ] Purchaser IA updated: `Purchaser-Supplier-X12-997` agreement + X12_00603_997 schema ref on
  `Purchaser-Supplier-X12` receive agreement; AS2 receive certs activated on `Purchaser-Supplier-AS2`.
- [ ] KV secrets present: `supplier-as2-endpoint-url` (supplier callback URL),
  `purchaser-997-endpoint-url` (purchaser-997 callback URL).
- [ ] App settings resolved: purchaser `SupplierAs2EndpointUrl`, supplier `Purchaser997EndpointUrl`
  and `X12AgreementName` = `Supplier-Purchaser-X12` (or the 997-send agreement name as wired).
- [ ] SQL `sup` schema deployed: `030-sup-tables.sql` + `040-usp-upsert-supplier.sql` executed;
  `SupplierRole` has INSERT + EXECUTE on `sup.*`.
- [ ] Your CLI identity holds **Azure Service Bus Data Sender** on topic `purchase-orders.received`.
- [ ] Both Logic Apps have been restarted after app-setting injection.

---

## 2. Publish step

Use `az rest` to post the fixture to the Service Bus topic (same mechanism as the existing
purchaser runbook). Replace `$namespace` with your environment's Service Bus FQDN and choose the
fixture matching the sub-test.

```powershell
$namespace = 'sb-jci-edi-dev-2vjolmqq.servicebus.windows.net'  # replace with your FQDN

# --- Sub-test A: single-line PO ---
$payload = 'samples\purchase-order-1line.json'
$msgId   = 'PO-E2E-1LINE-001'

# --- Sub-test B: three-line PO ---
# $payload = 'samples\purchase-order-3line.json'
# $msgId   = 'PO-E2E-3LINE-001'

az rest --method post `
  --url "https://$namespace/purchase-orders.received/messages?timeout=60" `
  --resource 'https://servicebus.azure.net' `
  --headers 'Content-Type=application/json' `
            "BrokerProperties={`"MessageId`":`"$msgId`",`"CorrelationId`":`"$msgId`",`"Label`":`"E2E`"}" `
  --body "@$payload"
```

Use a **unique `MessageId`** per run (append a timestamp suffix if re-running the same fixture) so
redelivery and dedup behaviour are observable. Expected HTTP response: **201 Created**.

---

## 3. Pass criteria — per action, per workflow

### 3.1 Purchaser `purchaser-po-to-as2` run

Open the Logic Apps designer run-history for `purchaser-po-to-as2`.

| Action | PASS condition |
|---|---|
| `Parse_Purchase_Order` | Succeeded |
| `Persist_Purchase_Order` | Succeeded (dbo.usp_UpsertPurchaseOrder returns a PurchaseOrderId) |
| `Compose_Canonical_Xml` | Succeeded |
| `Transform_to_X12_850_Xml` | Succeeded |
| `Encode_to_X12_850` | Succeeded |
| `Encode_to_AS2` | Succeeded |
| `POST_AS2_to_supplier` | Succeeded; **status code = 200** |

> **Note:** `Complete_Message` is a known failure (`VNetPrivatePortsNotConfigured`) — treat as
> expected until that settlement issue is resolved. The business path is green if everything above
> `POST_AS2_to_supplier` is succeeded and returns 200.

### 3.2 Supplier `supplier-inbound-ack` run

Open the Logic Apps designer run-history for `supplier-inbound-ack` (a new run should appear within
seconds of the purchaser run posting).

| Action | PASS condition |
|---|---|
| `Decode_AS2` | Succeeded; tracked property `mdnGenerated = true` |
| `Respond_With_MDN` | Succeeded; HTTP 200 returned (the MDN is the body of the purchaser's `POST_AS2_to_supplier` response) |
| `Decoded_850_FlatFile` | Succeeded; output is a non-empty X12 flat-file string starting with `ISA*` |
| `Decode_X12_850` | Succeeded; `goodMessages` array non-empty, `badMessages` array empty |
| `Build_997_Xml` | Succeeded; output XML root = `X12_00603_997`, AK102/AK202 are non-empty strings |
| `Encode_997_to_X12` | Succeeded; output is an X12 interchange starting with `ISA*` (version `00603`); GS01 = `FA` |
| `Encode_997_to_AS2` | Succeeded; output has `messageHeaders` and `messageContent.$content` (base64) |
| `POST_997_to_purchaser` | Succeeded; **status code = 200** (purchaser MDN); tracked property `ack997PostStatusCode = 200` |
| `Transform_850_to_PO_Canonical` | Succeeded |
| `Parse_Canonical` | Succeeded |
| `Normalize_Lines` | Succeeded; output is a JSON array (starts with `[`) regardless of line count |
| `Persist_Purchase_Order` | Succeeded; `sup.usp_UpsertPurchaseOrder` returns a PurchaseOrderId |
| `Record_997_Send_Failure` | **Must NOT run** (it runs only on POST failure — if it ran, the POST failed) |

### 3.3 Purchaser `purchaser-inbound-997` run

Open the Logic Apps designer run-history for `purchaser-inbound-997` (a new run should appear
after the supplier posts the 997).

| Action | PASS condition |
|---|---|
| `Decode_AS2` | Succeeded; tracked property `mdnGenerated = true` |
| `Respond_With_MDN` | Succeeded; HTTP 200 returned to the supplier's `POST_997_to_purchaser` |
| `Decoded_997_FlatFile` | Succeeded; non-empty flat-file string starting with `ISA*`; GS01 segment field 1 = `FA` |
| `Decode_X12_997` | Succeeded; `goodMessages` array non-empty, `badMessages` empty |
| `Record_997_Status` | Succeeded; tracked property `functionalAckReceived = true`, `functionalAckRejected = false` |

### 3.4 SQL assertions (run via Azure portal query editor or SSMS)

Run after confirming §3.2 `Persist_Purchase_Order` succeeded.

```sql
-- Confirm the PO header landed in the supplier-owned schema
SELECT PoNumber, OrderDate, BuyerId, SellerId, ReceivedUtc
FROM sup.PurchaseOrder
WHERE PoNumber = 'PO-E2E-1LINE-001';   -- or PO-E2E-3LINE-001

-- Confirm addresses
SELECT po.PoNumber, a.Name, a.Line1, a.City, a.State
FROM sup.PurchaseOrder po
JOIN sup.[Address] a ON a.AddressId IN (po.ShipToAddressId, po.BillToAddressId)
WHERE po.PoNumber = 'PO-E2E-1LINE-001';

-- Confirm line count matches the fixture
SELECT COUNT(*) AS LineCount
FROM sup.PurchaseOrderLine pol
JOIN sup.PurchaseOrder po ON po.PurchaseOrderId = pol.PurchaseOrderId
WHERE po.PoNumber = 'PO-E2E-1LINE-001';
-- Expected: 1

-- Repeat for 3-line fixture, expecting LineCount = 3
SELECT COUNT(*) AS LineCount
FROM sup.PurchaseOrderLine pol
JOIN sup.PurchaseOrder po ON po.PurchaseOrderId = pol.PurchaseOrderId
WHERE po.PoNumber = 'PO-E2E-3LINE-001';
-- Expected: 3
```

**PASS condition:** `sup.PurchaseOrder` row exists with the correct `PoNumber`; `sup.Address` rows
exist for both ship-to and bill-to; `sup.PurchaseOrderLine` row count matches the fixture (1 for the
1-line fixture, 3 for the 3-line fixture).

**Idempotency check (re-run test):** Re-publish the same fixture with the same `MessageId`. After
the second supplier run completes, confirm `COUNT(*)` from `sup.PurchaseOrder WHERE PoNumber = ...`
is still **1** (not 2) — the proc's idempotency guard must fire, not insert a duplicate.

---

## 4. Runtime health-check — UNVERIFIED shapes (verify at designer / first run)

These items were flagged during the build wave as **community-sourced or runtime-dependent** and
have not been live-verified. Each must be checked explicitly at first-run and resolved before
signing off on the round-trip. Failures route to **Wash** for workflow fix unless noted.

---

### HC-1: 997 control-number positional parse (AK102 ← GS06, AK103 ← GS08, AK202 ← ST02)

**What the workflow does:**
```
AK102  = trim(split(split(outputs('Decoded_850_FlatFile'),'~')[1],'*')[6])
AK103  = trim(split(split(outputs('Decoded_850_FlatFile'),'~')[2],'*')[8])  [note: index [1] in workflow]
AK202  = trim(split(split(outputs('Decoded_850_FlatFile'),'~')[2],'*')[2])
```

**Check:** In the `Build_997_Xml` action output XML, locate `<AK102>`, `<AK103>`, `<AK202>`.

**Good looks like:**
- `AK102` = the group control number the purchaser send agreement assigned to this 850 (a numeric
  string, e.g. `1` or `000000001`). Match it against the `Encode_to_X12_850` output in the
  purchaser run (GS segment element 6, zero-indexed).
- `AK103` = `006030` (the 850's GS08 version string).
- `AK202` = the transaction-set control number (numeric string, typically `0001` for the first 850
  in a group). Match it against ST02 in the purchaser 850.

**Failure / fallback:** If `AK102` is empty or wrong, the positional index is incorrect — the ISA
segment length or delimiter choice changed the segment order. **Route to Wash** to inspect the
actual flat-file string in `Decoded_850_FlatFile` and adjust the split indexes. The decoded flat
file is available in the action output in the designer (expand the `Decoded_850_FlatFile` action).

---

### HC-2: X12 Decode `goodMessages[0].body` accessor for the decoded 850 XML

**What the workflow does:**
```
content: @first(body('Decode_X12_850')?['goodMessages'])?['body']
```
(in `Transform_850_to_PO_Canonical`)

**Check:** `Transform_850_to_PO_Canonical` succeeds and produces non-empty XML. Inspect the
`Decode_X12_850` action output in the designer — confirm that `goodMessages` is an array and that
each item has a `body` field containing the decoded 850 XML.

**Good looks like:** `Transform_850_to_PO_Canonical` produces XML that `Parse_Canonical` can
convert to JSON, with `purchaseOrder.poNumber` matching the fixture's PO number.

**Failure / fallback:** If `Transform_850_to_PO_Canonical` fails with "Input content is null or
empty," the `body` accessor path is wrong. Common alternatives seen in the community:
`goodMessages[0].value`, `goodMessages[0].content`, or the entire `goodMessages[0]` object being
the flat-file string (not XML). Inspect the raw `Decode_X12_850` body in the designer and identify
the correct sub-key. **Route to Wash** to update the `Transform_850_to_PO_Canonical` content
expression.

---

### HC-3: AS2 v2 built-in output casing — `messageHeaders` vs `MessageHeaders`, `$content` path

**What the workflow does (supplier encode then POST):**
```
headers: @body('Encode_997_to_AS2')?['messageHeaders']
body:     @base64ToBinary(body('Encode_997_to_AS2')?['messageContent']?['$content'])
```

**Check:** `POST_997_to_purchaser` succeeds with HTTP 200. If it fails with 400/415 or the
purchaser `Decode_AS2` fails because the body is empty, the output shape is wrong.

**Good looks like:** HTTP 200 from the purchaser; purchaser `Decode_AS2` succeeds.

**Failure / fallback:** If `Encode_997_to_AS2` output uses PascalCase (`MessageHeaders`,
`MessageContent`) rather than camelCase, update the accessors. The verified shape from the
purchaser `Encode_to_AS2` action (live) uses camelCase `messageHeaders` / `messageContent.$content`
(confirmed in `docs/purchaser-workflow-runbook.md`). If the supplier's AS2 Encode (v2 built-in)
differs — possible if the supplier app targets a different runtime version — inspect the raw
`Encode_997_to_AS2` output in the designer and update accordingly. **Route to Wash.**

---

### HC-4: MDN signing cert — supplier AS2 receive (inbound 850 MDN) and AS2 send (997 MDN response)

**What the workflow does:** `Respond_With_MDN` in the supplier workflow returns the MDN produced by
`Decode_AS2`. The MDN must be signed with the **supplier-signing PRIVATE** cert (bound in the
supplier IA AS2 receive agreement) so the purchaser can verify it.

**Check:**
- Purchaser `POST_AS2_to_supplier` response body contains a non-empty MDN (MIME multipart with
  signature).
- Purchaser `Encode_to_AS2` tracked property (if the purchaser action captures MDN verification) or
  the purchaser run does not fault due to an invalid MDN.

**Good looks like:** The MDN body in the purchaser's `POST_AS2_to_supplier` response is MIME
multipart (Content-Type starts with `multipart/`); the run completes without faulting on MDN
verification.

**Failure / fallback:** If the MDN is unsigned (Content-Type = `text/plain`) or the purchaser
rejects it, the supplier IA AS2 receive agreement's `signingCertificateName` is not wired correctly
— the `demo-as2-supplier-signing` cert private-key reference may be missing or the agreement's
`signOutboundMdnIfOptional` is false. **Route to Kaylee** for IA agreement cert binding.

---

### HC-5: `Normalize_Lines` — single-object vs array (both paths must pass)

**What the workflow does:**
```
@if(startsWith(string(outputs('Parse_Canonical')?['purchaseOrder']?['lines']), '['),
    outputs('Parse_Canonical')?['purchaseOrder']?['lines'],
    array(outputs('Parse_Canonical')?['purchaseOrder']?['lines']))
```

**Check (1-line fixture):** `Normalize_Lines` output starts with `[{` (an array), even though
`json(xml(...))` collapsed the single `<lines>` element to an object.

**Check (3-line fixture):** `Normalize_Lines` output starts with `[` (already an array — the
pass-through branch fires).

**Good looks like:** `Persist_Purchase_Order` succeeds for both fixtures; SQL line count = 1 and 3
respectively.

**Failure / fallback:** If `Persist_Purchase_Order` fails with an OPENJSON error on the single-line
fixture, `Normalize_Lines` produced an object, not an array. The `startsWith` guard is
runtime-dependent on how `json(xml(...))` serializes. If the canonical XML emits `<lines><line>…`
(with a child `<line>` element), `json(xml(...))` nests differently and the path
`?['purchaseOrder']?['lines']?['line']` may be needed instead. Inspect `Parse_Canonical` output in
the designer. **Route to Wash / Simon** (Simon authors the map; Wash wires the expression).

---

### HC-6: `Respond_With_MDN` body expression — `outgoingMdnContent` vs top-level shape

**What the workflow does (supplier):**
```
headers: @body('Decode_AS2')?['outgoingMdnContent']?['outgoingMdnHeaders']
body:    @body('Decode_AS2')?['outgoingMdnContent']?['messageContent']
```

**Check:** `Respond_With_MDN` succeeds; the purchaser's `POST_AS2_to_supplier` response body is
non-empty. The same pattern is used verbatim in `purchaser-inbound-997`'s `Respond_With_MDN`.

**Good looks like:** Purchaser run shows a non-empty response body for `POST_AS2_to_supplier`;
supplier `Respond_With_MDN` shows Succeeded with a 200 status.

**Failure / fallback:** If `Respond_With_MDN` sends an empty body, the `outgoingMdnContent` key or
its children differ in the actual AS2 Decode output. Inspect the `Decode_AS2` body in the designer.
Possible alternatives: `body('Decode_AS2')?['mdnContent']?['headers']` / `['body']`. **Route to
Wash.**

---

## 5. Negative / edge-case tests (post-green-path)

These are defined here but should be run **after** the happy-path round-trip is green:

| ID | Fixture / scenario | Expected outcome |
|----|--------------------|-----------------|
| N-1 | Re-publish the same PO twice (same `MessageId`) | Supplier `sup.PurchaseOrder` has exactly 1 row (idempotency); a second 997 is sent to purchaser |
| N-2 | Publish with a missing required field (use `samples/purchase-order.invalid.json`) | Purchaser `Parse_Purchase_Order` fails; `Dead_Letter_Message` fires; no supplier run |
| N-3 | Publish with a PoNumber that exceeds 22 chars | Purchaser `Parse_Purchase_Order` fails; no supplier run |
| N-4 | (Manual, requires env) Tamper with the AS2 payload bytes before posting to supplier | Supplier `Decode_AS2` fails; no MDN returned; supplier run faults; no 997 transmitted |
| N-5 | (Manual) Publish a 1-line PO, then immediately publish a 3-line PO for the same PoNumber | Only the first run should persist; second supplier `Persist_Purchase_Order` is a no-op |

N-2 can be run offline (or against the purchaser send path alone). N-4 / N-5 require a deployed
environment.

---

## 6. Offline validation scope

| Check | Tool | Runs offline? |
|-------|------|---------------|
| 1-line fixture valid JSON schema | `python samples\validate-json.py` | **Yes** |
| 3-line fixture valid JSON schema | `python samples\validate-json.py` | **Yes** |
| `purchase-order.invalid.json` invalid (schema rejects it) | `python samples\validate-json.py` | **Yes** |
| Canonical XML → X12 850 transform + schema validation | `pwsh -File samples\transform-and-validate.ps1` | **Yes** (uses existing canonical XML fixture; does not exercise supplier-side map) |
| 997 structural skeleton content | `samples/expected/997-structural-skeleton.md` | Reference only — no automated validator |
| AS2 encode/decode, SQL persist, MDN signing | None | **No** — requires deployed environment |

> `transform-and-validate.ps1` validates the **purchaser** XSLT and XSD (purchaser canonical → 850).
> The **supplier** receive map (`X12_850_006030_to_PO_Canonical.xslt`) is not currently exercised by
> the offline harness. Extending the harness to cover the supplier map is documented in §7.

---

## 7. Extending the offline harness

### 7.1 `validate-json.py` (already extended)

The script now validates all three fixtures (`purchase-order-1line.json`,
`purchase-order-3line.json`, `purchase-order-e2e-test.json`) as valid, and `purchase-order.invalid.json`
as invalid. No additional manual step required for JSON schema validation.

### 7.2 `transform-and-validate.ps1` — supplier receive map (manual step required)

The existing script exercises the **purchaser XSLT** (`PO_Canonical_to_X12_850_006030.xslt`). The
**supplier receive map** (`logicapps/supplier/Artifacts/Maps/X12_850_006030_to_PO_Canonical.xslt`)
cannot be validated offline until:

1. Simon delivers `X12_850_006030_to_PO_Canonical.xslt`.
2. A sample decoded-850 XML is available as input (the transform takes X12 850 XML, not the
   canonical PO JSON).

**Manual step (runtime):** After the first green supplier run, export the
`Transform_850_to_PO_Canonical` action **input** XML from the designer run history. That is the
real decoded 850 XML produced by `Decode_X12_850`. Use it as input to the supplier XSLT offline
for future regression.

A future extension to `transform-and-validate.ps1` can add a supplier-XSLT validation step once
the decoded-850 XML sample is captured.

---

## 8. Sign-off checklist

All items must be checked before Jayne signs off on this round-trip:

- [ ] `python samples\validate-json.py` exits 0 (all fixtures pass schema check)
- [ ] §3.1 purchaser run: all actions through `POST_AS2_to_supplier` = Succeeded; status 200
- [ ] §3.2 supplier run: `Decode_AS2` MDN generated; `Decode_X12_850` goodMessages non-empty;
  `Build_997_Xml` AK102/AK202 correct (HC-1 verified); `POST_997_to_purchaser` = 200;
  `Persist_Purchase_Order` succeeded
- [ ] §3.3 purchaser-997 run: `Decode_AS2` succeeded; `Decode_X12_997` goodMessages non-empty;
  `Record_997_Status` `functionalAckReceived = true`
- [ ] §3.4 SQL: `sup.PurchaseOrder` row exists; `sup.PurchaseOrderLine` count = 1 (1-line fixture)
- [ ] Repeat §3.1–§3.4 with the 3-line fixture; SQL line count = 3
- [ ] Idempotency: re-run same fixture → sup.PurchaseOrder still has 1 row
- [ ] HC-1 through HC-6 have each been explicitly observed and recorded as "confirmed" or routed
- [ ] N-2 (invalid fixture dead-letter) tested and confirmed
