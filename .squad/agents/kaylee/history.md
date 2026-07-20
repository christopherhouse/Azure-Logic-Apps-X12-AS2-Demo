# Project Context

- **Owner:** Christopher House
- **Project:** End-to-end Azure Logic Apps Standard EDI/AS2 demo — two Logic Apps (purchaser + supplier) modeling a purchase-order exchange between trading partners.
- **Stack:** Azure Logic Apps Standard, AS2 + X12 EDI, Bicep with Azure Verified Modules (subscription-scoped, multi-RG, multi-region), GitHub Actions CI/CD.
- **Security mandate:** Managed identity only — no connection strings unless absolutely necessary (and then documented + Key Vault referenced).
- **Created:** 2026-07-16

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

📌 Team update (2026-07-16T11:20:48-05:00): Deploy-ordering design lives at `docs/infra-deploy-ordering.md`; the initial scaffold is in place.

📌 Team update (2026-07-16T11:20:48-05:00): Infra build now has modules under `infra/{naming,diagnostics,shared,compute,modules}`, Logic App connections under `logicapps/*`, cert script at `infra/scripts`, and content-share still needs a post-deploy CI secret publication step. — decided by Kaylee/Zoe/Wash

📌 Team update (2026-07-16T11:20:48-05:00): infra build complete (17 resources what-if-validated); CI/CD OIDC-based; docs at README + docs/deployment-guide.md; open item = provision deployment SP + GH secrets (#18) once gh re-authed.

📌 Team update (2026-07-16T12:32:21-05:00): OIDC deployment identity is provisioned and the repo is deploy-ready; humans need to review/merge PR #1 and run the first live deploy. — decided by Zoe

📌 Team update (2026-07-20T10:48:22-05:00): Persist Wash's live storage and purchaser `connections.json` managed-identity shape fixes into `infra/compute/logicapp-bundle.bicep`; otherwise CI/deploy can revert the healthy runtime shape. — decided by Wash

📌 Team update (2026-07-20T14:05:00-05:00): E2E live fixes need Bicep/CI persistence: supplier AzureWebJobsStorage identity settings, SupplierAs2EndpointUrl KV reference, SQL MI connection metadata, IA schema registration reproducibility, and the __ app-setting name gotcha for Logic Apps @appsetting() resolution.

📌 Team update (2026-07-20T14:25:00-05:00): Step 3 Bicep persistence complete on bugfix/edi-e2e-live-fixes at commit e07c4fe: identity-based AzureWebJobsStorage for both Logic Apps, clean SupplierAs2EndpointUrl KV reference, consistent OpenTelemetry, purchaser topic Data Receiver RBAC, UAMI-only identity, and senderApplicationId verification are persisted. Runbook backlog remains for schema registration, dev-only CLI Data Sender, deploy-SP Key Vault grants, and one-time system-MI cleanup. — decided by Kaylee

