// Integration Account CONTENT for the SUPPLIER (receive 850 + send 997 epic)
// ============================================================================
// Registers the trading partners, AS2 certificate artifacts, the inline 997
// schema, and the X12 (850 RECEIVE / 997 SEND) + AS2 (receive + send/MDN)
// agreements onto the ALREADY-EXISTING supplier Free Integration Account
// (created empty by infra/compute/logicapp-bundle.bicep, region Central US).
//
// This is the receive-side companion to ia-content.bicep (the purchaser IA).
// It binds to the LOCKED build-wave contract
// (.squad/decisions/inbox/squad-supplier-build-locks.md) and Simon's EDI spec
// (.squad/decisions/inbox/simon-997-receive.md D-997-2/3):
//   * Supplier-Purchaser-X12-850  — X12 RECEIVE 850 (host SUPPLIER01 / guest PURCHASER01, GS01=PO)
//   * Supplier-Purchaser-X12-997  — X12 SEND    997 (GS01=FA, agreement-generated control numbers)
//   * Supplier-Purchaser-AS2      — AS2 receive (decrypt+verify+signed MDN) + send (sign+encrypt)
//
// WHY A SEPARATE, CI-DRIVEN MODULE (not part of main.bicep, distinct from the
// purchaser ia-content.bicep):
//   1. The 2.15 MB X12_00603_850.xsd EXCEEDS the inline `content` limit and the
//      ARM/Bicep schema resource does not expose a writable `contentLink`, so the
//      850 schema is registered OUT OF BAND on the supplier IA via the Logic REST
//      API (`contentLink` = blob SAS) in deploy.yml BEFORE this module runs —
//      exactly the mechanism used for the purchaser IA (decisions.md 2026-07-17).
//      The 31 KB 997 xsd is small enough to register INLINE here via loadTextContent().
//   2. The 4 AS2 leaf public certificate bodies (and the 2 private-key names) are
//      only resolvable at deploy time; CI reads the public `.cer` from Key Vault
//      and passes them in as parameters (mirror ia-content.bicep's cert params).
//   3. The X12/AS2 agreements resolve the schema + certs BY NAME, so those
//      artifacts must exist first (enforced by deploy.yml ordering + dependsOn).
//   4. The supplier IA lives in rg-edi-supplier (Central US) — a distinct RG-scoped
//      deployment from the purchaser IA (rg-edi-purchaser, East US 2), so it cannot
//      share a single template with the purchaser IA content.
//
// Certificate binding (design §4.1 — the RECEIVE side, verified against MS Learn
// "Add certificates to secure B2B messages"):
//   * AS2 receive : signingCertificateName = purchaser-signing PUBLIC (validate the
//     partner's signature) ; encryptionCertificateName = supplier-encryption PRIVATE
//     (decrypt inbound). The signed synchronous MDN is emitted by the receive flow.
//   * AS2 send    : signingCertificateName = supplier-signing PRIVATE (sign the 997
//     and, via overrideGroupSigningCertificate, the MDN) ; encryptionCertificateName
//     = purchaser-encryption PUBLIC (encrypt the outbound 997).
// Private IA certs carry BOTH the public cert body AND a Key Vault KEY reference;
// public certs carry only the base64 body. The Logic Apps first-party SP
// (7cd684f4-...) reads the KV keys via its vault-scoped Crypto/Secrets User grant
// (infra/rbac/role-assignments.bicep) — no new RBAC edge is required.

targetScope = 'resourceGroup'

// ============================================================================
// PARAMETERS
// ============================================================================

@description('Name of the SUPPLIER Free Integration Account (already created by the compute bundle).')
param integrationAccountName string

@description('Resource ID of the shared Key Vault (rg-edi-shared) that holds the AS2 certificate keys.')
param keyVaultResourceId string

// --- Private-cert Key Vault KEY names (design §4.1) -------------------------------
@description('Key Vault KEY name backing the supplier ENCRYPTION private cert (decrypt inbound 850).')
param supplierEncryptionKeyName string = 'demo-as2-supplier-encryption'

@description('Key Vault KEY name backing the supplier SIGNING private cert (sign MDN + outbound 997).')
param supplierSigningKeyName string = 'demo-as2-supplier-signing'

@description('Optional Key Vault key VERSION for the supplier encryption key. Empty => LATEST (recommended for the demo).')
param supplierEncryptionKeyVersion string = ''

@description('Optional Key Vault key VERSION for the supplier signing key. Empty => LATEST (recommended for the demo).')
param supplierSigningKeyVersion string = ''

// --- Public certificate bodies (base64 DER .cer), read from Key Vault by CI ---------
@description('''Base64 PUBLIC cert (DER .cer) for the supplier ENCRYPTION cert (`demo-as2-supplier-encryption`).
Carried alongside the KV key on the PRIVATE supplier-encryption artifact. CI:
`az keyvault certificate show --vault-name <kv> --name demo-as2-supplier-encryption --query cer -o tsv`.''')
param supplierEncryptionPublicCertificate string

@description('''Base64 PUBLIC cert (DER .cer) for the supplier SIGNING cert (`demo-as2-supplier-signing`).
Carried alongside the KV key on the PRIVATE supplier-signing artifact. CI reads it from Key Vault.''')
param supplierSigningPublicCertificate string

@description('''Base64 PUBLIC cert (DER .cer) for the purchaser SIGNING cert (`demo-as2-purchaser-signing`).
PUBLIC-only artifact used to validate the purchaser's inbound signature. CI reads it from Key Vault.''')
param purchaserSigningPublicCertificate string

@description('''Base64 PUBLIC cert (DER .cer) for the purchaser ENCRYPTION cert (`demo-as2-purchaser-encryption`).
PUBLIC-only artifact used to encrypt the outbound 997. CI reads it from Key Vault.''')
param purchaserEncryptionPublicCertificate string

// --- Agreement + schema + artifact names (LOCKED build-wave contract) ---------------
@description('X12 RECEIVE agreement name for the inbound 850. LOCKED.')
param x12ReceiveAgreementName string = 'Supplier-Purchaser-X12-850'

@description('X12 SEND agreement name for the outbound 997 (GS01=FA). LOCKED.')
param x12SendAgreementName string = 'Supplier-Purchaser-X12-997'

@description('AS2 agreement name (receive + send/MDN). LOCKED.')
param as2AgreementName string = 'Supplier-Purchaser-AS2'

@description('IA schema artifact name for the 850 (registered out-of-band via REST contentLink, like the purchaser IA).')
param schema850Name string = 'X12_00603_850'

@description('IA schema artifact name for the 997 (registered INLINE by this module).')
param schema997Name string = 'X12_00603_997'

@description('IA certificate artifact name for the supplier ENCRYPTION (private) cert.')
param supplierEncryptionCertName string = 'supplier-encryption'

@description('IA certificate artifact name for the supplier SIGNING (private) cert.')
param supplierSigningCertName string = 'supplier-signing'

@description('IA certificate artifact name for the purchaser SIGNING (public) cert.')
param purchaserSigningCertName string = 'purchaser-signing'

@description('IA certificate artifact name for the purchaser ENCRYPTION (public) cert.')
param purchaserEncryptionCertName string = 'purchaser-encryption'

// ============================================================================
// EXISTING — supplier Integration Account (created empty by the compute bundle)
// ============================================================================
resource integrationAccount 'Microsoft.Logic/integrationAccounts@2019-05-01' existing = {
  name: integrationAccountName
}

// ============================================================================
// TRADING PARTNERS (design §3 / Simon D-997-3) — ZZ business identities
// Mirrored from the purchaser IA (ia-content.bicep) — Supplier is the HOST here.
// ============================================================================
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

// ============================================================================
// 997 SCHEMA (INLINE) — Simon D-997-5. The 31 KB xsd fits well under the 2 MB
// inline limit, so it is registered here via loadTextContent() (unlike the
// 2.15 MB 850, which is registered out-of-band via REST contentLink in CI).
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
// CERTIFICATE ARTIFACTS (design §4.1)
//   PRIVATE (public body + KV key ref): supplier-encryption, supplier-signing
//   PUBLIC  (public body only):         purchaser-signing, purchaser-encryption
// ============================================================================
resource supplierEncryptionCert 'Microsoft.Logic/integrationAccounts/certificates@2019-05-01' = {
  parent: integrationAccount
  name: supplierEncryptionCertName
  properties: {
    publicCertificate: supplierEncryptionPublicCertificate
    key: {
      keyName: supplierEncryptionKeyName
      keyVault: {
        id: keyVaultResourceId
      }
      keyVersion: empty(supplierEncryptionKeyVersion) ? null : supplierEncryptionKeyVersion
    }
  }
}

resource supplierSigningCert 'Microsoft.Logic/integrationAccounts/certificates@2019-05-01' = {
  parent: integrationAccount
  name: supplierSigningCertName
  properties: {
    publicCertificate: supplierSigningPublicCertificate
    key: {
      keyName: supplierSigningKeyName
      keyVault: {
        id: keyVaultResourceId
      }
      keyVersion: empty(supplierSigningKeyVersion) ? null : supplierSigningKeyVersion
    }
  }
}

resource purchaserSigningCert 'Microsoft.Logic/integrationAccounts/certificates@2019-05-01' = {
  parent: integrationAccount
  name: purchaserSigningCertName
  properties: {
    publicCertificate: purchaserSigningPublicCertificate
  }
}

resource purchaserEncryptionCert 'Microsoft.Logic/integrationAccounts/certificates@2019-05-01' = {
  parent: integrationAccount
  name: purchaserEncryptionCertName
  properties: {
    publicCertificate: purchaserEncryptionPublicCertificate
  }
}

// ============================================================================
// X12 RECEIVE AGREEMENT — inbound 850 (Simon D-997-3 A)
// host = Supplier (SUPPLIER01), guest = Purchaser (PURCHASER01).
// Receive-side DUPLICATE detection is ENABLED (reject replayed 850s by control
// number). needFunctionalAcknowledgement = false: the 997 is produced by an
// EXPLICIT X12 Encode against the 997 send agreement (LOCKED #1 — 006030), NOT
// by the Decode auto-generator (which emits a 4010 997).
// ============================================================================
resource x12ReceiveAgreement 'Microsoft.Logic/integrationAccounts/agreements@2019-05-01' = {
  parent: integrationAccount
  name: x12ReceiveAgreementName
  properties: {
    hostPartner: 'Supplier'
    guestPartner: 'Purchaser'
    hostIdentity: { qualifier: 'ZZ', value: 'SUPPLIER01' }
    guestIdentity: { qualifier: 'ZZ', value: 'PURCHASER01' }
    agreementType: 'X12'
    content: {
      x12: {
        receiveAgreement: {
          senderBusinessIdentity: { qualifier: 'ZZ', value: 'PURCHASER01' }
          receiverBusinessIdentity: { qualifier: 'ZZ', value: 'SUPPLIER01' }
          protocolSettings: {
            validationSettings: {
              validateCharacterSet: true
              checkDuplicateInterchangeControlNumber: true
              interchangeControlNumberValidityDays: 30
              checkDuplicateGroupControlNumber: true
              checkDuplicateTransactionSetControlNumber: true
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
                senderApplicationId: 'PURCHASER01'
                schemaVersion: '00603'
                schemaName: schema850Name
              }
            ]
            envelopeOverrides: []
            validationOverrides: []
            messageFilterList: []
            x12DelimiterOverrides: []
          }
        }
        sendAgreement: {
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
                schemaVersion: '00603'
                schemaName: schema850Name
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
    partnerSupplier
    partnerPurchaser
  ]
}

// ============================================================================
// X12 SEND AGREEMENT — outbound 997 (Simon D-997-2/3 B)
// GS01 = FA (Functional Acknowledgment). Control numbers agreement-generated
// (ISA13/GS06/ST02 rollover) — these are the 997's OWNING numbers, distinct from
// the AK102/AK202 echo values the workflow copies from the received 850.
// ============================================================================
resource x12SendAgreement 'Microsoft.Logic/integrationAccounts/agreements@2019-05-01' = {
  parent: integrationAccount
  name: x12SendAgreementName
  properties: {
    hostPartner: 'Supplier'
    guestPartner: 'Purchaser'
    hostIdentity: { qualifier: 'ZZ', value: 'SUPPLIER01' }
    guestIdentity: { qualifier: 'ZZ', value: 'PURCHASER01' }
    agreementType: 'X12'
    content: {
      x12: {
        receiveAgreement: {
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
                senderApplicationId: 'PURCHASER01'
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
    partnerSupplier
    partnerPurchaser
    schema997
  ]
}

// ============================================================================
// AS2 AGREEMENT — receive (decrypt + verify + signed MDN) + send (sign + encrypt)
// (design §4.1, verified against MS Learn AS2 message settings)
//   receive: signingCert = purchaser-signing PUBLIC (validate partner signature)
//            encryptionCert = supplier-encryption PRIVATE (decrypt inbound 850)
//   send:    signingCert = supplier-signing PRIVATE (sign 997 + MDN via override)
//            encryptionCert = purchaser-encryption PUBLIC (encrypt outbound 997)
// ============================================================================
resource as2Agreement 'Microsoft.Logic/integrationAccounts/agreements@2019-05-01' = {
  parent: integrationAccount
  name: as2AgreementName
  properties: {
    hostPartner: 'Supplier'
    guestPartner: 'Purchaser'
    hostIdentity: { qualifier: 'AS2Identity', value: 'SUPPLIER01' }
    guestIdentity: { qualifier: 'AS2Identity', value: 'PURCHASER01' }
    agreementType: 'AS2'
    content: {
      aS2: {
        receiveAgreement: {
          senderBusinessIdentity: { qualifier: 'AS2Identity', value: 'PURCHASER01' }
          receiverBusinessIdentity: { qualifier: 'AS2Identity', value: 'SUPPLIER01' }
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
        sendAgreement: {
          senderBusinessIdentity: { qualifier: 'AS2Identity', value: 'SUPPLIER01' }
          receiverBusinessIdentity: { qualifier: 'AS2Identity', value: 'PURCHASER01' }
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
              signingCertificateName: supplierSigningCertName
              encryptionCertificateName: purchaserEncryptionCertName
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
    partnerSupplier
    partnerPurchaser
    supplierEncryptionCert
    supplierSigningCert
    purchaserSigningCert
    purchaserEncryptionCert
  ]
}

// ============================================================================
// OUTPUTS
// ============================================================================
output x12ReceiveAgreementName string = x12ReceiveAgreement.name
output x12SendAgreementName string = x12SendAgreement.name
output as2AgreementName string = as2Agreement.name
output schema997Name string = schema997.name
output supplierEncryptionCertName string = supplierEncryptionCert.name
output supplierSigningCertName string = supplierSigningCert.name
output purchaserSigningCertName string = purchaserSigningCert.name
output purchaserEncryptionCertName string = purchaserEncryptionCert.name
