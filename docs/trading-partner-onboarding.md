# Trading Partner Onboarding Guide

> **Status:** IMPLEMENTED (purchaser → supplier **send** side, this epic)
> **Branch:** `feature/purchaser-po-to-as2-850-workflow` — **do not merge** (owner directive).
> **Authoritative design:** [`docs/purchaser-workflow-epic-design.md`](purchaser-workflow-epic-design.md) §5.
> **Runbook:** [`docs/purchaser-workflow-runbook.md`](purchaser-workflow-runbook.md).

This guide documents the concrete trading-partner and agreement configuration that the epic builds
into the **purchaser** Integration Account. It replaces the earlier placeholder. The configuration is
authored as Infrastructure-as-Code (`infra/integration-account/ia-content.bicep`) and deployed by CI —
you do not click through the portal for the demo — but the settings are documented here so an operator
can understand, verify, or extend them.

**What is configured this epic:** the **send** side only (Purchaser → Supplier), an AS2 send agreement
and an X12 (006030 / 850) send agreement, both on the **purchaser** Integration Account. The receive
side (inbound 850, MDN verify/decrypt) is future work.

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

`demo-as2-purchaser-encryption` and `demo-as2-supplier-signing` are **reserved for the future receive
side** (MDN verify / decrypt) and are not bound this epic.

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

The IA content is deployed by CI in this order (see the runbook §3 for the full pipeline):

1. Grant the Logic Apps first-party SP Key Vault Crypto User + Secrets User (Bicep RBAC).
2. AS2 certificates already in Key Vault (out-of-band prerequisite — §3).
3. Register the `X12_00603_850` schema via `contentLink` (§6).
4. Deploy `ia-content.bicep`: partners → certificate artifacts → X12 + AS2 send agreements.
5. Link the app to the IA (`WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL`).
6. Deploy the supplier workflow, then inject its callback URL, then deploy the purchaser workflow.

**Graceful guard:** if the supplier encryption public cert is not yet in Key Vault, the IA-content step
and all downstream EDI steps are skipped so an infra-only run stays green (runbook §4, R1).

---

## 8. Verification

After a full EDI deploy, confirm the IA content exists:

```powershell
# Partners on the purchaser Integration Account
az resource list `
  --resource-group rg-edi-purchaser `
  --resource-type Microsoft.Logic/integrationAccounts/partners `
  -o table

# Agreements (expect Purchaser-Supplier-AS2 and Purchaser-Supplier-X12)
az resource list `
  --resource-group rg-edi-purchaser `
  --resource-type Microsoft.Logic/integrationAccounts/agreements `
  -o table
```

Confirm the purchaser app setting matches the X12 agreement name:

```powershell
az functionapp config appsettings list `
  --resource-group rg-edi-purchaser `
  --name <purchaser Logic App name> `
  --query "[?name=='X12AgreementName'].value" -o tsv
# Expected: Purchaser-Supplier-X12
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

## References

- [Azure Logic Apps Standard — enterprise integration / EDI](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-overview)
- [AS2 (v2) in Logic Apps](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-as2)
- [X12 in Logic Apps](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-x12)
- [Add certificates to secure B2B messages](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-certificates)
- [Integration Accounts](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-create-integration-account)
