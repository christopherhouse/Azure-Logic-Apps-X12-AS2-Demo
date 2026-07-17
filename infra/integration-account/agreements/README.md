# Integration Account — Partners & Agreements build spec

> **Author:** Simon (EDI Analyst) · **Source contract:** `docs/purchaser-workflow-epic-design.md` §4.1, §5.1–§5.5, §8
> **Consumer:** Kaylee (Bicep) — translate the JSON bodies below into
> `Microsoft.Logic/integrationAccounts/partners` and `.../agreements` resource `content` blocks.
> **Scope:** purchaser Integration Account (Free, East US 2). Send-only this epic.

This document gives the **concrete, build-ready** partner definitions and the **X12 send** + **AS2 send**
agreement settings. Where a value must be supplied at deploy time (cert artifact names, IA resource wiring),
it is flagged **`{{ … }}`** or called out in a **Kaylee** note. The JSON `content` bodies are shaped to the
ARM schema for `Microsoft.Logic/integrationAccounts` partners/agreements so they can be pasted almost verbatim.

---

## 0. Mechanism (recap of §5.1)

Logic Apps **Standard** uses **built-in AS2 (v2) + X12 service-provider operations** — **no
`Microsoft.Web/connections`**. The app is linked to this IA via the single app setting
`WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` (KV-referenced, SAS = secret). The IA holds **partners +
agreements + the 850 schema + certificates**. The XSLT map stays in the app `Artifacts/Maps` folder (§4.3).

IA↔app linking requires **same subscription + same region** — satisfied: purchaser app and purchaser IA are
both East US 2.

**Deploy ordering (from §8):** grant IA identity KV access (B0) → IA cert artifacts (B) → upload
`X12_00603_850.xsd` (C) → partners (D) → X12 + AS2 send agreements (E) → link app (F). **All IA content
precedes any workflow that references it.**

---

## 1. Trading partners (§5.2)

Two partners. The host (self) is **Purchaser**; the guest is **Supplier**. Both carry a single **B2B**
business identity with qualifier **`ZZ`** (locked #4).

| Partner name (IA artifact) | Role | X12 business identity | AS2 identity |
|----------------------------|------|-----------------------|--------------|
| `Purchaser` | host / self / sender | qualifier `ZZ`, value `PURCHASER01` | AS2-From `PURCHASER01` |
| `Supplier`  | guest / receiver     | qualifier `ZZ`, value `SUPPLIER01`  | AS2-To `SUPPLIER01`   |

> The AS2 identity value equals the X12 identity value here (both `PURCHASER01` / `SUPPLIER01`). The AS2-From /
> AS2-To HTTP headers are taken from the AS2 agreement's sender/receiver business identities (§2.2).

### 1.1 Partner content — `Purchaser`

`Microsoft.Logic/integrationAccounts/partners@2019-05-01`, name `Purchaser`:

```json
{
  "properties": {
    "partnerType": "B2B",
    "content": {
      "b2b": {
        "businessIdentities": [
          { "qualifier": "ZZ", "value": "PURCHASER01" }
        ]
      }
    }
  }
}
```

### 1.2 Partner content — `Supplier`

`Microsoft.Logic/integrationAccounts/partners@2019-05-01`, name `Supplier`:

```json
{
  "properties": {
    "partnerType": "B2B",
    "content": {
      "b2b": {
        "businessIdentities": [
          { "qualifier": "ZZ", "value": "SUPPLIER01" }
        ]
      }
    }
  }
}
```

---

## 2. Agreements

Both agreements are **send** agreements in the **purchaser** IA: **host = Purchaser**, **guest = Supplier**.
For a one-way *send* flow we only populate the `sendAgreement`; the `receiveAgreement` is a schema-required
mirror and is filled with a symmetric skeleton (the receive side — MDN verify/decrypt — is a future epic,
§5.5). Delimiters, envelope, and control-number strategy come from §4.1.

### 2.1 X12 send agreement — `Purchaser-Supplier-X12` (§5.4)

`Microsoft.Logic/integrationAccounts/agreements@2019-05-01`, `agreementType: "X12"`.

**Key settings (from §4.1):**

| Setting | Value |
|---------|-------|
| Version / release (GS08) | `006030` |
| Transaction set (ST01) | `850` |
| Schema name (IA artifact) | `X12_00603_850` |
| Sender/receiver ID qualifier (ISA05/07) | `ZZ` |
| Interchange sender ID (ISA06) | `PURCHASER01` (15-char, space-padded by encoder) |
| Interchange receiver ID (ISA08) | `SUPPLIER01` |
| Repetition separator (ISA11) | `U` |
| Interchange control version (ISA12) | `00603` |
| Usage indicator (ISA15) | `T` (Test) |
| Component element separator (ISA16) | `>` |
| Functional ID code (GS01) | `PO` |
| App sender / receiver code (GS02/03) | `PURCHASER01` / `SUPPLIER01` |
| Data element separator | `*` (ASCII 42) |
| Component separator | `>` (ASCII 62) |
| Segment terminator | `~` (ASCII 126) |
| TA1 requested (ISA14) | `0` (no) |
| Control numbers (ISA13 / GS06 / ST02) | **agreement-generated** — auto-increment counters owned by the agreement; the workflow/map do NOT set them |

**Content body** (send side fully specified; receive side is the required symmetric skeleton):

```json
{
  "properties": {
    "hostPartner": "Purchaser",
    "guestPartner": "Supplier",
    "hostIdentity":  { "qualifier": "ZZ", "value": "PURCHASER01" },
    "guestIdentity": { "qualifier": "ZZ", "value": "SUPPLIER01" },
    "agreementType": "X12",
    "content": {
      "x12": {
        "receiveAgreement": {
          "senderBusinessIdentity":   { "qualifier": "ZZ", "value": "SUPPLIER01" },
          "receiverBusinessIdentity": { "qualifier": "ZZ", "value": "PURCHASER01" },
          "protocolSettings": {
            "validationSettings": {
              "validateCharacterSet": true,
              "checkDuplicateInterchangeControlNumber": false,
              "interchangeControlNumberValidityDays": 30,
              "checkDuplicateGroupControlNumber": false,
              "checkDuplicateTransactionSetControlNumber": false,
              "validateEDITypes": true,
              "validateXSDTypes": false,
              "allowLeadingAndTrailingSpacesAndZeroes": false,
              "trimLeadingAndTrailingSpacesAndZeroes": false,
              "trailingSeparatorPolicy": "NotAllowed"
            },
            "framingSettings": {
              "dataElementSeparator": 42,
              "componentSeparator": 62,
              "replaceSeparatorsInPayload": false,
              "replaceCharacter": 36,
              "segmentTerminator": 126,
              "characterSet": "UTF8",
              "segmentTerminatorSuffix": "None"
            },
            "envelopeSettings": {
              "controlStandardsId": 85,
              "useControlStandardsIdAsRepetitionCharacter": false,
              "senderApplicationId": "SUPPLIER01",
              "receiverApplicationId": "PURCHASER01",
              "controlVersionNumber": "00603",
              "enableDefaultGroupHeaders": true,
              "functionalGroupId": "PO",
              "groupControlNumberLowerBound": 1,
              "groupControlNumberUpperBound": 999999999,
              "rolloverGroupControlNumber": true,
              "interchangeControlNumberLowerBound": 1,
              "interchangeControlNumberUpperBound": 999999999,
              "rolloverInterchangeControlNumber": true,
              "overwriteExistingTransactionSetControlNumber": true,
              "transactionSetControlNumberLowerBound": 1,
              "transactionSetControlNumberUpperBound": 999999999,
              "rolloverTransactionSetControlNumber": true,
              "usageIndicator": "Test",
              "useControlStandardsIdAsRepetitionCharacter": false
            },
            "acknowledgementSettings": {
              "needTechnicalAcknowledgement": false,
              "batchTechnicalAcknowledgements": false,
              "needFunctionalAcknowledgement": false,
              "batchFunctionalAcknowledgements": false,
              "needLoopForValidMessages": false,
              "sendSynchronousAcknowledgement": false,
              "acknowledgementControlNumberLowerBound": 1,
              "acknowledgementControlNumberUpperBound": 999999999,
              "rolloverAcknowledgementControlNumber": true
            },
            "messageFilter": { "messageFilterType": "Exclude" },
            "securitySettings": { "authorizationRequired": false, "passwordValue": "" },
            "processingSettings": {
              "maskSecurityInfo": true,
              "convertImpliedDecimal": true,
              "preserveInterchange": false,
              "suspendInterchangeOnError": false,
              "createEmptyXmlTagsForTrailingSeparators": false,
              "useDotAsDecimalSeparator": true
            },
            "schemaReferences": [
              {
                "messageId": "850",
                "senderApplicationId": "SUPPLIER01",
                "receiverApplicationId": "PURCHASER01",
                "schemaVersion": "00603",
                "schemaName": "X12_00603_850"
              }
            ],
            "envelopeOverrides": [],
            "validationOverrides": [],
            "messageFilterList": [],
            "x12DelimiterOverrides": []
          }
        },
        "sendAgreement": {
          "senderBusinessIdentity":   { "qualifier": "ZZ", "value": "PURCHASER01" },
          "receiverBusinessIdentity": { "qualifier": "ZZ", "value": "SUPPLIER01" },
          "protocolSettings": {
            "validationSettings": {
              "validateCharacterSet": true,
              "checkDuplicateInterchangeControlNumber": false,
              "interchangeControlNumberValidityDays": 30,
              "checkDuplicateGroupControlNumber": false,
              "checkDuplicateTransactionSetControlNumber": false,
              "validateEDITypes": true,
              "validateXSDTypes": false,
              "allowLeadingAndTrailingSpacesAndZeroes": false,
              "trimLeadingAndTrailingSpacesAndZeroes": false,
              "trailingSeparatorPolicy": "NotAllowed"
            },
            "framingSettings": {
              "dataElementSeparator": 42,
              "componentSeparator": 62,
              "replaceSeparatorsInPayload": false,
              "replaceCharacter": 36,
              "segmentTerminator": 126,
              "characterSet": "UTF8",
              "segmentTerminatorSuffix": "None"
            },
            "envelopeSettings": {
              "controlStandardsId": 85,
              "useControlStandardsIdAsRepetitionCharacter": false,
              "senderApplicationId": "PURCHASER01",
              "receiverApplicationId": "SUPPLIER01",
              "controlVersionNumber": "00603",
              "enableDefaultGroupHeaders": true,
              "functionalGroupId": "PO",
              "groupControlNumberLowerBound": 1,
              "groupControlNumberUpperBound": 999999999,
              "rolloverGroupControlNumber": true,
              "interchangeControlNumberLowerBound": 1,
              "interchangeControlNumberUpperBound": 999999999,
              "rolloverInterchangeControlNumber": true,
              "overwriteExistingTransactionSetControlNumber": true,
              "transactionSetControlNumberLowerBound": 1,
              "transactionSetControlNumberUpperBound": 999999999,
              "rolloverTransactionSetControlNumber": true,
              "usageIndicator": "Test"
            },
            "acknowledgementSettings": {
              "needTechnicalAcknowledgement": false,
              "batchTechnicalAcknowledgements": false,
              "needFunctionalAcknowledgement": false,
              "batchFunctionalAcknowledgements": false,
              "needLoopForValidMessages": false,
              "sendSynchronousAcknowledgement": false,
              "acknowledgementControlNumberLowerBound": 1,
              "acknowledgementControlNumberUpperBound": 999999999,
              "rolloverAcknowledgementControlNumber": true
            },
            "messageFilter": { "messageFilterType": "Exclude" },
            "securitySettings": { "authorizationRequired": false, "passwordValue": "" },
            "processingSettings": {
              "maskSecurityInfo": true,
              "convertImpliedDecimal": true,
              "preserveInterchange": false,
              "suspendInterchangeOnError": false,
              "createEmptyXmlTagsForTrailingSeparators": false,
              "useDotAsDecimalSeparator": true
            },
            "schemaReferences": [
              {
                "messageId": "850",
                "senderApplicationId": "PURCHASER01",
                "receiverApplicationId": "SUPPLIER01",
                "schemaVersion": "00603",
                "schemaName": "X12_00603_850"
              }
            ],
            "envelopeOverrides": [],
            "validationOverrides": [],
            "messageFilterList": [],
            "x12DelimiterOverrides": []
          }
        }
      }
    }
  }
}
```

**Kaylee notes (X12):**
- `dataElementSeparator: 42` = `*`, `componentSeparator: 62` = `>`, `segmentTerminator: 126` = `~` (ASCII
  codes — that is how the ARM schema expresses delimiters). These match §4.1.
- `usageIndicator: "Test"` → ISA15 = `T`.
- `controlStandardsId: 85` is the X12 standards id (ISA11 repetition uses `U` in 006030; the runtime derives
  the repetition separator — leave `useControlStandardsIdAsRepetitionCharacter: false`).
- `schemaName` MUST equal the IA schema artifact name uploaded in §8 step C (`X12_00603_850`). The agreement
  resolves the schema by this name — **it must exist in the IA before the agreement is created.**
- Control-number rollovers are enabled so the agreement owns ISA13/GS06/ST02 auto-increment (§4.1). The map
  emits only placeholders.

### 2.2 AS2 send agreement — `Purchaser-Supplier-AS2` (§5.3)

`Microsoft.Logic/integrationAccounts/agreements@2019-05-01`, `agreementType: "AS2"`.

**Key settings (from §5.3):**

| Setting | Value |
|---------|-------|
| Direction | send (host Purchaser → guest Supplier) |
| Sign | **enabled**, **SHA-256**, purchaser **signing private** cert |
| Encrypt | **enabled**, **AES-256**, supplier **encryption public** cert |
| MDN | Request MDN = **yes**, Request signed MDN = **yes**, **synchronous** (no async URL) |
| MDN settlement | **non-fatal** — workflow does not gate on MDN (§1, §6); missing/negative MDN = tracked property only |
| MIC hashing | SHA-256 |
| Compression | disabled (demo) |

**Content body:**

```json
{
  "properties": {
    "hostPartner": "Purchaser",
    "guestPartner": "Supplier",
    "hostIdentity":  { "qualifier": "AS2Identity", "value": "PURCHASER01" },
    "guestIdentity": { "qualifier": "AS2Identity", "value": "SUPPLIER01" },
    "agreementType": "AS2",
    "content": {
      "as2": {
        "receiveAgreement": {
          "senderBusinessIdentity":   { "qualifier": "AS2Identity", "value": "SUPPLIER01" },
          "receiverBusinessIdentity": { "qualifier": "AS2Identity", "value": "PURCHASER01" },
          "protocolSettings": {
            "messageConnectionSettings": {
              "ignoreCertificateNameMismatch": true,
              "supportHttpStatusCodeContinue": false,
              "keepHttpConnectionAlive": true,
              "unfoldHttpHeaders": true
            },
            "acknowledgementConnectionSettings": {
              "ignoreCertificateNameMismatch": true,
              "supportHttpStatusCodeContinue": false,
              "keepHttpConnectionAlive": true,
              "unfoldHttpHeaders": true
            },
            "mdnSettings": {
              "needMdn": false,
              "signMdn": false,
              "sendMdnAsynchronously": false,
              "signOutboundMdnIfOptional": false,
              "sendInboundMdnToMessageBox": true,
              "micHashingAlgorithm": "SHA256",
              "dispositionNotificationTo": "http://localhost",
              "mdnText": ""
            },
            "securitySettings": {
              "overrideGroupSigningCertificate": false,
              "enableNrrForInboundEncodedMessages": false,
              "enableNrrForInboundDecodedMessages": false,
              "enableNrrForOutboundMdn": false,
              "enableNrrForOutboundEncodedMessages": false,
              "enableNrrForOutboundDecodedMessages": false,
              "enableNrrForInboundMdn": false
            },
            "validationSettings": {
              "overrideMessageProperties": false,
              "encryptMessage": false,
              "signMessage": false,
              "compressMessage": false,
              "checkDuplicateMessage": false,
              "interchangeDuplicatesValidityDays": 5,
              "checkCertificateRevocationListOnReceive": false,
              "checkCertificateRevocationListOnSend": false,
              "encryptionAlgorithm": "AES256",
              "signingAlgorithm": "SHA256"
            },
            "envelopeSettings": {
              "messageContentType": "application/edi-x12",
              "transmitFileNameInMimeHeader": false,
              "fileNameTemplate": "%FILE().ReceivedFileName%",
              "suspendMessageOnFileNameGenerationError": true,
              "autogenerateFileName": false
            },
            "errorSettings": {
              "suspendDuplicateMessage": false,
              "resendIfMdnNotReceived": false
            }
          }
        },
        "sendAgreement": {
          "senderBusinessIdentity":   { "qualifier": "AS2Identity", "value": "PURCHASER01" },
          "receiverBusinessIdentity": { "qualifier": "AS2Identity", "value": "SUPPLIER01" },
          "protocolSettings": {
            "messageConnectionSettings": {
              "ignoreCertificateNameMismatch": true,
              "supportHttpStatusCodeContinue": true,
              "keepHttpConnectionAlive": true,
              "unfoldHttpHeaders": true
            },
            "acknowledgementConnectionSettings": {
              "ignoreCertificateNameMismatch": true,
              "supportHttpStatusCodeContinue": true,
              "keepHttpConnectionAlive": true,
              "unfoldHttpHeaders": true
            },
            "mdnSettings": {
              "needMdn": true,
              "signMdn": true,
              "sendMdnAsynchronously": false,
              "signOutboundMdnIfOptional": true,
              "sendInboundMdnToMessageBox": true,
              "micHashingAlgorithm": "SHA256",
              "dispositionNotificationTo": "http://localhost",
              "mdnText": ""
            },
            "securitySettings": {
              "overrideGroupSigningCertificate": true,
              "signingCertificateName": "{{ purchaser-signing-cert-artifact-name }}",
              "encryptionCertificateName": "{{ supplier-encryption-cert-artifact-name }}",
              "enableNrrForInboundEncodedMessages": false,
              "enableNrrForInboundDecodedMessages": false,
              "enableNrrForOutboundMdn": false,
              "enableNrrForOutboundEncodedMessages": false,
              "enableNrrForOutboundDecodedMessages": false,
              "enableNrrForInboundMdn": false
            },
            "validationSettings": {
              "overrideMessageProperties": true,
              "encryptMessage": true,
              "signMessage": true,
              "compressMessage": false,
              "checkDuplicateMessage": false,
              "interchangeDuplicatesValidityDays": 5,
              "checkCertificateRevocationListOnReceive": false,
              "checkCertificateRevocationListOnSend": false,
              "encryptionAlgorithm": "AES256",
              "signingAlgorithm": "SHA256"
            },
            "envelopeSettings": {
              "messageContentType": "application/edi-x12",
              "transmitFileNameInMimeHeader": false,
              "fileNameTemplate": "%FILE().ReceivedFileName%",
              "suspendMessageOnFileNameGenerationError": true,
              "autogenerateFileName": false
            },
            "errorSettings": {
              "suspendDuplicateMessage": false,
              "resendIfMdnNotReceived": false
            }
          }
        }
      }
    }
  }
}
```

**Kaylee notes (AS2):**
- Send side: `signMessage: true` + `signingAlgorithm: SHA256`, `encryptMessage: true` +
  `encryptionAlgorithm: AES256` — matches §5.3.
- `needMdn: true` + `signMdn: true` + `sendMdnAsynchronously: false` → **synchronous signed MDN requested**
  (§5.3). **Non-fatal** settlement is enforced by the *workflow* (Wash), not the agreement — the agreement
  only *requests* the MDN. `resendIfMdnNotReceived: false` keeps a missing MDN from triggering AS2-layer
  resends.
- `overrideGroupSigningCertificate: true` lets the agreement name the specific certs:
  - `signingCertificateName` → the IA **certificate artifact** for the **purchaser signing PRIVATE** cert.
  - `encryptionCertificateName` → the IA **certificate artifact** for the **supplier encryption PUBLIC** cert.
  These names must match the IA certificate artifact names you create in §8 step B (see §3 below). Replace the
  `{{ … }}` placeholders with those exact artifact names.
- `hostIdentity`/`guestIdentity` use qualifier **`AS2Identity`** (the AS2 partner-identity qualifier), value
  `PURCHASER01` / `SUPPLIER01` — the AS2-From / AS2-To header values.
- `messageContentType: "application/edi-x12"` because the AS2 payload is the X12 interchange produced by the
  X12 Encode step.

---

## 3. Certificate binding (§5.5) — IA certificate artifacts

Two IA **certificate artifacts** are required for send-only. They are `Microsoft.Logic/integrationAccounts/certificates`
resources referenced by name from the AS2 send agreement (`securitySettings` above).

| IA certificate artifact (suggested name) | Type | Source | Bound in AS2 agreement as |
|------------------------------------------|------|--------|---------------------------|
| `purchaser-signing` | **Private** | **Key Vault key** reference to `demo-as2-purchaser-signing` | `signingCertificateName` |
| `supplier-encryption` | **Public** | public cert of `demo-as2-supplier-encryption` (uploaded directly) | `encryptionCertificateName` |

- **Public** certificate artifact — `content.publicCertificate` (base64 public cert). No Key Vault reference.
- **Private** certificate artifact — no embedded key; uses `content.keyVault` with:
  ```json
  {
    "properties": {
      "key": {
        "kid": "{{ https://{vault}.vault.azure.net/keys/demo-as2-purchaser-signing }}",
        "keyName": "demo-as2-purchaser-signing",
        "keyVault": { "id": "{{ shared Key Vault resource id }}" },
        "keyVersion": "{{ optional — omit for latest }}"
      }
    }
  }
  ```

> **Dependency — Zoe (RBAC, one NEW edge this epic introduces):** because the private cert artifact
> *references* a Key Vault key, the **identity the IA uses to reach Key Vault** must be granted **Key Vault
> Crypto User + Key Vault Secrets User** on the shared vault (`rg-edi-shared`). Confirm the exact IA identity
> mechanism (IA system-assigned MI vs. the Azure Logic Apps first-party service principal) at build time
> against Microsoft Learn *"Add certificates to secure B2B messages"*. This grant (§8 step B0) must land
> **before** the private cert artifact is registered (§8 step B). The four leaf certs + root CA already exist
> in Key Vault from the out-of-band cert script (#8).

The reserved certs (`demo-as2-purchaser-encryption`, `demo-as2-supplier-signing`) are for the **future
receive side** (MDN verify / decrypt) and are **not** wired this epic.

---

## 4. Handoff checklist (for Kaylee's Bicep)

- [ ] `partners/Purchaser` + `partners/Supplier` (§1.1, §1.2).
- [ ] `certificates/supplier-encryption` (public) + `certificates/purchaser-signing` (KV-key ref) (§3) —
      **after** Zoe's IA→KV grant (§8 B0).
- [ ] Upload schema artifact `X12_00603_850` from `infra/integration-account/schemas/X12_00603_850.xsd`
      (§8 C) — this is **Microsoft's official X12 850 006030 `.xsd`** supplied by the product owner (not
      hand-authored). The X12 agreement resolves it by this name.
- [ ] `agreements/Purchaser-Supplier-X12` (§2.1) — depends on both partners + schema.
- [ ] `agreements/Purchaser-Supplier-AS2` (§2.2) — depends on both partners + both cert artifacts;
      replace the two `{{ …cert-artifact-name }}` placeholders with `purchaser-signing` / `supplier-encryption`.
- [ ] Link app → IA: set `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL` (KV-referenced SAS) (§8 F).

**Verify at build time** (Microsoft Learn, per §5.5 / §5.1): exact ARM property names/casing for
`integrationAccounts/agreements` `content.x12` / `content.as2`, the certificate `content.keyVault` shape, and
the IA→Key Vault identity used for private-key certificates. The values above are correct; only the ARM
envelope property spelling should be reconciled against current API version `2019-05-01`.
