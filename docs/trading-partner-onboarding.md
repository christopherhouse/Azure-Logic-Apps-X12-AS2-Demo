# Trading Partner Onboarding Guide

> **Status:** PLACEHOLDER / DEFERRED  
> **Future Specification:** This guide will be completed in the EDI Implementation specification (post-Infrastructure v1.0).  
> **Current State:** The infrastructure (Integration Accounts, Key Vault certificates, Logic Apps) is deployed. Workflow implementation, X12 schemas, maps, AS2 agreements, and trading-partner configuration are **DEFERRED** per the Infrastructure v1.0 PRD.

---

## Purpose

This guide will document how to onboard a new trading partner into the Azure Logic Apps AS2/X12 EDI environment. Once the EDI implementation specification is complete, this guide will provide step-by-step instructions for:

- Defining trading partners in Integration Accounts
- Configuring AS2 identifiers, qualifiers, and certificates
- Creating AS2 send and receive agreements
- Uploading X12 schemas (850, 997, TA1, etc.)
- Deploying XSLT transformation maps
- Testing the end-to-end message flow

---

## Scope (Future)

### 1. Trading Partner Definition

**Objective:** Register a new trading partner (e.g., "Contoso Supplier") in the Integration Account.

**Steps (to be documented):**
- Define partner name, business identity (AS2-From, AS2-To)
- Assign AS2 identifiers and qualifiers (e.g., `AS2-Contoso`, qualifier `ZZ` or `01`)
- Link signing and encryption certificates from Key Vault

**Integration Account Resources:**
- Purchaser Integration Account: `ia-purchaser-jci-edi-dev-...`
- Supplier Integration Account: `ia-supplier-jci-edi-dev-...`

**Example (placeholder):**

```json
{
  "name": "Contoso-Supplier",
  "businessIdentities": [
    {
      "qualifier": "ZZ",
      "value": "CONTOSO"
    },
    {
      "qualifier": "AS2Identity",
      "value": "AS2-CONTOSO"
    }
  ]
}
```

**Tools/CLI:**
- Azure Portal: Integration Accounts > Partners
- Azure CLI: `az logic integration-account partner create` (to be verified)

---

### 2. AS2 Certificate Configuration

**Objective:** Assign signing and encryption certificates to each trading partner for AS2 message security.

**Prerequisites:**
- AS2 certificates must be generated and published to Key Vault (completed in [`docs/deployment-guide.md — Section 4`](deployment-guide.md#4-post-deployment-generate-and-publish-certificates))

**Certificate Mapping (placeholder):**

| Partner | Role | Signing Certificate | Encryption Certificate |
|---|---|---|---|
| Purchaser | Sender | `demo-as2-purchaser-signing` | `demo-as2-purchaser-encryption` |
| Supplier | Receiver | `demo-as2-supplier-signing` | `demo-as2-supplier-encryption` |

**Steps (to be documented):**
1. Download the public key (.cer) from Key Vault for the partner's signing certificate
2. Upload to Integration Account: Partners > {Partner Name} > Certificates
3. Repeat for encryption certificate
4. Verify certificate thumbprints match Key Vault

**Azure CLI Example (placeholder):**

```powershell
# Export certificate from Key Vault (public key only)
az keyvault certificate download --vault-name kv-jci-edi-dev-abc12345 --name demo-as2-purchaser-signing --file purchaser-signing.cer --encoding PEM

# Upload to Integration Account (command to be verified)
az logic integration-account certificate create --resource-group rg-edi-purchaser --integration-account ia-purchaser-jci-edi-dev-... --name purchaser-signing --key-vault-id /subscriptions/.../providers/Microsoft.KeyVault/vaults/kv-jci-edi-dev-abc12345/secrets/demo-as2-purchaser-signing
```

---

### 3. AS2 Agreements

**Objective:** Define send and receive agreements that specify message encoding, signing, encryption, MDN requirements, and error handling.

**Agreement Types:**
- **Send Agreement** — outbound AS2 messages from Purchaser to Supplier
- **Receive Agreement** — inbound AS2 messages from Supplier to Purchaser

**Agreement Parameters (placeholder):**

| Parameter | Send Agreement | Receive Agreement |
|---|---|---|
| **AS2 From** | Purchaser (`AS2-PURCHASER`) | Supplier (`AS2-SUPPLIER`) |
| **AS2 To** | Supplier (`AS2-SUPPLIER`) | Purchaser (`AS2-PURCHASER`) |
| **Signing Certificate** | Purchaser signing cert | Supplier signing cert |
| **Encryption Certificate** | Supplier encryption cert (public) | Purchaser encryption cert (public) |
| **MDN Required** | Yes | Yes |
| **MDN Signed** | Yes | Yes |
| **Compression** | Optional | Optional |
| **Message Disposition Notification** | Sync/Async | Sync/Async |

**Steps (to be documented):**
1. In Integration Account, navigate to Agreements
2. Create new AS2 Agreement
3. Select Host Partner (e.g., Purchaser) and Guest Partner (e.g., Supplier)
4. Configure Send/Receive settings:
   - AS2 identifiers
   - Signing algorithm (SHA-256 or SHA-512)
   - Encryption algorithm (AES-256, 3DES, etc.)
   - MDN settings (sync/async, signed/unsigned)
5. Save and validate

**Azure Portal Path:**
- Integration Accounts > Agreements > Add

---

### 4. X12 Schemas

**Objective:** Upload X12 schemas (XSD files) for the transaction sets used in the demo (e.g., 850 Purchase Order, 997 Functional Acknowledgment, TA1 Interchange Acknowledgment).

**Schema Files (to be provided in future spec):**
- `X12_00401_850.xsd` — Purchase Order (version 4010)
- `X12_00401_997.xsd` — Functional Acknowledgment (version 4010)
- `X12_00401_TA1.xsd` — Interchange Acknowledgment (version 4010)

**Steps (to be documented):**
1. Obtain or generate X12 schemas for the target transaction sets and versions
2. In Integration Account, navigate to Schemas
3. Upload each .xsd file
4. Verify schema name matches the transaction set and version (e.g., `X12_00401_850`)

**Azure CLI Example (placeholder):**

```powershell
# Upload schema (command to be verified)
az logic integration-account schema create --resource-group rg-edi-purchaser --integration-account ia-purchaser-jci-edi-dev-... --name X12_00401_850 --schema-type Xml --schema-content @X12_00401_850.xsd
```

---

### 5. XSLT Transformation Maps

**Objective:** Define XSLT maps to transform X12 purchase orders to an internal JSON/XML format and vice versa.

**Map Types (placeholder):**
- **Inbound Map:** X12 850 → Internal PO format (JSON or XML)
- **Outbound Map:** Internal acknowledgment format → X12 997/TA1

**Steps (to be documented):**
1. Develop XSLT 1.0 or 2.0 transformation map (or use BizTalk Mapper / Visual Studio)
2. Test the map locally with sample X12 payloads
3. Upload to Integration Account: Maps > Add
4. Reference the map in Logic App workflow `Transform XML` action (or X12 Decode/Encode actions)

**Example Map Skeleton (placeholder):**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <xsl:template match="/">
    <!-- Transform X12 850 to internal JSON/XML -->
    <PurchaseOrder>
      <OrderNumber><xsl:value-of select="//BEG/BEG03"/></OrderNumber>
      <OrderDate><xsl:value-of select="//BEG/BEG05"/></OrderDate>
      <!-- ... additional fields ... -->
    </PurchaseOrder>
  </xsl:template>
</xsl:stylesheet>
```

---

### 6. Logic App Workflow Configuration

**Objective:** Deploy Logic App workflows that orchestrate the AS2 and X12 message flow.

**Workflow Steps (high-level, to be detailed in future spec):**

#### Supplier Workflow (Receive PO)
1. **AS2 Receive** trigger — listen for inbound AS2 messages
2. **AS2 Decode** action — decrypt, verify signature, parse MDN
3. **X12 Decode** action — parse X12 850 envelope, validate against schema
4. **Transform XML** action — apply inbound XSLT map (X12 → internal format)
5. **Insert to SQL** action — persist PO to Azure SQL Database (using built-in SQL connector + managed identity)
6. **Publish to Service Bus** action — send to `purchase-orders.received` topic
7. **X12 Encode** action — generate 997 Functional Acknowledgment
8. **AS2 Encode** action — sign, encrypt, send AS2 MDN

#### Purchaser Workflow (Send PO / Receive ACK)
1. **HTTP trigger** or **Service Bus Receive** — inbound internal PO request
2. **Transform XML** action — apply outbound XSLT map (internal → X12 850)
3. **X12 Encode** action — wrap in X12 envelope (ISA/GS/ST/SE/GE/IEA)
4. **AS2 Encode** action — sign, encrypt
5. **HTTP action** — send AS2 message to Supplier endpoint
6. **AS2 Receive MDN** — wait for signed/async MDN
7. **X12 Decode** action — parse 997 acknowledgment
8. **Update SQL** action — mark PO as acknowledged

**Files (to be created in future spec):**
- `logicapps/supplier/workflows/receive-po.json`
- `logicapps/purchaser/workflows/send-po.json`

---

### 7. Testing the End-to-End Flow

**Objective:** Validate that a purchase order can be sent from Purchaser, received by Supplier, persisted to SQL, and acknowledged.

**Test Steps (to be documented):**
1. Prepare a sample X12 850 payload (valid ISA/GS/ST envelope)
2. Send to Purchaser Logic App HTTP trigger endpoint
3. Verify:
   - Purchaser encodes X12 850 and wraps in AS2
   - Supplier receives AS2 message, decodes, validates, transforms
   - Supplier persists PO to SQL database
   - Supplier sends 997 acknowledgment
   - Purchaser receives and validates 997
4. Check Application Insights logs for trace telemetry
5. Query SQL database to confirm PO record exists

**Sample X12 850 Payload (placeholder):**

```
ISA*00*          *00*          *ZZ*PURCHASER      *ZZ*SUPPLIER       *260716*1130*U*00401*000000001*0*P*>~
GS*PO*PURCHASER*SUPPLIER*20260716*113000*1*X*004010~
ST*850*0001~
BEG*00*NE*PO123456**20260716~
REF*DP*DEPT001~
PER*BD*John Doe*TE*555-1234~
N1*ST*Ship To Location~
N3*123 Main St~
N4*Anytown*CA*90210*US~
PO1*1*10*EA*19.99**BP*WIDGET-001~
SE*9*0001~
GE*1*1~
IEA*1*000000001~
```

---

## Placeholder Artifacts

The following artifacts **will be provided** in the future EDI implementation specification:

- [ ] Sample X12 schemas (.xsd files)
- [ ] Sample XSLT maps (inbound and outbound)
- [ ] Logic App workflow definitions (JSON)
- [ ] Sample X12 payloads (850, 997, TA1)
- [ ] SQL database schema (tables, stored procedures)
- [ ] Postman collection for testing
- [ ] Trading partner configuration templates
- [ ] AS2 agreement templates
- [ ] Troubleshooting guide for AS2/X12 errors

---

## References

- [Azure Logic Apps Standard Documentation](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-overview)
- [AS2 Connector Documentation](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-as2)
- [X12 Connector Documentation](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-x12)
- [Integration Accounts](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-create-integration-account)
- [EDI Message Validation](https://learn.microsoft.com/en-us/azure/logic-apps/logic-apps-enterprise-integration-edifact)

---

**End of Trading Partner Onboarding Guide (Placeholder)**

> **Note to future implementers:** This guide is intentionally incomplete. The structure above provides the framework for the EDI configuration documentation. Once workflows, schemas, maps, and agreements are implemented, this guide should be expanded with exact CLI commands, JSON examples, and screenshots.
