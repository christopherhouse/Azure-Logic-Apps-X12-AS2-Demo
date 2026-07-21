<?xml version="1.0" encoding="utf-8"?>
<!--
  X12_850_006030_to_PO_Canonical.xslt
  =============================================================================
  Author: Simon (EDI Analyst). Supplier-inbound epic (receive side).
  Coordinator locks: .squad/decisions/inbox/squad-supplier-build-locks.md (#3).

  DIRECTION: INVERSE of the purchaser send-side map
    logicapps/purchaser/Artifacts/Maps/PO_Canonical_to_X12_850_006030.xslt.

  INPUT : decoded X12 850 (006030) transaction-set XML produced by the built-in
          X12 Decode action. Root = x12:X12_00603_850 in namespace
          http://schemas.microsoft.com/BizTalk/EDI/X12/2006, mixed-namespace
          BizTalk EDI model (elementFormDefault = UNQUALIFIED):
            * GLOBAL elements (root, ref'ed segments BEG/REF/DTM/N1/N3/N4/PO1/
              PID_2/CTT, loop wrappers N1Loop1/PO1Loop1/PIDLoop1/CTTLoop1) are in
              the x12: namespace.
            * LOCAL elements (inline ST/SE and EVERY data field ST01, BEG03,
              N101, N401, PO101, PID05, ...) are in NO namespace.
          This stylesheet matches accordingly: x12:-prefixed for globals, bare
          names for data fields.

  OUTPUT: canonical Purchase Order XML, NO namespace, root <purchaseOrder> — the
          SAME shape the purchaser send-side map CONSUMES as input and the shape
          in docs/purchaser-workflow-epic-design.md §2.1. Wash then converts it
          with json(...) and calls sup.usp_UpsertPurchaseOrder: scalar header +
          address params from the canonical fields, and @LinesJson from the
          <lines> array (element names == canonical JSON keys == the proc's
          OPENJSON '$.xxx' paths: lineNumber, sku, description, quantity, uom,
          unitPrice). See mapping table in
          .squad/decisions/inbox/simon-receive-map.md.

  DATE REFORMAT: 850 carries CCYYMMDD (8 digits); canonical/SQL DATE wants
    YYYY-MM-DD. reformatDate rebuilds the dashes (inverse of the send map's
    translate(...,'-','') that stripped them).

  ============================  GAPS / FLAGS  =================================
  The purchaser send-side map DID NOT encode these canonical fields into the
  850, so they are NOT recoverable from the decoded transaction body. They are
  NOT NULL in the mirrored sup.* DDL, so a value MUST be supplied or the upsert
  fails. This map emits DOCUMENTED FALLBACKS (clearly derived, never invented
  business data) and flags each — do NOT treat them as faithful round-trips:

    * currency   -> constant 'USD'. No CUR segment is on the wire. FLAG G1.
    * buyer/name -> copied from buyer/id (REF*CO). No buyer-name N1*BY loop on
                    the wire. FLAG G2.
    * seller/id  -> constant 'SUPPLIER01' (the receiving supplier is the seller;
                    authoritatively the decode ENVELOPE GS03/ISA08, not the ST..SE
                    body). Wash MAY override from decode envelope metadata. FLAG G3.
    * seller/name-> constant 'SUPPLIER01' (id proxy). No seller-name loop on the
                    wire. FLAG G4.

  PROPER FIX (future, non-blocking for demo): enrich the 850 SEND map to carry
  buyer name (N1*BY), seller (N1*SE/SU) and currency (CUR) so a true round-trip
  is possible; OR relax buyer/seller-name + currency to NULL/defaults in sup.*;
  OR enrich from a partner master-data lookup in the workflow. Coordinator to
  route (Kaylee owns sup.* DDL, Wash owns the workflow enrichment).
  =============================================================================
-->
<xsl:stylesheet version="1.0"
                xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                xmlns:x12="http://schemas.microsoft.com/BizTalk/EDI/X12/2006"
                exclude-result-prefixes="xsl x12">

  <xsl:output method="xml" version="1.0" encoding="utf-8" indent="yes"/>
  <xsl:strip-space elements="*"/>

  <!-- CCYYMMDD (8 digits) -> YYYY-MM-DD. Passes through anything not 8 chars. -->
  <xsl:template name="reformatDate">
    <xsl:param name="d"/>
    <xsl:variable name="t" select="normalize-space($d)"/>
    <xsl:choose>
      <xsl:when test="string-length($t) = 8">
        <xsl:value-of select="concat(substring($t,1,4),'-',substring($t,5,2),'-',substring($t,7,2))"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="$t"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Emit one canonical address block from an N1Loop1 (N1/N3/N4). -->
  <xsl:template name="address">
    <xsl:param name="loop"/>
    <name><xsl:value-of select="$loop/x12:N1/N102"/></name>
    <line1><xsl:value-of select="$loop/x12:N3/N301"/></line1>
    <xsl:if test="$loop/x12:N3/N302 and normalize-space($loop/x12:N3/N302) != ''">
      <line2><xsl:value-of select="$loop/x12:N3/N302"/></line2>
    </xsl:if>
    <city><xsl:value-of select="$loop/x12:N4/N401"/></city>
    <state><xsl:value-of select="$loop/x12:N4/N402"/></state>
    <postalCode><xsl:value-of select="$loop/x12:N4/N403"/></postalCode>
    <country><xsl:value-of select="$loop/x12:N4/N404"/></country>
  </xsl:template>

  <xsl:template match="/">
    <xsl:apply-templates select="x12:X12_00603_850"/>
  </xsl:template>

  <xsl:template match="x12:X12_00603_850">
    <purchaseOrder>

      <!-- Header -->

      <poNumber><xsl:value-of select="x12:BEG/BEG03"/></poNumber>

      <orderDate>
        <xsl:call-template name="reformatDate">
          <xsl:with-param name="d" select="x12:BEG/BEG05"/>
        </xsl:call-template>
      </orderDate>

      <!-- requestedDeliveryDate: DTM with DTM01='002'. Emitted only if present. -->
      <xsl:variable name="dtm002" select="x12:DTM[DTM01='002']/DTM02"/>
      <xsl:if test="$dtm002 and normalize-space($dtm002) != ''">
        <requestedDeliveryDate>
          <xsl:call-template name="reformatDate">
            <xsl:with-param name="d" select="$dtm002"/>
          </xsl:call-template>
        </requestedDeliveryDate>
      </xsl:if>

      <!-- currency: FLAG G1 — no CUR segment on the wire. Documented default. -->
      <currency>USD</currency>

      <!-- buyer: id from REF*CO. name FLAG G2 — not on the wire, id used as proxy. -->
      <xsl:variable name="buyerId" select="x12:REF[REF01='CO']/REF02"/>
      <buyer>
        <id><xsl:value-of select="$buyerId"/></id>
        <name><xsl:value-of select="$buyerId"/></name>
      </buyer>

      <!-- seller: FLAG G3/G4 — not in ST..SE body. Supplier self-identity.
           Wash MAY override id/name from the decode envelope (GS03/ISA08). -->
      <seller>
        <id>SUPPLIER01</id>
        <name>SUPPLIER01</name>
      </seller>

      <!-- Ship To (N1*ST) / Bill To (N1*BT) -->
      <shipTo>
        <xsl:call-template name="address">
          <xsl:with-param name="loop" select="x12:N1Loop1[x12:N1/N101='ST']"/>
        </xsl:call-template>
      </shipTo>

      <billTo>
        <xsl:call-template name="address">
          <xsl:with-param name="loop" select="x12:N1Loop1[x12:N1/N101='BT']"/>
        </xsl:call-template>
      </billTo>

      <!-- Lines: one <lines> per PO1Loop1 (json() yields an array). -->
      <xsl:for-each select="x12:PO1Loop1">
        <lines>
          <lineNumber><xsl:value-of select="x12:PO1/PO101"/></lineNumber>
          <!-- PO107 is the buyer's part number (PO106=BP) => canonical sku. -->
          <sku><xsl:value-of select="x12:PO1/PO107"/></sku>
          <xsl:variable name="desc" select="x12:PIDLoop1/x12:PID_2[PID01='F']/PID05"/>
          <xsl:if test="$desc and normalize-space($desc) != ''">
            <description><xsl:value-of select="$desc"/></description>
          </xsl:if>
          <quantity><xsl:value-of select="x12:PO1/PO102"/></quantity>
          <uom><xsl:value-of select="x12:PO1/PO103"/></uom>
          <unitPrice><xsl:value-of select="x12:PO1/PO104"/></unitPrice>
        </lines>
      </xsl:for-each>

      <!-- CTT (count / quantity hash total) is VALIDATION-ONLY; not persisted.
           Wash may assert CTT01 = count(lines) and CTT02 = sum(quantity). -->

    </purchaseOrder>
  </xsl:template>

</xsl:stylesheet>
