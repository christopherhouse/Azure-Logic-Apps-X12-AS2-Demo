# Project Context

- **Owner:** Christopher House
- **Project:** End-to-end Azure Logic Apps Standard EDI/AS2 demo — two Logic Apps (purchaser + supplier) modeling a purchase-order exchange between trading partners.
- **Stack:** Azure Logic Apps Standard, AS2 + X12 EDI, Bicep with Azure Verified Modules (subscription-scoped, multi-RG, multi-region), GitHub Actions CI/CD.
- **Security mandate:** Managed identity only — no connection strings unless absolutely necessary (and then documented + Key Vault referenced).
- **Created:** 2026-07-16

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

📌 Team update (2026-07-20T14:05:00-05:00): X12 send agreement schema matching failed when senderApplicationId was included in schemaReferences; remove it so the agreement matches registered schema X12_00603_850 by message/version metadata.
