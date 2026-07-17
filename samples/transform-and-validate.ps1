<#
  transform-and-validate.ps1
  ============================================================================
  Jayne's QA harness for the purchaser PO -> X12 850 (006030) transform.

  What it does (all via .NET System.Xml, XSLT 1.0 = the stylesheet's version):
    1. Validate the intermediate canonical XML against PurchaseOrder_Canonical.xsd.
    2. Run the REAL map (PO_Canonical_to_X12_850_006030.xslt) over that canonical
       XML -> X12 850 XML. Writes samples/expected/purchase-order.sample.850.xml.
    3. Validate the produced 850 XML against the official Microsoft X12_00603_850.xsd.

  This mirrors workflow steps 5a (xml/json), 5b (Transform XML), and the schema
  the X12 Encode step (5c) uses. It does NOT exercise Service Bus, SQL, AS2, or
  control-number generation (those require a deployed environment).

  Usage:  pwsh -File samples/transform-and-validate.ps1
  Exit code 0 = all PASS, non-zero = at least one FAIL.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

$canonicalXsd = Join-Path $RepoRoot 'logicapps/purchaser/Artifacts/Schemas/PurchaseOrder_Canonical.xsd'
$map          = Join-Path $RepoRoot 'logicapps/purchaser/Artifacts/Maps/PO_Canonical_to_X12_850_006030.xslt'
$x12Xsd       = Join-Path $RepoRoot 'infra/integration-account/schemas/X12_00603_850.xsd'
$canonicalXml = Join-Path $RepoRoot 'samples/expected/purchase-order.sample.canonical.xml'
$outXml       = Join-Path $RepoRoot 'samples/expected/purchase-order.sample.850.xml'

$x12Ns = 'http://schemas.microsoft.com/BizTalk/EDI/X12/2006'

$failures = New-Object System.Collections.Generic.List[string]

function Test-XmlAgainstXsd {
    param([string]$XmlPath, [string]$XsdPath, [string]$TargetNs, [string]$Label)
    $errs = New-Object System.Collections.Generic.List[string]
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.ValidationType = [System.Xml.ValidationType]::Schema
    [void]$settings.Schemas.Add($TargetNs, $XsdPath)
    $handler = [System.Xml.Schema.ValidationEventHandler]{
        param($s, $e) $errs.Add("$($e.Severity): $($e.Message)")
    }
    $settings.add_ValidationEventHandler($handler)
    $reader = [System.Xml.XmlReader]::Create($XmlPath, $settings)
    try { while ($reader.Read()) { } } finally { $reader.Dispose() }
    if ($errs.Count -eq 0) {
        Write-Host "  PASS  $Label" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  FAIL  $Label" -ForegroundColor Red
        $errs | Select-Object -First 15 | ForEach-Object { Write-Host "        $_" -ForegroundColor Yellow }
        return $false
    }
}

Write-Host "== 1. Validate canonical XML against PurchaseOrder_Canonical.xsd ==" -ForegroundColor Cyan
if (-not (Test-XmlAgainstXsd -XmlPath $canonicalXml -XsdPath $canonicalXsd -TargetNs $null -Label 'canonical XML -> PurchaseOrder_Canonical.xsd')) {
    $failures.Add('canonical-xml-invalid')
}

Write-Host "== 2. Run XSLT map (canonical XML -> X12 850 XML) ==" -ForegroundColor Cyan
try {
    $xslt = New-Object System.Xml.Xsl.XslCompiledTransform
    $xsltSettings = New-Object System.Xml.Xsl.XsltSettings($false, $false)
    $resolver = New-Object System.Xml.XmlUrlResolver
    $xslt.Load($map, $xsltSettings, $resolver)

    $writerSettings = New-Object System.Xml.XmlWriterSettings
    $writerSettings.Indent = $true
    $writerSettings.Encoding = New-Object System.Text.UTF8Encoding($false)

    # Pass input as XmlReader so xsl:strip-space works (loaded XmlDocument is rejected).
    $inReader = [System.Xml.XmlReader]::Create($canonicalXml)
    $writer = [System.Xml.XmlWriter]::Create($outXml, $writerSettings)
    try { $xslt.Transform($inReader, $writer) } finally { $writer.Dispose(); $inReader.Dispose() }
    Write-Host "  PASS  transform produced $outXml" -ForegroundColor Green
} catch {
    Write-Host "  FAIL  transform threw: $($_.Exception.Message)" -ForegroundColor Red
    $failures.Add('transform-threw')
}

Write-Host "== 3. Validate produced 850 XML against X12_00603_850.xsd ==" -ForegroundColor Cyan
if (Test-Path $outXml) {
    if (-not (Test-XmlAgainstXsd -XmlPath $outXml -XsdPath $x12Xsd -TargetNs $x12Ns -Label '850 XML -> X12_00603_850.xsd')) {
        $failures.Add('x12-output-invalid')
    }
} else {
    Write-Host "  SKIP  no output file to validate" -ForegroundColor Yellow
    $failures.Add('no-output')
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host "ALL PASS — canonical valid, transform ran, 850 output validates against 006030 schema." -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILURES: $($failures -join ', ')" -ForegroundColor Red
    exit 1
}
