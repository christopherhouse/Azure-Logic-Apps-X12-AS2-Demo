# Squad Team

> AzLogicAppsAS2X12Demo

## Coordinator

| Name | Role | Notes |
|------|------|-------|
| Squad | Coordinator | Routes work, enforces handoffs and reviewer gates. |

## Members

| Name | Role | Charter | Status |
|------|------|---------|--------|
| Mal | Lead / Integration Architect | .squad/agents/mal/charter.md | 🏗️ Lead |
| Kaylee | Infra / DevOps Engineer | .squad/agents/kaylee/charter.md | 🔧 Infra |
| Wash | Logic Apps / EDI Developer | .squad/agents/wash/charter.md | 🔌 Workflows |
| Zoe | Security Engineer | .squad/agents/zoe/charter.md | 🔒 Security |
| Jayne | Tester / QA | .squad/agents/jayne/charter.md | 🧪 QA |
| Book | Technical Writer | .squad/agents/book/charter.md | 📝 Docs |
| Simon | EDI Analyst | .squad/agents/simon/charter.md | 📊 EDI |
| Scribe | Session Logger | .squad/agents/scribe/charter.md | 📋 Scribe |
| Ralph | Work Monitor | .squad/agents/ralph/charter.md | 🔄 Monitor |
| Rai | RAI Reviewer | .squad/agents/Rai/charter.md | 🛡️ RAI |
| Fact Checker | Fact Checker | .squad/agents/fact-checker/charter.md | 🔍 Verifier |


## Coding Agent

<!-- copilot-auto-assign: false -->

| Name | Role | Charter | Status |
|------|------|---------|--------|
| @copilot | Coding Agent | — | 🤖 Coding Agent |

### Capabilities

**🟢 Good fit — auto-route when enabled:**
- Bug fixes with clear reproduction steps
- Test coverage (adding missing tests, fixing flaky tests)
- Lint/format fixes and code style cleanup
- Dependency updates and version bumps
- Small isolated features with clear specs
- Boilerplate/scaffolding generation
- Documentation fixes and README updates

**🟡 Needs review — route to @copilot but flag for squad member PR review:**
- Medium features with clear specs and acceptance criteria
- Refactoring with existing test coverage
- API endpoint additions following established patterns
- Migration scripts with well-defined schemas

**🔴 Not suitable — route to squad member instead:**
- Architecture decisions and system design
- Multi-system integration requiring coordination
- Ambiguous requirements needing clarification
- Security-critical changes (auth, encryption, access control)
- Performance-critical paths requiring benchmarking
- Changes requiring cross-team discussion

## Project Context

- **Project:** AzLogicAppsAS2X12Demo — end-to-end Logic Apps Standard EDI/AS2 demo (purchaser + supplier PO exchange)
- **Owner:** Christopher House
- **Stack:** Azure Logic Apps Standard, AS2 + X12 EDI, Bicep + Azure Verified Modules (subscription-scoped, multi-RG, multi-region), GitHub Actions CI/CD
- **Security mandate:** Managed identity only — no connection strings unless absolutely necessary (documented + Key Vault referenced)
- **Universe:** Firefly
- **Created:** 2026-07-16

## PRD Source

**Path:** docs/Azure-Logic-Apps-EDI-Infrastructure-Engineering-Spec.md
**Scope:** Infrastructure v1.0 (workflows, SQL schema, X12, AS2, partners, agreements, maps are deferred to future specs)
**Ingested:** 2026-07-16
**Hash:** 289A12660936FD7DAEAD1A4A212D4368DF6838934C049BBC9FB4016C240A5285
