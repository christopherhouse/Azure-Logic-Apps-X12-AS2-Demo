# Infrastructure Scripts

This directory contains **manually-run infrastructure scripts** that are **NOT** part of the automated Bicep deployment or CI/CD pipelines. These scripts must be executed by an authenticated operator at specific points in the deployment sequence (see `docs/infra-deploy-ordering.md`).

---

## generate-certificates.ps1

### Purpose
Generates a **Demo Root CA** and **four AS2 leaf certificates** (Purchaser Signing, Purchaser Encryption, Supplier Signing, Supplier Encryption) and publishes them to Azure Key Vault.

This script is **work item #8** and is a **manual, one-time operator action**. It is **NOT**:
- A Bicep Deployment Script
- Part of the `deploy.yml` CI/CD pipeline
- Automated in any way

### Prerequisites
1. **Azure CLI** installed and authenticated (`az login`)
2. The **Key Vault must already exist** (provisioned by `main.bicep` work item #7)
3. The **operator principal** must hold the following RBAC roles on the Key Vault:
   - **Key Vault Certificates Officer** (`00482a5a-887f-4fb3-b363-3b7fe8e74483`)
   - **Key Vault Secrets Officer** (`b86a8fe4-44ce-4948-aee5-eccb2c155cd7`)

   The Logic App UAMIs get **only** read-only roles (Certificate User + Secrets User).

4. **PowerShell 7+** (or Windows PowerShell 5.1+)

### When to Run
- **After:** Key Vault is provisioned (work item #7, deploy sequence step 6)
- **Before:** App settings are configured (work item #17, deploy sequence step 13)
- **Trigger:** After running `az deployment sub create ... --template-file infra/main.bicep` and confirming the Key Vault exists

### Usage

```powershell
# 1. Ensure you are logged in to Azure CLI with an identity that has Certificates Officer + Secrets Officer on the Key Vault
az login

# 2. Run the script with the Key Vault name (from main.bicep outputs or Azure Portal)
cd infra/scripts
.\generate-certificates.ps1 -KeyVaultName "kv-jci-edi-dev-abc12345"

# Optional: specify a custom cert name prefix (default: "demo-as2")
.\generate-certificates.ps1 -KeyVaultName "kv-jci-edi-dev-abc12345" -CertPrefix "my-as2"
```

### What It Does
1. Validates Azure CLI authentication and Key Vault accessibility
2. Generates a **self-signed Demo Root CA** (valid 10 years, 4096-bit RSA)
3. Generates **four leaf certificates** (valid 2 years, 2048-bit RSA):
   - `demo-as2-purchaser-signing` (DigitalSignature, NonRepudiation)
   - `demo-as2-purchaser-encryption` (KeyEncipherment, DataEncipherment)
   - `demo-as2-supplier-signing` (DigitalSignature, NonRepudiation)
   - `demo-as2-supplier-encryption` (KeyEncipherment, DataEncipherment)
4. Imports each certificate directly into Key Vault using `az keyvault certificate import`
5. **No files are written to disk or committed** — all cert generation happens in-memory

### Idempotency
The script checks if each certificate already exists in the vault. If it does, the script skips that cert and logs a message. To regenerate a cert, delete it from Key Vault first.

### Security Notes
- These are **NON-SENSITIVE demo certificates** generated for the EDI demo environment.
- The private keys are generated in-memory and published directly to Key Vault; **no .pfx/.cer/.pem files are written to disk or committed to the repository**.
- The certificates are self-signed and **not suitable for production**.
- For production, use a proper CA (e.g., DigiCert, Entrust) or Azure Certificate Services.

### Troubleshooting

**Error: "Key Vault 'xyz' does not exist or is not accessible"**
- The Key Vault has not been deployed yet. Run the Bicep deployment first.
- Your Azure CLI identity does not have the required RBAC roles. Ask a Key Vault Administrator to grant you Certificates Officer + Secrets Officer.

**Error: "Failed to import certificate to Key Vault"**
- Check RBAC: your identity needs **both** Certificates Officer and Secrets Officer roles.
- Check Key Vault firewall/networking: ensure "Allow Azure services" is enabled (it is, per the spec).

**Error: "Not logged in to Azure CLI"**
- Run `az login` and ensure you are authenticated to the correct subscription.

---

## Future Scripts

Additional scripts for operational tasks (e.g., SQL role/user creation, cert rotation) will be added here as needed.

Each script will follow the same pattern:
- **Manually run** by an authenticated operator
- **NOT part of Bicep or CI/CD automation**
- Clearly documented prerequisites, usage, and when-to-run timing
- Idempotent-friendly where possible

---

**For the full infrastructure deployment ordering, see:** `docs/infra-deploy-ordering.md`
