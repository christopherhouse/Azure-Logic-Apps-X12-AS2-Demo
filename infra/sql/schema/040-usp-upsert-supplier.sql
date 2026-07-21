-- =============================================================================
-- 040-usp-upsert-supplier.sql — sup.usp_UpsertPurchaseOrder (JSON lines, no TVP)
-- =============================================================================
-- Authoritative source: .squad/decisions/inbox/squad-supplier-build-locks.md (#3)
-- + docs/supplier-workflow-epic-design.md §7.
--
-- Supplier-side upsert of a decoded 850 into the supplier-owned `sup` tables.
-- This is the SUPPLIER mirror of dbo.usp_UpsertPurchaseOrder (020-usp-upsert.sql)
-- and is DISTINCT from it — the supplier NEVER calls the purchaser's dbo proc
-- (LOCKED #3, clean trust boundary). SupplierRole gets EXECUTE on sup (see
-- create-users-roles.sql).
--
-- WHY JSON, NOT A TVP:
--   The Logic Apps BUILT-IN SQL connector (Execute stored procedure) cannot bind
--   a table-valued parameter — a LOCKED repo decision (TVP→JSON/OPENJSON,
--   decisions.md 2026-07-17). The line array is passed as a single NVARCHAR(MAX)
--   JSON string (@LinesJson) and shredded server-side with OPENJSON(...) WITH (...).
--
-- IDEMPOTENT on PoNumber: an AS2 re-transmit / redelivery must NOT create
-- duplicates. If PoNumber already exists, the proc is a no-op and returns the
-- existing PurchaseOrderId.
--
-- SCRIPT IDEMPOTENCY: CREATE OR ALTER PROCEDURE (always current). Requires the
-- `sup` schema + tables from 030-sup-tables.sql.
--
-- @LinesJson SHAPE (array of objects; camelCase keys match the OPENJSON paths and
--   the purchaser canonical §2.1 shape so the same map output feeds both sides):
--   [
--     { "lineNumber": 1, "sku": "WIDGET-BLUE-01", "description": "Blue widget",
--       "quantity": 120, "uom": "EA", "unitPrice": 2.5 }, ...
--   ]
--
-- Execution: CI T-SQL step (deploy.yml). Run AFTER 030-sup-tables.sql, before the
-- first supplier workflow run. Requires DB COMPATIBILITY_LEVEL >= 130 for OPENJSON.
-- =============================================================================

SET NOCOUNT ON;
GO

-- -----------------------------------------------------------------------------
-- sup.usp_UpsertPurchaseOrder
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE sup.usp_UpsertPurchaseOrder
    @PoNumber              VARCHAR(22),
    @OrderDate             DATE,
    @RequestedDeliveryDate DATE = NULL,
    @Currency              CHAR(3),
    @BuyerId  VARCHAR(15),  @BuyerName  NVARCHAR(60),
    @SellerId VARCHAR(15),  @SellerName NVARCHAR(60),
    -- ship-to
    @ShipToName NVARCHAR(60), @ShipToLine1 NVARCHAR(55), @ShipToLine2 NVARCHAR(55) = NULL,
    @ShipToCity NVARCHAR(30), @ShipToState CHAR(2), @ShipToPostalCode NVARCHAR(15), @ShipToCountry CHAR(2),
    -- bill-to
    @BillToName NVARCHAR(60), @BillToLine1 NVARCHAR(55), @BillToLine2 NVARCHAR(55) = NULL,
    @BillToCity NVARCHAR(30), @BillToState CHAR(2), @BillToPostalCode NVARCHAR(15), @BillToCountry CHAR(2),
    -- line items as a JSON array string (built-in SQL connector cannot pass a TVP)
    @LinesJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

        -- idempotency: a re-delivered AS2 message must not duplicate.
        -- If PoNumber exists, no-op and return the existing id.
        DECLARE @PurchaseOrderId INT =
            (SELECT PurchaseOrderId FROM sup.PurchaseOrder WHERE PoNumber = @PoNumber);

        IF @PurchaseOrderId IS NULL
        BEGIN
            DECLARE @ShipId INT, @BillId INT;

            INSERT sup.[Address] (Name, Line1, Line2, City, [State], PostalCode, Country)
                VALUES (@ShipToName, @ShipToLine1, @ShipToLine2, @ShipToCity, @ShipToState, @ShipToPostalCode, @ShipToCountry);
            SET @ShipId = SCOPE_IDENTITY();

            INSERT sup.[Address] (Name, Line1, Line2, City, [State], PostalCode, Country)
                VALUES (@BillToName, @BillToLine1, @BillToLine2, @BillToCity, @BillToState, @BillToPostalCode, @BillToCountry);
            SET @BillId = SCOPE_IDENTITY();

            INSERT sup.PurchaseOrder (PoNumber, OrderDate, RequestedDeliveryDate, Currency,
                  BuyerId, BuyerName, SellerId, SellerName, ShipToAddressId, BillToAddressId)
                VALUES (@PoNumber, @OrderDate, @RequestedDeliveryDate, @Currency,
                  @BuyerId, @BuyerName, @SellerId, @SellerName, @ShipId, @BillId);
            SET @PurchaseOrderId = SCOPE_IDENTITY();

            -- shred the JSON line array server-side (no TVP available)
            INSERT sup.PurchaseOrderLine (PurchaseOrderId, LineNumber, Sku, [Description], Quantity, Uom, UnitPrice)
                SELECT @PurchaseOrderId, j.LineNumber, j.Sku, j.[Description], j.Quantity, j.Uom, j.UnitPrice
                FROM OPENJSON(@LinesJson) WITH (
                    LineNumber    INT           '$.lineNumber',
                    Sku           VARCHAR(30)   '$.sku',
                    [Description] NVARCHAR(80)  '$.description',
                    Quantity      DECIMAL(18,4) '$.quantity',
                    Uom           VARCHAR(2)    '$.uom',
                    UnitPrice     DECIMAL(18,4) '$.unitPrice'
                ) AS j;
        END

    COMMIT TRAN;

    SELECT @PurchaseOrderId AS PurchaseOrderId;   -- returned to the workflow
END
GO

PRINT '';
PRINT '==========================================================';
PRINT '040-usp-upsert-supplier.sql - sup upsert proc (JSON lines) complete';
PRINT '==========================================================';
GO
