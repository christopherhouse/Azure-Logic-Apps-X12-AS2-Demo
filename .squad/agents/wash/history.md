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

📌 Team update (2026-07-20T14:05:00-05:00): Hard-won Logic Apps pitfalls: @appsetting() can resolve null when setting names use the wrong double-underscore shape; AS2 v2 encode output must be consumed as messageHeaders plus base64-decoded messageContent.# 2026-07-20T10:52:00-05:00: Service Bus RBAC for purchaser E2E test

**By:** Zoe

**What:** Added the minimum Service Bus data-plane RBAC needed to run the dev end-to-end purchase-order test against topic `purchase-orders.received` in namespace `sb-jci-edi-dev-2vjolmqq` (`rg-edi-shared`, subscription `8bd05b2f-62c5-4def-9869-f0617ebb3970`).

- Purchaser workflow UAMI `id-jci-purchaser-dev` principalId `452730cd-6c5e-40e4-93b2-7b421a9ab4ce` now has **Azure Service Bus Data Receiver** at scope `/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970/resourceGroups/rg-edi-shared/providers/Microsoft.ServiceBus/namespaces/sb-jci-edi-dev-2vjolmqq/topics/purchase-orders.received`.
- Active CLI test publisher `chhouse@microsoft.com` principalId `2ede4c0c-360b-47f8-80b0-bdba8badea7b` now has **Azure Service Bus Data Sender** at scope `/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970/resourceGroups/rg-edi-shared/providers/Microsoft.ServiceBus/namespaces/sb-jci-edi-dev-2vjolmqq/topics/purchase-orders.received`.

**Why:** The purchaser workflow uses a peek-lock topic trigger and must listen, complete, and dead-letter messages, so it requires receiver rights, not sender rights. The active CLI principal needs sender rights only to publish a PO for the dev E2E test. The Sender grant is explicit dev-test enablement and must not be treated as production design; in prod, the real trading-system publisher identity should receive a similarly narrow topic-scoped sender grant.

**IaC status:** These two topic-scoped assignments were applied out-of-band with `az role assignment create` and are not currently expressed in Bicep. `infra/rbac/role-assignments.bicep` currently expresses namespace-scoped purchaser sender and supplier receiver assignments, so Kaylee should fold the purchaser receiver assignment and any desired dev-test publisher assignment model into Bicep/runbook without broadening scope.

**Propagation:** Azure RBAC propagation can take 1-5+ minutes after assignment creation before Service Bus data-plane operations succeed., not assumed legacy accessors.

📌 Team update (2026-07-21T09:15:00-05:00): Hard-won SB settlement pattern: use a matched Service Bus V2 topic trigger/settle set (peekLockTopicMessagesV2, completeTopicMessageV2, deadLetterTopicMessageV2) with topicName + subscriptionName + lockToken; V2 settle needs a concrete FQN and may ignore serviceBus__fullyQualifiedNamespace; pin uthProvider.Identity in connections.json or settlement can fall back to a stray system-assigned identity and fail AADSTS700016. — decided by Coordinator
