# Jayne — Supplier Inbound + 997 QA Notes

> **Author:** Jayne (Tester / QA) · **Branch:** `feature/supplier-inbound-997-workflow`
> **Date:** 2026-07-21
> **For the Scribe to merge into `.squad/decisions.md`.**
>
> These notes record QA decisions, fixture choices, and open items arising from the supplier
> inbound + 997 epic. They supplement (not replace) `docs/supplier-roundtrip-test-plan.md`.

---

## Q-1: Fixture strategy — 1-line and 3-line PO fixtures added

**Decision:** Added two new canonical PO JSON fixtures under `samples/`:
- `purchase-order-1line.json` (PO-E2E-1LINE-001, 1 line item)
- `purchase-order-3line.json` (PO-E2E-3LINE-001, 3 line items)

**Rationale:** The `Normalize_Lines` action in `supplier-inbound-ack` has two distinct code paths:
a single `<lines>` element in the decoded 850 canonical XML collapses to a JSON object after
`json(xml(...))`, while multiple `<lines>` elements correctly produce an array. The 1-line fixture
exercises the `array(...)` wrap branch; the 3-line fixture exercises the pass-through branch. Both
paths must be confirmed at runtime — a fix to one path can silently break the other. The existing
2-line fixture (`purchase-order-e2e-test.json`) exercises the array path only; it does not cover
the single-object collapse case.

**Offline validation:** `python samples\validate-json.py` now validates all three fixtures (and the
existing sample + invalid fixture). Exit code 0 confirmed on branch.

---

## Q-2: `validate-json.py` extended — new fixtures included

**Decision:** Extended `samples/validate-json.py` to validate `purchase-order-e2e-test.json`,
`purchase-order-1line.json`, and `purchase-order-3line.json` as valid. The invalid-fixture check
remains. No new test infrastructure introduced — the existing jsonschema harness covers all five
cases.

**What it does NOT cover:** AS2 encode/decode, X12 encode/decode, SQL persist, MDN signing — all
of which require a deployed runtime. These are documented as runtime checks in
`docs/supplier-roundtrip-test-plan.md`.

---

## Q-3: `transform-and-validate.ps1` — not extended yet; manual step documented

**Decision:** The existing PowerShell harness validates the **purchaser** XSLT
(`PO_Canonical_to_X12_850_006030.xslt`). Extending it for the **supplier** receive map
(`X12_850_006030_to_PO_Canonical.xslt`) requires:
1. Simon's map to be delivered.
2. A sample decoded-850 XML as input (cannot be produced without a deployed supplier IA).

**Action (deferred):** After the first green supplier run, export the `Transform_850_to_PO_Canonical`
action input XML from the designer and use it as a regression input. Document the extension in
`transform-and-validate.ps1` at that point. This is a sprint-2 / post-deploy QA item.

---

## Q-4: Offline vs runtime classification (explicit boundary)

No runtime claims are made in the fixtures or skeleton notes. The following are clearly
**offline-only**:
- JSON schema validation (automated, confirmed green)
- 997 structural skeleton (`samples/expected/997-structural-skeleton.md`) — reference, not
  executable

The following are **runtime-only** (pending deploy):
- All action-level PASS criteria in `docs/supplier-roundtrip-test-plan.md §3`
- Health-checks HC-1 through HC-6
- SQL assertions (§3.4)
- Negative tests N-4 / N-5

---

## Q-5: UNVERIFIED shapes — 6 runtime health-checks captured

The following items from the build wave were flagged as unverified and are captured as explicit
health-checks in `docs/supplier-roundtrip-test-plan.md §4`:

| HC | Shape / assumption | Risk if wrong | Route |
|----|-------------------|---------------|-------|
| HC-1 | AK102/AK103/AK202 positional parse (tilde/star split indexes) | 997 echoes wrong control numbers → purchaser X12 997 decode rejects it | Wash |
| HC-2 | `goodMessages[0].body` accessor for decoded 850 XML | Transform step gets null input → sup persist never runs | Wash |
| HC-3 | AS2 v2 output casing — `messageHeaders` / `messageContent.$content` | POST_997_to_purchaser sends malformed AS2 → purchaser 997 decode fails | Wash |
| HC-4 | MDN signing cert wiring (supplier-signing PRIVATE) | Purchaser receives unsigned MDN → may fault on MDN verification | Kaylee |
| HC-5 | `Normalize_Lines` single-object vs array — both paths | 1-line PO silently writes 0 lines to SQL | Wash / Simon |
| HC-6 | `Respond_With_MDN` body expression `outgoingMdnContent` shape | Empty MDN body → purchaser treats AS2 as failed | Wash |

All six have a documented "good looks like" state and a "failure / fallback" routing step in the
test plan.

---

## Q-6: Idempotency test included

**Decision:** The sign-off checklist includes an explicit idempotency check (re-publish the same
fixture, confirm `sup.PurchaseOrder` has exactly 1 row, not 2). This exercises the
`IF @PurchaseOrderId IS NULL` guard in `sup.usp_UpsertPurchaseOrder`. A missing idempotency guard
would be silent — no workflow error, just a duplicate row — so it must be tested explicitly.

---

## Q-7: Negative test N-2 (invalid fixture dead-letter) is offline-runnable

The invalid fixture (`purchase-order.invalid.json`) fails `Parse_Purchase_Order` because the JSON
schema check fails. This is partially verifiable offline via `validate-json.py` (the schema-level
rejection is confirmed). The `Dead_Letter_Message` action's behaviour requires a live Service Bus
environment, but the schema-rejection itself is confirmed offline.

---

## Open items (hand-off to Mal / Coordinator)

- HC-2 (`goodMessages[0].body`) is the highest-risk unverified item: if this accessor is wrong,
  the entire supplier-side business processing (map → SQL persist) silently fails. Recommend
  Wash inspect this at designer level before declaring the first run done.
- HC-5 (Normalize_Lines) must be tested with the **1-line fixture first** — the array path is
  easier to accidentally pass even if broken. The failure mode (0 SQL lines for a 1-line PO) may
  not raise a workflow error.
- Simon's `X12_850_006030_to_PO_Canonical.xslt` output shape drives the `Parse_Canonical` JSON
  paths (`purchaseOrder.lines`, address fields). If the map uses different root or field names,
  `Normalize_Lines` and `Persist_Purchase_Order` expressions break silently. The map must be
  reviewed against the `sup.usp_UpsertPurchaseOrder` parameter names before the first run.
