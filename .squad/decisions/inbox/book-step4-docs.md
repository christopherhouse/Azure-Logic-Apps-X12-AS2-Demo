# Book Step 4 Docs — Working EDI Demo Runbook

- **Recorded:** 2026-07-20T14:35:00-05:00
- **Agent:** Book (Technical Writer)
- **Branch:** `bugfix/edi-e2e-live-fixes`
- **Source of truth:** `.squad/decisions.md`, `RESUME.md`, branch code under `infra/`, `logicapps/`, `.github/workflows/deploy.yml`, and `samples/`.

## Documented

- Updated `README.md` to reflect the current live status: purchaser PO → X12 850 (006030) → AS2 → supplier HTTP 200 is working, with Service Bus settlement still open.
- Added `docs/end-to-end-flow.md` with the action-by-action message path from Service Bus topic `purchase-orders.received` through Parse, SQL persist, canonical XML, XSLT, X12 Encode, AS2 Encode, supplier POST, and HTTP 200.
- Rewrote `docs/deployment-guide.md` as the operational deploy runbook, including out-of-band deploy-SP Key Vault grants, certificate generation, REST `contentLink` schema registration order, RBAC reality, and one-time purchaser system-assigned identity cleanup.
- Rewrote `docs/purchaser-workflow-runbook.md` with current run/verify steps, verified AS2 output shape, app-setting gotcha, SQL binding notes, and open known issues.

## TBD items needing owner confirmation

- Exact reusable Service Bus REST publish command for `samples/purchase-order-e2e-test.json` (approach verified; copy/paste command should be confirmed by Kaylee/Wash before docs present it as canonical).
- Exact reusable commands for deploy-SP Key Vault Certificate User + Secrets Officer grants.
- Manual cleanup command, if needed, for the stray purchaser system-assigned identity; next `main.bicep` deploy should remove it.
- Settlement root cause/fix for `Complete_Message` / `Dead_Letter_Message` `VNetPrivatePortsNotConfigured` in a no-VNet topology.
- Final Mal/Simon decision on whether length-only currency/state/country validation is acceptable or workflow logic must restore regex semantics.
