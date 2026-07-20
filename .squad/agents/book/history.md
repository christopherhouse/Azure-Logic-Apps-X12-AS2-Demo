# Project Context

- **Owner:** Christopher House
- **Project:** End-to-end Azure Logic Apps Standard EDI/AS2 demo — two Logic Apps (purchaser + supplier) modeling a purchase-order exchange between trading partners.
- **Stack:** Azure Logic Apps Standard, AS2 + X12 EDI, Bicep with Azure Verified Modules (subscription-scoped, multi-RG, multi-region), GitHub Actions CI/CD.
- **Security mandate:** Managed identity only — no connection strings unless absolutely necessary (and then documented + Key Vault referenced).
- **Created:** 2026-07-16

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

📌 Team update (2026-07-16T11:20:48-05:00): Infra build now has modules under `infra/{naming,diagnostics,shared,compute,modules}`, Logic App connections under `logicapps/*`, cert script at `infra/scripts`, and content-share still needs a post-deploy CI secret publication step. — decided by Kaylee/Zoe/Wash

📌 Team update (2026-07-16T11:20:48-05:00): infra build complete (17 resources what-if-validated); CI/CD OIDC-based; docs at README + docs/deployment-guide.md; open item = provision deployment SP + GH secrets (#18) once gh re-authed.

📌 Team update (2026-07-20T14:25:00-05:00): Docs/runbook backlog from Step 3: document identity-based AzureWebJobsStorage settings, deploy-SP Key Vault Certificate User + Secrets Officer grants, cert-generation prerequisite, CI schema registration via REST contentLink, Logic Apps __ app-setting gotcha, dev-only CLI Data Sender grant, and purchaser system-MI cleanup/redeploy behavior. — decided by Kaylee

