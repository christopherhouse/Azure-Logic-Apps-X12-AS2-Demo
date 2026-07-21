# Book — supplier inbound + 997 return documentation

> **Author:** Book (Technical Writer) · **Branch:** `feature/supplier-inbound-997-workflow`
> **For the Scribe to merge into `.squad/decisions.md`. Do NOT edit `decisions.md` directly.**

---

## What was done

Updated or created the following docs on branch `feature/supplier-inbound-997-workflow` to reflect
the supplier receive + 997 round-trip epic. All new receive-side content is explicitly marked
**AUTHORED — not yet deployed or live-verified**; only the purchaser send path retains live-verified status.

| File | Action | Summary |
|------|--------|---------|
| `docs/end-to-end-flow.md` | Updated | Title, dual status header, §1 purchaser send (adds note that supplier is no longer a stub), new §2 with full Mermaid + action table for supplier receive and purchaser-inbound-997, new verification evidence section for §2. Wash FLAGS W-1 to W-5 noted inline. |
| `docs/trading-partner-onboarding.md` | Updated | Dual status header; updated intro scope paragraph; updated §3 cert note (all 4 now active); replaced §7 deploy ordering with send+receive combined sequence; replaced §8 verification with purchaser+supplier commands; added §9 (unchanged), §10 (supplier IA partners), §11 (full cert binding table, all 4 leaf certs), §12 (supplier IA agreements — see inconsistency flag below), §13 (purchaser IA additions), §14 (sup SQL schema). |
| `docs/supplier-workflow-runbook.md` | **Created** | Full supplier runbook: what's new, app settings, callback-URL injection ordering, `sup.*` persist target, how-to-run steps, known flags W-1–W-5 from Wash, offline validation note. Cross-link to Jayne's test plan. |
| `docs/purchaser-workflow-runbook.md` | Updated | Added a forward cross-link to `supplier-workflow-runbook.md` after the "end-to-end-flow" reference. |

---

## Decisions recorded

### D-BOOK-1: Created `docs/supplier-workflow-runbook.md` as a separate file (not extending the purchaser runbook)

**What:** New file rather than a section in `purchaser-workflow-runbook.md`.
**Why:** The supplier workflow is a distinct app in a distinct region with distinct app settings, SQL tables, and run procedure. Merging it into the purchaser runbook would make both runbooks harder to follow. Cross-link from purchaser runbook keeps discoverability intact.

---

## Inconsistencies flagged — for Mal and the Coordinator

These are real discrepancies between the design doc/inbox note and the coordinator build-lock/actual build artifacts. I have documented the **built state** (what the coordinator locked and what Kaylee + Wash implemented), not Mal's design doc. Flagged here for reconciliation.

### FLAG B-1: X12 agreement naming — single bidirectional vs split agreements

**Mal's design** (`supplier-workflow-epic-design.md §3.1` and `mal-supplier-inbound.md`):
> One X12 agreement per IA — `Supplier-Purchaser-X12` (receive 850 + send 997) and extend
> `Purchaser-Supplier-X12` (add 997 receive schema reference).

**Coordinator locks + build (Kaylee, Wash):**
> Separate agreements: `Supplier-Purchaser-X12-850` (receive) and `Supplier-Purchaser-X12-997`
> (send) on the supplier IA; new `Purchaser-Supplier-X12-997` on the purchaser IA.

**Impact:** The design doc (`supplier-workflow-epic-design.md §3.2` table) is stale — it lists `Supplier-Purchaser-X12` and extension of `Purchaser-Supplier-X12`, not the split names that were built. The workflow `@appsetting('X12SendAgreementName')` = `Supplier-Purchaser-X12-997` is the built truth. Mal's inbox note also lists `X12AgreementName = Supplier-Purchaser-X12` as the setting name, which conflicts with the built `X12SendAgreementName`.

**Recommended action:** Update `supplier-workflow-epic-design.md §3.1–3.2` to reflect the split-agreement build shape, or add an addendum. The design doc is cross-linked from multiple docs and should not remain stale.

### FLAG B-2: `X12ReceiveAgreementName` app setting is redundant

**Kaylee built** `X12ReceiveAgreementName = Supplier-Purchaser-X12-850` as a supplier app setting.
**Wash confirmed** (review-gate §1) that the built-in X12 Decode never takes a receive-agreement-name
param — it auto-resolves by ISA/GS envelope identities. The setting exists in the app but is unused
at runtime.

**Recommended action:** Kaylee can drop `X12ReceiveAgreementName` from `logicapp-bundle.bicep` in a follow-up (no urgency — harmless surplus). Document it as redundant for now (done in §12 of the trading-partner doc).

### FLAG B-3: Mal's inbox note lists wrong app-setting names

`mal-supplier-inbound.md` lists `X12AgreementName = Supplier-Purchaser-X12`. The built state
(coordinator locks + Kaylee) uses `X12SendAgreementName = Supplier-Purchaser-X12-997`. Mal's inbox
note predates the split-agreement decision and was not updated.

**Recommended action:** No code change needed (Kaylee + Wash are consistent). Scribe should note the supersession when merging Mal's inbox note into `decisions.md`.
