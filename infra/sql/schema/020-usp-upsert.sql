-- =============================================================================
-- 020-usp-upsert.sql — dbo.usp_UpsertPurchaseOrder (JSON lines, no TVP)
-- =============================================================================
-- Authoritative source: docs/purchaser-workflow-epic-design.md §3.2
--
-- One call persists an entire canonical Purchase Order atomically: header +
-- ship-to/bill-to addresses (scalar params) + N lines (a JSON array string).
--
-- WHY JSON, NOT A TVP:
--   The Logic Apps BUILT-IN SQL connector (Execute stored procedure) cannot
--   bind a table-valued parameter — TVPs are only reachable over the managed
--   (on-prem data gateway) connector, which this workflow does not use. So the
--   line array is passed as a single NVARCHAR(MAX) JSON string (@LinesJson) and
--   shredded server-side with OPENJSON(...) WITH (...). The workflow builds
--   @LinesJson from the canonical PO's `lines` array before the SQL call.
--
-- IDEMPOTENT on PoNumber: a Service Bus redelivery (peek-lock expiry, retries)
-- must NOT create duplicates — settlement is at-least-once. If PoNumber already
-- exists, the proc is a no-op and returns the existing PurchaseOrderId.
--
-- SCRIPT IDEMPOTENCY:
--   * PROCEDURE dbo.usp_UpsertPurchaseOrder — CREATE OR ALTER (always current).
--   * No table type to guard — the previous dbo.PurchaseOrderLineType TVP has
--     been REMOVED. (If re-running over an older DB that still has the type,
--     it is now unreferenced and harmless; drop it manually if desired.)
--
-- DEPENDENCY (Zoe, infra/sql/create-users-roles.sql):
--   PurchaserRole already has GRANT EXECUTE ON SCHEMA::dbo (can EXEC the proc)
--   and GRANT SELECT ON SCHEMA::dbo (can read the returned id). That is now
--   SUFFICIENT — no TYPE grant is needed. Zoe is REMOVING the previously
--   required "GRANT EXECUTE ON TYPE::dbo.PurchaseOrderLineType TO PurchaserRole"
--   from create-users-roles.sql, since the TVP no longer exists.
--
-- @LinesJson SHAPE (array of objects; keys are camelCase per canonical PO §2.1,
--   and MUST match the case-sensitive OPENJSON '$.xxx' paths below):
--   [
--     { "lineNumber": 1, "sku": "WIDGET-BLUE-01", "description": "Blue widget",
--       "quantity": 120, "uom": "EA", "unitPrice": 2.5 }, ...
--   ]
--
-- Execution: CI T-SQL step (deploy.yml). Run AFTER 010-tables.sql, before the
-- first purchaser workflow run (§8, step A). Requires DB COMPATIBILITY_LEVEL
-- >= 130 for OPENJSON (Azure SQL DB satisfies this by default).
-- =============================================================================

SET NOCOUNT ON;
GO

-- -----------------------------------------------------------------------------
-- dbo.usp_UpsertPurchaseOrder
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_UpsertPurchaseOrder
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

        -- idempotency: a re-delivered SB message must not duplicate.
        -- If PoNumber exists, no-op and return the existing id.
        DECLARE @PurchaseOrderId INT =
            (SELECT PurchaseOrderId FROM dbo.PurchaseOrder WHERE PoNumber = @PoNumber);

        IF @PurchaseOrderId IS NULL
        BEGIN
            DECLARE @ShipId INT, @BillId INT;

            INSERT dbo.[Address] (Name, Line1, Line2, City, [State], PostalCode, Country)
                VALUES (@ShipToName, @ShipToLine1, @ShipToLine2, @ShipToCity, @ShipToState, @ShipToPostalCode, @ShipToCountry);
            SET @ShipId = SCOPE_IDENTITY();

            INSERT dbo.[Address] (Name, Line1, Line2, City, [State], PostalCode, Country)
                VALUES (@BillToName, @BillToLine1, @BillToLine2, @BillToCity, @BillToState, @BillToPostalCode, @BillToCountry);
            SET @BillId = SCOPE_IDENTITY();

            INSERT dbo.PurchaseOrder (PoNumber, OrderDate, RequestedDeliveryDate, Currency,
                  BuyerId, BuyerName, SellerId, SellerName, ShipToAddressId, BillToAddressId)
                VALUES (@PoNumber, @OrderDate, @RequestedDeliveryDate, @Currency,
                  @BuyerId, @BuyerName, @SellerId, @SellerName, @ShipId, @BillId);
            SET @PurchaseOrderId = SCOPE_IDENTITY();

            -- shred the JSON line array server-side (no TVP available)
            INSERT dbo.PurchaseOrderLine (PurchaseOrderId, LineNumber, Sku, [Description], Quantity, Uom, UnitPrice)
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
PRINT '020-usp-upsert.sql - upsert proc (JSON lines) setup complete';
PRINT '==========================================================';
GO
