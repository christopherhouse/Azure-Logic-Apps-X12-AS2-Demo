-- SQL Contained Users and Custom Roles for EDI Demo
-- Creates contained users for purchaser and supplier UAMIs, plus custom roles with least-privilege grants.
-- This script is executed by the CI runner (deploy.yml) after Bicep deployment completes.
--
-- Prerequisites:
-- - SQL Server and database must exist
-- - SQL Server Entra admin group must be configured (b9dac399-abc0-479d-9900-f2115a98297d)
-- - Executing identity must be a member of the Entra admin group
-- - Both purchaser and supplier UAMIs must exist
--
-- NOTE: UAMI names are substituted by the CI step from Bicep outputs:
--   {{PURCHASER_UAMI_NAME}} -> id-edi-purchaser-{token}-{env}-{hash}
--   {{SUPPLIER_UAMI_NAME}} -> id-edi-supplier-{token}-{env}-{hash}

-- ==============================================================================
-- CREATE CONTAINED USERS (idempotent)
-- ==============================================================================

-- Purchaser UAMI user (SID-based — no directory lookup / no server identity required)
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '{{PURCHASER_UAMI_NAME}}')
BEGIN
    CREATE USER [{{PURCHASER_UAMI_NAME}}] WITH SID = {{PURCHASER_UAMI_SID}}, TYPE = E;
    PRINT 'Created user: {{PURCHASER_UAMI_NAME}}';
END
ELSE
BEGIN
    PRINT 'User already exists: {{PURCHASER_UAMI_NAME}}';
END
GO

-- Supplier UAMI user (SID-based — no directory lookup / no server identity required)
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '{{SUPPLIER_UAMI_NAME}}')
BEGIN
    CREATE USER [{{SUPPLIER_UAMI_NAME}}] WITH SID = {{SUPPLIER_UAMI_SID}}, TYPE = E;
    PRINT 'Created user: {{SUPPLIER_UAMI_NAME}}';
END
ELSE
BEGIN
    PRINT 'User already exists: {{SUPPLIER_UAMI_NAME}}';
END
GO

-- ==============================================================================
-- CREATE CUSTOM ROLES (idempotent)
-- ==============================================================================

-- PurchaserRole: SELECT and EXECUTE only (read and stored procedure execution)
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'PurchaserRole' AND type = 'R')
BEGIN
    CREATE ROLE PurchaserRole;
    PRINT 'Created role: PurchaserRole';
END
ELSE
BEGIN
    PRINT 'Role already exists: PurchaserRole';
END
GO

-- SupplierRole: INSERT and EXECUTE (write and stored procedure execution)
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'SupplierRole' AND type = 'R')
BEGIN
    CREATE ROLE SupplierRole;
    PRINT 'Created role: SupplierRole';
END
ELSE
BEGIN
    PRINT 'Role already exists: SupplierRole';
END
GO

-- ==============================================================================
-- GRANT PERMISSIONS TO ROLES (idempotent)
-- ==============================================================================

-- PurchaserRole: SELECT (read data) and EXECUTE (call stored procedures)
GRANT SELECT ON SCHEMA::dbo TO PurchaserRole;
GRANT EXECUTE ON SCHEMA::dbo TO PurchaserRole;
PRINT 'Granted SELECT and EXECUTE to PurchaserRole';
GO

-- SupplierRole: NO dbo grants. The supplier writes ONLY its own `sup` schema
-- (see the sup grants below) to enforce the supplier-inbound trust boundary.
-- Earlier revisions granted INSERT + EXECUTE on SCHEMA::dbo to SupplierRole; those
-- are explicitly REVOKEd here so a redeploy against an already-granted database
-- actually removes them (omitting a GRANT does not revoke a prior one). REVOKE is
-- a no-op when the permission is absent, so this stays idempotent / re-runnable.
REVOKE INSERT ON SCHEMA::dbo FROM SupplierRole;
REVOKE EXECUTE ON SCHEMA::dbo FROM SupplierRole;
PRINT 'Revoked dbo INSERT and EXECUTE from SupplierRole (supplier writes sup schema only)';
GO

-- ==============================================================================
-- SUPPLIER-OWNED `sup` SCHEMA GRANTS (supplier-inbound 997 epic, LOCKED #3)
-- ==============================================================================
-- The supplier persists the inbound 850 into its OWN `sup` schema (mirror tables +
-- sup.usp_UpsertPurchaseOrder), kept distinct from dbo for a clean trust boundary.
-- SupplierRole gets INSERT + EXECUTE on SCHEMA::sup.
--
-- The `sup` schema is created here (idempotent) so the GRANT below resolves even
-- though this script runs BEFORE the sup DDL step (030-sup-tables.sql) in CI;
-- 030 re-creates it idempotently. CREATE SCHEMA must be first in its batch → EXEC.
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

GRANT INSERT ON SCHEMA::sup TO SupplierRole;
GRANT EXECUTE ON SCHEMA::sup TO SupplierRole;
PRINT 'Granted INSERT and EXECUTE on SCHEMA::sup to SupplierRole';
GO

-- ==============================================================================
-- ADD USERS TO ROLES (idempotent)
-- ==============================================================================

-- Add purchaser UAMI to PurchaserRole
IF NOT EXISTS (
    SELECT * FROM sys.database_role_members rm
    JOIN sys.database_principals member ON rm.member_principal_id = member.principal_id
    JOIN sys.database_principals role ON rm.role_principal_id = role.principal_id
    WHERE member.name = '{{PURCHASER_UAMI_NAME}}' AND role.name = 'PurchaserRole'
)
BEGIN
    ALTER ROLE PurchaserRole ADD MEMBER [{{PURCHASER_UAMI_NAME}}];
    PRINT 'Added {{PURCHASER_UAMI_NAME}} to PurchaserRole';
END
ELSE
BEGIN
    PRINT 'User {{PURCHASER_UAMI_NAME}} is already a member of PurchaserRole';
END
GO

-- Add supplier UAMI to SupplierRole
IF NOT EXISTS (
    SELECT * FROM sys.database_role_members rm
    JOIN sys.database_principals member ON rm.member_principal_id = member.principal_id
    JOIN sys.database_principals role ON rm.role_principal_id = role.principal_id
    WHERE member.name = '{{SUPPLIER_UAMI_NAME}}' AND role.name = 'SupplierRole'
)
BEGIN
    ALTER ROLE SupplierRole ADD MEMBER [{{SUPPLIER_UAMI_NAME}}];
    PRINT 'Added {{SUPPLIER_UAMI_NAME}} to SupplierRole';
END
ELSE
BEGIN
    PRINT 'User {{SUPPLIER_UAMI_NAME}} is already a member of SupplierRole';
END
GO

-- ==============================================================================
-- VERIFICATION
-- ==============================================================================

PRINT '';
PRINT '==========================================================';
PRINT 'SQL Contained Users and Custom Roles - Setup Complete';
PRINT '==========================================================';
PRINT '';
PRINT 'Created users:';
SELECT name, type_desc, authentication_type_desc FROM sys.database_principals WHERE name IN ('{{PURCHASER_UAMI_NAME}}', '{{SUPPLIER_UAMI_NAME}}');
PRINT '';
PRINT 'Created roles:';
SELECT name, type_desc FROM sys.database_principals WHERE name IN ('PurchaserRole', 'SupplierRole');
PRINT '';
PRINT 'Role memberships:';
SELECT 
    role.name AS RoleName,
    member.name AS MemberName
FROM sys.database_role_members rm
JOIN sys.database_principals member ON rm.member_principal_id = member.principal_id
JOIN sys.database_principals role ON rm.role_principal_id = role.principal_id
WHERE role.name IN ('PurchaserRole', 'SupplierRole');
PRINT '';
