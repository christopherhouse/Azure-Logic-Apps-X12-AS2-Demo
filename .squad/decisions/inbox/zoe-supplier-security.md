# Zoe — Security sign-off: supplier-inbound 850 + 997 round-trip epic

> **Author:** Zoe (Security Engineer) · **Branch:** `feature/supplier-inbound-997-workflow`
> **Scope:** Security-specialist deep pass on the AS2 / certificate / identity / secret surface.
> Read-only on code — no source edited. Findings routed to the Coordinator; this is the sign-off record.
> **For the Scribe to merge into `.squad/decisions.md`. Do NOT edit `decisions.md` directly.**
>
> Reviewed `git diff main...HEAD` against Mal's design §4 (cert-binding table + trust boundaries),
> Kaylee's infra inbox, the LOCKED build-wave contract, and the first-party SP RBAC decision
> (`.squad/decisions.md:140,210`).

---

## VERDICT: ✅ SIGN-OFF (no BLOCKERs)

All five review areas PASS. One documented **runtime-verify** item (the signed-MDN cert on the
receive leg) — it is **not** a security blocker: worst case is a functional/interop MDN defect that
the design already treats as non-fatal (§0.6). No secret leakage, no over-broad RBAC, no new RBAC
edge, managed identity everywhere, no embedded private keys.

---

## Findings by severity

### BLOCKER — none.

### HIGH — none.

### MEDIUM — none.

### LOW / advisory
- **L1 (runtime-verify, not a fix):** signed-MDN certificate resolution on both AS2 **receive** legs
  — see the MDN-signing analysis below. Owner for live verification: Wash (AS2-Decode round-trip),
  per Kaylee D-K3.
- **L2 (info):** `ignoreCertificateNameMismatch: true` and `checkCertificateRevocationListOn*: false`
  on all four AS2 agreement blocks (`ia-content-supplier.bicep:643-651,666-676`;
  `ia-content.bicep`). Acceptable for a self-signed **demo** with reserved leaf certs; would be a
  finding in production (no CRL/OCSP, name-mismatch tolerated). Flagged so it is a conscious choice,
  not an oversight. No action this epic.

---

## Item-by-item verification

### 1. Cert bindings correct per Mal's §4.1 table — ✅ PASS
Confirmed private = KV **key reference** (never embedded key material); public = uploaded base64
`.cer` body only.

**Supplier IA (`ia-content-supplier.bicep`):**
- `supplierEncryptionCert` (`:178-190`) — PRIVATE, decrypt inbound 850: `publicCertificate` body +
  `key.keyVault.id` KV key ref. ✅
- `supplierSigningCert` (`:193-205`) — PRIVATE, sign MDN + sign 997: body + KV key ref. ✅
- `purchaserSigningCert` (`:208-213`) — PUBLIC only (`publicCertificate`, no `key`), verify partner sig. ✅
- `purchaserEncryptionCert` (`:216-221`) — PUBLIC only, encrypt outbound 997. ✅
- AS2 **receive** securitySettings (`:666-669`): sign=`purchaser-signing` (public), enc=`supplier-encryption` (private). ✅
- AS2 **send** securitySettings (`:729-731`): sign=`supplier-signing` (private), enc=`purchaser-encryption` (public). ✅

**Purchaser IA (`ia-content.bicep`):**
- `purchaserEncryptionCert` (`:187-197`) — PRIVATE, decrypt inbound 997: body + KV key ref, guarded `if (activateAs2Receive)`. ✅
- `supplierSigningCert` (`:202-207`) — PUBLIC only, verify supplier sig (997 + MDN). ✅
- AS2 **receive** securitySettings (`:472-474`): sign=`supplier-signing` (public), enc=`purchaser-encryption` (private). ✅

**No private key embedded in any committed file.** Private artifacts carry only the public cert
body plus a KV key-name reference; the private key stays in the shared vault. CI passes public
`.cer` bodies as parameters read from Key Vault at deploy time (`deploy.yml` schema/cert steps).
No `.pfx/.pem/.key/.cer/.p12` file is committed; `.gitignore` only adds compiled ARM JSON.

### 2. MDN-signing-cert nuance — ✅ SAFE (with one RUNTIME-VERIFY item; NOT a must-fix)
**Answer: RUNTIME-VERIFY, security-safe / non-blocking.**

Both receive blocks set `overrideGroupSigningCertificate: true` with `signingCertificateName` = the
**partner PUBLIC** cert (supplier receive: `purchaser-signing`, `ia-content-supplier.bicep:667-668`;
purchaser receive: `supplier-signing`, `ia-content.bicep:472-473`). On the receive leg that signing
cert's job is to **verify the inbound signature** — which is correct (partner public = verify).

The open question Kaylee flagged (D-K3) is whether the returned **signed MDN** gets signed with that
receive-block public cert (which has no private key) instead of the host's own `*-signing` PRIVATE
cert. Azure Logic Apps resolves the outbound-MDN signing certificate from the **host partner**, and
the host's private `*-signing` is bound via the **send**-block override (supplier send
`:730` = `supplier-signing` private; the purchaser already holds `purchaser-signing` private from the
send epic). So the intended behavior — MDN signed by the host private cert — is expressed.

**Why it is security-SAFE regardless of how the runtime resolves it:**
- Signing is impossible without a private key, so the failure mode is a **missing / wrongly-identified
  MDN**, never a leak of the partner's key or a broken trust boundary.
- Inbound **decrypt** (own private) and **verify** (partner public) are bound correctly and
  independently of the MDN path — message confidentiality/integrity do not depend on this.
- Design §0.6 / risk table make a missing/negative MDN **non-fatal** (recorded as a tracked property,
  not gated on). No security control rides on the MDN.

**Verdict:** not a must-fix. If a live AS2 round-trip shows the MDN unsigned or signed with the wrong
identity, the remedy is a receive-block signing-cert swap (Kaylee D-K3) — a functional fix owned by
Wash's AS2-Decode verification, not a security gate.

### 3. RBAC — ✅ PASS (no new edge, least-privilege intact)
- `infra/rbac/role-assignments.bicep` is **unchanged** on this branch (empty diff). The three new
  private-key refs (`supplier-encryption`, `supplier-signing`, `purchaser-encryption`) resolve
  through the **existing vault-scoped** Azure Logic Apps first-party SP grant
  (`7cd684f4-8a78-49b0-91ec-6a35d38739ba` = KV Crypto User + KV Secrets User on the shared vault;
  `.squad/decisions.md:140,210-211`). Grant is scoped to the whole shared vault, not per-secret, so
  every key resolves with **zero** new role assignments. Mal §4.2 / Kaylee D-K7 confirmed. ✅
- No over-broad role (no Owner/Contributor); first-party SP holds only the two data-plane KV roles. ✅
- `SupplierRole` is **`sup`-only**: `REVOKE INSERT/EXECUTE ON SCHEMA::dbo` (idempotent) +
  `GRANT INSERT/EXECUTE ON SCHEMA::sup` (`create-users-roles.sql`). ✅
- `PurchaserRole` retains `GRANT SELECT/EXECUTE ON SCHEMA::dbo`. ✅

### 4. Managed identity everywhere — ✅ PASS
- `logicapps/supplier/connections.json`: SQL and Service Bus both `parameterSetName:
  ManagedServiceIdentity` / `authProvider.Type: ManagedServiceIdentity`. No connection strings/keys. ✅
- AS2 / X12 are **native in-app** actions (`AS2Decode`, `X12Decode`, `X12Encode` — no
  `serviceProviderConfiguration`, no `connections.json` entry). ✅
- `keyVaultReferenceIdentity: uamiId` (`logicapp-bundle.bicep:316`) — every `@Microsoft.KeyVault(...)`
  app setting resolves via the app's user-assigned identity. ✅
- New/existing KV-ref app settings — `WORKFLOW_INTEGRATION_ACCOUNT_CALLBACK_URL`,
  `Purchaser997EndpointUrl` (`logicapp-bundle.bicep:250-251,281`) — are all
  `@Microsoft.KeyVault(SecretUri=...)`. SQL contained users are SID-based external (`TYPE = E`), no
  passwords. Agreement-name settings (`X12SendAgreementName` etc.) are non-secret plain strings. ✅

### 5. Secret leakage — ✅ PASS
- Diff grep for `sig=`, `AccountKey=`, `SharedAccessKey`, `BEGIN * PRIVATE KEY`, `password`, `MII...`
  → **no committed secret material.** `passwordValue: ''` (empty AS2 X12 password) is the only
  `password` hit. Markdown `-----` hits are table rules, not PEM.
- The two runtime callback URLs are **CI-generated into KV secrets**, never committed: `listCallbackUrl`
  read at deploy time → `az keyvault secret set ... --only-show-errors 1>/dev/null` (value never echoed;
  only the secret **name** is printed) — `deploy.yml` dual-injection + supplier IA callback steps.
- Storage `$KEY` / `$SAS` for the 2.15 MB 850 contentLink are **runtime-only** shell vars
  (`az storage account keys list` / `generate-sas`), never echoed, folded into the ARM request body
  via `jq`; SAS expiry capped at 2h. No key/SAS persisted to source.
- No secret in `.squad/` inbox files or `docs/` (design cert table lists cert **names**, not material).

---

## Hand-offs
- **Wash:** during AS2-Decode verification, confirm on a live round-trip that each returned MDN is
  signed by the host's own `*-signing` PRIVATE cert (L1 / Kaylee D-K3). Security-non-blocking.
- **Coordinator:** L2 (CRL disabled + `ignoreCertificateNameMismatch`) is an accepted demo posture;
  record it so a future prod-hardening pass revisits it. No change required this epic.

*Signed: Zoe — Security Engineer. Every private key stayed in the vault; every connection authenticates
without a secret. Ship it.*
