# Trading Partner Onboarding Guide

> **Status — purchaser send side:** IMPLEMENTED and live-verified (`feature/purchaser-po-to-as2-850-workflow` — **do not merge**, owner directive).
> **Status — supplier receive + 997 return side (this epic):** AUTHORED on branch `feature/supplier-inbound-997-workflow`; not yet deployed or live-verified.
> **Authoritative designs:** [`docs/purchaser-workflow-epic-design.md`](purchaser-workflow-epic-design.md) §5 (send side); [`docs/supplier-workflow-epic-design.md`](supplier-workflow-epic-design.md) §3–§4 (receive side).
> **Runbooks:** [`docs/purchaser-workflow-runbook.md`](purchaser-workflow-runbook.md) · [`docs/supplier-workflow-runbook.md`](supplier-workflow-runbook.md).

This guide documents the concrete trading-partner and agreement configuration built into both the
**purchaser** and **supplier** Integration Accounts. The configuration is authored as
Infrastructure-as-Code (`infra/integration-account/ia-content.bicep` for the purchaser IA;
`infra/integration-account/ia-content-supplier.bicep` for the supplier IA) and deployed by CI.

**What is configured, send epic:** the **send** side (Purchaser → Supplier), an AS2 send agreement
and an X12 (006030 / 850) send agreement, both on the **purchaser** Integration Account. Live-verified.

**What is configured, receive/997 epic (authored, pending deploy):** the **supplier** Integration Account
(new — partners, AS2 receive+send agreements, X12 850-receive + 997-send agreements, and all 4 leaf certs);
and extensions to the **purchaser** IA (997 receive agreement, AS2 receive activation). See §§10–13.

---

## 1. Mechanism — linked Integration Account, built-in EDI operations

Logic Apps **Standard** exposes **AS2 (v2)** and **X12** as built-in service-provider operations that
need **no** `Microsoft.Web/connections` — consistent with the repo's managed-identity-only,
built-in-connectors-only posture. They require the app to be **linked** to an Integration Account that
holds the partners, agreements, schema, and certificates. Linking on Standard is one app setting:

```
WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL = <IA callback URL>   (Key Vault reference; SAS-signed = secret)
```

Each app uses its own **per-app Free Integration Account in its own region** (purchaser IA in East US 2,
supplier IA in Central US), which satisfies the same-subscription + same-region requirement for
IA↔app linking. Partners, the AS2/X12 send agreements, and the 850 schema live on the **purchaser** IA;
the XSLT map ships with the app (`Artifacts/Maps`), not the IA.

---

## 2. Trading partners

Two partners are registered on the purchaser Integration Account
(`infra/integration-account/ia-content.bicep`), each with a single **ZZ** X12 business identity:

| Partner | IA partner name | Role | X12 business identity (qualifier / value) | AS2 identity |
|---------|-----------------|------|-------------------------------------------|--------------|
| **Purchaser** (host / self) | `Purchaser` | Sender | `ZZ` / `PURCHASER01` | AS2-From: `PURCHASER01` |
| **Supplier** (guest) | `Supplier` | Receiver | `ZZ` / `SUPPLIER01` | AS2-To: `SUPPLIER01` |

Bicep partner definition (as deployed):

```bicep
resource partnerPurchaser 'Microsoft.Logic/integrationAccounts/partners@2019-05-01' = {
  parent: integrationAccount
  name: 'Purchaser'
  properties: {
    partnerType: 'B2B'
    content: { b2b: { businessIdentities: [ { qualifier: 'ZZ', value: 'PURCHASER01' } ] } }
  }
}
```

The AS2 identities (`PURCHASER01` / `SUPPLIER01`) are the `as2From` / `as2To` values used by the
purchaser workflow's `Encode_to_AS2` action, which resolves the AS2 send agreement from these identities.

---

## 3. AS2 certificate configuration

Four AS2 leaf certificates (plus the Demo Root CA) are published to Key Vault out of band by
`infra/scripts/generate-certificates.ps1` — see
[`docs/deployment-guide.md` — Section 4](deployment-guide.md#4-post-deployment-generate-and-publish-certificates).
This epic's **send** agreement binds two of them as IA certificate artifacts:

| IA certificate artifact | IA artifact name | Type | Source | Used for |
|-------------------------|------------------|------|--------|----------|
| Purchaser signing | `purchaser-signing` | **Private** | References the Key Vault **key** `demo-as2-purchaser-signing` (latest version) — the private key is **not** embedded | Signing outbound AS2 messages (SHA-256). |
| Supplier encryption | `supplier-encryption` | **Public** | Base64 public cert body of `demo-as2-supplier-encryption`, read from Key Vault by CI at deploy time | Encrypting outbound AS2 messages (AES-256). |

`demo-as2-purchaser-encryption` and `demo-as2-supplier-signing` were **reserved for the receive side**
in the send epic. **This epic binds all four leaf certs** — see §11 for the full receive-side cert binding
table across both IAs.

**Private-certificate Key Vault access (R2).** Because `purchaser-signing` references a Key Vault key,
the identity that reads it is the Azure Logic Apps **first-party service principal** (well-known app ID
`7cd684f4-8a78-49b0-91ec-6a35d38739ba`), **not** the Integration Account's managed identity. It is
granted **Key Vault Crypto User** + **Key Vault Secrets User** on the shared vault by
`infra/rbac/role-assignments.bicep` (param `logicAppsServicePrincipalObjectId`, resolved in CI). See
the runbook §9 (R2).

The IA certificate artifact for the private cert, as deployed:

```bicep
resource purchaserSigningCert 'Microsoft.Logic/integrationAccounts/certificates@2019-05-01' = {
  parent: integrationAccount
  name: 'purchaser-signing'
  properties: {
    key: { keyName: 'demo-as2-purchaser-signing', keyVault: { id: <shared Key Vault resource ID> } }
  }
}
```

---

## 4. AS2 send agreement (Purchaser → Supplier)

- **IA artifact name:** `Purchaser-Supplier-AS2` (on the purchaser IA).
- **Direction:** send; host = Purchaser, guest = Supplier.
- **Sign:** enabled, SHA-256, using the purchaser signing private cert.
- **Encrypt:** enabled, AES-256, using the supplier encryption public cert.
- **MDN:** Request MDN = yes, Request signed MDN = yes, **synchronous** (no async MDN URL). **Non-fatal**
  — settlement does not gate on the MDN; a missing/negative MDN is recorded as a tracked property only.
- **Packaging:** the AS2 Encode action emits the signed + encrypted payload plus AS2 headers; the
  workflow then HTTP POSTs it to the supplier callback URL.

The purchaser workflow's `Encode_to_AS2` action supplies `as2From: PURCHASER01` / `as2To: SUPPLIER01`;
the built-in AS2 operation resolves this agreement from the linked IA by those identities.

---

## 5. X12 send agreement (Purchaser → Supplier)

- **IA artifact name:** `Purchaser-Supplier-X12` (on the purchaser IA). This value **must equal** the
  purchaser app setting `X12AgreementName`, which the workflow reads via
  `@appsetting('X12AgreementName')` for the `Encode_to_X12_850` action's `agreementName`.
- **Direction:** send; **version 006030**, transaction set **850**.
- **Schema:** references the IA schema artifact `X12_00603_850` (registered via `contentLink`, §6).
- **Envelope (per design §4.1):** `ZZ` sender/receiver ID qualifiers; interchange sender ID
  `PURCHASER01`, receiver ID `SUPPLIER01`; interchange control version `00603`; usage indicator
  **`T`** (test); component separator `>`; data element separator `*`; segment terminator `~`.
- **Control numbers:** generated by the agreement (it owns the interchange / group / set counters); the
  workflow does not hand-roll control numbers.

---

## 6. X12 850 schema (006030)

| | |
|---|---|
| **File** | `infra/integration-account/schemas/X12_00603_850.xsd` |
| **Root** | `X12_00603_850` (`standards_version="00603"`) |
| **Size** | ~2.15 MB (Microsoft's official 006030 850 schema) |
| **IA artifact name** | `X12_00603_850` |
| **Registration** | Via **`contentLink`** (blob SAS URL), **not** inline `content` |

Because the schema is 2.15 MB it exceeds the inline `content` limit for
`Microsoft.Logic/integrationAccounts/schemas`, and the ARM/Bicep schema resource exposes no writable
`contentLink`. CI therefore registers it out of band (`deploy.yml` step *Register X12 schema via REST
contentLink*): upload the xsd to the purchaser storage account (`ia-artifacts` container), mint a
short-lived read SAS, and `PUT` the schema resource via the Logic REST API with
`properties.contentLink.uri` set to the blob SAS URL. The X12 send agreement resolves the schema **by
name** (`X12_00603_850`), so this step runs **before** the IA-content deployment.

The **canonical** PO schema (`logicapps/purchaser/Artifacts/Schemas/PurchaseOrder_Canonical.xsd`) and
the XSLT map (`logicapps/purchaser/Artifacts/Maps/PO_Canonical_to_X12_850_006030.xslt`) are small and
ship with the app project — they are **not** IA artifacts.

---

## 7. Deploy ordering summary

The IA content is deployed by CI in this order:

**Send-side (purchaser IA — live):**

1. Grant the Logic Apps first-party SP Key Vault Crypto User + Secrets User (Bicep RBAC).
2. AS2 certificates already in Key Vault (out-of-band prerequisite — §3).
3. Register the `X12_00603_850` schema on the purchaser IA via `contentLink` (§6).
4. Deploy `ia-content.bicep`: partners → certificate artifacts → X12 + AS2 send agreements.
5. Link the purchaser app to the IA (`WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL`).
6. Deploy supplier `supplier-inbound-ack` and purchaser `purchaser-po-to-as2`.

**Receive-side additions (authored, pending deploy) — appended after step 6:**

7. Run `infra/sql/schema/030-sup-tables.sql` + `040-usp-upsert-supplier.sql` on the shared SQL server (§13).
8. Register `X12_00603_850` on the **supplier** IA via REST `contentLink` (mirror of step 3).
9. Register `X12_00603_997` on **both** IAs (inline Bicep — 31 KB, fits under the 2 MB limit).
10. Deploy `ia-content-supplier.bicep`: supplier IA partners, cert artifacts (all 4 leaf certs on supplier IA), X12 and AS2 agreements.
11. Extend `ia-content.bicep` (purchaser IA): add `Purchaser-Supplier-X12-997` receive agreement; activate AS2 receive block on `Purchaser-Supplier-AS2` with receive-side certs.
12. Link the supplier app to the supplier IA (`WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL`).
13. Deploy **both** workflows (`supplier-inbound-ack` full pipeline + `purchaser-inbound-997`).
14. Read **both** trigger callback URLs (`manual` on each workflow).
15. Write **both** KV secrets (`supplier-as2-endpoint-url`, `purchaser-997-endpoint-url`).
16. Set **both** app settings and restart **both** apps. (No interleaving — both secrets are written before either app is restarted. See §12 for the deadlock explanation.)

**Graceful guards:** `ediReady` flag gates the purchaser send content + supplier-AS2 injection. `supplierEdiReady` (all 4 leaf certs present) gates the supplier IA content, purchaser AS2 receive activation, and 997 injection. An infra-only run (before cert-gen) stays green in both cases.

---

## 8. Verification

After a full EDI deploy, confirm the purchaser IA content exists:

```powershell
# Partners on the purchaser Integration Account
az resource list `
  --resource-group rg-edi-purchaser `
  --resource-type Microsoft.Logic/integrationAccounts/partners `
  -o table

# Agreements (expect Purchaser-Supplier-AS2, Purchaser-Supplier-X12, Purchaser-Supplier-X12-997)
az resource list `
  --resource-group rg-edi-purchaser `
  --resource-type Microsoft.Logic/integrationAccounts/agreements `
  -o table
```

Confirm the purchaser app setting matches the X12 send agreement name:

```powershell
az functionapp config appsettings list `
  --resource-group rg-edi-purchaser `
  --name <purchaser Logic App name> `
  --query "[?name=='X12AgreementName'].value" -o tsv
# Expected: Purchaser-Supplier-X12
```

After the receive-side deploy, confirm the supplier IA content:

```powershell
# Supplier IA agreements (expect Supplier-Purchaser-X12-850, Supplier-Purchaser-X12-997, Supplier-Purchaser-AS2)
az resource list `
  --resource-group rg-edi-supplier `
  --resource-type Microsoft.Logic/integrationAccounts/agreements `
  -o table

# Supplier app settings — X12SendAgreementName and Purchaser997EndpointUrl
az functionapp config appsettings list `
  --resource-group rg-edi-supplier `
  --name <supplier Logic App name> `
  --query "[?name=='X12SendAgreementName' || name=='Purchaser997EndpointUrl'].{name:name,value:value}" -o table
# Expected: X12SendAgreementName = Supplier-Purchaser-X12-997
#           Purchaser997EndpointUrl = @Microsoft.KeyVault(VaultName=...) [resolves to SAS URL]
```

---

## 9. Onboarding a new partner (extending this configuration)

To add another trading partner (e.g. a second supplier), follow the same IaC pattern rather than
portal steps:

1. **Publish certificates** for the new partner to Key Vault (extend `generate-certificates.ps1` or
   import existing public certs).
2. **Add a partner** resource in `infra/integration-account/ia-content.bicep` with the partner's `ZZ`
   business identity.
3. **Add certificate artifacts** — public encryption cert (uploaded) and, if you also sign for a new
   host, a private signing cert (Key Vault key reference + first-party SP RBAC).
4. **Add AS2 + X12 send/receive agreements** binding the partners, schema, and certs.
5. **Wire app settings** if the workflow must select the agreement by name (as `X12AgreementName` does).
6. **Extend the workflow** (`as2From`/`as2To`, agreement name) to route to the new partner.

---

## 10. Supplier Integration Account — trading partners (this epic, authored)

> Configuration file: `infra/integration-account/ia-content-supplier.bicep` · IA region: Central US (same region as supplier app in `rg-edi-supplier`) · IA tier: Free.

The supplier IA uses the **same two partner artifacts** as the purchaser IA, mirrored — both parties must exist on whichever IA hosts an agreement:

| Partner | IA partner name | Role | X12 business identity | AS2 identity |
|---------|-----------------|------|----------------------|--------------|
| **Supplier** (host / self) | `Supplier` | Host | `ZZ` / `SUPPLIER01` | AS2-From: `SUPPLIER01` |
| **Purchaser** (guest) | `Purchaser` | Guest | `ZZ` / `PURCHASER01` | AS2-To: `PURCHASER01` |

---

## 11. Certificate binding — all four leaf certs (this epic, authored)

All four leaf certs from Key Vault are now active. The rule: **each private cert lives on its owning party's IA; only the public cert is shared to the counterparty's IA.** Private IA certificate artifacts carry the public cert body **plus** a Key Vault key reference (same shape as the live `purchaserSigningCert` in `ia-content.bicep`).

| Function | Cert (KV) | Form | IA artifact lives on | KV mechanism |
|----------|-----------|------|----------------------|--------------|
| Supplier **decrypt** inbound 850 | `demo-as2-supplier-encryption` | **PRIVATE** | Supplier IA | KV key reference |
| Supplier **verify** purchaser sig on 850 | `demo-as2-purchaser-signing` | **PUBLIC** | Supplier IA | base64 public cert body |
| Supplier **sign MDN** + **sign** outbound 997 | `demo-as2-supplier-signing` | **PRIVATE** | Supplier IA | KV key reference |
| Supplier **encrypt** outbound 997 | `demo-as2-purchaser-encryption` | **PUBLIC** | Supplier IA | base64 public cert body |
| Purchaser **decrypt** inbound 997 | `demo-as2-purchaser-encryption` | **PRIVATE** | Purchaser IA | KV key reference (was reserved; now active) |
| Purchaser **verify** supplier sig on 997+MDN | `demo-as2-supplier-signing` | **PUBLIC** | Purchaser IA | base64 public cert body (was reserved; now active) |

**Note:** `demo-as2-purchaser-encryption` appears as PRIVATE on the purchaser IA (for decryption) and as PUBLIC on the supplier IA (for encryption of the outbound 997). This is correct PKI — the private key never leaves its owner.

All three new private-key KV references resolve through the existing Azure Logic Apps first-party SP (`7cd684f4-8a78-49b0-91ec-6a35d38739ba`), which holds Key Vault Crypto User + Secrets User on the shared vault. **No new RBAC edge is required** (Kaylee D-K7; Zoe to confirm vault-scoped grant covers all new keys at deploy).

---

## 12. Supplier IA agreements (this epic, authored)

> ⚠️ **Design note:** Mal's design (`supplier-workflow-epic-design.md §3.1`) modelled one bidirectional X12 agreement per IA (`Supplier-Purchaser-X12`). The **coordinator build-lock** (`squad-supplier-build-locks.md`) and the **actual build** (Kaylee, Wash) use **two separate X12 agreements** per the locked names below. The design doc is stale relative to the build artifact. Flagged for Mal/Scribe.

### Supplier IA — X12 850 receive agreement

| | |
|---|---|
| **IA artifact name** | `Supplier-Purchaser-X12-850` |
| **Direction** | Receive (host = Supplier, guest = Purchaser) |
| **Schema** | `X12_00603_850` (registered on supplier IA via REST `contentLink` — 2.15 MB, same mechanism as purchaser IA) |
| **Identities** | `receiveAgreement.senderBusinessIdentity` = `ZZ`/`PURCHASER01`; receiver = `ZZ`/`SUPPLIER01` |
| **Envelope** | `controlVersionNumber: '00603'`, `functionalGroupId: 'PO'`, `usageIndicator: 'Test'`, `ZZ` qualifiers |
| **Validation** | Duplicate-detection enabled (`checkDuplicateInterchangeControlNumber: true`, 30-day window); `validateEDITypes: true`; `validateXSDTypes: false`; `trailingSeparatorPolicy: 'NotAllowed'` |
| **Auto-resolve** | Built-in X12 Decode resolves this agreement automatically from ISA/GS identities — no `agreementName` param on the Decode action. The app setting `X12ReceiveAgreementName` (also set by Kaylee) is **redundant at runtime** (Wash review-gate §1). |

### Supplier IA — X12 997 send agreement

| | |
|---|---|
| **IA artifact name** | `Supplier-Purchaser-X12-997` |
| **Direction** | Send (host = Supplier, guest = Purchaser) |
| **Schema** | `X12_00603_997` (registered inline via `loadTextContent` — 31 KB, fits Bicep 2 MB limit) |
| **Identities** | `sendAgreement.senderBusinessIdentity` = `ZZ`/`SUPPLIER01`; receiver = `ZZ`/`PURCHASER01` |
| **Envelope** | `controlVersionNumber: '00603'`, **`functionalGroupId: 'FA'`** (Functional Acknowledgment), `usageIndicator: 'Test'`, `ZZ` qualifiers, `senderApplicationId: 'SUPPLIER01'`, `receiverApplicationId: 'PURCHASER01'` |
| **Control numbers** | Agreement-generated; rollover enabled. These are the 997's **own** ISA13/GS06/ST02 — independent of the AK102/AK202 echo values copied from the received 850. |
| **App setting** | `X12SendAgreementName = Supplier-Purchaser-X12-997` (the supplier workflow's `Encode_997_to_X12` action references this via `@appsetting('X12SendAgreementName')`). |

### Supplier IA — AS2 agreement (receive + send)

| | |
|---|---|
| **IA artifact name** | `Supplier-Purchaser-AS2` |
| **Receive block** | Decrypt with `supplier-encryption` PRIVATE; verify sig with `purchaser-signing` PUBLIC; return signed sync MDN (`overrideGroupSigningCertificate: true`). |
| **Send block** | Sign with `supplier-signing` PRIVATE; encrypt with `purchaser-encryption` PUBLIC; request sync MDN from purchaser. |
| **MDN semantics** | Non-fatal on both legs. A missing/negative MDN is recorded as a tracked property; it does not block the 997 transmission. |

---

## 13. Purchaser IA additions (this epic, authored)

Two changes to the existing purchaser IA (`infra/integration-account/ia-content.bicep`):

### Purchaser IA — new X12 997 receive agreement

| | |
|---|---|
| **IA artifact name** | `Purchaser-Supplier-X12-997` |
| **Direction** | Receive (host = Purchaser, guest = Supplier) |
| **Schema** | `X12_00603_997` (registered inline on purchaser IA — same xsd, inline on both IAs) |
| **Identities** | `receiveAgreement.senderBusinessIdentity` = `ZZ`/`SUPPLIER01`; receiver = `ZZ`/`PURCHASER01` |
| **Envelope** | `controlVersionNumber: '00603'`, `functionalGroupId: 'FA'`, `usageIndicator: 'Test'` |
| **Auto-resolve** | Built-in X12 Decode in `purchaser-inbound-997` resolves this agreement automatically from ISA/GS identities. No `agreementName` app setting needed on the purchaser side. |
| **Ack** | `needFunctionalAcknowledgement: false` — you do not ACK an ACK. |

### Purchaser IA — AS2 receive activation

The existing `Purchaser-Supplier-AS2` agreement already carries a receive block (with encryption/signing disabled). This epic activates it by binding the receive-side certs:

| Setting | Value |
|---------|-------|
| `receiveAgreement.securitySettings.encryptionCertificateName` | `purchaser-encryption` (PRIVATE — decrypt inbound 997) |
| `receiveAgreement.securitySettings.signingCertificateName` | `supplier-signing` (PUBLIC — verify supplier sig) |
| `receiveAgreement.securitySettings.encryptMessage` | `true` |
| `receiveAgreement.securitySettings.signMessage` | `true` |

---

## 14. SQL mirror tables and SupplierRole (this epic, authored)

> Files: `infra/sql/schema/030-sup-tables.sql`, `infra/sql/schema/040-usp-upsert-supplier.sql`.

The supplier persists inbound POs into its **own schema**, isolated from the purchaser's `dbo` tables:

| Object | Schema | Mirrors | Notes |
|--------|--------|---------|-------|
| `sup.PurchaseOrder` | `sup` | `dbo.PurchaseOrder` | Same columns/types; idempotent on `PoNumber`. |
| `sup.Address` | `sup` | `dbo.Address` | Same columns/types. |
| `sup.PurchaseOrderLine` | `sup` | `dbo.PurchaseOrderLine` | Same columns/types. |
| `sup.usp_UpsertPurchaseOrder` | `sup` | `dbo.usp_UpsertPurchaseOrder` | Same `@LinesJson` OPENJSON contract; idempotent on `PoNumber`. |

**`SupplierRole`** — granted INSERT + EXECUTE on `SCHEMA::sup` only (not `dbo`). The supplier UAMI is a member. This role is defined in `infra/sql/create-users-roles.sql` and was created before the `sup` DDL; both scripts are idempotent so ordering is safe.

The four field gaps in the decoded 850 (currency, buyerName, sellerId, sellerName) are covered by documented fallbacks in the XSLT map (`X12_850_006030_to_PO_Canonical.xslt`): `currency=USD`, `buyerName`=buyer-id proxy, `sellerId`=GS03 from 850 envelope, `sellerName=SUPPLIER01`. All `NOT NULL` columns are satisfied without schema relaxation. See [`docs/supplier-workflow-runbook.md`](supplier-workflow-runbook.md) §Known flags.

---

## References

- [Azure Logic Apps Standard — enterprise integration / EDI](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-overview)
- [AS2 (v2) in Logic Apps](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-as2)
- [X12 in Logic Apps](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-x12)
- [Add certificates to secure B2B messages](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-certificates)
- [Integration Accounts](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-create-integration-account)
