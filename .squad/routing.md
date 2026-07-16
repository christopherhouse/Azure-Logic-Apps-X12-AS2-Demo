# Work Routing

How to decide who handles what.

## Routing Table

| Work Type | Route To | Examples |
|-----------|----------|----------|
| Architecture & flow design | Mal | AS2/X12 end-to-end flow, integration topology, deploy ordering, agreements wiring |
| Infra & deployment | Kaylee | Bicep, Azure Verified Modules, multi-RG/region, subscription-scoped deploy, CI/CD pipelines |
| Logic App workflows | Wash | workflow.json authoring, AS2 decode/encode, X12 encode/decode, MDN/ack generation, connectors |
| Security & identity | Zoe | Managed identity, RBAC least-privilege, Key Vault, AS2 certificates, OIDC/federated auth, secret-leakage review |
| EDI specs & mapping | Simon | X12 850/855/997, ISA/GS/ST envelopes, schemas (.xsd), maps (.xslt), partner mapping specs |
| Testing & QA | Jayne | EDI round-trip validation, MDN/ack checks, sample payloads, edge cases, deploy verification |
| Documentation | Book | README, deploy guide, trading-partner onboarding, architecture docs |
| Code review | Mal | Review PRs, check quality, enforce reviewer gates |
| Scope & priorities | Mal | What to build next, trade-offs, decisions |
| Session logging | Scribe | Automatic — never needs routing |
| RAI review | Rai | Content safety, bias checks, credential detection, ethical review |
| Verification & devil's advocate | Fact Checker | Verify claims/commands/URLs, challenge design assumptions |

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| `squad` | Triage: analyze issue, assign `squad:{member}` label | Lead |
| `squad:{name}` | Pick up issue and complete the work | Named member |

### How Issue Assignment Works

1. When a GitHub issue gets the `squad` label, the **Lead** triages it — analyzing content, assigning the right `squad:{member}` label, and commenting with triage notes.
2. When a `squad:{member}` label is applied, that member picks up the issue in their next session.
3. Members can reassign by removing their label and adding another member's label.
4. The `squad` label is the "inbox" — untriaged issues waiting for Lead review.

## Rules

1. **Eager by default** — spawn all agents who could usefully start work, including anticipatory downstream work.
2. **Scribe always runs** after substantial work, always as `mode: "background"`. Never blocks.
3. **Quick facts → coordinator answers directly.** Don't spawn an agent for "what port does the server run on?"
4. **When two agents could handle it**, pick the one whose domain is the primary concern.
5. **"Team, ..." → fan-out.** Spawn all relevant agents in parallel as `mode: "background"`.
6. **Anticipate downstream work.** If a feature is being built, spawn the tester to write test cases from requirements simultaneously.
7. **Issue-labeled work** — when a `squad:{member}` label is applied to an issue, route to that member. The Lead handles all `squad` (base label) triage.
