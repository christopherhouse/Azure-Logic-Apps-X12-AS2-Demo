-- =============================================================================
-- 010-tables.sql — Normalized Purchase Order relational model (dbo)
-- =============================================================================
-- Authoritative source: docs/purchaser-workflow-epic-design.md §3.1
--
-- Three tables: dbo.[Address], dbo.PurchaseOrder, dbo.PurchaseOrderLine.
-- Surrogate IDENTITY PKs; PoNumber is the natural business key (UNIQUE).
-- Addresses are normalized into a shared Address table referenced by the
-- PurchaseOrder header (ship-to + bill-to).
--
-- IDEMPOTENT: guarded with IF OBJECT_ID(...) IS NULL so CI (deploy.yml) can
-- re-run this script on every deployment without error. Column/constraint
-- lengths are reconciled with the X12 850 element limits in §4 and the JSON
-- Schema caps in §2.2.
--
-- Execution: CI T-SQL step (deploy.yml), alongside create-users-roles.sql and
-- 020-usp-upsert.sql. Must run before the first purchaser workflow run (§8, step A).
-- =============================================================================

SET NOCOUNT ON;
GO

-- -----------------------------------------------------------------------------
-- dbo.[Address]
-- -----------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.[Address]', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.[Address] (
        AddressId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Address PRIMARY KEY,
        Name         NVARCHAR(60)  NOT NULL,
        Line1        NVARCHAR(55)  NOT NULL,
        Line2        NVARCHAR(55)  NULL,
        City         NVARCHAR(30)  NOT NULL,
        [State]      CHAR(2)       NOT NULL,
        PostalCode   NVARCHAR(15)  NOT NULL,
        Country      CHAR(2)       NOT NULL
    );
    PRINT 'Created table: dbo.[Address]';
END
ELSE
BEGIN
    PRINT 'Table already exists: dbo.[Address]';
END
GO

-- -----------------------------------------------------------------------------
-- dbo.PurchaseOrder
-- -----------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.PurchaseOrder', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PurchaseOrder (
        PurchaseOrderId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrder PRIMARY KEY,
        PoNumber              VARCHAR(22)   NOT NULL CONSTRAINT UQ_PurchaseOrder_PoNumber UNIQUE,  -- business key
        OrderDate             DATE          NOT NULL,
        RequestedDeliveryDate DATE          NULL,
        Currency              CHAR(3)       NOT NULL,
        BuyerId               VARCHAR(15)   NOT NULL,
        BuyerName             NVARCHAR(60)  NOT NULL,
        SellerId              VARCHAR(15)   NOT NULL,
        SellerName            NVARCHAR(60)  NOT NULL,
        ShipToAddressId       INT           NOT NULL CONSTRAINT FK_PO_ShipTo REFERENCES dbo.[Address](AddressId),
        BillToAddressId       INT           NOT NULL CONSTRAINT FK_PO_BillTo REFERENCES dbo.[Address](AddressId),
        ReceivedUtc           DATETIME2(3)  NOT NULL CONSTRAINT DF_PO_ReceivedUtc DEFAULT SYSUTCDATETIME()
    );
    PRINT 'Created table: dbo.PurchaseOrder';
END
ELSE
BEGIN
    PRINT 'Table already exists: dbo.PurchaseOrder';
END
GO

-- -----------------------------------------------------------------------------
-- dbo.PurchaseOrderLine
-- -----------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.PurchaseOrderLine', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PurchaseOrderLine (
        PurchaseOrderLineId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrderLine PRIMARY KEY,
        PurchaseOrderId     INT           NOT NULL CONSTRAINT FK_POL_PO REFERENCES dbo.PurchaseOrder(PurchaseOrderId),
        LineNumber          INT           NOT NULL,
        Sku                 VARCHAR(30)   NOT NULL,
        [Description]       NVARCHAR(80)  NULL,
        Quantity            DECIMAL(18,4) NOT NULL,
        Uom                 VARCHAR(2)    NOT NULL,
        UnitPrice           DECIMAL(18,4) NOT NULL,
        CONSTRAINT UQ_POL_PO_Line UNIQUE (PurchaseOrderId, LineNumber)
    );
    PRINT 'Created table: dbo.PurchaseOrderLine';
END
ELSE
BEGIN
    PRINT 'Table already exists: dbo.PurchaseOrderLine';
END
GO

PRINT '';
PRINT '==========================================================';
PRINT '010-tables.sql - Schema setup complete';
PRINT '==========================================================';
GO
