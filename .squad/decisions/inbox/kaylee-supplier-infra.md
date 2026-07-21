# Kaylee — Supplier-inbound + 997 infra (Bicep, SQL, app settings, CI)

> **Author:** Kaylee (Infra / DevOps) · **Branch:** `feature/supplier-inbound-997-workflow`
> **Scope:** IaC + SQL + CI for the supplier-inbound 850 receive + 997 return epic.
> **For the Scribe to merge into `.squad/decisions.md`. Do NOT edit `decisions.md` directly.**
>
> Built to the LOCKED build-wave contract (`.squad/decisions/inbox/squad-supplier-build-locks.md`),
> Mal's design (`docs/supplier-workflow-epic-design.md`), and Simon's EDI spec
> (`.squad/decisions/inbox/simon-997-receive.md`). Bound to the LOCKED names — no renames.

---

## Files changed

- **NEW** `infra/integration-account/ia-content-supplier.bicep` — supplier IA content module.
- `infra/integration-account/ia-content.bicep` — extended (purchaser IA receive-side additions).
- **NEW** `infra/sql/schema/030-sup-tables.sql` — `sup` schema mirror tables.
- **NEW** `infra/sql/schema/040-usp-upsert-supplier.sql` — `sup.usp_UpsertPurchaseOrder`.
- `infra/sql/create-users-roles.sql` — `SupplierRole` INSERT + EXECUTE on `SCHEMA::sup`.
- `infra/compute/logicapp-bundle.bicep` — supplier app settings (`Purchaser997EndpointUrl`,
  `X12ReceiveAgreementName`, `X12SendAgreementName`).
- `infra/main.bicep` — wired supplier compute EDI settings + new secret/agreement-name vars + outputs.
- `.github/workflows/deploy.yml` — supplier 850 contentLink, supplier IA content deploy, purchaser
  receive-side cert activation, supplier IA callback publish, supplier `sup` SQL DDL, and the
  non-interleaved dual callback-URL injection.

---

## Decisions (What / Why)

### D-K1: Supplier IA content is a SEPARATE Bicep module, not a branch of `ia-content.bicep`
- **What:** The supplier IA content lives in a new `ia-content-supplier.bicep`; the existing
  `ia-content.bicep` was extended only for the purchaser-IA additions.
- **Why:** A `Microsoft.Logic/integrationAccounts` content deployment is single-IA and RG-scoped.
  The supplier IA is in `rg-edi-supplier` (Central US); the purchaser IA is in `rg-edi-purchaser`
  (East US 2). They cannot share one template. Two modules mirror the existing one-IA-per-module
  boundary and let CI deploy each into its own RG. This is a module-organization choice within
  Kaylee's ownership — **no LOCKED name changed**. (The task text listed both IAs under "extend
  ia-content.bicep"; splitting is the only correct engineering shape. Flagged, not a deviation.)

### D-K2: 997 schema INLINE (Bicep `loadTextContent`), 850 via REST contentLink (both IAs)
- **What:** `X12_00603_997.xsd` (31 KB) is registered inline in both IA modules via
  `loadTextContent('schemas/X12_00603_997.xsd')`. `X12_00603_850.xsd` (2.15 MB) stays out-of-band
  via the Logic REST API `contentLink` — a new CI step registers it on the **supplier** IA
  (mirror of the existing purchaser step).
- **Why:** 31 KB is far under the 2 MB inline limit; inline keeps the 997 in source-controlled
  Bicep. The 850 exceeds the inline limit and ARM exposes no writable `contentLink`
  (decisions.md 2026-07-17), so REST is the only path.

### D-K3: AS2 receive-side cert binding (verified against Microsoft Learn)
- **What:** Per MS Learn *"Add certificates to secure B2B messages"* — Receive Settings: signing
  cert = **validate the partner's signature** (counterparty PUBLIC); encryption cert = **decrypt**
  (own PRIVATE). Send Settings: signing = sign outgoing (own PRIVATE); encryption = encrypt
  outgoing (counterparty PUBLIC). `overrideGroupSigningCertificate:true` makes the signing cert
  also sign the outbound **MDN** (BizTalk *"Configuring Signature Certificates (AS2)"*).
  Resulting bindings:
  - **Supplier IA `Supplier-Purchaser-AS2`** — receive: sign=`purchaser-signing` (public),
    enc=`supplier-encryption` (private); send: sign=`supplier-signing` (private),
    enc=`purchaser-encryption` (public).
  - **Purchaser IA `Purchaser-Supplier-AS2`** — receive activated: sign=`supplier-signing`
    (public), enc=`purchaser-encryption` (private). Send block unchanged (live 850).
- **Why:** Matches Mal's §4.1 binding table exactly. Private certs carry the public body + a KV key
  ref; public certs carry only the body.
- **FLAG (Wash + Mal):** the signed MDN on the *receive* leg. The receive block's signing cert is
  the partner PUBLIC cert (to validate), while Mal's table wants the MDN signed by the host's
  PRIVATE `*-signing`. Azure resolves the MDN signing cert from the host partner at runtime; the
  send-block override binds the host private signing cert. If a live run shows the MDN unsigned or
  signed with the wrong cert, the fix is a receive-block signing-cert swap — call it out in Wash's
  AS2-Decode verification.

### D-K4: Supplier persistence = supplier-owned `sup` schema (LOCKED #3)
- **What:** New `sup.[Address]` / `sup.PurchaseOrder` / `sup.PurchaseOrderLine` (dbo mirror shape)
  + `sup.usp_UpsertPurchaseOrder` (idempotent on PoNumber, OPENJSON-shredded `@LinesJson` — no
  TVP, per the locked SQL-connector constraint). `SupplierRole` granted INSERT + EXECUTE on
  `SCHEMA::sup`. DDL is idempotent (schema/`OBJECT_ID` guards; `CREATE OR ALTER` proc).
- **Why:** Clean trust boundary — the supplier never writes `dbo.PurchaseOrder`. The `sup` schema is
  created in BOTH `create-users-roles.sql` (so the grant resolves; that script runs before DDL) and
  `030-sup-tables.sql` (idempotent), so ordering is safe either way.

### D-K5: Supplier app settings (KV-referenced, managed identity only)
- **What:** Supplier app now gets `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL`
  (KV-ref → `supplier-ia-callback-url`), `Purchaser997EndpointUrl`
  (KV-ref → `purchaser-997-endpoint-url`), `X12ReceiveAgreementName`=`Supplier-Purchaser-X12-850`,
  `X12SendAgreementName`=`Supplier-Purchaser-X12-997`. SQL + Service Bus stay managed-identity
  (`connections.json` already had the SQL MI built-in connection — unchanged).
- **Why:** Mirrors the purchaser pattern. Clean setting names (no `__url`) per the earlier
  `SupplierAs2EndpointUrl` lesson. No secrets in source; every sensitive value is a KV reference
  resolved via the supplier UAMI.
- **FLAG (Wash):** the X12 agreement-name app-setting KEYS are `X12ReceiveAgreementName` /
  `X12SendAgreementName` (Simon D-997-3's proposed names, the EDI spec of record). The supplier
  workflow's X12 Decode (850) reads `@appsetting('X12ReceiveAgreementName')` and X12 Encode (997)
  reads `@appsetting('X12SendAgreementName')`. If Wash prefers different keys, say so — trivial to
  rename in `logicapp-bundle.bicep`.

### D-K6: Non-interleaved dual callback-URL injection (LOCKED #4 / design §5.2)
- **What:** `deploy.yml` deploys BOTH workflows, then in ONE post-deploy step: reads BOTH trigger
  callback URLs (`supplier-inbound-ack`/`manual` + `purchaser-inbound-997`/`manual`), writes BOTH
  KV secrets, then restarts BOTH apps. No deploy is interleaved between injections.
- **Why:** Breaks the circular dependency (supplier needs purchaser-997 URL; purchaser send needs
  supplier URL). `listCallbackUrl` depends only on the trigger existing, so decoupling deploy from
  inject cuts the cycle. The 850 (purchaser→supplier) half always runs; the 997 (supplier→purchaser)
  half runs only when the receive-side certs are present (`supplierEdiReady`).

### D-K7: No new RBAC edge (confirmed) — first-party SP grant is vault-scoped
- **What:** The 3 new private-key refs (`supplier-encryption`, `supplier-signing` on the supplier
  IA; `purchaser-encryption` on the purchaser IA) resolve through the existing Azure Logic Apps
  first-party SP (`7cd684f4-8a78-49b0-91ec-6a35d38739ba`) grant (KV Crypto User + Secrets User),
  which is scoped to the **whole shared vault** (`targetResourceId: keyVaultId` in
  `infra/rbac/role-assignments.bicep`), not per-secret. **No RBAC change made.**
- **Why:** Verified against the RBAC module — the guarded grant already covers every key in the
  vault. Zoe's build-time confirmation (design §4.2) holds.

### D-K8: Graceful cert-state guards (infra-only runs stay green)
- **What:** CI now sets two flags: `ediReady` (send-side certs present → purchaser send content +
  supplier-as2 injection) and `supplierEdiReady` (all 4 leaf certs present → supplier IA content +
  purchaser AS2 receive activation + 997 injection). The purchaser Bicep auto-computes
  `activateAs2Receive` from the two receive-cert params being non-empty.
- **Why:** Keeps infra-only deploys (before cert-gen) green, exactly like the existing `ediReady`
  guard, while making the receive side self-activate once the reserved certs land.

---

## Validation performed

- `az bicep build` (0.41.2) — PASS (exit 0) for `infra/main.bicep`,
  `infra/integration-account/ia-content.bicep`, `infra/integration-account/ia-content-supplier.bicep`,
  `infra/compute/logicapp-bundle.bicep` (997 xsd inline via `loadTextContent` compiles).
- `az bicep lint` — clean (no diagnostics) on all four modules.
- `deploy.yml` — parses as valid YAML (`yaml.safe_load`).
- SQL not executed here (no DB in this environment); `sup` DDL/proc mirror the proven `dbo`
  files' idempotency patterns.

## Blockers / hand-offs for Wash

1. Supplier X12 agreement-name app-setting keys = `X12ReceiveAgreementName` /
   `X12SendAgreementName` (D-K5 flag). Confirm the workflow reads these.
2. Receive-leg MDN signing cert nuance (D-K3 flag) — verify against the live AS2 Decode.
3. The purchaser `purchaser-inbound-997` workflow MUST ship in the purchaser app zip (already
   zipped as the whole `logicapps/purchaser` folder) so CI can read its `manual` trigger callback
   URL in the dual-injection step. Trigger name must be `manual` (LOCKED #5).
