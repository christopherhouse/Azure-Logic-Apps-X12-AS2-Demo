# Purchaser Workflow Runbook — PO to X12 850 AS2

> **Status (2026-07-20T14:35:00-05:00):** The live purchaser path reaches the supplier HTTP endpoint and receives HTTP 200. Service Bus settlement is still open.

## What this workflow does

`logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json` consumes canonical purchase orders from Service Bus topic `purchase-orders.received`, persists them to SQL, transforms them to X12 850 (006030), AS2-encodes the interchange, and posts it to supplier workflow `supplier-inbound-ack`.

## End-to-end path

1. **Trigger:** Service Bus topic `purchase-orders.received`, subscription `all-messages`, peek-lock.
2. **Parse:** `Parse_Purchase_Order` validates the supported subset of the canonical PO JSON schema.
3. **Persist:** `Persist_Purchase_Order` executes `dbo.usp_UpsertPurchaseOrder` through the built-in SQL connector using managed identity.
4. **Canonical XML:** `Compose_Canonical_Xml` converts the parsed PO to XML.
5. **Transform:** `Transform_to_X12_850_Xml` uses `PO_Canonical_to_X12_850_006030.xslt`.
6. **X12 Encode:** `Encode_to_X12_850` uses IA agreement `Purchaser-Supplier-X12`.
7. **AS2 Encode:** `Encode_to_AS2` signs/encrypts and requests a synchronous MDN.
8. **HTTP POST:** `POST_AS2_to_supplier` posts raw AS2 MIME bytes and AS2 headers to `@appsetting('SupplierAs2EndpointUrl')`.
9. **Supplier:** `supplier-inbound-ack` returns HTTP 200 (`"AS2 message received."`).
10. **Settlement:** Intended complete/dead-letter actions run after the business scope, but completion currently errors and is a known issue.

See [`end-to-end-flow.md`](end-to-end-flow.md) for the flow diagram.

## How to run

Preconditions:

- `.github/workflows/deploy.yml` has completed through IA content and both workflow deployments.
- `infra\scripts\generate-certificates.ps1` has published demo certs to Key Vault.
- Secret `supplier-as2-endpoint-url` exists in Key Vault and purchaser app setting `SupplierAs2EndpointUrl` resolves.
- Purchaser UAMI has Service Bus Data Receiver on topic `purchase-orders.received`.
- A dev/test publishing identity has Service Bus Data Sender on the topic.

Steps:

1. Use fixture `samples/purchase-order-e2e-test.json`.
2. Publish it with an AAD-token REST POST to the Service Bus topic `messages` endpoint (no connection string). This sends the raw JSON as the message body. Verified live: this returns **HTTP 201 Created** and drives a purchaser run.

   ```powershell
   # Replace the namespace host with your environment's Service Bus FQDN.
   $namespace = 'sb-jci-edi-dev-2vjolmqq.servicebus.windows.net'
   $payload   = 'samples\purchase-order-e2e-test.json'

   $token = az account get-access-token --resource 'https://servicebus.azure.net' --query accessToken -o tsv
   curl.exe --fail-with-body -i -X POST "https://$namespace/purchase-orders.received/messages?timeout=60" `
     -H "Authorization: Bearer $token" `
     -H 'Content-Type: application/json' `
     -H 'BrokerProperties: {"MessageId":"PO-E2E-07201052","CorrelationId":"PO-E2E-07201052","Label":"E2E"}' `
     --data-binary "@$payload"
   ```

   Preconditions for this to succeed: your CLI identity holds **Azure Service Bus Data Sender** on topic `purchase-orders.received`, and the purchaser UAMI holds **Azure Service Bus Data Receiver** on the same topic (see [`trading-partner-onboarding.md`](trading-partner-onboarding.md) / `.squad/decisions.md`). The `MessageId`/`CorrelationId` should be unique per run so redelivery and dedup are observable.
3. Open purchaser run history for `purchaser-po-to-as2`.
4. Confirm these actions succeeded: `Parse_Purchase_Order`, `Persist_Purchase_Order`, `Compose_Canonical_Xml`, `Transform_to_X12_850_Xml`, `Encode_to_X12_850`, `Encode_to_AS2`, `POST_AS2_to_supplier`.
5. Confirm `POST_AS2_to_supplier` has status code `200`.
6. Open supplier run history for `supplier-inbound-ack`; confirm `Return_200_OK` succeeded.
7. Expect `Complete_Message` to fail until settlement is fixed; message redelivery is currently expected.

## Important implementation facts

- X12 version is 006030, but the Integration Account schema metadata uses `schemaVersion = 00603` and schema name/root `X12_00603_850`.
- X12 send agreement schema reference must **not** include `senderApplicationId`; the envelope still uses `senderApplicationId = PURCHASER01`.
- AS2 Encode output shape is Standard built-in AS2 v2: `body('Encode_to_AS2')?['messageHeaders']` and `body('Encode_to_AS2')?['messageContent']?['$content']`.
- The HTTP action sends `@base64ToBinary(body('Encode_to_AS2')?['messageContent']?['$content'])` with the AS2 headers.
- The supplier endpoint app setting is `SupplierAs2EndpointUrl`; do not use `SupplierAs2Endpoint__url`.
- SQL managed-identity connection uses concrete server/database/UAMI values in `logicapps/purchaser/connections.json`; do not reintroduce app-setting indirection for SQL server/database without live verification.

## Known issues

- `Complete_Message` fails with `VNetPrivatePortsNotConfigured`; cause/fix TBD. `Dead_Letter_Message` may fail similarly. The AS2 POST can be green while settlement is red.
- `supplier-inbound-ack` is only a stub. It does not decode AS2/X12 or return a real MDN/997/999/TA1.
- Parse JSON cannot use regex `pattern`; currency/state/country are length-only for now.
- The dev/test Service Bus Data Sender grant for publishing test POs is not production architecture.

## Offline validation

These commands validate only local fixtures and transform artifacts; they do not prove the live AS2 send:

```powershell
python samples\validate-json.py
pwsh -File samples\transform-and-validate.ps1
```
