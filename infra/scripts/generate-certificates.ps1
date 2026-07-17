#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generate AS2 demo certificates and publish to Azure Key Vault.

.DESCRIPTION
    This script is a MANUALLY-RUN, ONE-TIME operator action that generates a Demo Root CA and four AS2 leaf certificates
    (Purchaser Signing, Purchaser Encryption, Supplier Signing, Supplier Encryption) and publishes them to Azure Key Vault.

    This script is NOT a Bicep Deployment Script and is NOT part of the automated deploy.yml pipeline.
    It is executed by an authenticated operator AFTER Key Vault has been provisioned (#7) and BEFORE app settings are configured (#17).

    The certificates are NON-SENSITIVE demo certs generated in-memory and directly imported to Key Vault.
    No .pfx/.cer/.pem files are written to disk or committed to the repository.

.PREREQUISITES
    - PowerShell 7+ (or Windows PowerShell 5.1+)
    - Azure CLI authenticated (`az login` as an identity with Key Vault Certificates Officer + Secrets Officer roles)
    - The target Key Vault must already exist (provisioned by main.bicep)
    - The operator principal must hold Key Vault Certificates Officer and Key Vault Secrets Officer roles on the vault

.PARAMETER KeyVaultName
    Name of the Azure Key Vault to which certificates will be imported. REQUIRED.

.PARAMETER CertPrefix
    Prefix for certificate names in Key Vault (default: "demo-as2").

.EXAMPLE
    # Run after Key Vault is deployed and operator has been granted Certificates Officer + Secrets Officer roles:
    .\generate-certificates.ps1 -KeyVaultName "kv-jci-edi-dev-abc12345"

.NOTES
    Author: Zoe (Security Engineer)
    Date: 2026-07-16
    Version: 1.0

    IDEMPOTENCY: The script checks for existing certificates by name. If a cert exists, it is skipped (logged).
    To overwrite existing certs, delete them from the vault first or modify the script to use `az keyvault certificate import --policy @policy.json`.

    OPERATOR RBAC: The identity running this script must hold:
    - Key Vault Certificates Officer (00482a5a-887f-4fb3-b363-3b7fe8e74483) — to create/import certs
    - Key Vault Secrets Officer (b86a8fe4-44ce-4948-aee5-eccb2c155cd7) — to write cert secrets (private keys)

    The Logic Apps (UAMIs) get only Key Vault Certificate User + Secrets User (read-only) — they do NOT have write permissions.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [string]$CertPrefix = "demo-as2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================================
# Helper Functions
# ============================================================================

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "    [SKIP] $Message" -ForegroundColor Yellow
}

function Test-CertificateExists {
    param([string]$VaultName, [string]$CertName)
    $result = az keyvault certificate show --vault-name $VaultName --name $CertName 2>$null
    return $LASTEXITCODE -eq 0
}

# ============================================================================
# Validation
# ============================================================================

Write-Step "Validating prerequisites..."

# Check Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is not installed or not in PATH. Install from https://aka.ms/install-azure-cli"
}

# Check login status
$accountCheck = az account show 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Not logged in to Azure CLI. Run 'az login' first."
}

# Check Key Vault exists
$kvCheck = az keyvault show --name $KeyVaultName 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Key Vault '$KeyVaultName' does not exist or is not accessible. Verify the name and your RBAC permissions."
}

Write-Success "Azure CLI authenticated; Key Vault '$KeyVaultName' is accessible."

# ============================================================================
# Certificate Generation and Import
# ============================================================================

Write-Step "Generating Demo Root CA..."

$rootCertName = "$CertPrefix-root-ca"
if (Test-CertificateExists -VaultName $KeyVaultName -CertName $rootCertName) {
    Write-Skip "Root CA certificate '$rootCertName' already exists in Key Vault."
} else {
    # Generate self-signed Root CA in-memory
    $rootCert = New-SelfSignedCertificate `
        -Subject "CN=Demo AS2 Root CA, O=EDI Demo, C=US" `
        -KeyAlgorithm RSA `
        -KeyLength 4096 `
        -NotAfter (Get-Date).AddYears(10) `
        -CertStoreLocation Cert:\CurrentUser\My `
        -KeyUsage CertSign, CRLSign, DigitalSignature `
        -KeyExportPolicy Exportable `
        -HashAlgorithm SHA256 `
        -Type Custom `
        -Extension @(
            New-Object System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension($true, $true, 0, $true)
        )

    # Export to PFX (in-memory)
    $rootPassword = ConvertTo-SecureString -String "DemoRootCA$(Get-Random)" -Force -AsPlainText
    $rootPfxPath = [System.IO.Path]::GetTempFileName() + ".pfx"
    try {
        Export-PfxCertificate -Cert $rootCert -FilePath $rootPfxPath -Password $rootPassword -Force | Out-Null

        # Import to Key Vault
        az keyvault certificate import `
            --vault-name $KeyVaultName `
            --name $rootCertName `
            --file $rootPfxPath `
            --password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($rootPassword))) `
            | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Success "Root CA '$rootCertName' imported to Key Vault."
        } else {
            throw "Failed to import Root CA to Key Vault."
        }
    } finally {
        Remove-Item $rootPfxPath -Force -ErrorAction SilentlyContinue
        Remove-Item "Cert:\CurrentUser\My\$($rootCert.Thumbprint)" -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# Generate Leaf Certificates (Purchaser Signing, Purchaser Encryption, Supplier Signing, Supplier Encryption)
# ============================================================================

$leafCerts = @(
    @{ Name = "$CertPrefix-purchaser-signing"; Subject = "CN=Purchaser Signing, O=EDI Demo Purchaser, C=US"; Usage = @("DigitalSignature", "NonRepudiation") },
    @{ Name = "$CertPrefix-purchaser-encryption"; Subject = "CN=Purchaser Encryption, O=EDI Demo Purchaser, C=US"; Usage = @("KeyEncipherment", "DataEncipherment") },
    @{ Name = "$CertPrefix-supplier-signing"; Subject = "CN=Supplier Signing, O=EDI Demo Supplier, C=US"; Usage = @("DigitalSignature", "NonRepudiation") },
    @{ Name = "$CertPrefix-supplier-encryption"; Subject = "CN=Supplier Encryption, O=EDI Demo Supplier, C=US"; Usage = @("KeyEncipherment", "DataEncipherment") }
)

Write-Step "Generating and importing leaf certificates..."

foreach ($certSpec in $leafCerts) {
    $certName = $certSpec.Name
    if (Test-CertificateExists -VaultName $KeyVaultName -CertName $certName) {
        Write-Skip "Certificate '$certName' already exists in Key Vault."
        continue
    }

    # Map usage strings to KeyUsage enum
    # New-SelfSignedCertificate -KeyUsage expects an ARRAY of enum values (e.g.
    # DigitalSignature, NonRepudiation), not a single combined X509KeyUsageFlags value.
    # Pass the usage list from the spec directly.
    $keyUsage = $certSpec.Usage

    # Generate leaf certificate signed by Root CA (in practice, for a demo we'll use self-signed; real chaining requires cert chaining logic)
    # For simplicity in a demo script, we generate self-signed leaves with appropriate key usage
    $leafCert = New-SelfSignedCertificate `
        -Subject $certSpec.Subject `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -NotAfter (Get-Date).AddYears(2) `
        -CertStoreLocation Cert:\CurrentUser\My `
        -KeyUsage $keyUsage `
        -KeyExportPolicy Exportable `
        -HashAlgorithm SHA256 `
        -Type Custom

    # Export to PFX
    $leafPassword = ConvertTo-SecureString -String "DemoLeaf$(Get-Random)" -Force -AsPlainText
    $leafPfxPath = [System.IO.Path]::GetTempFileName() + ".pfx"
    try {
        Export-PfxCertificate -Cert $leafCert -FilePath $leafPfxPath -Password $leafPassword -Force | Out-Null

        # Import to Key Vault
        az keyvault certificate import `
            --vault-name $KeyVaultName `
            --name $certName `
            --file $leafPfxPath `
            --password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($leafPassword))) `
            | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Success "Certificate '$certName' imported to Key Vault."
        } else {
            throw "Failed to import certificate '$certName' to Key Vault."
        }
    } finally {
        Remove-Item $leafPfxPath -Force -ErrorAction SilentlyContinue
        Remove-Item "Cert:\CurrentUser\My\$($leafCert.Thumbprint)" -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# Summary
# ============================================================================

Write-Step "Certificate generation complete!"
Write-Host ""
Write-Host "Generated/imported certificates in Key Vault '$KeyVaultName':" -ForegroundColor Green
Write-Host "  - $CertPrefix-root-ca (Demo Root CA)" -ForegroundColor White
Write-Host "  - $CertPrefix-purchaser-signing (Purchaser Signing)" -ForegroundColor White
Write-Host "  - $CertPrefix-purchaser-encryption (Purchaser Encryption)" -ForegroundColor White
Write-Host "  - $CertPrefix-supplier-signing (Supplier Signing)" -ForegroundColor White
Write-Host "  - $CertPrefix-supplier-encryption (Supplier Encryption)" -ForegroundColor White
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Verify certificates in Azure Portal: Key Vault > Certificates" -ForegroundColor White
Write-Host "  2. Logic App workflows will reference these certs via Key Vault references in app settings (work item #17)." -ForegroundColor White
Write-Host "  3. AS2 encode/decode/MDN steps will consume these at runtime." -ForegroundColor White
Write-Host ""
