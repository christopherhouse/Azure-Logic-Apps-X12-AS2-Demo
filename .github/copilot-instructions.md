# Copilot instructions for AzLogicAppsAS2X12Demo

> **Repository status:** Greenfield / empty. This is a **demo** of **X12** (EDI) and **AS2**
> processing on Azure. Nothing has been committed yet — the sections below describe where the
> project is headed so future Copilot sessions build in the right places with the right
> conventions. Replace the `TBD` markers with real, verified commands and paths as each piece
> lands, and keep this file in sync with the code.

## What this repo is

A demonstration of business-document exchange over **AS2** with **X12** EDI translation,
orchestrated by **Azure Logic Apps**. Planned deliverables:

- **IaC (Bicep)** — provisions the Azure resources: Logic Apps, Integration Account (trading
  partners, AS2 + X12 agreements, schemas, maps), storage, Key Vault, and connections.
- **Logic App workflows** — orchestrate the AS2/X12 message flow (receive → decode → validate
  → transform → route → encode → send, plus acknowledgments).
- **CI/CD assets** — pipeline definitions to build/validate and deploy the IaC and workflows
  across environments.
- **README and docs** — how to deploy, configure trading partners, and run the demo.

## Planned repository layout

This is the intended shape (create these as you go; adjust the tree to match reality and
delete this note once the structure is real):

- `infra/` — Bicep templates and parameter files (`main.bicep`, modules, `*.bicepparam` or
  `*.parameters.json`).
- `logicapp/` (or `workflows/`) — Logic App workflow definitions and, for Standard, the
  `workflow.json` per workflow plus host/app settings.
- Integration Account artifacts — `schemas/` (`.xsd`), `maps/` (`.xslt`), and
  partner/agreement definitions.
- `.github/workflows/` — CI/CD pipeline(s).
- `samples/` — non-sensitive sample X12 payloads and expected outputs for the demo.
- `README.md` — deploy + run instructions.

## Commands (fill in as they exist)

Record the exact, verified invocation for each — do not guess:

- **Bicep build/lint:** `az bicep build --file infra/main.bicep` / `az bicep lint ...` — _confirm_
- **Deploy IaC:** `az deployment {sub|group} create ...` (or `azd up` if `azd` is adopted) — _TBD_
- **Deploy workflows:** _TBD_
- **Validate / test:** full run — _TBD_; **single test / single message round-trip** — _TBD_
  (this is required once tests exist).
- **Local Logic App (Standard) run, if used:** typically `func start` in the logic app folder — _confirm_

## Architecture to document (the "big picture")

Capture these once built, since they span multiple files:

- **End-to-end message flow:** AS2 receive → AS2 decode (+ MDN) → X12 decode → schema
  validation → XSLT transform → routing → X12 encode → AS2 encode → send, and where the X12
  acknowledgments (997/999/TA1) are generated.
- **Integration Account wiring:** which agreements/partners/schemas/maps each workflow binds
  to, and the deploy ordering (Integration Account artifacts must exist before workflows that
  reference them).
- **Environment config:** how AS2 identifiers/qualifiers, certificates, and connection values
  flow from Bicep parameters → app settings / Key Vault into the workflows.
- **CI/CD:** what the pipeline builds, validates, and deploys, and how environments (dev/test/
  prod) are parameterized and promoted.

## Branching & PR workflow

- **Branch off `main`.** All work happens on a new branch created from an up-to-date `main`;
  never commit directly to `main`.
- **Branch naming:** use a type prefix matching the work — `feature/<short-description>`,
  `bugfix/<short-description>`, or `chore/<short-description>` (e.g., `feature/as2-decode-workflow`).
- **The agent may** create branches, commit, push, and open pull requests.
- **The agent must never merge pull requests.** Merging is a human decision — leave the PR
  open for review and hand it off.

## Conventions to record here as they emerge

- Naming for resources, schemas, maps, partners, and agreements.
- X12 transaction sets and versions in scope for the demo (e.g., 850, 810, 997).
- How workflows reference Integration Account artifacts.
- Any required deploy ordering or manual post-deploy steps.

## Guardrails

- Never commit secrets, connection strings, or private keys/certificates — use Key Vault and
  parameter/app-setting references.
- Keep only **non-sensitive** sample EDI payloads and test certificates in the repo.
