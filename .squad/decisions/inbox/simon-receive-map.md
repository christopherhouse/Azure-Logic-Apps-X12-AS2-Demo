# Simon — supplier receive-side map (X12 850 006030 → supplier canonical)

> **Author:** Simon (EDI Analyst) · **Branch:** `feature/supplier-inbound-997-workflow`
> **Companion to:** `.squad/decisions/inbox/simon-997-receive.md` and the coordinator locks
> `.squad/decisions/inbox/squad-supplier-build-locks.md` (#1 = 006030 via explicit Encode,
> #3 = supplier `sup.*` mirror tables + `sup.usp_UpsertPurchaseOrder`).
> **For the Scribe to merge into `.squad/decisions.md`. Do NOT edit `decisions.md` directly.**

---

## D-RCVMAP-1: Map artifact

- **Path:** `logicapps/supplier/Artifacts/Maps/X12_850_006030_to_PO_Canonical.xslt` (created this task).
- **Direction:** the exact **inverse** of the purchaser send-side map
  `logicapps/purchaser/Artifacts/Maps/PO_Canonical_to_X12_850_006030.xslt`.
- **Invoked by:** Wash, via the built-in **Transform XML** action in `supplier-inbound-ack`
  (Standard loads maps from `Artifacts/Maps`; no Integration Account needed for the transform —
  same split as the purchaser app).
- **INPUT:** decoded X12 850 (006030) transaction-set XML from the built-in **X12 Decode** action —
  root `x12:X12_00603_850`, ns `http://schemas.microsoft.com/BizTalk/EDI/X12/2006`, BizTalk
  mixed-namespace model (global segments/loops `x12:`-prefixed, inline `ST/SE` + all data fields in
  no namespace). The map matches accordingly.
- **OUTPUT:** canonical Purchase Order XML, **no namespace**, root `<purchaseOrder>` — the SAME shape
  the purchaser send map consumes and the shape in design §2.1. Repeated `<lines>` elements so a
  downstream `json(...)` yields a `lines` **array**.

## D-RCVMAP-2: How Wash feeds `sup.usp_UpsertPurchaseOrder`

`sup.usp_UpsertPurchaseOrder` mirrors `dbo.usp_UpsertPurchaseOrder` (see
`infra/sql/schema/020-usp-upsert.sql`): scalar header + ship-to/bill-to params, and the line items
as a single JSON string `@LinesJson` shredded server-side by `OPENJSON(...) WITH (...)`.

- **Scalar params** come from the canonical fields via XPath / `json()` property refs
  (`poNumber`, `orderDate`, `requestedDeliveryDate`, `currency`, `buyer/id`, `buyer/name`,
  `seller/id`, `seller/name`, `shipTo/*`, `billTo/*`).
- **`@LinesJson`** = the canonical `lines` array serialized to JSON. The `<lines>` child element
  names are **identical** to the proc's `OPENJSON` `$.xxx` paths, so no re-keying is needed:

  | canonical `<lines>` element | OPENJSON path | column | type |
  |-----------------------------|---------------|--------|------|
  | `lineNumber` | `$.lineNumber` | `LineNumber` | INT |
  | `sku` | `$.sku` | `Sku` | VARCHAR(30) |
  | `description` | `$.description` | `[Description]` | NVARCHAR(80) |
  | `quantity` | `$.quantity` | `Quantity` | DECIMAL(18,4) |
  | `uom` | `$.uom` | `Uom` | VARCHAR(2) |
  | `unitPrice` | `$.unitPrice` | `UnitPrice` | DECIMAL(18,4) |

  > **json() type note (verified):** XML element text becomes JSON **strings** (e.g.
  > `"quantity":"120"`). `OPENJSON ... WITH (Quantity DECIMAL(18,4) '$.quantity')` casts strings to
  > the target type, so numeric round-trip is safe. `description` is omitted from a line when the
  > 850 carries no `PID*F`; OPENJSON yields `NULL` (column is nullable). ✔ matches the proc.

## D-RCVMAP-3: Mapping table — decoded 850 → canonical → `sup.*` column

`sup.*` column names/types mirror `dbo.*` (`infra/sql/schema/010-tables.sql`) per lock #3.

| # | X12 850 (decoded) source | canonical field | `sup.*` column | rule / note |
|---|--------------------------|-----------------|----------------|-------------|
| 1 | `BEG/BEG03` | `poNumber` | `PurchaseOrder.PoNumber` VARCHAR(22) | business key; idempotency key in the proc. |
| 2 | `BEG/BEG05` (CCYYMMDD) | `orderDate` | `PurchaseOrder.OrderDate` DATE | reformat `CCYYMMDD`→`YYYY-MM-DD` (inverse of send `translate(...,'-','')`). |
| 3 | `DTM[DTM01='002']/DTM02` | `requestedDeliveryDate` | `PurchaseOrder.RequestedDeliveryDate` DATE NULL | reformat as #2; element omitted when absent. |
| 4 | `REF[REF01='CO']/REF02` | `buyer/id` | `PurchaseOrder.BuyerId` VARCHAR(15) | customer/buyer reference. |
| 5 | `N1Loop1[N1/N101='ST']` `N1/N102` | `shipTo/name` | `Address.Name` (ShipTo) | party name. |
| 6 | `…ST…/N3/N301` (+`N302`) | `shipTo/line1` (+`line2`) | `Address.Line1/Line2` | `line2` omitted when empty. |
| 7 | `…ST…/N4/N401..N404` | `shipTo/city,state,postalCode,country` | `Address.City/State/PostalCode/Country` | N401=city, N402=state, N403=zip, N404=country. |
| 8 | `N1Loop1[N1/N101='BT']` (N1/N3/N4) | `billTo/*` | `Address.*` (BillTo) | as #5–#7. |
| 9 | `PO1Loop1` (1 each) `PO1/PO101` | `lines[]/lineNumber` | `PurchaseOrderLine.LineNumber` | assigned id. |
| 10 | `PO1/PO107` (with `PO106='BP'`) | `lines[]/sku` | `PurchaseOrderLine.Sku` | buyer's part number. |
| 11 | `PO1/PO102` | `lines[]/quantity` | `PurchaseOrderLine.Quantity` | quantity ordered. |
| 12 | `PO1/PO103` | `lines[]/uom` | `PurchaseOrderLine.Uom` | unit of measure. |
| 13 | `PO1/PO104` | `lines[]/unitPrice` | `PurchaseOrderLine.UnitPrice` | unit price. |
| 14 | `PO1Loop1/PIDLoop1/PID_2[PID01='F']/PID05` | `lines[]/description` | `PurchaseOrderLine.[Description]` NULL | free-form item desc; omitted when absent. |
| 15 | `CTTLoop1/CTT/CTT01,CTT02` | — (not persisted) | — | **validation only**: assert `CTT01 = count(lines)`, `CTT02 = sum(quantity)` (Wash may gate). |

## D-RCVMAP-4: GAPS — canonical/`sup.*` fields with NO clean 850 source (**flagged, not invented**)

The purchaser send map never encoded these into the 850, so they are **unrecoverable from the
decoded ST..SE body**. All are **NOT NULL** in the mirrored `sup.*` DDL, so a value MUST be supplied
or the upsert fails. The map emits **documented fallbacks** (clearly derived, never fabricated
business data) and flags each:

| Flag | canonical field | `sup.*` column | map fallback emitted | why no source | proper fix |
|------|-----------------|----------------|----------------------|---------------|-----------|
| **G1** | `currency` | `PurchaseOrder.Currency` CHAR(3) NOT NULL | constant `USD` | no `CUR` segment on the wire (send map drops `currency`). | add `CUR` to the 850 send map, OR default `USD` in `sup.*`, OR workflow enrichment. |
| **G2** | `buyer/name` | `PurchaseOrder.BuyerName` NVARCHAR(60) NOT NULL | copy of `buyer/id` | no buyer-name `N1*BY` loop on the wire. | add `N1*BY` to send map, OR partner master-data lookup. |
| **G3** | `seller/id` | `PurchaseOrder.SellerId` VARCHAR(15) NOT NULL | constant `SUPPLIER01` | not in ST..SE body; authoritatively the **decode ENVELOPE** `GS03`/`ISA08`. | **Wash SHOULD override** from X12 Decode envelope metadata if exposed; else constant is correct (supplier = self). |
| **G4** | `seller/name` | `PurchaseOrder.SellerName` NVARCHAR(60) NOT NULL | constant `SUPPLIER01` (id proxy) | no seller-name loop on the wire. | supplier's own display name (config/app-setting), OR master-data lookup. |

> **Decision needed (route to coordinator):** pick ONE remediation per gap for the demo. Simplest
> path that keeps the demo green with the current send map: accept the map fallbacks (G1 `USD`,
> G2/G4 id-proxies) and have **Wash override `seller/id`+`seller/name` from the decode envelope**
> (G3/G4) when available. If a faithful round-trip is required later, enrich the **send** map
> (`CUR` + `N1*BY` + `N1*SE`/`SU`) — that is a purchaser-side change I (Simon) would own.

## D-RCVMAP-5: Verification performed (this task)

- **XSLT 1.0 compile** (`XslCompiledTransform.Load`) → **OK** (after removing `--` runs from
  decorative comments — XML comments cannot contain `--`).
- **Direct transform** of a representative decoded 850 (2 lines, ST+BT addresses, PID descriptions,
  DTM 002) → canonical output **matches design §2.1 shape**; dates reformatted `YYYY-MM-DD`;
  `lines` emitted as repeated elements (→ JSON array).
- **Full inverse round-trip** `canonical → PO_Canonical_to_X12_850_006030.xslt → 850 →
  X12_850_006030_to_PO_Canonical.xslt → canonical`: **all recoverable fields identical**
  (poNumber, orderDate, requestedDeliveryDate, buyer.id, shipTo/billTo incl. line2, all line
  fields). The four gaps (G1–G4) surface exactly as the flagged fallbacks. **PASS.**

## Coordination notes for Wash / Kaylee

- **Wash:** Transform XML input = X12 Decode body (root `x12:X12_00603_850`); output = `purchaseOrder`
  XML. Build `@LinesJson` from `purchaseOrder/lines` (keys already match OPENJSON). Consider
  overriding `seller/id`+`seller/name` from Decode envelope metadata (G3/G4). Optionally gate on the
  CTT totals (row 15). The map targets the `sup` shape but is **schema-shape only** — it does not
  itself call SQL.
- **Kaylee:** `sup.*` must mirror `dbo.*` column names/types (rows in D-RCVMAP-3). If the team
  chooses "relax to NULL/default" for any gap (G1/G2/G4), that changes the `sup.*` DDL nullability —
  confirm before I adjust the map fallbacks. `sup.usp_UpsertPurchaseOrder` should keep the same
  `@LinesJson` OPENJSON contract as `dbo` (D-RCVMAP-2).
- **No 997 impact:** this map is the **inbound-persistence** path only. The 997 acknowledgment is
  generated from Decode metadata + X12 Encode (per `simon-997-receive.md` D-997-4 / lock #1), **not**
  from this map.
