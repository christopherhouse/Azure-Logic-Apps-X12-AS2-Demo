# Azure Logic Apps AS2/X12 EDI Demo — Deployment Runbook

> **Audience:** Azure operators deploying or repairing the live EDI demo.
> **Current status (2026-07-20T14:35:00-05:00):** Purchaser PO → X12 850 (006030) → AS2 → supplier HTTP 200 is working. Settlement is a known open issue.

## 1. Verified environment

| Item | Value |
|---|---|
| Subscription | `8bd05b2f-62c5-4def-9869-f0617ebb3970` |
| Tenant | `76de2d2d-77f8-438d-9a87-01806f2345da` |
| Shared RG | `rg-edi-shared` |
| Purchaser RG | `rg-edi-purchaser` |
| Supplier RG | `rg-edi-supplier` |
| Key Vault | `kv-jci-edi-dev-2vjolmqq` |
| Purchaser Logic App | `logic-jci-purchaser-dev` |
| Supplier Logic App | `logic-jci-supplier-dev` |
| Purchaser IA | `ia-jci-purchaser-dev` |
| Service Bus namespace | `sb-jci-edi-dev-2vjolmqq` |
| Topic / subscription | `purchase-orders.received` / `all-messages` |

## 2. Required one-time setup

### GitHub OIDC deploy identity

The deploy identity must have:

- Contributor at subscription scope.
- User Access Administrator at subscription scope.
- Membership in SQL Entra admin group `b9dac399-abc0-479d-9900-f2115a98297d`.
- GitHub secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
- Repository variable `LOGICAPPS_FIRSTPARTY_SP_OBJECT_ID` set to the tenant object id of the Azure Logic Apps first-party service principal (`7cd684f4-8a78-49b0-91ec-6a35d38739ba`).

### Deploy-SP Key Vault data-plane grants (out-of-band)

The deploy service principal needs Key Vault data-plane access to read/write EDI deployment material:

- **Key Vault Certificate User**
- **Key Vault Secrets Officer**

These grants were applied out-of-band and are not created by Bicep. Exact grant commands are **TBD** for a reusable operator script.

### AS2 certificate generation (out-of-band)

After Key Vault exists and before IA content deploy succeeds, run:

```powershell
infra\scripts\generate-certificates.ps1 -KeyVaultName "kv-jci-edi-dev-2vjolmqq"
```

The script publishes the demo root and AS2 leaf certificates to Key Vault. These are demo certificates only; do not commit private keys or exported certificate material.

## 3. Deployment ordering

The verified deployment path is `.github/workflows/deploy.yml`:

1. Resolve or read `LOGICAPPS_FIRSTPARTY_SP_OBJECT_ID`.
2. Deploy subscription-scoped Bicep: `infra\main.bicep` with `infra\main.bicepparam`.
3. Create SQL contained users and custom roles with Entra-token T-SQL.
4. Run SQL DDL: `infra\sql\schema\010-tables.sql` and `infra\sql\schema\020-usp-upsert.sql`.
5. Register `infra\integration-account\schemas\X12_00603_850.xsd` through REST `contentLink`.
6. Deploy Integration Account content from `infra\integration-account\ia-content.bicep`.
7. Publish the purchaser IA callback URL to Key Vault.
8. Deploy supplier workflow first.
9. Deploy purchaser workflow.
10. Write the supplier callback URL to Key Vault and restart the purchaser app.

### Why the X12 schema is registered before IA content

`X12_00603_850.xsd` is about 2.15 MB, too large for inline Bicep schema content. The deploy workflow uploads it to the purchaser storage account container `ia-artifacts`, creates a short-lived read SAS, and registers the Integration Account schema via Logic REST API `properties.contentLink.uri` **before** deploying agreements that reference the schema. Do not move IA content before this step.

## 4. Bicep-persisted runtime settings

`infra/compute/logicapp-bundle.bicep` now emits identity-based host storage for both apps:

- `AzureWebJobsStorage__credential = managedIdentity`
- `AzureWebJobsStorage__credentialType = managedIdentity`
- `AzureWebJobsStorage__managedIdentityResourceId = <app UAMI resource id>`
- `AzureWebJobsStorage__blobServiceUri = https://<storage>.blob.core.windows.net`
- `AzureWebJobsStorage__queueServiceUri = https://<storage>.queue.core.windows.net`
- `AzureWebJobsStorage__tableServiceUri = https://<storage>.table.core.windows.net`

It intentionally does **not** emit plain `AzureWebJobsStorage`, `AzureWebJobsStorage__accountName`, or `AzureWebJobsStorage__clientId`.

The purchaser supplier endpoint setting is `SupplierAs2EndpointUrl` (no double underscore), Key Vault-referenced to secret `supplier-as2-endpoint-url`.

## 5. RBAC reality

| Grant | Status / reason |
|---|---|
| Purchaser UAMI → Service Bus Data Receiver on topic `purchase-orders.received` | Persisted in Bicep; required for trigger and settlement attempts. |
| Purchaser UAMI → Key Vault Secrets User / Certificate User | Persisted; required for Key Vault references and cert reads. |
| Supplier UAMI → storage roles | Persisted; required for Logic Apps host storage. |
| Supplier UAMI → Service Bus Data Receiver | Still present from the original trust model, though the current supplier is HTTP-only. |
| Test publisher → Service Bus Data Sender | Dev/test only; out-of-band. A real trading system should publish in production. |
| Deploy SP → Key Vault Certificate User + Secrets Officer | Out-of-band; required by deployment operations. |

## 6. One-time cleanup

A system-assigned identity was added to the purchaser Logic App during debugging. The Bicep model is UAMI-only, so the next `infra\main.bicep` deployment should remove it. If manual cleanup is required, exact command is **TBD**.

## 7. Run the demo

1. Use non-sensitive fixture `samples/purchase-order-e2e-test.json`.
2. Publish to Service Bus topic `purchase-orders.received` with an AAD token for `https://servicebus.azure.net` and the REST topic messages endpoint.
   - The verified test used `az account get-access-token --resource https://servicebus.azure.net` and REST `POST`.
   - Exact reusable publish command is **TBD — verify against `.squad/decisions.md` before documenting as copy/paste.**
3. Verify purchaser run history reaches `POST_AS2_to_supplier` with HTTP `200`.
4. Verify the supplier `supplier-inbound-ack` run fired and returned `"AS2 message received."`.
5. Do not count Service Bus completion as verified until the settlement issue is resolved.

## 8. Known issues / gotchas

- `__` in app-setting names can break Logic Apps Standard `@appsetting()` resolution even when a Key Vault reference reports `Resolved`. This affected `SupplierAs2Endpoint__url`; avoid double-underscore names for workflow-read settings. SQL also could not use `sql__serverFqdn` through `@appsetting()` for the built-in SQL managed-identity binding, so the verified fix uses concrete SQL values in `connections.json`.
- `Complete_Message` currently errors `VNetPrivatePortsNotConfigured` despite no VNet topology. Cause/fix is TBD. Messages redeliver.
- `supplier-inbound-ack` is a stub; no AS2 decode, X12 decode, SQL persist, or 997/999/TA1 generation exists yet.
- Parse JSON regex `pattern` is unsupported; currency/state/country validation is length-only pending Mal/Simon decision.
- Do not persist the earlier `vnetPrivatePortsCount = 2` lead; it was reverted and is not applicable without VNet integration.

## 9. Validation commands

Documentation-only updates do not require live Azure validation. For code/IaC changes, use only verified commands already present in this repo, for example:

```powershell
az bicep build --file infra\main.bicep
python samples\validate-json.py
pwsh -File samples\transform-and-validate.ps1
```

Run live Azure mutations only when the operator has explicitly authorized them.
