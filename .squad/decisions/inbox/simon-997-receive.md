# Simon — 997 functional acknowledgment + supplier-inbound receive spec

> **Author:** Simon (EDI Analyst) · **Branch:** `feature/supplier-inbound-997-workflow`
> **Scope:** EDI detail for the supplier-inbound epic — supplier receives the purchaser's
> AS2/X12 **850**, decodes + validates it, generates an X12 **997** functional acknowledgment,
> and transmits the 997 back to the purchaser over AS2.
> **For the Scribe to merge into `.squad/decisions.md`. Do NOT edit `decisions.md` directly.**
>
> Mal owns the flow/trust-boundary/wiring; this file is the EDI content of record he references.
> Envelope + control-number correctness is non-negotiable — a wrong control number is a silent
> time bomb.

---

## 0. Grounding (what this builds on — already locked)

- **850 is X12 006030** (product-owner choice, decisions.md 2026-07-17): schema `X12_00603_850`
  (root `X12_00603_850`, ns `http://schemas.microsoft.com/BizTalk/EDI/X12/2006`), ISA12=`00603`,
  GS08=`006030`, `controlVersionNumber`/`schemaVersion`=`00603`, ISA11=`U`, usage `T`, `ZZ`
  qualifiers, `PURCHASER01`/`SUPPLIER01`.
- **X12 `securitySettings`** (locked): `authorizationQualifier:'00'`, `securityQualifier:'00'`,
  `passwordValue:''`.
- **Control numbers are agreement-generated** (the X12 agreement owns ISA13/GS06/ST02 counters;
  workflows never hand-roll them).
- **850 direction:** Purchaser = SENDER (`PURCHASER01`), Supplier = RECEIVER (`SUPPLIER01`).
- **997 direction (this epic):** **Supplier = SENDER (`SUPPLIER01`), Purchaser = RECEIVER
  (`PURCHASER01`)** — the reverse of the 850.
- Ground-truth for the 997 structure: **Microsoft Learn**
  `logic-apps-enterprise-integration-x12-997-acknowledgment#997-ack-segments`.

---

## D-997-1: 997 functional-acknowledgment transaction-set structure (version 006030)

The 997 acknowledges the **functional group (GS/GE)** of the received 850 and, per transaction
set, whether each 850 (ST/SE) was accepted or rejected. Segment table (grounded against MS Learn):

| Pos | Segment | Name | Req | Max | Loop |
|-----|---------|------|-----|-----|------|
| 010 | ST  | Transaction Set Header (of the 997) | M | 1 | — |
| 020 | AK1 | Functional Group Response Header | M | 1 | — |
| 030 | AK2 | Transaction Set Response Header | O | 1 | 999999 (loop AK2) |
| 040 | AK3 | Data Segment Note | O | 1 | 999999 (loop AK3, inside AK2) |
| 050 | AK4 | Data Element Note | O | 99 (per AK3) | — |
| 060 | AK5 | Transaction Set Response Trailer | M *(within AK2 loop)* | 1 | — |
| 070 | AK9 | Functional Group Response Trailer | M | 1 | — |
| 080 | SE  | Transaction Set Trailer (of the 997) | M | 1 | — |

**Loop nesting:** `AK2Loop1 = { AK2, AK3Loop1{ AK3, AK4[0..99] }[0..999999], AK5 }`. One `AK2Loop1`
per acknowledged/rejected transaction set; the `AK3Loop1` / `AK4` detail appears only when a set is
in error. In the happy-path (single 850 accepted) the 997 is `ST · AK1 · AK2 · AK5 · AK9 · SE`.

### Element detail (verified vs Learn; lengths per X12 006030)

| Element | Data element | Type/len | Req | Meaning |
|---------|--------------|----------|-----|---------|
| ST01 | 143 | ID 3/3 = `997` | M | Transaction set id of the ACK itself. |
| ST02 | 329 | AN 4/9 | M | 997 transaction-set control number (**997's own**, agreement/Encode-generated). |
| **AK101** | 479 | ID 2/2 | M | **Functional group id of the acknowledged group = the received 850's GS01 (`PO`).** |
| **AK102** | 28 | N0 1/9 | M | **Group control number being acknowledged = the received 850's GS06 / GE02.** |
| AK103 | 480 | AN 1/12 | O | Echoes the received GS08 (`006030`); supports 5010-style ACK. |
| **AK201** | 143 | ID 3/3 | M | Transaction set id being acknowledged = received **ST01 (`850`)**. |
| **AK202** | 329 | AN 4/9 | M | Transaction set control number acknowledged = received **ST02 / SE02**. |
| AK203 | 1705 | AN 1/35 | O | Echoes received ST03 (5010-style). |
| AK301 | 721 | ID 2/3 | M | Segment id in error. |
| AK302 | 719 | N0 1/6 | M | Segment position in set (ST = 1). |
| AK303 | 447 | AN 1/6 | O | Bounded LS/LE loop id. |
| AK304 | 720 | ID 1/3 | O | Segment syntax error code (`8` ⇒ AK4 follows). |
| AK401 | C030 | composite | M | Position in segment: C03001 (722, elem pos) M; C03002 (1528, comp pos) O; C03003 (1686, repeat pos) O *(006030/5010 addition — flagged)*. |
| AK402 | 725 | N0 1/4 | O | Data-element reference number of element in error. |
| AK403 | 723 | ID 1/3 | M | Data-element syntax error code. |
| AK404 | 724 | AN 1/99 | O | Copy of bad data element (omitted for invalid-char). |
| **AK501** | 717 | ID 1/1 | M | **Transaction set accept/reject: `A`ccept, `E` accept-with-errors, `P`artial, `R`eject.** |
| AK502–AK506 | 718 | ID 1/3 | O | Transaction-set syntax error codes. |
| **AK901** | 715 | ID 1/1 | M | **Functional group accept/reject (`A`/`E`/`P`/`R`).** |
| AK902 | 97 | N0 1/6 | M | # transaction sets included (received GE01). |
| AK903 | 123 | N0 1/6 | M | # transaction sets received. |
| AK904 | 2 | N0 1/6 | M | # transaction sets accepted. |
| AK905–AK909 | 716 | ID 1/3 | O | Functional-group syntax error codes. |

### CONTROL-NUMBER RELATIONSHIPS (the non-negotiable part)

The 997 carries **two distinct classes of control numbers** — do not conflate them:

1. **Referencing (echo) numbers** — copied FROM the received 850 into the 997 body:
   - `AK102` ← received **850 GS06** (group control number). *(This is the primary linkage.)*
   - `AK202` ← received **850 ST02** (transaction-set control number).
   - `AK101` ← received **850 GS01** (`PO`); `AK201` ← received **850 ST01** (`850`).
   - (optional) `AK103` ← received **850 GS08**; `AK203` ← received **850 ST03**.
2. **Owning (generated) numbers** — the 997 interchange's **own** ISA13/GS06/ST02, generated by the
   **supplier→purchaser X12 SEND agreement's** control-number generator (rollover enabled). These
   are unrelated to the 850's numbers and increment independently.

> **Rule of record:** the 997 *references* the 850's GS06/ST02 in AK102/AK202, and *owns* a fresh
> ISA13/GS06/ST02 for its own envelope. The workflow (Wash) never types a control number; the
> reference values come from the X12 Decode output metadata of the received 850, the owning values
> come from the send agreement.

---

## D-997-2: Envelope (ISA / GS / ST) for the supplier → purchaser 997 interchange

Reverse of the 850 direction. All control numbers **agreement-generated** by the supplier IA's X12
**send** agreement.

| Level | Element | Value | Notes |
|-------|---------|-------|-------|
| ISA05/07 | Sender/Receiver ID qualifier | `ZZ` | Same mutually-agreed qualifier as the 850. |
| ISA06 | Interchange Sender ID | `SUPPLIER01    ` | 15-char space-padded. **Supplier is now sender.** |
| ISA08 | Interchange Receiver ID | `PURCHASER01   ` | **Purchaser is now receiver.** |
| ISA11 | Repetition separator | `U` | Same as 850. |
| ISA12 | Interchange ctrl version | `00603` | 006030 interchange control version. |
| ISA13 | Interchange control number | auto | Supplier send-agreement generator (owns; rollover). |
| ISA14 | Ack requested (TA1) | `0` | No TA1 for this demo. |
| ISA15 | Usage indicator | `T` | Test posture (matches the 850). |
| ISA16 | Component separator | `>` | Same delimiters as the 850. |
| GS01 | Functional ID code | `FA` | **`FA` = Functional Acknowledgment (997)** — *not* `PO`. |
| GS02 | Application Sender Code | `SUPPLIER01` | |
| GS03 | Application Receiver Code | `PURCHASER01` | |
| GS06 | Group control number | auto | Supplier send-agreement generator (owns). |
| GS08 | Version/Release | `006030` | Matches the 850 version in scope. |
| ST01 | Transaction Set ID | `997` | |
| ST02 | Transaction Set ctrl # | auto | Supplier send-agreement generator (owns). |

**Delimiters:** data element `*`, component `>`, segment terminator `~` — identical to the 850
(framingSettings: `dataElementSeparator:42`, `componentSeparator:62`, `segmentTerminator:126`).

> **FLAG for Kaylee/Wash:** GS01 for the 997 is **`FA`**, so the send agreement's
> `envelopeSettings.functionalGroupId` = **`FA`** (the 850 agreement uses `PO`). The 997 schema
> reference messageId is **`997`**.

---

## D-997-3: Agreements this epic needs (EDI content for Wash / Kaylee to bind)

Three X12 agreements across two Integration Accounts. Naming follows the existing
`Purchaser-Supplier-X12` convention. **AS2 agreements are Mal/Zoe's domain — listed only for
context.**

### A) Supplier IA — X12 **receive** agreement for the inbound 850

- **Proposed name:** `Supplier-Purchaser-X12-850` *(host-first; host=Supplier, guest=Purchaser).*
- **Partners:** host `Supplier` (`ZZ`/`SUPPLIER01`), guest `Purchaser` (`ZZ`/`PURCHASER01`).
- **`receiveAgreement`** identities: `senderBusinessIdentity` = `ZZ`/`PURCHASER01`,
  `receiverBusinessIdentity` = `ZZ`/`SUPPLIER01`.
- **Schema binding (`schemaReferences`):** `messageId:'850'`, `schemaVersion:'00603'`,
  `schemaName:'X12_00603_850'`, `senderApplicationId:'PURCHASER01'`. *(The 2.15 MB 850 xsd is
  registered on the supplier IA via REST `contentLink` — same mechanism Kaylee used for the
  purchaser IA; it is **not** inline Bicep.)*
- **Envelope:** `controlVersionNumber:'00603'`, `groupHeaderVersion:'006030'`,
  `functionalGroupId:'PO'`, `usageIndicator:'Test'`, `groupHeaderAgencyCode:'X'`, `ZZ` identities.
- **`validationSettings` / duplicate handling (control-number validation):**
  - `checkDuplicateInterchangeControlNumber: true`, `interchangeControlNumberValidityDays: 30`
  - `checkDuplicateGroupControlNumber: true`, `checkDuplicateTransactionSetControlNumber: true`
  - `validateCharacterSet: true`, `validateEDITypes: true`, `validateXSDTypes: false`,
    `trailingSeparatorPolicy:'NotAllowed'`.
  > On the receive side we **enable** duplicate detection (the purchaser send agreement had them
  > `false` because it was generating, not validating). Rejecting a replayed 850 by control number
  > is the whole point of receive-side validation.
- **`securitySettings`:** `{ authorizationQualifier:'00', securityQualifier:'00', passwordValue:'' }`.
- **997 generation (`acknowledgementSettings`):** see D-997-4 — this is where FA generation is
  switched on.

### B) Supplier IA — X12 **send** agreement for the outbound 997

- **Proposed name:** `Supplier-Purchaser-X12-997` *(host=Supplier, guest=Purchaser).*
- **Partners:** host `Supplier` (`ZZ`/`SUPPLIER01`), guest `Purchaser` (`ZZ`/`PURCHASER01`).
- **`sendAgreement`** identities: `senderBusinessIdentity` = `ZZ`/`SUPPLIER01`,
  `receiverBusinessIdentity` = `ZZ`/`PURCHASER01`.
- **Schema binding:** `messageId:'997'`, `schemaVersion:'00603'`, `schemaName:'X12_00603_997'`.
- **Envelope (per D-997-2):** `senderApplicationId:'SUPPLIER01'`,
  `receiverApplicationId:'PURCHASER01'`, `controlVersionNumber:'00603'`,
  `groupHeaderVersion:'006030'`, **`functionalGroupId:'FA'`**, `usageIndicator:'Test'`, `ZZ`.
- **Control-number strategy:** agreement-generated & rollover (matches the 850 send agreement) —
  `rolloverInterchangeControlNumber/GroupControlNumber/TransactionSetControlNumber: true`,
  bounds `1 .. 999999999`, `overwriteExistingTransactionSetControlNumber: true`. **These are the
  997's *owning* numbers (ISA13/GS06/ST02), NOT the AK102/AK202 echo values.**
- **`securitySettings`:** `{ '00','00','' }`.

### C) Purchaser IA — X12 **receive** agreement for the inbound 997

- **Proposed name:** `Purchaser-Supplier-X12-997` *(host=Purchaser, guest=Supplier).*
- **Partners:** host `Purchaser` (`ZZ`/`PURCHASER01`), guest `Supplier` (`ZZ`/`SUPPLIER01`).
- **`receiveAgreement`** identities: `senderBusinessIdentity` = `ZZ`/`SUPPLIER01`,
  `receiverBusinessIdentity` = `ZZ`/`PURCHASER01`.
- **Schema binding:** `messageId:'997'`, `schemaVersion:'00603'`, `schemaName:'X12_00603_997'`,
  `senderApplicationId:'SUPPLIER01'`. *(The `X12_00603_997.xsd` is small — 31 KB — so it can be
  registered **inline** in Bicep `content`, unlike the 850. Kaylee's choice.)*
- **Envelope:** `controlVersionNumber:'00603'`, `groupHeaderVersion:'006030'`,
  `functionalGroupId:'FA'`, `usageIndicator:'Test'`, `ZZ`.
- **`acknowledgementSettings`:** `needFunctionalAcknowledgement:false` — **you do not ACK an ACK.**
- **`validationSettings`:** duplicate detection may be enabled (defensive), `validateEDITypes:true`,
  `validateXSDTypes:false`.

### Exact names & bindings summary (for Wash / Kaylee)

| Purpose | IA | Agreement name | Host / Guest | Schema artifact | msgId / ver | GS01 |
|---------|----|----------------|--------------|-----------------|-------------|------|
| Receive 850 | Supplier | `Supplier-Purchaser-X12-850` | Supplier / Purchaser | `X12_00603_850` (REST contentLink) | 850 / 00603 | PO |
| Send 997 | Supplier | `Supplier-Purchaser-X12-997` | Supplier / Purchaser | `X12_00603_997` (inline) | 997 / 00603 | FA |
| Receive 997 | Purchaser | `Purchaser-Supplier-X12-997` | Purchaser / Supplier | `X12_00603_997` (inline) | 997 / 00603 | FA |

- **Schema artifact names (exact):** `X12_00603_850`, `X12_00603_997`.
- **Schema files:** `infra/integration-account/schemas/X12_00603_850.xsd`,
  `infra/integration-account/schemas/X12_00603_997.xsd`.
- **Partner identities:** unchanged — `ZZ`/`PURCHASER01`, `ZZ`/`SUPPLIER01` (AS2 identity
  `AS2Identity`/`PURCHASER01`|`SUPPLIER01`).
- **App-setting convention:** mirror the existing `X12AgreementName` pattern — suggest the supplier
  app read `X12ReceiveAgreementName` (=`Supplier-Purchaser-X12-850`) and
  `X12SendAgreementName` (=`Supplier-Purchaser-X12-997`) so agreements can be renamed without a
  workflow edit. *(Wash/Mal to confirm the app-setting names.)*

---

## D-997-4: How the 997 is generated — Decode auto-gen vs. explicit Encode (**decision + FLAG**)

Two mechanisms exist. **This is the single most important open question for Mal.**

- **Option 1 — X12 Decode auto-generates the 997.** Set the supplier **receive** agreement
  `acknowledgementSettings.needFunctionalAcknowledgement: true` (`batchFunctionalAcknowledgements:
  false`, `needLoopForValidMessages: true` if you want an AK2 loop for accepted sets). The **X12
  Decode** action then returns the 997 as one of its outputs, control numbers and AK1/AK2/AK5/AK9
  populated automatically from the decoded 850. Simplest; least workflow code.
  - **⚠ HARD CONSTRAINT (verified on MS Learn):** *"The X12 Decode action always generates a
    **4010-compliant** 997 ACK."* So the auto-generated 997 is **004010**, **not 006030**, even
    though the 850 is 006030. Its structure still matches `X12_00603_997.xsd` at the segment level
    (AK1/AK2/AK5/AK9 are stable across 4010→6030), but the envelope GS08 it emits will be `004010`.
- **Option 2 — explicit build + X12 Encode.** The workflow constructs the 997 XML (root
  `X12_00603_997`, populating AK102←GS06, AK202←ST02, AK501/AK901 from the Decode result) and runs
  **X12 Encode** against `Supplier-Purchaser-X12-997`. This yields a **true 006030** 997 and binds
  `X12_00603_997.xsd`. More workflow logic; full version control.

> **Simon's recommendation:** For a version-consistent demo (**006030 end-to-end**) use **Option 2**
> (explicit Encode against the 997 send agreement) so the acknowledgment matches the 850 version and
> the schema binding is exercised. If the team prefers minimal workflow, **Option 1** is acceptable
> **provided** everyone accepts the 997 is 4010 on the wire and the purchaser receive agreement is
> set to `groupHeaderVersion:'004010'` for the 997 (mismatch with the send side otherwise).
> **DECISION NEEDED FROM MAL/COORDINATOR — do not let this default silently.** The schema, envelope,
> and send-agreement spec above assume **Option 2 (006030)**.

---

## D-997-5: 997 schema artifact

- **Path:** `infra/integration-account/schemas/X12_00603_997.xsd` (created this task).
- **Root/name:** `X12_00603_997`; **namespace:** `http://schemas.microsoft.com/BizTalk/EDI/X12/2006`
  (identical to the 850). `standards_version="00603"`, `document_type="997"`.
- **Structural consistency with the 850:** inline local `ST`/`SE`; global ref'ed segments
  (`AK1`,`AK9`) and loop wrappers (`AK2Loop1`,`AK3Loop1`) exactly like the 850's `N1Loop1`/`PO1Loop1`/
  `CTTLoop1`; composite `AK401` modelled as a ref'ed global `C030` element with `C03001/2/3` subfields
  (mirrors the 850's `C001` composite); base simple types `X12_AN`/`X12_ID`/`X12_N0` transcribed
  verbatim (all `xs:string`; EDI-type enforcement is the agreement's `validateEDITypes`, not the xsd).
- **Mixed-namespace behavior (same as 850, per decisions.md):** global elements
  (`X12_00603_997`, `AK1`, `AK2Loop1`, `AK2`, `AK3Loop1`, `AK3`, `AK4`, `C030`, `AK5`, `AK9`) are in
  the X12 namespace (`x12:`-prefixed); local elements (`ST`/`SE` and all data fields `AK101` …) are
  **unqualified**. Any hand-authored 997 XML or map output must follow this or it won't validate.
- **Verification performed (this task):**
  - `XmlSchemaSet.Compile()` → **OK** (10 global elements, 3 base simple types).
  - Accepted-path instance (`ST·AK1·AK2·AK5·AK9·SE`, AK501=`A`, AK901=`A`) → **VALIDATION PASS**.
  - Rejected-path instance (`AK3Loop1{AK3,AK4{C030}}`, AK501=`R`, AK502=`5`, AK901=`R`) →
    **VALIDATION PASS**.
- **Flagged elements (could not exhaustively verify against a published 006030 997 implementation
  guide — modelled from MS Learn semantics + standard X12 element dictionary):**
  - `AK401.3` / `C03003` (Repeating Data Element Position, 1686) — a 5010/6030 addition; present per
    Learn's AK401 description. Optional; only appears on repeating-element errors.
  - `AK203` (1705) length 1/35 — 5010-style implementation-convention reference; optional.
  - Element **max-lengths** (e.g., AK102 N0 1/9, AK302 1/6) follow the standard X12 dictionary; if a
    partner implementation guide tightens these, adjust. Non-blocking for the accept-path demo.

---

## D-997-6: Receive-side map (XSLT) — needed? (item 4)

**Two separable questions:**

1. **997 generation → NO map needed.** Whether via Decode auto-gen (Option 1) or Encode (Option 2),
   the 997 is produced from Decode metadata, not an XSLT transform. If Option 2 is chosen, the 997
   XML is built with Logic Apps expressions/compose (AK102←GS06, AK202←ST02, counts from the Decode
   result), not an `.xslt`. **No new map for the acknowledgment.**

2. **Persisting the decoded 850 → supplier SQL (optional, if the epic persists the inbound PO).**
   If the supplier stores the received order (mirroring the purchaser's canonical), a map is needed:
   **source = decoded X12 850 XML** (root `X12_00603_850`, the Decode output) → **target = supplier
   canonical PO XML/JSON** matching the purchaser's SQL shape. Confirmed against
   `infra/sql/schema/010-tables.sql`: `dbo.[Address]`, `dbo.PurchaseOrder`, `dbo.PurchaseOrderLine`,
   upsert proc `dbo.usp_UpsertPurchaseOrder` (OPENJSON `@LinesJson`). Proposed map:
   **`X12_850_006030_to_PO_Canonical.xslt`** (the inverse of the purchaser's
   `PO_Canonical_to_X12_850_006030.xslt`). Table-level source→target:

   | 850 segment/elem | Canonical / SQL target |
   |------------------|------------------------|
   | BEG03 | `poNumber` → `PurchaseOrder.PoNumber` |
   | BEG05 (CCYYMMDD) | `orderDate` → `PurchaseOrder.OrderDate` (reformat to `YYYY-MM-DD`) |
   | DTM(002) | `requestedDeliveryDate` → `PurchaseOrder.RequestedDeliveryDate` |
   | REF(CO) | `buyer.id` → `PurchaseOrder.BuyerId` |
   | N1Loop1 (ST) N1/N3/N4 | `shipTo.*` → `dbo.[Address]` (ShipTo) |
   | N1Loop1 (BT) N1/N3/N4 | `billTo.*` → `dbo.[Address]` (BillTo) |
   | PO1Loop1 PO1 (01/02/03/04/07) | `lines[].lineNumber/quantity/uom/unitPrice/sku` → `PurchaseOrderLine` |
   | PO1Loop1 PID(F,05) | `lines[].description` → `PurchaseOrderLine.Description` |
   | CTTLoop1 CTT01/02 | validation only (count/hash), not persisted |

   **This is scoped but NOT built this task** — it's only required if the epic persists the inbound
   850. **OPEN: does the supplier persist the received PO, or only ACK-and-forward?** (Mal to
   confirm the epic scope.) If persist: Wash invokes the map + `dbo.usp_UpsertPurchaseOrder`, Kaylee
   registers the supplier SQL (mirror of the purchaser DDL). If ACK-only: skip map + SQL entirely.

---

## Assumptions & open questions (for Mal / coordinator)

1. **[BLOCKING-ish] 997 version mechanism (D-997-4):** Decode auto-gen = **4010**; Encode = true
   **006030**. Spec assumes **Option 2 / 006030**. Confirm before Kaylee binds envelope versions,
   else the supplier send (`006030`) and purchaser receive agreements will mismatch the actual wire
   version.
2. **GS01 = `FA` for the 997** (not `PO`). Send agreement `functionalGroupId` must be `FA`.
3. **Agreement naming** proposed host-first (`Supplier-Purchaser-X12-850/997`,
   `Purchaser-Supplier-X12-997`) to disambiguate direction from the existing `Purchaser-Supplier-X12`
   (the 850 send). Coordinator/Scribe: confirm the naming convention is acceptable or normalize.
4. **Supplier persistence scope (D-997-6):** persist inbound 850 to supplier SQL, or ACK-only?
   Drives whether the `X12_850_006030_to_PO_Canonical.xslt` map + supplier SQL are in scope.
5. **AK2 for accepted sets:** default Logic Apps emits AK2 loops only for *rejected* sets. If the
   purchaser wants an AK2/AK5 line per accepted 850, set receive-agreement `needLoopForValidMessages:
   true` (a.k.a. "Include AK2 / IK2 loop"). Spec's happy-path sample assumes AK2 present for the
   accepted set.
6. **850 schema on supplier IA:** the 2.15 MB `X12_00603_850.xsd` must be registered on the
   **supplier** IA too (via REST `contentLink`, same as purchaser) before the receive agreement
   resolves it. Kaylee: replicate the deploy.yml contentLink step for the supplier IA.
7. **Flagged 997 elements** (`AK401.3`/`C03003`, `AK203`, some max-lengths) are modelled from MS
   Learn + the standard X12 dictionary, not a partner 006030 implementation guide. Accept-path is
   fully verified; tighten if a partner IG says otherwise.

---

### Sample 997 (non-sensitive, accepted single 850) — for Jayne's expected output

```
ISA*00*          *00*          *ZZ*SUPPLIER01     *ZZ*PURCHASER01    *<date>*<time>*U*00603*000000001*0*T*>~
GS*FA*SUPPLIER01*PURCHASER01*<CCYYMMDD>*<HHMM>*000000001*X*006030~
ST*997*0001~
AK1*PO*000000012*006030~           (AK102 = received 850 GS06)
AK2*850*000012345~                 (AK202 = received 850 ST02)
AK5*A~
AK9*A*1*1*1~
SE*6*0001~
GE*1*000000001~
IEA*1*000000001~
```
*(ISA13/GS06/ST02 = 997's own agreement-generated numbers; AK102/AK202 = echoes of the received
850's control numbers. Delimiters `*` `>` `~` per the 850 framing.)*
