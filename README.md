# Azure Logic Apps Standard AS2/X12 EDI Demo

> **Current status (2026-07-20T14:35:00-05:00):** The purchaser PO → X12 850 (006030) → AS2 → supplier path works live. The supplier AS2 POST returns HTTP 200. Settlement is a known open issue.

## What this demo is

This repository demonstrates business-document exchange on Azure Logic Apps Standard:

1. A canonical purchase order is published to Service Bus topic `purchase-orders.received`.
2. The purchaser workflow validates and persists the PO to Azure SQL.
3. The PO is converted to canonical XML, transformed to X12 850 (006030), X12-encoded, AS2-encoded, signed, encrypted, and posted to the supplier.
4. The supplier workflow `supplier-inbound-ack` returns HTTP 200.

The demo is intentionally dev-focused: public network access is enabled, resources are tagged `SecurityControl=Ignore`, and AS2 certificates are demo certificates generated into Key Vault.

## Architecture summary

| Area | Resource / artifact |
|---|---|
| Shared RG | `rg-edi-shared` — Log Analytics, Application Insights, Key Vault `kv-jci-edi-dev-2vjolmqq`, Azure SQL, Service Bus `sb-jci-edi-dev-2vjolmqq` |
| Purchaser RG | `rg-edi-purchaser` — Logic App `logic-jci-purchaser-dev`, UAMI `id-jci-purchaser-dev`, storage `stjcipurchaserdev2vjolmq`, Integration Account `ia-jci-purchaser-dev` |
| Supplier RG | `rg-edi-supplier` — Logic App `logic-jci-supplier-dev`, UAMI `id-jci-supplier-dev`, storage `stjcisupplierdev2vjolmqq` |
| Workflow | `logicapps/purchaser/workflows/purchaser-po-to-as2/workflow.json` |
| Supplier stub | `logicapps/supplier/workflows/supplier-inbound-ack/workflow.json` |
| X12 schema | `infra\integration-account\schemas\X12_00603_850.xsd` |
| XSLT map | `logicapps/purchaser/Artifacts/Maps/PO_Canonical_to_X12_850_006030.xslt` |
| Test payload | `samples/purchase-order-e2e-test.json` |

Detailed flow: [`docs/end-to-end-flow.md`](docs/end-to-end-flow.md). Operational deploy notes: [`docs/deployment-guide.md`](docs/deployment-guide.md). Workflow runbook: [`docs/purchaser-workflow-runbook.md`](docs/purchaser-workflow-runbook.md).

## Prerequisites

- Azure CLI authenticated to tenant `76de2d2d-77f8-438d-9a87-01806f2345da` and subscription `8bd05b2f-62c5-4def-9869-f0617ebb3970`.
- GitHub Actions OIDC deploy identity with Contributor + User Access Administrator at subscription scope.
- Deploy service principal membership in SQL Entra admin group `b9dac399-abc0-479d-9900-f2115a98297d`.
- Deploy service principal Key Vault data-plane grants applied out-of-band: **Key Vault Certificate User** and **Key Vault Secrets Officer**.
- AS2 demo certificates generated into Key Vault with `infra\scripts\generate-certificates.ps1`.
- Repository variable `LOGICAPPS_FIRSTPARTY_SP_OBJECT_ID` set to the tenant object id for the Azure Logic Apps first-party service principal.

Never store secrets, callback URLs, connection strings, private keys, or SAS URLs in source. They belong in Key Vault or GitHub secrets/variables.

## Deploy

For the full runbook, see [`docs/deployment-guide.md`](docs/deployment-guide.md). The verified deployment path is the GitHub Actions workflow `.github/workflows/deploy.yml`, which runs:

1. Subscription-scoped Bicep deployment: `infra\main.bicep` with `infra\main.bicepparam`.
2. SQL contained users/roles and DDL/proc scripts.
3. REST `contentLink` registration for `X12_00603_850.xsd` before Integration Account content deploy.
4. Integration Account partners, certificates, X12 agreement, and AS2 agreement.
5. Supplier workflow deploy, then purchaser workflow deploy.
6. Supplier callback URL injection to Key Vault, followed by purchaser restart.

Manual Azure mutation commands are intentionally not duplicated here. If a command is not verified in the runbook, it is marked `TBD`.

## Run the live demo

1. Confirm the deployed EDI prerequisites are complete: AS2 certs exist in Key Vault, IA content deployed, supplier URL secret exists, and both Logic Apps are running.
2. Publish `samples/purchase-order-e2e-test.json` to Service Bus topic `purchase-orders.received` using an AAD token for `https://servicebus.azure.net` and the Service Bus REST messages endpoint.
   - Verified approach: `az account get-access-token --resource https://servicebus.azure.net` + REST `POST` to the topic `messages` endpoint.
   - Exact reusable command: **TBD — verify against `.squad/decisions.md` before publishing from docs.**
3. In the purchaser Logic App run history, verify these actions succeed: Parse, Persist, Compose, Transform, X12 Encode, AS2 Encode, and `POST_AS2_to_supplier`.
4. Verify the supplier run fired and returned HTTP 200 with the stub response body `"AS2 message received."`.

## Known issues and gotchas

- **Settlement is open.** `Complete_Message` currently errors with `VNetPrivatePortsNotConfigured`; the environment has no VNet and the real cause/fix is still TBD. Messages may redeliver even when the AS2 POST succeeded.
- **Supplier is a stub.** `supplier-inbound-ack` returns 200 only. It does not AS2-decode, X12-decode, persist, or generate 997/999/TA1 acknowledgments yet.
- **Double underscore app-setting names can break `@appsetting()`.** `SupplierAs2Endpoint__url` and `sql__serverFqdn` both led to null resolution in runtime paths. Use single-token names for app settings read by workflows, for example `SupplierAs2EndpointUrl`, or provide concrete connection values where the connector requires them.
- **Parse JSON validation is reduced.** Logic Apps Parse JSON rejects regex `pattern`; currency/state/country are length-only until Mal/Simon choose the final validation approach.
- **Dev/test publisher RBAC is not production design.** The interactive/test publisher Data Sender grant is only for demo publishing. A real trading-system identity should publish in production.

## Repository structure

```text
.github/workflows/      CI/CD pipelines
infra/                  Bicep, Integration Account content, SQL scripts, cert script
logicapps/              Purchaser and supplier Logic App Standard projects
samples/                Non-sensitive payloads and offline validation harnesses
docs/                   Architecture, deploy, onboarding, and runbook docs
```

## Documentation

- [`docs/end-to-end-flow.md`](docs/end-to-end-flow.md) — current live message path and open settlement issue.
- [`docs/deployment-guide.md`](docs/deployment-guide.md) — operational deploy runbook and out-of-band steps.
- [`docs/purchaser-workflow-runbook.md`](docs/purchaser-workflow-runbook.md) — workflow-focused run/verify guide.
- [`docs/trading-partner-onboarding.md`](docs/trading-partner-onboarding.md) — partner/agreement settings.
- [`docs/infra-deploy-ordering.md`](docs/infra-deploy-ordering.md) — original infrastructure ordering design.

## License

This project is provided as-is for demonstration purposes under the [MIT License](LICENSE).
