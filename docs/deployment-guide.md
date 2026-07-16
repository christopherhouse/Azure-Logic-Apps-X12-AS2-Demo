# Azure Logic Apps AS2/X12 EDI Demo — Deployment Guide

> **Audience:** Azure operators deploying the EDI demo environment from scratch.  
> **Prerequisite reading:** [`README.md`](../README.md) for architecture overview; [`docs/infra-deploy-ordering.md`](infra-deploy-ordering.md) for the resource-dependency rationale.

This guide provides **exact, serialized CLI steps** to deploy the complete environment. Each step includes the precise command, expected output, and verification.

---

## Table of Contents

1. [Prerequisites and Required Roles](#1-prerequisites-and-required-roles)
2. [OIDC Deployment Identity Setup](#2-oidc-deployment-identity-setup)
3. [Deploy Infrastructure](#3-deploy-infrastructure)
4. [Post-Deployment: Generate and Publish Certificates](#4-post-deployment-generate-and-publish-certificates)
5. [Verification](#5-verification)
6. [Teardown](#6-teardown)
7. [Troubleshooting](#7-troubleshooting)

---

## 1. Prerequisites and Required Roles

### 1.1 Required Tools

Install and authenticate with the following tools before proceeding:

| Tool | Minimum Version | Installation |
|---|---|---|
| **Azure CLI** | 2.50.0+ | [Install Azure CLI](https://aka.ms/install-azure-cli) |
| **GitHub CLI** | 2.20.0+ | [Install GitHub CLI](https://cli.github.com/) |
| **Bicep CLI** | Bundled with Azure CLI 2.20.0+ | `az bicep version` to verify |
| **PowerShell 7+** | 7.0+ (or Windows PowerShell 5.1+) | [Install PowerShell 7](https://aka.ms/powershell) |
| **Git** | Any recent version | [Install Git](https://git-scm.com/) |

**Verification:**

```powershell
# Verify Azure CLI
az version

# Verify GitHub CLI
gh --version

# Verify Bicep
az bicep version

# Verify PowerShell
$PSVersionTable.PSVersion
```

### 1.2 Azure Subscription and Tenant

This demo targets a specific Azure subscription and tenant (locked by Christopher House, 2026-07-16):

| Parameter | Value |
|---|---|
| **Subscription ID** | `8bd05b2f-62c5-4def-9869-f0617ebb3970` |
| **Tenant ID** | `76de2d2d-77f8-438d-9a87-01806f2345da` |

### 1.3 Required Azure RBAC Roles

The identity deploying the infrastructure must hold the following roles **at subscription scope** (not just resource-group scope, because the deployment itself creates the resource groups and role assignments):

- **Contributor** (`b24988ac-6180-42a0-ab88-20f7382dd24c`)
- **User Access Administrator** (`18d7d88d-d35e-4fb5-a5c3-7773c20a72d9`)

Additionally, the deployment service principal must be a **member of the SQL Entra admin group** (`b9dac399-abc0-479d-9900-f2115a98297d`) so the CI pipeline can authenticate to SQL and create contained users.

**Why subscription scope?**

The Bicep deployment is **subscription-scoped** (`targetScope='subscription'`) and creates three resource groups programmatically. A deployment identity scoped only to resource groups cannot authorize creating those resource groups or assigning roles within them. Therefore, Contributor + User Access Administrator must be granted at the **subscription** level.

**Security note:** These are elevated permissions. This demo is intentionally configured for a development/demo subscription. For production environments, follow the principle of least privilege and consider using a dedicated management group or subscription for infrastructure automation.

### 1.4 SQL Entra Admin Group

The SQL Server uses **Entra-only authentication** with an Entra security group as the admin. The deployment service principal must be added to this group:

- **Group Object ID:** `b9dac399-abc0-479d-9900-f2115a98297d`
- **Group Name:** (verify with `az ad group show --group b9dac399-abc0-479d-9900-f2115a98297d --query displayName`)

This allows the CI pipeline (running as the deployment service principal) to authenticate to SQL and execute the T-SQL script that creates contained users for both Logic App UAMIs and the custom roles (PurchaserRole, SupplierRole).

---

## 2. OIDC Deployment Identity Setup

GitHub Actions workflows use **OIDC federated credentials** to authenticate to Azure without storing secrets. This section creates the Entra app registration, configures the federated credential, assigns roles, adds the principal to the SQL admin group, and publishes the GitHub repository secrets.

> **Authorization note:** The steps below require you to be authenticated as a user with sufficient Entra and Azure permissions. This is a **one-time operator setup** authorized by Christopher House using his `az`/`gh` logins. (As of 2026-07-16, `gh` re-auth is pending.)

### 2.1 Authenticate to Azure and GitHub

```powershell
# Authenticate to Azure
az login --tenant 76de2d2d-77f8-438d-9a87-01806f2345da

# Set the target subscription
az account set --subscription 8bd05b2f-62c5-4def-9869-f0617ebb3970

# Authenticate to GitHub (required for setting secrets)
gh auth login
```

**Expected output:**
- Azure CLI: account details for subscription `8bd05b2f-...`
- GitHub CLI: "Logged in to github.com as <your-username>"

### 2.2 Create an Entra App Registration

```powershell
# Create the app registration
$appName = "sp-github-edi-demo-deploy"
$app = az ad app create --display-name $appName | ConvertFrom-Json

# Store the app (client) ID for later steps
$clientId = $app.appId
Write-Host "App (Client) ID: $clientId" -ForegroundColor Green

# Create a service principal for the app
az ad sp create --id $clientId
```

**Expected output:**
- App (Client) ID: `<GUID>` (save this value)
- Service principal created for the app

### 2.3 Configure Federated Credential for GitHub OIDC

```powershell
# Define the federated credential for the GitHub repo
$repoOwner = "christopherhouse"
$repoName = "Azure-Logic-Apps-X12-AS2-Demo"

# Create the federated credential for the main branch (adjust if using a different branch/environment)
$credentialParams = @{
    name = "github-oidc-main"
    issuer = "https://token.actions.githubusercontent.com"
    subject = "repo:$repoOwner/$repoName:ref:refs/heads/main"
    audiences = @("api://AzureADTokenExchange")
} | ConvertTo-Json -Depth 10

# Save to a temporary file (Azure CLI requires a JSON file for this command)
$credentialFile = ".\federated-credential.json"
$credentialParams | Out-File $credentialFile -Encoding utf8

# Create the federated credential
az ad app federated-credential create --id $clientId --parameters $credentialFile

# Clean up the temp file
Remove-Item $credentialFile
```

**Expected output:**
- Federated credential created for `repo:christopherhouse/Azure-Logic-Apps-X12-AS2-Demo:ref:refs/heads/main`

**Note:** If you are running workflows from a different branch (e.g., `dev`) or using GitHub Environments, adjust the `subject` claim accordingly:
- Branch: `repo:<owner>/<repo>:ref:refs/heads/<branch>`
- Environment: `repo:<owner>/<repo>:environment:<env-name>`
- Pull request: `repo:<owner>/<repo>:pull_request`

### 2.4 Assign Contributor and User Access Administrator Roles at Subscription Scope

```powershell
# Get the service principal object ID
$spObjectId = az ad sp show --id $clientId --query id -o tsv

# Assign Contributor role at subscription scope
az role assignment create `
    --assignee $spObjectId `
    --role "Contributor" `
    --scope "/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970"

# Assign User Access Administrator role at subscription scope
az role assignment create `
    --assignee $spObjectId `
    --role "User Access Administrator" `
    --scope "/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970"
```

**Expected output:**
- Two role assignments created (Contributor and User Access Administrator)

**Verification:**

```powershell
az role assignment list --assignee $spObjectId --scope "/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970" -o table
```

You should see both Contributor and User Access Administrator in the output.

### 2.5 Add Service Principal to SQL Entra Admin Group

```powershell
# Add the service principal to the SQL admin group
az ad group member add `
    --group b9dac399-abc0-479d-9900-f2115a98297d `
    --member-id $spObjectId
```

**Expected output:**
- Member added successfully

**Verification:**

```powershell
az ad group member check `
    --group b9dac399-abc0-479d-9900-f2115a98297d `
    --member-id $spObjectId
```

Output should be `true`.

### 2.6 Set GitHub Repository Secrets

```powershell
# Set the required secrets for GitHub Actions
gh secret set AZURE_CLIENT_ID --body $clientId --repo $repoOwner/$repoName
gh secret set AZURE_TENANT_ID --body "76de2d2d-77f8-438d-9a87-01806f2345da" --repo $repoOwner/$repoName
gh secret set AZURE_SUBSCRIPTION_ID --body "8bd05b2f-62c5-4def-9869-f0617ebb3970" --repo $repoOwner/$repoName
```

**Expected output:**
- ✓ Set secret AZURE_CLIENT_ID for christopherhouse/Azure-Logic-Apps-X12-AS2-Demo
- ✓ Set secret AZURE_TENANT_ID for christopherhouse/Azure-Logic-Apps-X12-AS2-Demo
- ✓ Set secret AZURE_SUBSCRIPTION_ID for christopherhouse/Azure-Logic-Apps-X12-AS2-Demo

**Verification:**

```powershell
gh secret list --repo $repoOwner/$repoName
```

You should see `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID` listed.

---

## 3. Deploy Infrastructure

### 3.1 Clone the Repository

```powershell
# Clone the repository
git clone https://github.com/christopherhouse/Azure-Logic-Apps-X12-AS2-Demo.git
cd Azure-Logic-Apps-X12-AS2-Demo
```

### 3.2 Review Parameters

The parameter file is `infra/main.bicepparam`. The locked parameters are:

| Parameter | Default Value | Description |
|---|---|---|
| `namingToken` | `'jci'` | CAF naming token (deterministic resource names) |
| `environmentName` | `'dev'` | Environment (dev, test, prod) |
| `sharedLocation` | `'centralus'` | Location for shared resources and supplier |
| `purchaserLocation` | `'eastus2'` | Location for purchaser resources |
| `enablePurgeProtection` | `false` | Key Vault purge protection (false for dev/test) |

**No changes are required** for the default dev environment. For production, set `enablePurgeProtection` to `true`.

### 3.3 Execute the Subscription-Scoped Deployment

```powershell
# Ensure you are authenticated and the correct subscription is set
az account show

# Deploy (subscription-scoped)
$deploymentName = "edi-demo-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

az deployment sub create `
    --location centralus `
    --template-file infra\main.bicep `
    --parameters infra\main.bicepparam `
    --name $deploymentName
```

**Expected duration:** 10–15 minutes

**Expected output:**
- Resource groups created: `rg-edi-shared`, `rg-edi-supplier`, `rg-edi-purchaser`
- Shared tier deployed: Log Analytics Workspace, Application Insights, Key Vault, SQL Server + DB, Service Bus
- UAMIs created: `id-purchaser-jci-edi-dev`, `id-supplier-jci-edi-dev`
- Compute bundles deployed: 2 Logic Apps (empty), 2 storage accounts, 2 Free Integration Accounts
- RBAC assignments completed

### 3.4 Capture Deployment Outputs

```powershell
# Retrieve deployment outputs
$outputs = az deployment sub show --name $deploymentName --query properties.outputs -o json | ConvertFrom-Json

# Key Vault name (needed for cert generation in the next step)
$keyVaultName = $outputs.keyVaultName.value
Write-Host "`nKey Vault Name: $keyVaultName" -ForegroundColor Cyan

# Display other important outputs
Write-Host "`nSQL Server FQDN: $($outputs.sqlServerFqdn.value)" -ForegroundColor Cyan
Write-Host "Service Bus Namespace: $($outputs.serviceBusFullyQualifiedNamespace.value)" -ForegroundColor Cyan
Write-Host "Purchaser Logic App: $($outputs.purchaserLogicAppName.value)" -ForegroundColor Cyan
Write-Host "Supplier Logic App: $($outputs.supplierLogicAppName.value)" -ForegroundColor Cyan
```

---

## 4. Post-Deployment: Generate and Publish Certificates

The infrastructure deployment is **incomplete without AS2 certificates**. Certificates must be generated and published to Key Vault **after** Key Vault exists and **before** the Logic App workflows are deployed (future work).

This step is **not automated** in the Bicep deployment or CI/CD pipelines. It is a **one-time manual operator action** (work item #8).

### 4.1 Prerequisites

- Key Vault must exist (completed in step 3.3)
- Your Azure CLI identity must hold **Key Vault Certificates Officer** and **Key Vault Secrets Officer** roles on the Key Vault

**Grant yourself the required roles (if not already assigned):**

```powershell
# Get your current user object ID
$currentUserObjectId = az ad signed-in-user show --query id -o tsv

# Assign Key Vault Certificates Officer
az role assignment create `
    --assignee $currentUserObjectId `
    --role "Key Vault Certificates Officer" `
    --scope "/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970/resourceGroups/rg-edi-shared/providers/Microsoft.KeyVault/vaults/$keyVaultName"

# Assign Key Vault Secrets Officer
az role assignment create `
    --assignee $currentUserObjectId `
    --role "Key Vault Secrets Officer" `
    --scope "/subscriptions/8bd05b2f-62c5-4def-9869-f0617ebb3970/resourceGroups/rg-edi-shared/providers/Microsoft.KeyVault/vaults/$keyVaultName"
```

### 4.2 Run the Certificate Generation Script

```powershell
# Navigate to the scripts directory
cd infra\scripts

# Run the script with the Key Vault name from step 3.4
.\generate-certificates.ps1 -KeyVaultName $keyVaultName
```

**What this does:**
- Generates a **Demo Root CA** (self-signed, valid 10 years, 4096-bit RSA)
- Generates **four AS2 leaf certificates** (valid 2 years, 2048-bit RSA):
  - `demo-as2-purchaser-signing` (DigitalSignature, NonRepudiation)
  - `demo-as2-purchaser-encryption` (KeyEncipherment, DataEncipherment)
  - `demo-as2-supplier-signing` (DigitalSignature, NonRepudiation)
  - `demo-as2-supplier-encryption` (KeyEncipherment, DataEncipherment)
- Imports each certificate directly into Key Vault using `az keyvault certificate import`
- **No files are written to disk** — all cert generation happens in-memory

**Expected output:**

```
==> Validating prerequisites...
    [OK] Azure CLI authenticated; Key Vault 'kv-jci-edi-dev-abc12345' is accessible.

==> Generating Demo Root CA...
    [OK] Root CA 'demo-as2-root-ca' imported to Key Vault.

==> Generating and importing leaf certificates...
    [OK] Certificate 'demo-as2-purchaser-signing' imported to Key Vault.
    [OK] Certificate 'demo-as2-purchaser-encryption' imported to Key Vault.
    [OK] Certificate 'demo-as2-supplier-signing' imported to Key Vault.
    [OK] Certificate 'demo-as2-supplier-encryption' imported to Key Vault.

==> Certificate generation complete!

Generated/imported certificates in Key Vault 'kv-jci-edi-dev-abc12345':
  - demo-as2-root-ca (Demo Root CA)
  - demo-as2-purchaser-signing (Purchaser Signing)
  - demo-as2-purchaser-encryption (Purchaser Encryption)
  - demo-as2-supplier-signing (Supplier Signing)
  - demo-as2-supplier-encryption (Supplier Encryption)
```

**Verification:**

```powershell
az keyvault certificate list --vault-name $keyVaultName -o table
```

You should see 5 certificates listed.

### 4.3 Idempotency Note

The script checks for existing certificates before creating new ones. If a certificate already exists, it is skipped with a `[SKIP]` message. To regenerate a certificate, delete it from Key Vault first:

```powershell
az keyvault certificate delete --vault-name $keyVaultName --name demo-as2-purchaser-signing
```

---

## 5. Verification

### 5.1 Verify Resource Groups

```powershell
az group list --query "[?contains(name, 'rg-edi')].{Name:name, Location:location, ProvisioningState:properties.provisioningState}" -o table
```

**Expected output:**

| Name | Location | ProvisioningState |
|---|---|---|
| rg-edi-shared | centralus | Succeeded |
| rg-edi-supplier | centralus | Succeeded |
| rg-edi-purchaser | eastus2 | Succeeded |

### 5.2 Verify Logic Apps

```powershell
az logicapp list --query "[].{Name:name, ResourceGroup:resourceGroup, State:state, DefaultHostName:defaultHostName}" -o table
```

**Expected output:**

| Name | ResourceGroup | State | DefaultHostName |
|---|---|---|---|
| logic-purchaser-jci-edi-dev-... | rg-edi-purchaser | Running | logic-purchaser-....azurewebsites.net |
| logic-supplier-jci-edi-dev-... | rg-edi-supplier | Running | logic-supplier-....azurewebsites.net |

### 5.3 Verify Key Vault Certificates

```powershell
az keyvault certificate list --vault-name $keyVaultName --query "[].{Name:name, Enabled:attributes.enabled, Expires:attributes.expires}" -o table
```

**Expected output:** 5 certificates (root CA + 4 AS2 leaf certs)

### 5.4 Verify SQL Database

```powershell
az sql db list --resource-group rg-edi-shared --server $($outputs.sqlServerFqdn.value.Split('.')[0]) --query "[].{Name:name, Status:status, Sku:sku.name}" -o table
```

**Expected output:**

| Name | Status | Sku |
|---|---|---|
| sqldb-edi-... | Online | GP_S_Gen5_1 (or similar Serverless SKU) |

### 5.5 Verify Service Bus Topic and Subscription

```powershell
$serviceBusNamespace = $outputs.serviceBusFullyQualifiedNamespace.value.Split('.')[0]

az servicebus topic show --resource-group rg-edi-shared --namespace-name $serviceBusNamespace --name purchase-orders.received --query "{Name:name, Status:status}" -o table

az servicebus topic subscription show --resource-group rg-edi-shared --namespace-name $serviceBusNamespace --topic-name purchase-orders.received --name all-messages --query "{Name:name, Status:status}" -o table
```

**Expected output:** Topic and subscription both show `Status: Active`

### 5.6 Verify RBAC Assignments

```powershell
# Check Purchaser UAMI has Service Bus Data Sender
az role assignment list --assignee $outputs.purchaserUamiPrincipalId.value --scope $outputs.serviceBusNamespaceId.value --query "[].{Role:roleDefinitionName}" -o table

# Check Supplier UAMI has Service Bus Data Receiver
az role assignment list --assignee $outputs.supplierUamiPrincipalId.value --scope $outputs.serviceBusNamespaceId.value --query "[].{Role:roleDefinitionName}" -o table
```

**Expected output:**
- Purchaser: `Azure Service Bus Data Sender`
- Supplier: `Azure Service Bus Data Receiver`

---

## 6. Teardown

To fully remove the environment:

### 6.1 Delete Resource Groups

```powershell
# Delete all three resource groups
az group delete --name rg-edi-shared --yes --no-wait
az group delete --name rg-edi-supplier --yes --no-wait
az group delete --name rg-edi-purchaser --yes --no-wait
```

**Duration:** 5–10 minutes (asynchronous; `--no-wait` returns immediately)

### 6.2 Purge Key Vault

Key Vault soft delete is **enabled** but purge protection is **false** (default). After the resource group is deleted, the Key Vault enters a soft-deleted state. Purge it to fully remove:

```powershell
# Wait for resource group deletion to complete (optional)
az group wait --name rg-edi-shared --deleted

# Purge the soft-deleted Key Vault
az keyvault purge --name $keyVaultName
```

**Verification:**

```powershell
az keyvault list-deleted --query "[?name=='$keyVaultName']" -o table
```

If the output is empty, the vault has been purged.

### 6.3 Remove Deployment Identity (Optional)

If you no longer need the deployment service principal:

```powershell
# Remove the app registration (this also deletes the service principal)
az ad app delete --id $clientId
```

---

## 7. Troubleshooting

### 7.1 Deployment Fails with "Insufficient Permissions to Create Resource Groups"

**Cause:** The deployment identity does not have Contributor or User Access Administrator at subscription scope.

**Solution:** Follow [Section 2.4](#24-assign-contributor-and-user-access-administrator-roles-at-subscription-scope) to assign the roles at the correct scope.

### 7.2 Certificate Script Fails with "Key Vault 'xyz' does not exist or is not accessible"

**Cause:** Either the Key Vault has not been deployed yet, or your Azure CLI identity does not have the required RBAC roles.

**Solution:**
1. Verify the Key Vault exists: `az keyvault show --name $keyVaultName`
2. If it exists, verify you have Certificates Officer + Secrets Officer roles (see [Section 4.1](#41-prerequisites))

### 7.3 Logic Apps Show "Stopped" State After Deployment

**Cause:** The Logic Apps may start in a stopped state if the content-share connection string is not yet configured (deferred to CI pipeline in future work item).

**Solution:** This is expected for the current Infrastructure v1.0 deliverable. The `deploy.yml` pipeline will publish the content-share secrets and restart the apps (work item #20, currently a placeholder).

### 7.4 SQL Connection Fails from Logic App

**Cause:** SQL contained users and custom roles (PurchaserRole, SupplierRole) are created by a CI/runner T-SQL step (work item #15) that runs post-`main.bicep` in `deploy.yml`. This is not yet implemented.

**Solution:** Until `deploy.yml` is fully implemented, SQL contained users do not exist. The Logic Apps will have network + RBAC permissions but no database principal. This is documented as DEFERRED in the README.

### 7.5 Deployment Takes Longer Than Expected

**Cause:** Azure region capacity, Service Bus/SQL provisioning delays, or RBAC propagation latency.

**Solution:** Wait an additional 5–10 minutes. If the deployment times out, check the Azure Portal deployment logs for the specific resource that is delaying.

### 7.6 GitHub Actions Workflow Fails with "OIDC Token Exchange Failed"

**Cause:** Federated credential subject claim does not match the branch/environment where the workflow is running.

**Solution:** Verify the `subject` claim in [Section 2.3](#23-configure-federated-credential-for-github-oidc) matches your workflow's branch or environment. Update the federated credential if necessary:

```powershell
az ad app federated-credential list --id $clientId -o table
```

### 7.7 "gh secret set" Fails with Authentication Error

**Cause:** GitHub CLI is not authenticated or does not have permission to set secrets on the repository.

**Solution:**
1. Re-authenticate: `gh auth login`
2. Verify you have admin or write permissions on the repository
3. If using a personal access token, ensure it has the `repo` and `admin:repo_hook` scopes

---

## Next Steps

After successful deployment and verification:

1. **Review the deployed resources** in the Azure Portal
2. **Test the Logic Apps** — currently empty; workflows will be added in a future specification
3. **Configure trading partners** (DEFERRED) — see [`docs/trading-partner-onboarding.md`](trading-partner-onboarding.md)
4. **Deploy X12 schemas and maps** (DEFERRED)
5. **Implement and deploy Logic App workflows** (DEFERRED)
6. **Test the end-to-end PO exchange flow** (DEFERRED)

For the architectural rationale and resource-dependency DAG, see [`docs/infra-deploy-ordering.md`](infra-deploy-ordering.md).

---

**End of Deployment Guide**
