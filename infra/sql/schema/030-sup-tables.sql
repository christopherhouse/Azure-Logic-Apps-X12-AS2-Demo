-- =============================================================================
-- 030-sup-tables.sql — Supplier-owned Purchase Order mirror tables (sup schema)
-- =============================================================================
-- Authoritative source: .squad/decisions/inbox/squad-supplier-build-locks.md (#3)
-- + docs/supplier-workflow-epic-design.md §7 (supplier-owned tables, clean trust
--   boundary) + Simon's D-997-6 canonical shape.
--
-- The supplier persists the INBOUND 850 (decoded → canonical) into its OWN schema
-- `sup`, mirroring the purchaser's dbo canonical model. Keeping purchaser (dbo) and
-- supplier (sup) data on DISTINCT schemas preserves the trust boundary — the
-- supplier NEVER writes dbo.PurchaseOrder (the LOCKED decision, #3).
--
-- Three tables: sup.[Address], sup.PurchaseOrder, sup.PurchaseOrderLine — same
-- normalized shape and column lengths as dbo (010-tables.sql) so the same canonical
-- map/JSON contract feeds both. Surrogate IDENTITY PKs; PoNumber is the natural key.
--
-- IDEMPOTENT: schema + tables are guarded (sys.schemas / IF OBJECT_ID(...) IS NULL)
-- so CI (deploy.yml) re-runs this on every deployment without error.
--
-- Execution: CI T-SQL step (deploy.yml), alongside create-users-roles.sql and the
-- dbo DDL. Must run before the first supplier workflow run.
-- =============================================================================

SET NOCOUNT ON;
GO

-- -----------------------------------------------------------------------------
-- sup schema (CREATE SCHEMA must be the first statement in its batch → dynamic SQL)
-- -----------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'sup')
BEGIN
    EXEC (N'CREATE SCHEMA sup AUTHORIZATION dbo;');
    PRINT 'Created schema: sup';
END
ELSE
BEGIN
    PRINT 'Schema already exists: sup';
END
GO

-- -----------------------------------------------------------------------------
-- sup.[Address]
-- -----------------------------------------------------------------------------
IF OBJECT_ID(N'sup.[Address]', N'U') IS NULL
BEGIN
    CREATE TABLE sup.[Address] (
        AddressId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_sup_Address PRIMARY KEY,
        Name         NVARCHAR(60)  NOT NULL,
        Line1        NVARCHAR(55)  NOT NULL,
        Line2        NVARCHAR(55)  NULL,
        City         NVARCHAR(30)  NOT NULL,
        [State]      CHAR(2)       NOT NULL,
        PostalCode   NVARCHAR(15)  NOT NULL,
        Country      CHAR(2)       NOT NULL
    );
    PRINT 'Created table: sup.[Address]';
END
ELSE
BEGIN
    PRINT 'Table already exists: sup.[Address]';
END
GO

-- -----------------------------------------------------------------------------
-- sup.PurchaseOrder
-- -----------------------------------------------------------------------------
IF OBJECT_ID(N'sup.PurchaseOrder', N'U') IS NULL
BEGIN
    CREATE TABLE sup.PurchaseOrder (
        PurchaseOrderId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_sup_PurchaseOrder PRIMARY KEY,
        PoNumber              VARCHAR(22)   NOT NULL CONSTRAINT UQ_sup_PurchaseOrder_PoNumber UNIQUE,  -- business key
        OrderDate             DATE          NOT NULL,
        RequestedDeliveryDate DATE          NULL,
        Currency              CHAR(3)       NOT NULL,
        BuyerId               VARCHAR(15)   NOT NULL,
        BuyerName             NVARCHAR(60)  NOT NULL,
        SellerId              VARCHAR(15)   NOT NULL,
        SellerName            NVARCHAR(60)  NOT NULL,
        ShipToAddressId       INT           NOT NULL CONSTRAINT FK_sup_PO_ShipTo REFERENCES sup.[Address](AddressId),
        BillToAddressId       INT           NOT NULL CONSTRAINT FK_sup_PO_BillTo REFERENCES sup.[Address](AddressId),
        ReceivedUtc           DATETIME2(3)  NOT NULL CONSTRAINT DF_sup_PO_ReceivedUtc DEFAULT SYSUTCDATETIME()
    );
    PRINT 'Created table: sup.PurchaseOrder';
END
ELSE
BEGIN
    PRINT 'Table already exists: sup.PurchaseOrder';
END
GO

-- -----------------------------------------------------------------------------
-- sup.PurchaseOrderLine
-- -----------------------------------------------------------------------------
IF OBJECT_ID(N'sup.PurchaseOrderLine', N'U') IS NULL
BEGIN
    CREATE TABLE sup.PurchaseOrderLine (
        PurchaseOrderLineId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_sup_PurchaseOrderLine PRIMARY KEY,
        PurchaseOrderId     INT           NOT NULL CONSTRAINT FK_sup_POL_PO REFERENCES sup.PurchaseOrder(PurchaseOrderId),
        LineNumber          INT           NOT NULL,
        Sku                 VARCHAR(30)   NOT NULL,
        [Description]       NVARCHAR(80)  NULL,
        Quantity            DECIMAL(18,4) NOT NULL,
        Uom                 VARCHAR(2)    NOT NULL,
        UnitPrice           DECIMAL(18,4) NOT NULL,
        CONSTRAINT UQ_sup_POL_PO_Line UNIQUE (PurchaseOrderId, LineNumber)
    );
    PRINT 'Created table: sup.PurchaseOrderLine';
END
ELSE
BEGIN
    PRINT 'Table already exists: sup.PurchaseOrderLine';
END
GO

PRINT '';
PRINT '==========================================================';
PRINT '030-sup-tables.sql - Supplier sup schema setup complete';
PRINT '==========================================================';
GO
