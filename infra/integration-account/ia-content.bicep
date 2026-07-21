// Integration Account CONTENT for the purchaser (send-only this epic)
// ============================================================================
// Registers the trading partners, AS2 certificate artifacts, and the X12 + AS2
// SEND agreements onto the ALREADY-EXISTING purchaser Free Integration Account
// (created empty by infra/compute/logicapp-bundle.bicep).
//
// WHY A SEPARATE, CI-DRIVEN DEPLOYMENT (not part of main.bicep):
//   1. The 2.15 MB X12_00603_850.xsd EXCEEDS the inline `content` limit for
//      Microsoft.Logic/integrationAccounts/schemas AND the ARM/Bicep resource
//      does not expose `contentLink` as a writable input — so the schema is
//      registered OUT OF BAND via the Logic REST API (`contentLink` = blob SAS
//      URL) in deploy.yml BEFORE this module runs. See design §4.3 / §8-C.
//   2. The supplier-encryption PUBLIC certificate body and the purchaser-signing
//      Key Vault key reference are only resolvable at deploy time (the certs are
//      produced by the out-of-band cert-gen script, #8). CI reads the public
//      cert from Key Vault and passes it in as a parameter.
//   3. The X12/AS2 agreements resolve the schema + certs BY NAME, so those
//      artifacts must exist first. Ordering is enforced by deploy.yml §8.
//
// This module therefore runs as a resource-group-scoped deployment AFTER:
//   B0. IA identity granted KV Crypto User + Secrets User (main.bicep RBAC)
//   B.  cert artifacts depend on the certs already being in Key Vault (#8)
//   C.  X12_00603_850 schema registered via REST contentLink (deploy.yml)
//
// Content bodies are transcribed VERBATIM from Simon's build spec
// (infra/integration-account/agreements/README.md §1–§3), shaped to ARM API
// version 2019-05-01.

targetScope = 'resourceGroup'

// ============================================================================
// PARAMETERS
// ============================================================================

@description('Name of the purchaser Free Integration Account (already created by the compute bundle).')
param integrationAccountName string

@description('Resource ID of the shared Key Vault (rg-edi-shared) that holds the AS2 certificate keys.')
param keyVaultResourceId string

@description('Key Vault KEY name backing the purchaser SIGNING private certificate (design §5.5).')
param purchaserSigningKeyName string = 'demo-as2-purchaser-signing'

@description('''Optional Key Vault key VERSION for the purchaser signing key. Leave empty to bind the
LATEST version (recommended for the demo).''')
param purchaserSigningKeyVersion string = ''

@description('''Base64-encoded PUBLIC certificate (DER `.cer`) for the purchaser SIGNING cert
(`demo-as2-purchaser-signing`). Required because a private IA certificate must carry its public
cert body alongside the Key Vault key reference. Read from Key Vault by CI at deploy time:
`az keyvault certificate show --vault-name <kv> --name demo-as2-purchaser-signing --query cer -o tsv`.''')
param purchaserSigningPublicCertificate string

@description('''Base64-encoded PUBLIC certificate (DER `.cer`) for the supplier ENCRYPTION cert
(`demo-as2-supplier-encryption`). Read from Key Vault by CI at deploy time:
`az keyvault certificate show --vault-name <kv> --name demo-as2-supplier-encryption --query cer -o tsv`.''')
param supplierEncryptionPublicCertificate string

@description('X12 SEND agreement name. MUST equal the purchaser app setting `X12AgreementName` (design §5.4).')
param x12AgreementName string = 'Purchaser-Supplier-X12'

@description('AS2 SEND agreement name.')
param as2AgreementName string = 'Purchaser-Supplier-AS2'

@description('IA schema artifact name the X12 agreement resolves by name (registered out-of-band via REST contentLink).')
param schemaName string = 'X12_00603_850'

@description('IA certificate artifact name for the purchaser signing (private) cert.')
param purchaserSigningCertName string = 'purchaser-signing'

@description('IA certificate artifact name for the supplier encryption (public) cert.')
param supplierEncryptionCertName string = 'supplier-encryption'

// --- RECEIVE-SIDE additions (supplier-inbound 997 epic, design §3.2/§4) --------------
@description('Key Vault KEY name backing the purchaser ENCRYPTION private cert (decrypt inbound 997, design §4.1).')
param purchaserEncryptionKeyName string = 'demo-as2-purchaser-encryption'

@description('Optional Key Vault key VERSION for the purchaser encryption key. Empty => LATEST (recommended for the demo).')
param purchaserEncryptionKeyVersion string = ''

@description('''Base64 PUBLIC cert (DER .cer) for the purchaser ENCRYPTION cert (`demo-as2-purchaser-encryption`).
Carried alongside the KV key on the PRIVATE purchaser-encryption artifact used to DECRYPT the inbound 997.
CI: `az keyvault certificate show --vault-name <kv> --name demo-as2-purchaser-encryption --query cer -o tsv`.''')
param purchaserEncryptionPublicCertificate string = ''

@description('''Base64 PUBLIC cert (DER .cer) for the supplier SIGNING cert (`demo-as2-supplier-signing`).
PUBLIC-only artifact used to VALIDATE the supplier's inbound 997 + MDN signature. CI reads it from Key Vault.''')
param supplierSigningPublicCertificate string = ''

@description('X12 RECEIVE agreement name for the inbound 997 (design §3.2, Simon D-997-3 C). LOCKED.')
param x12Receive997AgreementName string = 'Purchaser-Supplier-X12-997'

@description('IA schema artifact name for the 997 (registered INLINE by this module, design §3.2).')
param schema997Name string = 'X12_00603_997'

@description('IA certificate artifact name for the purchaser ENCRYPTION (private) cert.')
param purchaserEncryptionCertName string = 'purchaser-encryption'

@description('IA certificate artifact name for the supplier SIGNING (public) cert.')
param supplierSigningCertName string = 'supplier-signing'

@description('''Activate the AS2 RECEIVE block cert bindings (decrypt inbound 997 + verify supplier signature +
signed MDN). Kept as a flag so an infra run without the two new receive-side public certs stays green: when the
purchaser-encryption / supplier-signing public bodies are absent, CI passes false and the receive block stays
in its inactive (send-only) shape. Design §3.2 / §5.2.''')
param activateAs2Receive bool = !empty(purchaserEncryptionPublicCertificate) && !empty(supplierSigningPublicCertificate)

// ============================================================================
// EXISTING — purchaser Integration Account (created empty by the compute bundle)
// ============================================================================
resource integrationAccount 'Microsoft.Logic/integrationAccounts@2019-05-01' existing = {
  name: integrationAccountName
}

// ============================================================================
// TRADING PARTNERS (design §5.2 / README §1) — ZZ business identities
// ============================================================================
resource partnerPurchaser 'Microsoft.Logic/integrationAccounts/partners@2019-05-01' = {
  parent: integrationAccount
  name: 'Purchaser'
  properties: {
    partnerType: 'B2B'
    content: {
      b2b: {
        businessIdentities: [
          { qualifier: 'ZZ', value: 'PURCHASER01' }
        ]
      }
    }
  }
}

resource partnerSupplier 'Microsoft.Logic/integrationAccounts/partners@2019-05-01' = {
  parent: integrationAccount
  name: 'Supplier'
  properties: {
    partnerType: 'B2B'
    content: {
      b2b: {
        businessIdentities: [
          { qualifier: 'ZZ', value: 'SUPPLIER01' }
        ]
      }
    }
  }
}

// ============================================================================
// CERTIFICATE ARTIFACTS (design §5.5 / README §3)
//   - purchaser-signing = PRIVATE: references the Key Vault KEY (no embedded key)
//   - supplier-encryption = PUBLIC: base64 public cert, no Key Vault reference
// The Logic Apps first-party SP (7cd684f4-...) reads the KV key; its RBAC grant
// is provisioned by main.bicep (Zoe, step B0) before this module runs.
// ============================================================================
resource purchaserSigningCert 'Microsoft.Logic/integrationAccounts/certificates@2019-05-01' = {
  parent: integrationAccount
  name: purchaserSigningCertName
  properties: {
    // A private IA certificate needs BOTH the public certificate body (so the IA knows the
    // cert's public part) AND the Key Vault key reference (private key for signing). The AS2
    // agreement that references this cert requires publicCertificate to be present.
    publicCertificate: purchaserSigningPublicCertificate
    key: {
      keyName: purchaserSigningKeyName
      keyVault: {
        id: keyVaultResourceId
      }
      keyVersion: empty(purchaserSigningKeyVersion) ? null : purchaserSigningKeyVersion
    }
  }
}

resource supplierEncryptionCert 'Microsoft.Logic/integrationAccounts/certificates@2019-05-01' = {
  parent: integrationAccount
  name: supplierEncryptionCertName
  properties: {
    publicCertificate: supplierEncryptionPublicCertificate
  }
}

// ============================================================================
// RECEIVE-SIDE CERTIFICATE ARTIFACTS (supplier-inbound 997 epic, design §4.1)
//   - purchaser-encryption = PRIVATE: public body + Key Vault KEY ref (decrypt inbound 997)
//   - supplier-signing     = PUBLIC : base64 public cert (verify supplier 997 + MDN signature)
// Guarded on activateAs2Receive so an infra run without the receive-side public certs stays green.
// ============================================================================
resource purchaserEncryptionCert 'Microsoft.Logic/integrationAccounts/certificates@2019-05-01' = if (activateAs2Receive) {
  parent: integrationAccount
  name: purchaserEncryptionCertName
  properties: {
    publicCertificate: purchaserEncryptionPublicCertificate
    key: {
      keyName: purchaserEncryptionKeyName
      keyVault: {
        id: keyVaultResourceId
      }
      keyVersion: empty(purchaserEncryptionKeyVersion) ? null : purchaserEncryptionKeyVersion
    }
  }
}

resource supplierSigningCert 'Microsoft.Logic/integrationAccounts/certificates@2019-05-01' = if (activateAs2Receive) {
  parent: integrationAccount
  name: supplierSigningCertName
  properties: {
    publicCertificate: supplierSigningPublicCertificate
  }
}

// ============================================================================
// 997 SCHEMA (INLINE) — the purchaser IA must resolve the 997 to DECODE it
// (design §3.2). The 31 KB xsd fits under the 2 MB inline limit, so it is
// registered here via loadTextContent() (unlike the 2.15 MB 850 via contentLink).
// ============================================================================
resource schema997 'Microsoft.Logic/integrationAccounts/schemas@2019-05-01' = {
  parent: integrationAccount
  name: schema997Name
  properties: {
    schemaType: 'Xml'
    contentType: 'application/xml'
    content: loadTextContent('schemas/X12_00603_997.xsd')
  }
}

// ============================================================================
// X12 SEND AGREEMENT (design §5.4 / README §2.1)
// Send side fully specified; receive side is the schema-required symmetric mirror.
// Control numbers are agreement-generated (ISA13/GS06/ST02 rollover enabled).
// Delimiters (ASCII): dataElementSeparator 42 '*', componentSeparator 62 '>',
// segmentTerminator 126 '~'. usageIndicator 'Test' => ISA15 'T'.
// schemaName MUST match the IA schema artifact registered out-of-band (§8-C).
// ============================================================================
resource x12Agreement 'Microsoft.Logic/integrationAccounts/agreements@2019-05-01' = {
  parent: integrationAccount
  name: x12AgreementName
  properties: {
    hostPartner: 'Purchaser'
    guestPartner: 'Supplier'
    hostIdentity: { qualifier: 'ZZ', value: 'PURCHASER01' }
    guestIdentity: { qualifier: 'ZZ', value: 'SUPPLIER01' }
    agreementType: 'X12'
    content: {
      x12: {
        receiveAgreement: {
          senderBusinessIdentity: { qualifier: 'ZZ', value: 'SUPPLIER01' }
          receiverBusinessIdentity: { qualifier: 'ZZ', value: 'PURCHASER01' }
          protocolSettings: {
            validationSettings: {
              validateCharacterSet: true
              checkDuplicateInterchangeControlNumber: false
              interchangeControlNumberValidityDays: 30
              checkDuplicateGroupControlNumber: false
              checkDuplicateTransactionSetControlNumber: false
              validateEDITypes: true
              validateXSDTypes: false
              allowLeadingAndTrailingSpacesAndZeroes: false
              trimLeadingAndTrailingSpacesAndZeroes: false
              trailingSeparatorPolicy: 'NotAllowed'
            }
            framingSettings: {
              dataElementSeparator: 42
              componentSeparator: 62
              replaceSeparatorsInPayload: false
              replaceCharacter: 36
              segmentTerminator: 126
              characterSet: 'UTF8'
              segmentTerminatorSuffix: 'None'
            }
            envelopeSettings: {
              controlStandardsId: 85
              useControlStandardsIdAsRepetitionCharacter: false
              senderApplicationId: 'SUPPLIER01'
              receiverApplicationId: 'PURCHASER01'
              controlVersionNumber: '00603'
              enableDefaultGroupHeaders: true
              groupHeaderAgencyCode: 'X'
              groupHeaderVersion: '006030'
              groupHeaderDateFormat: 'CCYYMMDD'
              groupHeaderTimeFormat: 'HHMM'
              functionalGroupId: 'PO'
              groupControlNumberLowerBound: 1
              groupControlNumberUpperBound: 999999999
              rolloverGroupControlNumber: true
              interchangeControlNumberLowerBound: 1
              interchangeControlNumberUpperBound: 999999999
              rolloverInterchangeControlNumber: true
              overwriteExistingTransactionSetControlNumber: true
              transactionSetControlNumberLowerBound: 1
              transactionSetControlNumberUpperBound: 999999999
              rolloverTransactionSetControlNumber: true
              usageIndicator: 'Test'
            }
            acknowledgementSettings: {
              needTechnicalAcknowledgement: false
              batchTechnicalAcknowledgements: false
              needFunctionalAcknowledgement: false
              batchFunctionalAcknowledgements: false
              needImplementationAcknowledgement: false
              batchImplementationAcknowledgements: false
              needLoopForValidMessages: false
              sendSynchronousAcknowledgement: false
              acknowledgementControlNumberLowerBound: 1
              acknowledgementControlNumberUpperBound: 999999999
              rolloverAcknowledgementControlNumber: true
            }
            messageFilter: { messageFilterType: 'Exclude' }
            securitySettings: { authorizationQualifier: '00', securityQualifier: '00', passwordValue: '' }
            processingSettings: {
              maskSecurityInfo: true
              convertImpliedDecimal: true
              preserveInterchange: false
              suspendInterchangeOnError: false
              createEmptyXmlTagsForTrailingSeparators: false
              useDotAsDecimalSeparator: true
            }
            schemaReferences: [
              {
                messageId: '850'
                senderApplicationId: 'SUPPLIER01'
                schemaVersion: '00603'
                schemaName: schemaName
              }
            ]
            envelopeOverrides: []
            validationOverrides: []
            messageFilterList: []
            x12DelimiterOverrides: []
          }
        }
        sendAgreement: {
          senderBusinessIdentity: { qualifier: 'ZZ', value: 'PURCHASER01' }
          receiverBusinessIdentity: { qualifier: 'ZZ', value: 'SUPPLIER01' }
          protocolSettings: {
            validationSettings: {
              validateCharacterSet: true
              checkDuplicateInterchangeControlNumber: false
              interchangeControlNumberValidityDays: 30
              checkDuplicateGroupControlNumber: false
              checkDuplicateTransactionSetControlNumber: false
              validateEDITypes: true
              validateXSDTypes: false
              allowLeadingAndTrailingSpacesAndZeroes: false
              trimLeadingAndTrailingSpacesAndZeroes: false
              trailingSeparatorPolicy: 'NotAllowed'
            }
            framingSettings: {
              dataElementSeparator: 42
              componentSeparator: 62
              replaceSeparatorsInPayload: false
              replaceCharacter: 36
              segmentTerminator: 126
              characterSet: 'UTF8'
              segmentTerminatorSuffix: 'None'
            }
            envelopeSettings: {
              controlStandardsId: 85
              useControlStandardsIdAsRepetitionCharacter: false
              senderApplicationId: 'PURCHASER01'
              receiverApplicationId: 'SUPPLIER01'
              controlVersionNumber: '00603'
              enableDefaultGroupHeaders: true
              groupHeaderAgencyCode: 'X'
              groupHeaderVersion: '006030'
              groupHeaderDateFormat: 'CCYYMMDD'
              groupHeaderTimeFormat: 'HHMM'
              functionalGroupId: 'PO'
              groupControlNumberLowerBound: 1
              groupControlNumberUpperBound: 999999999
              rolloverGroupControlNumber: true
              interchangeControlNumberLowerBound: 1
              interchangeControlNumberUpperBound: 999999999
              rolloverInterchangeControlNumber: true
              overwriteExistingTransactionSetControlNumber: true
              transactionSetControlNumberLowerBound: 1
              transactionSetControlNumberUpperBound: 999999999
              rolloverTransactionSetControlNumber: true
              usageIndicator: 'Test'
            }
            acknowledgementSettings: {
              needTechnicalAcknowledgement: false
              batchTechnicalAcknowledgements: false
              needFunctionalAcknowledgement: false
              batchFunctionalAcknowledgements: false
              needImplementationAcknowledgement: false
              batchImplementationAcknowledgements: false
              needLoopForValidMessages: false
              sendSynchronousAcknowledgement: false
              acknowledgementControlNumberLowerBound: 1
              acknowledgementControlNumberUpperBound: 999999999
              rolloverAcknowledgementControlNumber: true
            }
            messageFilter: { messageFilterType: 'Exclude' }
            securitySettings: { authorizationQualifier: '00', securityQualifier: '00', passwordValue: '' }
            processingSettings: {
              maskSecurityInfo: true
              convertImpliedDecimal: true
              preserveInterchange: false
              suspendInterchangeOnError: false
              createEmptyXmlTagsForTrailingSeparators: false
              useDotAsDecimalSeparator: true
            }
            schemaReferences: [
              {
                messageId: '850'
                schemaVersion: '00603'
                schemaName: schemaName
              }
            ]
            envelopeOverrides: []
            validationOverrides: []
            messageFilterList: []
            x12DelimiterOverrides: []
          }
        }
      }
    }
  }
  dependsOn: [
    partnerPurchaser
    partnerSupplier
  ]
}

// ============================================================================
// AS2 SEND AGREEMENT (design §5.3 / README §2.2)
// Send: sign SHA-256 (purchaser-signing private cert) + encrypt AES-256
// (supplier-encryption public cert); synchronous signed MDN requested.
// MDN NON-FATAL settlement is enforced by the workflow (Wash), not the agreement.
// securitySettings names the IA certificate artifacts created above.
// ============================================================================
resource as2Agreement 'Microsoft.Logic/integrationAccounts/agreements@2019-05-01' = {
  parent: integrationAccount
  name: as2AgreementName
  properties: {
    hostPartner: 'Purchaser'
    guestPartner: 'Supplier'
    hostIdentity: { qualifier: 'AS2Identity', value: 'PURCHASER01' }
    guestIdentity: { qualifier: 'AS2Identity', value: 'SUPPLIER01' }
    agreementType: 'AS2'
    content: {
      aS2: {
        receiveAgreement: {
          senderBusinessIdentity: { qualifier: 'AS2Identity', value: 'SUPPLIER01' }
          receiverBusinessIdentity: { qualifier: 'AS2Identity', value: 'PURCHASER01' }
          protocolSettings: {
            messageConnectionSettings: {
              ignoreCertificateNameMismatch: true
              supportHttpStatusCodeContinue: false
              keepHttpConnectionAlive: true
              unfoldHttpHeaders: true
            }
            acknowledgementConnectionSettings: {
              ignoreCertificateNameMismatch: true
              supportHttpStatusCodeContinue: false
              keepHttpConnectionAlive: true
              unfoldHttpHeaders: true
            }
            mdnSettings: {
              needMDN: activateAs2Receive
              signMDN: activateAs2Receive
              sendMDNAsynchronously: false
              signOutboundMDNIfOptional: activateAs2Receive
              sendInboundMDNToMessageBox: true
              micHashingAlgorithm: 'SHA2256'
              dispositionNotificationTo: 'http://localhost'
              mdnText: ''
            }
            securitySettings: {
              // RECEIVE side (design §4.1): validate the SUPPLIER's inbound 997 + MDN signature with the
              // supplier-signing PUBLIC cert; decrypt the inbound 997 with the purchaser-encryption PRIVATE cert.
              // Activated only when both receive-side certs are present (activateAs2Receive).
              overrideGroupSigningCertificate: activateAs2Receive
              signingCertificateName: activateAs2Receive ? supplierSigningCertName : null
              encryptionCertificateName: activateAs2Receive ? purchaserEncryptionCertName : null
              enableNRRForInboundEncodedMessages: false
              enableNRRForInboundDecodedMessages: false
              enableNRRForOutboundMDN: false
              enableNRRForOutboundEncodedMessages: false
              enableNRRForOutboundDecodedMessages: false
              enableNRRForInboundMDN: false
            }
            validationSettings: {
              overrideMessageProperties: activateAs2Receive
              encryptMessage: activateAs2Receive
              signMessage: activateAs2Receive
              compressMessage: false
              checkDuplicateMessage: false
              interchangeDuplicatesValidityDays: 5
              checkCertificateRevocationListOnReceive: false
              checkCertificateRevocationListOnSend: false
              encryptionAlgorithm: 'AES256'
              signingAlgorithm: 'SHA2256'
            }
            envelopeSettings: {
              messageContentType: 'application/edi-x12'
              transmitFileNameInMimeHeader: false
              fileNameTemplate: '%FILE().ReceivedFileName%'
              suspendMessageOnFileNameGenerationError: true
              autogenerateFileName: false
            }
            errorSettings: {
              suspendDuplicateMessage: false
              resendIfMDNNotReceived: false
            }
          }
        }
        sendAgreement: {
          senderBusinessIdentity: { qualifier: 'AS2Identity', value: 'PURCHASER01' }
          receiverBusinessIdentity: { qualifier: 'AS2Identity', value: 'SUPPLIER01' }
          protocolSettings: {
            messageConnectionSettings: {
              ignoreCertificateNameMismatch: true
              supportHttpStatusCodeContinue: true
              keepHttpConnectionAlive: true
              unfoldHttpHeaders: true
            }
            acknowledgementConnectionSettings: {
              ignoreCertificateNameMismatch: true
              supportHttpStatusCodeContinue: true
              keepHttpConnectionAlive: true
              unfoldHttpHeaders: true
            }
            mdnSettings: {
              needMDN: true
              signMDN: true
              sendMDNAsynchronously: false
              signOutboundMDNIfOptional: true
              sendInboundMDNToMessageBox: true
              micHashingAlgorithm: 'SHA2256'
              dispositionNotificationTo: 'http://localhost'
              mdnText: ''
            }
            securitySettings: {
              overrideGroupSigningCertificate: true
              signingCertificateName: purchaserSigningCertName
              encryptionCertificateName: supplierEncryptionCertName
              enableNRRForInboundEncodedMessages: false
              enableNRRForInboundDecodedMessages: false
              enableNRRForOutboundMDN: false
              enableNRRForOutboundEncodedMessages: false
              enableNRRForOutboundDecodedMessages: false
              enableNRRForInboundMDN: false
            }
            validationSettings: {
              overrideMessageProperties: true
              encryptMessage: true
              signMessage: true
              compressMessage: false
              checkDuplicateMessage: false
              interchangeDuplicatesValidityDays: 5
              checkCertificateRevocationListOnReceive: false
              checkCertificateRevocationListOnSend: false
              encryptionAlgorithm: 'AES256'
              signingAlgorithm: 'SHA2256'
            }
            envelopeSettings: {
              messageContentType: 'application/edi-x12'
              transmitFileNameInMimeHeader: false
              fileNameTemplate: '%FILE().ReceivedFileName%'
              suspendMessageOnFileNameGenerationError: true
              autogenerateFileName: false
            }
            errorSettings: {
              suspendDuplicateMessage: false
              resendIfMDNNotReceived: false
            }
          }
        }
      }
    }
  }
  dependsOn: [
    partnerPurchaser
    partnerSupplier
    purchaserSigningCert
    supplierEncryptionCert
    purchaserEncryptionCert
    supplierSigningCert
  ]
}

// ============================================================================
// X12 RECEIVE AGREEMENT — inbound 997 (design §3.2, Simon D-997-3 C)
// host = Purchaser (PURCHASER01), guest = Supplier (SUPPLIER01). Decodes the
// supplier's 997 (GS01=FA). needFunctionalAcknowledgement = false — you do not
// ACK an ACK. Separate agreement from the live 850 SEND (`Purchaser-Supplier-X12`)
// per the LOCKED build-wave contract.
// ============================================================================
resource x12Receive997Agreement 'Microsoft.Logic/integrationAccounts/agreements@2019-05-01' = {
  parent: integrationAccount
  name: x12Receive997AgreementName
  properties: {
    hostPartner: 'Purchaser'
    guestPartner: 'Supplier'
    hostIdentity: { qualifier: 'ZZ', value: 'PURCHASER01' }
    guestIdentity: { qualifier: 'ZZ', value: 'SUPPLIER01' }
    agreementType: 'X12'
    content: {
      x12: {
        receiveAgreement: {
          senderBusinessIdentity: { qualifier: 'ZZ', value: 'SUPPLIER01' }
          receiverBusinessIdentity: { qualifier: 'ZZ', value: 'PURCHASER01' }
          protocolSettings: {
            validationSettings: {
              validateCharacterSet: true
              checkDuplicateInterchangeControlNumber: false
              interchangeControlNumberValidityDays: 30
              checkDuplicateGroupControlNumber: false
              checkDuplicateTransactionSetControlNumber: false
              validateEDITypes: true
              validateXSDTypes: false
              allowLeadingAndTrailingSpacesAndZeroes: false
              trimLeadingAndTrailingSpacesAndZeroes: false
              trailingSeparatorPolicy: 'NotAllowed'
            }
            framingSettings: {
              dataElementSeparator: 42
              componentSeparator: 62
              replaceSeparatorsInPayload: false
              replaceCharacter: 36
              segmentTerminator: 126
              characterSet: 'UTF8'
              segmentTerminatorSuffix: 'None'
            }
            envelopeSettings: {
              controlStandardsId: 85
              useControlStandardsIdAsRepetitionCharacter: false
              senderApplicationId: 'SUPPLIER01'
              receiverApplicationId: 'PURCHASER01'
              controlVersionNumber: '00603'
              enableDefaultGroupHeaders: true
              groupHeaderAgencyCode: 'X'
              groupHeaderVersion: '006030'
              groupHeaderDateFormat: 'CCYYMMDD'
              groupHeaderTimeFormat: 'HHMM'
              functionalGroupId: 'FA'
              groupControlNumberLowerBound: 1
              groupControlNumberUpperBound: 999999999
              rolloverGroupControlNumber: true
              interchangeControlNumberLowerBound: 1
              interchangeControlNumberUpperBound: 999999999
              rolloverInterchangeControlNumber: true
              overwriteExistingTransactionSetControlNumber: true
              transactionSetControlNumberLowerBound: 1
              transactionSetControlNumberUpperBound: 999999999
              rolloverTransactionSetControlNumber: true
              usageIndicator: 'Test'
            }
            acknowledgementSettings: {
              needTechnicalAcknowledgement: false
              batchTechnicalAcknowledgements: false
              needFunctionalAcknowledgement: false
              batchFunctionalAcknowledgements: false
              needImplementationAcknowledgement: false
              batchImplementationAcknowledgements: false
              needLoopForValidMessages: false
              sendSynchronousAcknowledgement: false
              acknowledgementControlNumberLowerBound: 1
              acknowledgementControlNumberUpperBound: 999999999
              rolloverAcknowledgementControlNumber: true
            }
            messageFilter: { messageFilterType: 'Exclude' }
            securitySettings: { authorizationQualifier: '00', securityQualifier: '00', passwordValue: '' }
            processingSettings: {
              maskSecurityInfo: true
              convertImpliedDecimal: true
              preserveInterchange: false
              suspendInterchangeOnError: false
              createEmptyXmlTagsForTrailingSeparators: false
              useDotAsDecimalSeparator: true
            }
            schemaReferences: [
              {
                messageId: '997'
                senderApplicationId: 'SUPPLIER01'
                schemaVersion: '00603'
                schemaName: schema997Name
              }
            ]
            envelopeOverrides: []
            validationOverrides: []
            messageFilterList: []
            x12DelimiterOverrides: []
          }
        }
        sendAgreement: {
          senderBusinessIdentity: { qualifier: 'ZZ', value: 'PURCHASER01' }
          receiverBusinessIdentity: { qualifier: 'ZZ', value: 'SUPPLIER01' }
          protocolSettings: {
            validationSettings: {
              validateCharacterSet: true
              checkDuplicateInterchangeControlNumber: false
              interchangeControlNumberValidityDays: 30
              checkDuplicateGroupControlNumber: false
              checkDuplicateTransactionSetControlNumber: false
              validateEDITypes: true
              validateXSDTypes: false
              allowLeadingAndTrailingSpacesAndZeroes: false
              trimLeadingAndTrailingSpacesAndZeroes: false
              trailingSeparatorPolicy: 'NotAllowed'
            }
            framingSettings: {
              dataElementSeparator: 42
              componentSeparator: 62
              replaceSeparatorsInPayload: false
              replaceCharacter: 36
              segmentTerminator: 126
              characterSet: 'UTF8'
              segmentTerminatorSuffix: 'None'
            }
            envelopeSettings: {
              controlStandardsId: 85
              useControlStandardsIdAsRepetitionCharacter: false
              senderApplicationId: 'PURCHASER01'
              receiverApplicationId: 'SUPPLIER01'
              controlVersionNumber: '00603'
              enableDefaultGroupHeaders: true
              groupHeaderAgencyCode: 'X'
              groupHeaderVersion: '006030'
              groupHeaderDateFormat: 'CCYYMMDD'
              groupHeaderTimeFormat: 'HHMM'
              functionalGroupId: 'FA'
              groupControlNumberLowerBound: 1
              groupControlNumberUpperBound: 999999999
              rolloverGroupControlNumber: true
              interchangeControlNumberLowerBound: 1
              interchangeControlNumberUpperBound: 999999999
              rolloverInterchangeControlNumber: true
              overwriteExistingTransactionSetControlNumber: true
              transactionSetControlNumberLowerBound: 1
              transactionSetControlNumberUpperBound: 999999999
              rolloverTransactionSetControlNumber: true
              usageIndicator: 'Test'
            }
            acknowledgementSettings: {
              needTechnicalAcknowledgement: false
              batchTechnicalAcknowledgements: false
              needFunctionalAcknowledgement: false
              batchFunctionalAcknowledgements: false
              needImplementationAcknowledgement: false
              batchImplementationAcknowledgements: false
              needLoopForValidMessages: false
              sendSynchronousAcknowledgement: false
              acknowledgementControlNumberLowerBound: 1
              acknowledgementControlNumberUpperBound: 999999999
              rolloverAcknowledgementControlNumber: true
            }
            messageFilter: { messageFilterType: 'Exclude' }
            securitySettings: { authorizationQualifier: '00', securityQualifier: '00', passwordValue: '' }
            processingSettings: {
              maskSecurityInfo: true
              convertImpliedDecimal: true
              preserveInterchange: false
              suspendInterchangeOnError: false
              createEmptyXmlTagsForTrailingSeparators: false
              useDotAsDecimalSeparator: true
            }
            schemaReferences: [
              {
                messageId: '997'
                schemaVersion: '00603'
                schemaName: schema997Name
              }
            ]
            envelopeOverrides: []
            validationOverrides: []
            messageFilterList: []
            x12DelimiterOverrides: []
          }
        }
      }
    }
  }
  dependsOn: [
    partnerPurchaser
    partnerSupplier
    schema997
  ]
}

// ============================================================================
// OUTPUTS
// ============================================================================
output x12AgreementName string = x12Agreement.name
output as2AgreementName string = as2Agreement.name
output purchaserSigningCertName string = purchaserSigningCert.name
output supplierEncryptionCertName string = supplierEncryptionCert.name
output x12Receive997AgreementName string = x12Receive997Agreement.name
output schema997Name string = schema997.name
output as2ReceiveActivated bool = activateAs2Receive
