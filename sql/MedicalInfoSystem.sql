/* =========================================================
   MedicalInfoSystem — All Parts (1–7 + Auditing Test)
   Combined SQL Script
   NOTE:
     - Demo/test blocks inside parts are expected to be commented.
     - Keep restore/PITR templates commented.
     - Run on SQL Server (SSMS). Save file as UTF-8.
   ========================================================= */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
/* TABLE OF CONTENTS
   1. Database part 1.sql
   2. Security Part 2.sql
   3. Appointments Part 3.sql
   4. Encryption Part 4.sql
   5. Diagnosis Part 5.sql
   6. Auditing.sql
   7. Auditing Test.sql
   8. Recovery and Backup Part .sql
*/
GO

/* ========== PART 1 — Database part 1.sql ========== */
USE master;
GO
/* ==========================================
   FILE: Part 1 — DB Setup.sql (Annotated)
   SCOPE: Database + app/api schemas + core tables + seed data
   ========================================== */

------------------------------------------------------------
-- SECTION: DDL — Database (idempotent create, optional)
-- PURPOSE: Ensure target DB exists; switch context
-- OBJECTS: [MedicalInfoSystem]
------------------------------------------------------------
IF DB_ID(N'MedicalInfoSystem') IS NULL
BEGIN
  CREATE DATABASE [MedicalInfoSystem];
END;
GO
USE [MedicalInfoSystem];
GO

------------------------------------------------------------
-- SECTION: DDL — Schemas
-- PURPOSE: Separate concerns: app=data, api=surface
-- OBJECTS: [app], [api]
------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'app')
  EXEC('CREATE SCHEMA app AUTHORIZATION dbo;');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'api')
  EXEC('CREATE SCHEMA api AUTHORIZATION dbo;');
GO

------------------------------------------------------------
-- SECTION: DDL — Table: app.Staff
-- PURPOSE: Staff master with role constraint (Doctor/Nurse)
-- OBJECTS: app.Staff (PK), CK_Position
------------------------------------------------------------
IF OBJECT_ID(N'app.Staff','U') IS NULL
BEGIN
  CREATE TABLE app.Staff (
    StaffID       CHAR(6)    NOT NULL PRIMARY KEY,            -- e.g., D1001 / N2001
    StaffName     NVARCHAR(100) NOT NULL,
    Position      VARCHAR(10) NOT NULL
      CONSTRAINT CK_Staff_Position CHECK (Position IN ('Doctor','Nurse')),
    OfficePhone   VARCHAR(20) NULL,
    UpdatedBy     SYSNAME     NULL,
    UpdatedAt     DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
  );
END;
GO

------------------------------------------------------------
-- SECTION: DDL — Table: app.Patient
-- PURPOSE: Patient master
-- OBJECTS: app.Patient (PK)
------------------------------------------------------------
IF OBJECT_ID(N'app.Patient','U') IS NULL
BEGIN
  CREATE TABLE app.Patient (
    PatientID     CHAR(6)      NOT NULL PRIMARY KEY,          -- e.g., P3001 / P3002
    PatientName   NVARCHAR(100) NOT NULL,
    UpdatedBy     SYSNAME       NULL,
    UpdatedAt     DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
  );
END;
GO

------------------------------------------------------------
-- SECTION: DDL — Table: app.AppointmentAndDiagnosis
-- PURPOSE: Single table holding appointment + diagnosis (encrypted column added later)
-- OBJECTS: app.AppointmentAndDiagnosis (PK, FKs)
------------------------------------------------------------
IF OBJECT_ID(N'app.AppointmentAndDiagnosis','U') IS NULL
BEGIN
  CREATE TABLE app.AppointmentAndDiagnosis (
    DiagID        INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    AppDateTime   DATETIME2(0)      NOT NULL,
    PatientID     CHAR(6)           NOT NULL,                 -- FK → Patient
    DoctorID      CHAR(6)           NOT NULL,                 -- FK → Staff
    -- DiagDetails_Enc VARBINARY(MAX) is added in Part 5 (Encryption)
    UpdatedBy     SYSNAME           NULL,
    UpdatedAt     DATETIME2(0)      NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_AAD_Patient FOREIGN KEY (PatientID) REFERENCES app.Patient(PatientID),
    CONSTRAINT FK_AAD_Staff   FOREIGN KEY (DoctorID)  REFERENCES app.Staff(StaffID)
  );
END;
GO

------------------------------------------------------------
-- SECTION: DML — Seed data (minimal, idempotent)
-- PURPOSE: One doctor, one nurse, two patients
------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM app.Staff WHERE StaffID='D1001')
  INSERT INTO app.Staff(StaffID, StaffName, Position, OfficePhone, UpdatedBy)
  VALUES ('D1001','Dr. Ali','Doctor','03-1000-1000', SUSER_SNAME());

IF NOT EXISTS (SELECT 1 FROM app.Staff WHERE StaffID='N2001')
  INSERT INTO app.Staff(StaffID, StaffName, Position, OfficePhone, UpdatedBy)
  VALUES ('N2001','Nurse Amy','Nurse','03-2000-2000', SUSER_SNAME());

IF NOT EXISTS (SELECT 1 FROM app.Patient WHERE PatientID='P3001')
  INSERT INTO app.Patient(PatientID, PatientName, UpdatedBy)
  VALUES ('P3001','Patient ThreeZeroZeroOne', SUSER_SNAME());

IF NOT EXISTS (SELECT 1 FROM app.Patient WHERE PatientID='P3002')
  INSERT INTO app.Patient(PatientID, PatientName, UpdatedBy)
  VALUES ('P3002','Patient ThreeZeroZeroTwo', SUSER_SNAME());
GO

------------------------------------------------------------
-- SECTION: DDL — Helpful view (directory)
-- PURPOSE: Safe readonly staff directory exposed via api.*
-- OBJECTS: api.vw_Staff_Directory
------------------------------------------------------------
IF OBJECT_ID(N'api.vw_Staff_Directory','V') IS NULL
EXEC('
CREATE VIEW api.vw_Staff_Directory
AS
SELECT s.StaffID, s.StaffName, s.Position, s.OfficePhone
FROM app.Staff AS s;
');
GO

------------------------------------------------------------
-- SECTION: NOTES
-- * Permissions (DCL) are defined in Part 2 (Security)
-- * Encryption columns + procs are in Part 5 (Encryption)
-- * Diagnosis write/read APIs are in Phase 4 (Diagnosis)
-- * Auditing/Temporal get added in Part 7
------------------------------------------------------------
/* ==========================================
   VERIFICATION — Part 1 DB Setup (Fixed)
   PURPOSE: Show that base tables and seed data exist
   ========================================== */

-- 1. List all schemas you created
SELECT s.name AS SchemaName
FROM sys.schemas AS s
WHERE s.name IN ('app','api');

-- 2. Check the tables and row counts (safe method)
SELECT 
    t.name AS TableName,
    SUM(p.row_count) AS [Row_Count]
FROM sys.tables AS t
JOIN sys.dm_db_partition_stats AS p
    ON t.object_id = p.object_id
   AND p.index_id IN (0,1)  -- heap or clustered index
WHERE t.name IN ('Staff','Patient','AppointmentAndDiagnosis')
GROUP BY t.name;

-- 3. See the seeded staff
SELECT StaffID, StaffName, Position, OfficePhone
FROM app.Staff;

-- 4. See the seeded patients
SELECT PatientID, PatientName
FROM app.Patient;

-- 5. Confirm view is accessible
SELECT TOP 10 * FROM api.vw_Staff_Directory;

GO

/* ========== PART 2 — Security Part 2.sql ========== */
/* ==========================================
   FILE: Part 2 — Security.sql (Annotated)
   SCOPE: Server logins, DB users, roles, DENY/GRANT model
   ENGINE: Microsoft SQL Server (on-prem/VM/Developer/Express/Std/Ent)
   NOTES:
     - Logins are SERVER-scope → run the login block in [master].
     - Users/roles/permissions are DATABASE-scope → run in [MedicalInfoSystem].
     - Principle: humans are DENIED direct access to [app] schema; they only use [api]*.
   ========================================== */

------------------------------------------------------------
-- SECTION: DDL — Server logins (idempotent)
-- PURPOSE: Create principals for admin, doctor, nurse, and two patients
-- OBJECTS: [login_superadmin], [D1001], [N2001], [P3001], [P3002]
------------------------------------------------------------
USE [master];
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'login_superadmin')
    CREATE LOGIN [login_superadmin] WITH PASSWORD = 'SuperAdmin#2025!', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'D1001')
    CREATE LOGIN [D1001] WITH PASSWORD = 'Doctor#2025!', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'N2001')
    CREATE LOGIN [N2001] WITH PASSWORD = 'Nurse#2025!', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'P3001')
    CREATE LOGIN [P3001] WITH PASSWORD = 'Patient1#2025!', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'P3002')
    CREATE LOGIN [P3002] WITH PASSWORD = 'Patient2#2025!', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
GO

------------------------------------------------------------
-- SECTION: DDL — Database users (idempotent)
-- PURPOSE: Map server logins to database users
-- OBJECTS: [user_superadmin], [user_dr_ali], [user_nurse_amy], [user_pt_3001], [user_pt_3002]
------------------------------------------------------------
USE [MedicalInfoSystem];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'user_superadmin')
    CREATE USER [user_superadmin] FOR LOGIN [login_superadmin];

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'user_dr_ali')
    CREATE USER [user_dr_ali] FOR LOGIN [D1001];

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'user_nurse_amy')
    CREATE USER [user_nurse_amy] FOR LOGIN [N2001];

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'user_pt_3001')
    CREATE USER [user_pt_3001] FOR LOGIN [P3001];

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'user_pt_3002')
    CREATE USER [user_pt_3002] FOR LOGIN [P3002];
GO

------------------------------------------------------------
-- SECTION: DDL — Roles (idempotent)
-- PURPOSE: Role-based access control for doctors, nurses, patients
-- OBJECTS: [r_doctor], [r_nurse], [r_patient]
------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE type = 'R' AND name = N'r_doctor')
    CREATE ROLE [r_doctor] AUTHORIZATION [dbo];

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE type = 'R' AND name = N'r_nurse')
    CREATE ROLE [r_nurse] AUTHORIZATION [dbo];

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE type = 'R' AND name = N'r_patient')
    CREATE ROLE [r_patient] AUTHORIZATION [dbo];
GO

------------------------------------------------------------
-- SECTION: DDL — Role membership (idempotent)
-- PURPOSE: Place users in their least-privilege roles
------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals u ON u.principal_id = drm.member_principal_id
    WHERE r.name = N'r_doctor' AND u.name = N'user_dr_ali'
)
    ALTER ROLE [r_doctor] ADD MEMBER [user_dr_ali];

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals u ON u.principal_id = drm.member_principal_id
    WHERE r.name = N'r_nurse' AND u.name = N'user_nurse_amy'
)
    ALTER ROLE [r_nurse] ADD MEMBER [user_nurse_amy];

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals u ON u.principal_id = drm.member_principal_id
    WHERE r.name = N'r_patient' AND u.name = N'user_pt_3001'
)
    ALTER ROLE [r_patient] ADD MEMBER [user_pt_3001];

IF NOT EXISTS (
    SELECT 1
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON r.principal_id = drm.role_principal_id
    JOIN sys.database_principals u ON u.principal_id = drm.member_principal_id
    WHERE r.name = N'r_patient' AND u.name = N'user_pt_3002'
)
    ALTER ROLE [r_patient] ADD MEMBER [user_pt_3002];
GO

------------------------------------------------------------
-- SECTION: DDL — Admin elevation (idempotent)
-- PURPOSE: Give superadmin database-owner capabilities
------------------------------------------------------------
IF IS_ROLEMEMBER('db_owner', 'user_superadmin') = 0
    EXEC sp_addrolemember @rolename = N'db_owner', @membername = N'user_superadmin';
GO

------------------------------------------------------------
-- SECTION: DCL — Deny direct table access to humans
-- PURPOSE: Enforce "no direct access to [app]" for non-admin roles
-- OBJECTS: DENY on SCHEMA::app for r_doctor, r_nurse, r_patient
------------------------------------------------------------
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[app] TO [r_doctor];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[app] TO [r_nurse];
DENY SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[app] TO [r_patient];
GO

------------------------------------------------------------
-- SECTION: DCL — Allow access via the API surface
-- PURPOSE: Roles can SELECT/EXECUTE against [api]* only
-- OBJECTS: GRANT on SCHEMA::api to r_doctor / r_nurse / r_patient
-- NOTE: Granting at schema-level keeps this file decoupled from later parts.
------------------------------------------------------------
GRANT SELECT, EXECUTE ON SCHEMA::[api] TO [r_doctor];
GRANT SELECT, EXECUTE ON SCHEMA::[api] TO [r_nurse];
GRANT SELECT, EXECUTE ON SCHEMA::[api] TO [r_patient];
GO

/* ==========================================
   VERIFICATION — Part 2 Security
   PURPOSE: Prove principals, roles, denies, and api access policy exist
   ========================================== */

-- 1) Users and roles in this DB
SELECT name AS PrincipalName, type_desc
FROM sys.database_principals
WHERE name IN ('user_superadmin','user_dr_ali','user_nurse_amy','user_pt_3001','user_pt_3002',
               'r_doctor','r_nurse','r_patient');

-- 2) Role memberships (who’s in which role)
SELECT USER_NAME(member_principal_id) AS MemberName,
       USER_NAME(role_principal_id)   AS RoleName
FROM sys.database_role_members
WHERE USER_NAME(role_principal_id) IN ('r_doctor','r_nurse','r_patient')
ORDER BY RoleName, MemberName;

-- 3) DENY check on [app] (role-scoped)
SELECT dp.state_desc, dp.permission_name, dp.class_desc, OBJECT_SCHEMA_NAME(dp.major_id) AS SchemaName,
       USER_NAME(grantee_principal_id) AS Grantee
FROM sys.database_permissions dp
WHERE dp.class_desc = 'SCHEMA'
  AND dp.major_id = SCHEMA_ID('app')
  AND dp.permission_name IN ('SELECT','INSERT','UPDATE','DELETE')
  AND USER_NAME(grantee_principal_id) IN ('r_doctor','r_nurse','r_patient')
ORDER BY Grantee, permission_name;

-- 4) GRANT check on [api] (role-scoped)
SELECT dp.state_desc, dp.permission_name, dp.class_desc, OBJECT_SCHEMA_NAME(dp.major_id) AS SchemaName,
       USER_NAME(grantee_principal_id) AS Grantee
FROM sys.database_permissions dp
WHERE dp.class_desc = 'SCHEMA'
  AND dp.major_id = SCHEMA_ID('api')
  AND dp.permission_name IN ('SELECT','EXECUTE')
  AND USER_NAME(grantee_principal_id) IN ('r_doctor','r_nurse','r_patient')
ORDER BY Grantee, permission_name;

-- 5) Sanity: do roles have SELECT on app? (should be 0 = no)
SELECT 
  'r_doctor' AS RoleName,
  HAS_PERMS_BY_NAME('app', 'SCHEMA', 'SELECT') AS HasSelectOnApp
UNION ALL SELECT 'r_nurse',  HAS_PERMS_BY_NAME('app', 'SCHEMA', 'SELECT')
UNION ALL SELECT 'r_patient',HAS_PERMS_BY_NAME('app', 'SCHEMA', 'SELECT');

-- 6) Admin role check
SELECT IS_ROLEMEMBER('db_owner','user_superadmin') AS IsSuperAdminDbOwner;  -- 1 = yes

GO

/* ========== PART 3 — Appointments Part 3.sql ========== */
/* ==========================================
   FILE: Part 3 � Appointments.sql (Integrated & Idempotent)
   SCOPE: Nurse-facing appointment API (add / reschedule / cancel) + vie
   PRE-REQS:
     - Part 1: tables app.Staff, app.Patient, app.AppointmentAndDiagnosis
     - Part 2: roles/users & DENY on [app], GRANT on [api]
   PRINCIPLES:
     - Humans have NO direct access to [app] (Part 2 DENY).
     - All access is via api.* modules with EXECUTE AS OWNER.
     - FK columns (PatientID, DoctorID) are WRITE-ONCE at INSERT; never updated.
     - Procs are CREATE OR ALTER, safe to re-run.
   ========================================== */

USE [MedicalInfoSystem];
GO
SET ANSI_NULLS ON; 
SET QUOTED_IDENTIFIER ON;
GO

/* ------------------------------
   VIEW: Nurse view of appointments
   ------------------------------ */
CREATE OR ALTER VIEW api.vw_Appointments_ForNurse
AS
SELECT 
    A.DiagID,
    A.AppDateTime,
    A.PatientID,
    P.PatientName,
    A.DoctorID,
    S.StaffName AS DoctorName,
    A.UpdatedBy,
    A.UpdatedAt
FROM app.AppointmentAndDiagnosis A
JOIN app.Patient P ON P.PatientID = A.PatientID
JOIN app.Staff   S ON S.StaffID   = A.DoctorID;
GO

/* ------------------------------
   PROC: Add appointment
   ------------------------------ */
CREATE OR ALTER PROCEDURE api.usp_App_Add
    @PatientID   CHAR(6),
    @DoctorID    CHAR(6),
    @AppDateTime DATETIME2(0)
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    -- Existence & role checks
    IF NOT EXISTS (SELECT 1 FROM app.Patient WHERE PatientID=@PatientID)
        THROW 52010, 'Patient does not exist.', 1;

    IF NOT EXISTS (SELECT 1 FROM app.Staff WHERE StaffID=@DoctorID AND Position='Doctor')
        THROW 52011, 'Doctor does not exist or is not a Doctor.', 1;

    -- Avoid exact-duplicate appointment for same patient/doctor/timestamp
    IF EXISTS (
        SELECT 1 FROM app.AppointmentAndDiagnosis
        WHERE PatientID=@PatientID AND DoctorID=@DoctorID AND AppDateTime=@AppDateTime
    )
        THROW 52012, 'Duplicate appointment already exists for this patient, doctor, time.', 1;

    INSERT INTO app.AppointmentAndDiagnosis (PatientID, DoctorID, AppDateTime, UpdatedBy, UpdatedAt)
    VALUES (@PatientID, @DoctorID, @AppDateTime, SUSER_SNAME(), SYSUTCDATETIME());

    -- Return the newly created row
    SELECT * 
    FROM api.vw_Appointments_ForNurse
    WHERE DiagID = SCOPE_IDENTITY();
END
GO

/* ------------------------------
   PROC: Reschedule appointment (change time only)
   ------------------------------ */
CREATE OR ALTER PROCEDURE api.usp_App_Reschedule
    @DiagID         INT,
    @NewAppDateTime DATETIME2(0)
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM app.AppointmentAndDiagnosis WHERE DiagID=@DiagID)
        THROW 52020, 'Appointment not found.', 1;

    -- Optional: prevent accidental exact duplicates on reschedule
    IF EXISTS (
        SELECT 1 
        FROM app.AppointmentAndDiagnosis A
        WHERE A.DiagID<>@DiagID
          AND A.PatientID = (SELECT PatientID FROM app.AppointmentAndDiagnosis WHERE DiagID=@DiagID)
          AND A.DoctorID  = (SELECT DoctorID  FROM app.AppointmentAndDiagnosis WHERE DiagID=@DiagID)
          AND A.AppDateTime = @NewAppDateTime
    )
        THROW 52021, 'Another appointment already exists at the requested time.', 1;

    UPDATE app.AppointmentAndDiagnosis
      SET AppDateTime=@NewAppDateTime,
          UpdatedBy  =SUSER_SNAME(),
          UpdatedAt  =SYSUTCDATETIME()
    WHERE DiagID=@DiagID;

    SELECT * 
    FROM api.vw_Appointments_ForNurse
    WHERE DiagID=@DiagID;
END
GO

/* ------------------------------
   PROC: Cancel appointment
 
   ------------------------------ */
CREATE OR ALTER PROCEDURE api.usp_App_Cancel
    @DiagID INT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM app.AppointmentAndDiagnosis WHERE DiagID=@DiagID)
        THROW 52030, 'Appointment not found.', 1;

    DELETE FROM app.AppointmentAndDiagnosis WHERE DiagID=@DiagID;

    -- Return the latest remaining rows as a convenience
    SELECT TOP 10 * 
    FROM api.vw_Appointments_ForNurse
    ORDER BY AppDateTime DESC, DiagID DESC;
END
GO

/* ------------------------------
   DCL: Minimal grants for nurses
   ------------------------------ */
GRANT SELECT  ON OBJECT::api.vw_Appointments_ForNurse TO [r_nurse];
GRANT EXECUTE ON OBJECT::api.usp_App_Add             TO [r_nurse];
GRANT EXECUTE ON OBJECT::api.usp_App_Reschedule      TO [r_nurse];
GRANT EXECUTE ON OBJECT::api.usp_App_Cancel          TO [r_nurse];
GO

/* ==========================================
   VERIFICATION � Objects & Grants (safe)
   ========================================== */
-- Objects present
SELECT name, type_desc
FROM sys.objects
WHERE name IN ('vw_Appointments_ForNurse','usp_App_Add','usp_App_Reschedule','usp_App_Cancel')
ORDER BY type_desc, name;

-- Grants check
SELECT dp.state_desc, dp.permission_name,
       OBJECT_SCHEMA_NAME(dp.major_id) AS SchemaName,
       OBJECT_NAME(dp.major_id)        AS ObjectName,
       USER_NAME(grantee_principal_id) AS Grantee
FROM sys.database_permissions dp
WHERE OBJECT_NAME(dp.major_id) IN ('vw_Appointments_ForNurse','usp_App_Add','usp_App_Reschedule','usp_App_Cancel')
ORDER BY Grantee, ObjectName;
GO

/* ==========================================
   AUTO-DEMO � Seed appointments 
   for BOTH P3001 and P3002 so Diagnosis (Part 5)
   has data to work with.
   - Picks an existing doctor (D1001 if present; else first Doctor)
   - Adds future appointments unless exact duplicates exist
   - Shows nurse view at the end
   ========================================== */

DECLARE @DoctorID CHAR(6);
SELECT @DoctorID = 'D1001'
WHERE EXISTS (SELECT 1 FROM app.Staff WHERE StaffID='D1001' AND Position='Doctor');

IF @DoctorID IS NULL
    SELECT TOP 1 @DoctorID = StaffID FROM app.Staff WHERE Position='Doctor';

IF @DoctorID IS NULL
BEGIN
    RAISERROR('No Doctor found. Seed a doctor in Part 1.', 16, 1);
    RETURN;
END

-- Helper: add one appointment if the exact slot doesn't already exist
DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();

DECLARE @p CHAR(6), @t DATETIME2(0);

-- Appointments for P3001 (two future slots)
SET @p = 'P3001';
SET @t = DATEADD(HOUR, 1,  @Now);
IF NOT EXISTS (SELECT 1 FROM app.AppointmentAndDiagnosis WHERE PatientID=@p AND DoctorID=@DoctorID AND AppDateTime=@t)
BEGIN
    EXECUTE AS USER='user_nurse_amy';
        EXEC api.usp_App_Add @PatientID=@p, @DoctorID=@DoctorID, @AppDateTime=@t;
    REVERT;
END
SET @t = DATEADD(HOUR, 3,  @Now);
IF NOT EXISTS (SELECT 1 FROM app.AppointmentAndDiagnosis WHERE PatientID=@p AND DoctorID=@DoctorID AND AppDateTime=@t)
BEGIN
    EXECUTE AS USER='user_nurse_amy';
        EXEC api.usp_App_Add @PatientID=@p, @DoctorID=@DoctorID, @AppDateTime=@t;
    REVERT;
END

-- Appointments for P3002 (two future slots) � ensures P3002 exists for Diagnosis
SET @p = 'P3002';
SET @t = DATEADD(HOUR, 2,  @Now);
IF NOT EXISTS (SELECT 1 FROM app.AppointmentAndDiagnosis WHERE PatientID=@p AND DoctorID=@DoctorID AND AppDateTime=@t)
BEGIN
    EXECUTE AS USER='user_nurse_amy';
        EXEC api.usp_App_Add @PatientID=@p, @DoctorID=@DoctorID, @AppDateTime=@t;
    REVERT;
END
SET @t = DATEADD(HOUR, 4,  @Now);
IF NOT EXISTS (SELECT 1 FROM app.AppointmentAndDiagnosis WHERE PatientID=@p AND DoctorID=@DoctorID AND AppDateTime=@t)
BEGIN
    EXECUTE AS USER='user_nurse_amy';
        EXEC api.usp_App_Add @PatientID=@p, @DoctorID=@DoctorID, @AppDateTime=@t;
    REVERT;
END

-- Show latest appointments (nurse view)
EXECUTE AS USER='user_nurse_amy';
    SELECT TOP 20 * FROM api.vw_Appointments_ForNurse ORDER BY AppDateTime DESC, DiagID DESC;
REVERT;

GO

/* ========== PART 4 — Encryption Part 4.sql ========== */
/* ==========================================
   FILE: Part 4 — Encryption (Option A).sql
   SCOPE: Column-level encryption + API + (Option A) demo calls
   PRE-REQS:
     - Part 1: app.Staff, app.Patient, app.AppointmentAndDiagnosis
     - Part 2: users/roles (r_doctor, r_nurse, r_patient), DENY on app, GRANT on api
     - Part 3: appointments API (not strictly required here, but already done)
   
   PRINCIPLES:
     - Key hierarchy: DB Master Key → Certificate → Symmetric Key (AES_256)
     - Encrypted-at-rest columns for Patient/Staff/Diagnosis
     - Access via api.* with EXECUTE AS OWNER (callers don’t need table perms)
   ========================================== */

USE [MedicalInfoSystem];
GO

------------------------------------------------------------
-- SECTION: SECURITY/CRYPTO — Master Key (idempotent)
------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
  CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'Strong#DMK#2025!';
END
GO

------------------------------------------------------------
-- SECTION: SECURITY/CRYPTO — Certificate (idempotent)
------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'CertForCLE')
BEGIN
  CREATE CERTIFICATE CertForCLE
    WITH SUBJECT = 'CLE certificate for MedicalInfoSystem';
END
GO

------------------------------------------------------------
-- SECTION: SECURITY/CRYPTO — Symmetric Key (idempotent)
------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = 'SimKey1')
BEGIN
  CREATE SYMMETRIC KEY SimKey1
    WITH ALGORITHM = AES_256
    ENCRYPTION BY CERTIFICATE CertForCLE;
END
GO

------------------------------------------------------------
-- SECTION: DDL — Add encrypted columns (idempotent)
------------------------------------------------------------
-- Patient
IF COL_LENGTH('app.Patient', 'Phone_Enc') IS NULL
  ALTER TABLE app.Patient ADD Phone_Enc VARBINARY(MAX) NULL;
IF COL_LENGTH('app.Patient', 'HomeAddress_Enc') IS NULL
  ALTER TABLE app.Patient ADD HomeAddress_Enc VARBINARY(MAX) NULL;

-- Staff
IF COL_LENGTH('app.Staff', 'PersonalPhone_Enc') IS NULL
  ALTER TABLE app.Staff ADD PersonalPhone_Enc VARBINARY(MAX) NULL;
IF COL_LENGTH('app.Staff', 'HomeAddress_Enc') IS NULL
  ALTER TABLE app.Staff ADD HomeAddress_Enc VARBINARY(MAX) NULL;

-- Appointment & Diagnosis
IF COL_LENGTH('app.AppointmentAndDiagnosis', 'DiagDetails_Enc') IS NULL
  ALTER TABLE app.AppointmentAndDiagnosis ADD DiagDetails_Enc VARBINARY(MAX) NULL;
GO

------------------------------------------------------------
-- SECTION: DDL — API: Patient directory (nurse)
------------------------------------------------------------
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; 
GO
CREATE OR ALTER PROCEDURE api.usp_Patient_Directory
  @PatientID CHAR(6) = NULL
WITH EXECUTE AS OWNER
AS
BEGIN
  SET NOCOUNT ON;
  OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE;

  SELECT 
    P.PatientID,
    P.PatientName,
    CONVERT(varchar(200),  DECRYPTBYKEY(P.Phone_Enc))       AS Phone,
    CONVERT(nvarchar(400), DECRYPTBYKEY(P.HomeAddress_Enc)) AS HomeAddress
  FROM app.Patient AS P
  WHERE (@PatientID IS NULL OR P.PatientID = @PatientID);

  CLOSE SYMMETRIC KEY SimKey1;
END
GO

------------------------------------------------------------
-- SECTION: DDL — API: Patient self-service (select/update)
------------------------------------------------------------
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; 
GO
CREATE OR ALTER PROCEDURE api.usp_Patient_Self_Select
  @PatientID CHAR(6)
WITH EXECUTE AS OWNER
AS
BEGIN
  SET NOCOUNT ON;
  OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE;

  SELECT 
    P.PatientID,
    P.PatientName,
    CONVERT(varchar(200),  DECRYPTBYKEY(P.Phone_Enc))       AS Phone,
    CONVERT(nvarchar(400), DECRYPTBYKEY(P.HomeAddress_Enc)) AS HomeAddress
  FROM app.Patient AS P
  WHERE P.PatientID = @PatientID;

  CLOSE SYMMETRIC KEY SimKey1;
END
GO

CREATE OR ALTER PROCEDURE api.usp_Patient_Self_Update
  @PatientID    CHAR(6),
  @PhonePlain   VARCHAR(200)   = NULL,
  @AddressPlain NVARCHAR(400)  = NULL
WITH EXECUTE AS OWNER
AS
BEGIN
  SET NOCOUNT ON;

  IF NOT EXISTS (SELECT 1 FROM app.Patient WHERE PatientID=@PatientID)
    THROW 51001, 'Invalid PatientID.', 1;

  OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE;

  UPDATE app.Patient
     SET Phone_Enc       = CASE WHEN @PhonePlain   IS NULL THEN Phone_Enc
                                 ELSE ENCRYPTBYKEY(KEY_GUID('SimKey1'), @PhonePlain) END,
         HomeAddress_Enc = CASE WHEN @AddressPlain IS NULL THEN HomeAddress_Enc
                                 ELSE ENCRYPTBYKEY(KEY_GUID('SimKey1'), @AddressPlain) END,
         UpdatedBy       = SUSER_SNAME(),
         UpdatedAt       = SYSUTCDATETIME()
   WHERE PatientID=@PatientID;

  CLOSE SYMMETRIC KEY SimKey1;

  EXEC api.usp_Patient_Self_Select @PatientID=@PatientID;
END
GO

------------------------------------------------------------
-- SECTION: DDL — API: Staff self-service (select/update)
------------------------------------------------------------
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; 
GO
CREATE OR ALTER PROCEDURE api.usp_Staff_Self_Select
  @StaffID CHAR(6)
WITH EXECUTE AS OWNER
AS
BEGIN
  SET NOCOUNT ON;
  OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE;

  SELECT 
    S.StaffID,
    S.StaffName,
    S.Position,
    CONVERT(varchar(200),  DECRYPTBYKEY(S.PersonalPhone_Enc)) AS PersonalPhone,
    CONVERT(nvarchar(400), DECRYPTBYKEY(S.HomeAddress_Enc))   AS HomeAddress
  FROM app.Staff AS S
  WHERE S.StaffID = @StaffID;

  CLOSE SYMMETRIC KEY SimKey1;
END
GO

CREATE OR ALTER PROCEDURE api.usp_Staff_Self_Update
  @StaffID      CHAR(6),
  @PhonePlain   VARCHAR(200)   = NULL,
  @AddressPlain NVARCHAR(400)  = NULL
WITH EXECUTE AS OWNER
AS
BEGIN
  SET NOCOUNT ON;

  IF NOT EXISTS (SELECT 1 FROM app.Staff WHERE StaffID=@StaffID)
    THROW 52001, 'Invalid StaffID.', 1;

  OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE;

  UPDATE app.Staff
     SET PersonalPhone_Enc = CASE WHEN @PhonePlain   IS NULL THEN PersonalPhone_Enc
                                   ELSE ENCRYPTBYKEY(KEY_GUID('SimKey1'), @PhonePlain) END,
         HomeAddress_Enc   = CASE WHEN @AddressPlain IS NULL THEN HomeAddress_Enc
                                   ELSE ENCRYPTBYKEY(KEY_GUID('SimKey1'), @AddressPlain) END,
         UpdatedBy         = SUSER_SNAME(),
         UpdatedAt         = SYSUTCDATETIME()
   WHERE StaffID=@StaffID;

  CLOSE SYMMETRIC KEY SimKey1;

  EXEC api.usp_Staff_Self_Select @StaffID=@StaffID;
END
GO

------------------------------------------------------------
-- SECTION: DCL — Grants (role-appropriate)
------------------------------------------------------------
-- Nurse operational directory
GRANT EXECUTE ON OBJECT::api.usp_Patient_Directory   TO [r_nurse];

-- Patients self-service
GRANT EXECUTE ON OBJECT::api.usp_Patient_Self_Select TO [r_patient];
GRANT EXECUTE ON OBJECT::api.usp_Patient_Self_Update TO [r_patient];

-- Staff self-service
GRANT EXECUTE ON OBJECT::api.usp_Staff_Self_Select   TO [r_doctor];
GRANT EXECUTE ON OBJECT::api.usp_Staff_Self_Update   TO [r_doctor];
GRANT EXECUTE ON OBJECT::api.usp_Staff_Self_Select   TO [r_nurse];
GRANT EXECUTE ON OBJECT::api.usp_Staff_Self_Update   TO [r_nurse];
GO

/* ==========================================
   (OPTION A) DEMO — Patients update via API (commented)
   PURPOSE: Fill encrypted columns by calling the intended API
   NOTE: Un-comment to run; uses patient personas from Part 2
   ========================================== */

EXECUTE AS USER = 'user_pt_3001';
EXEC api.usp_Patient_Self_Update 
     @PatientID='P3001',
     @PhonePlain='012-3456789',
     @AddressPlain=N'Block A, Jalan 1, KL';
REVERT;

EXECUTE AS USER = 'user_pt_3002';
EXEC api.usp_Patient_Self_Update 
     @PatientID='P3002',
     @PhonePlain='019-8887777',
     @AddressPlain=N'Block B, Jalan 2, KL';
REVERT;


 /* ==========================================
    VERIFICATION — Keys/Columns/Blobs/Decrypt (safe to run)
    PURPOSE: Show key presence, columns, raw blobs, and plaintext side-by-side
    ========================================== */

-- 1) Key hierarchy
SELECT 'HasDMK' AS Item, CASE WHEN EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name='##MS_DatabaseMasterKey##') THEN 1 ELSE 0 END AS Present
UNION ALL
SELECT 'HasCert', CASE WHEN EXISTS (SELECT 1 FROM sys.certificates WHERE name='CertForCLE') THEN 1 ELSE 0 END
UNION ALL
SELECT 'HasSymKey', CASE WHEN EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name='SimKey1') THEN 1 ELSE 0 END;

-- 2) Encrypted columns (existence)
SELECT t.name AS TableName, c.name AS ColumnName, TYPE_NAME(c.user_type_id) AS TypeName
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id
WHERE (t.name='Patient' AND c.name IN ('Phone_Enc','HomeAddress_Enc'))
   OR (t.name='Staff'   AND c.name IN ('PersonalPhone_Enc','HomeAddress_Enc'))
   OR (t.name='AppointmentAndDiagnosis' AND c.name='DiagDetails_Enc')
ORDER BY t.name, c.name;

-- 3) Raw ciphertext vs decrypted (side-by-side). Run as dbo/superadmin.
OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE;

SELECT 
  P.PatientID,
  P.Phone_Enc                                  AS PhoneCipher,
  sys.fn_varbintohexsubstring(1, P.Phone_Enc, 1, 0)       AS PhoneHex,
  CONVERT(varchar(200),  DECRYPTBYKEY(P.Phone_Enc))        AS PhonePlain,
  P.HomeAddress_Enc                             AS AddressCipher,
  sys.fn_varbintohexsubstring(1, P.HomeAddress_Enc, 1, 0) AS AddressHex,
  CONVERT(nvarchar(400), DECRYPTBYKEY(P.HomeAddress_Enc))  AS AddressPlain
FROM app.Patient AS P
WHERE P.PatientID IN ('P3001','P3002');

CLOSE SYMMETRIC KEY SimKey1;

GO

/* ========== PART 5 — Diagnosis Part 5.sql ========== */
/* ==========================================
   FILE: Part 5 � Diagnosis API.sql
   SCOPE: Doctor write (encrypt) + Doctor/Patient read (decrypt)
   PRE-REQS:
     - Part 1: app tables (Staff, Patient, AppointmentAndDiagnosis)
     - Part 2: users/roles (r_doctor, r_patient)
     - Part 4: encryption (DMK, CertForCLE, SimKey1, DiagDetails_Enc column)
   PRINCIPLES:
     - EXECUTE AS OWNER; callers never need table perms
     - Never modify FK columns (PatientID, DoctorID)
     - ENCRYPTBYKEY on write; DECRYPTBYKEY on read
   ========================================== */

USE [MedicalInfoSystem];
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ------------------------------
   Proc: Doctor adds diagnosis (encrypts)
   ------------------------------ */
CREATE OR ALTER PROCEDURE api.usp_Diag_Add_ByDoctor
    @DiagID      INT,
    @DoctorID    CHAR(6),
    @DiagDetails NVARCHAR(MAX)
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM app.AppointmentAndDiagnosis WHERE DiagID=@DiagID)
        THROW 53001, 'Appointment (DiagID) not found.', 1;

    IF NOT EXISTS (
        SELECT 1
        FROM app.AppointmentAndDiagnosis A
        JOIN app.Staff S ON S.StaffID = A.DoctorID
        WHERE A.DiagID=@DiagID AND A.DoctorID=@DoctorID AND S.Position='Doctor'
    )
        THROW 53002, 'Doctor mismatch or not a Doctor.', 1;

    OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE;

    UPDATE app.AppointmentAndDiagnosis
       SET DiagDetails_Enc = ENCRYPTBYKEY(KEY_GUID('SimKey1'), @DiagDetails),
           UpdatedBy       = SUSER_SNAME(),
           UpdatedAt       = SYSUTCDATETIME()
     WHERE DiagID=@DiagID;

    CLOSE SYMMETRIC KEY SimKey1;

    EXEC api.usp_Diag_Select_All_ForDoctors @FilterDiagID=@DiagID;
END
GO

/* ------------------------------
   Proc: Same doctor updates diagnosis (encrypts)
   ------------------------------ */
CREATE OR ALTER PROCEDURE api.usp_Diag_Update_BySameDoctor
    @DiagID     INT,
    @DoctorID   CHAR(6),
    @NewDetails NVARCHAR(MAX)
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM app.AppointmentAndDiagnosis WHERE DiagID=@DiagID AND DoctorID=@DoctorID)
        THROW 53101, 'Appointment not found for this doctor.', 1;

    OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE;

    UPDATE app.AppointmentAndDiagnosis
       SET DiagDetails_Enc = ENCRYPTBYKEY(KEY_GUID('SimKey1'), @NewDetails),
           UpdatedBy       = SUSER_SNAME(),
           UpdatedAt       = SYSUTCDATETIME()
     WHERE DiagID=@DiagID;

    CLOSE SYMMETRIC KEY SimKey1;

    EXEC api.usp_Diag_Select_All_ForDoctors @FilterDiagID=@DiagID;
END
GO

/* ------------------------------
   Proc: Doctors read (decrypts)
   ------------------------------ */
CREATE OR ALTER PROCEDURE api.usp_Diag_Select_All_ForDoctors
    @FilterDiagID INT = NULL
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE;

    SELECT 
        A.DiagID,
        A.AppDateTime,
        A.PatientID,
        P.PatientName,
        A.DoctorID,
        S.StaffName AS DoctorName,
        CONVERT(NVARCHAR(MAX), DECRYPTBYKEY(A.DiagDetails_Enc)) AS DiagDetails_Plain,
        A.UpdatedBy,
        A.UpdatedAt
    FROM app.AppointmentAndDiagnosis A
    JOIN app.Patient P ON P.PatientID = A.PatientID
    JOIN app.Staff   S ON S.StaffID   = A.DoctorID
    WHERE (@FilterDiagID IS NULL OR A.DiagID=@FilterDiagID)
    ORDER BY A.AppDateTime DESC, A.DiagID DESC;

    CLOSE SYMMETRIC KEY SimKey1;
END
GO

/* ------------------------------
   Proc: Patient self-read (decrypts own rows)
   ------------------------------ */
CREATE OR ALTER PROCEDURE api.usp_Diag_Select_PatientSelf
    @PatientID CHAR(6)
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE;

    SELECT
        A.DiagID,
        A.AppDateTime,
        A.PatientID,
        A.DoctorID,
        S.StaffName AS DoctorName,
        CONVERT(NVARCHAR(MAX), DECRYPTBYKEY(A.DiagDetails_Enc)) AS DiagDetails_Plain,
        A.UpdatedBy,
        A.UpdatedAt
    FROM app.AppointmentAndDiagnosis A
    JOIN app.Staff S ON S.StaffID = A.DoctorID
    WHERE A.PatientID=@PatientID
    ORDER BY A.AppDateTime DESC, A.DiagID DESC;

    CLOSE SYMMETRIC KEY SimKey1;
END
GO

/* ------------------------------
   Grants
   ------------------------------ */
GRANT EXECUTE ON OBJECT::api.usp_Diag_Add_ByDoctor          TO [r_doctor];
GRANT EXECUTE ON OBJECT::api.usp_Diag_Update_BySameDoctor   TO [r_doctor];
GRANT EXECUTE ON OBJECT::api.usp_Diag_Select_All_ForDoctors TO [r_doctor];
GRANT EXECUTE ON OBJECT::api.usp_Diag_Select_PatientSelf    TO [r_patient];
GO

/* ==========================================
   VERIFICATION & AUTO-DEMO � Part 5
   PURPOSE:
     - Auto-detect latest N appointments for BOTH patients (P3001, P3002)
     - Add a note if missing; update if already present
     - Avoid hardcoded DiagIDs; handle �no appointments� gracefully
   HOW TO USE:
     - Remove the comment markers to run (/* ... */)
     - Adjust @PerPatientN as you like (e.g., 2, 3, 5)
   ========================================== */

DECLARE @PerPatientN int = 3;  -- how many appointments per patient to fill

-- Show current state (HAS_NOTE vs MISSING)
SELECT DiagID, PatientID, DoctorID, AppDateTime,
       CASE WHEN DiagDetails_Enc IS NULL THEN 'MISSING' ELSE 'HAS_NOTE' END AS NoteState
FROM app.AppointmentAndDiagnosis
WHERE PatientID IN ('P3001','P3002')
ORDER BY PatientID, AppDateTime DESC;

-- Build a target list: latest N appts per patient (P3001, P3002)
DECLARE @Targets TABLE(
  DiagID     INT     NOT NULL,
  PatientID  CHAR(6) NOT NULL,
  DoctorID   CHAR(6) NOT NULL,
  rn         INT     NOT NULL
);

INSERT @Targets (DiagID, PatientID, DoctorID, rn)
SELECT DiagID, PatientID, DoctorID,
       ROW_NUMBER() OVER (PARTITION BY PatientID ORDER BY AppDateTime DESC) AS rn
FROM app.AppointmentAndDiagnosis
WHERE PatientID IN ('P3001','P3002');

-- Keep only latest N per patient
DELETE FROM @Targets WHERE rn > @PerPatientN;

-- If a patient has no appointments, print a helpful message
IF NOT EXISTS (SELECT 1 FROM @Targets WHERE PatientID='P3001')
    PRINT 'Note: P3001 has no appointments. Use Part 3 (Appointments) to create some.';
IF NOT EXISTS (SELECT 1 FROM @Targets WHERE PatientID='P3002')
    PRINT 'Note: P3002 has no appointments. Use Part 3 (Appointments) to create some.';

-- Loop and add/update notes using the correct DoctorID per appointment
DECLARE 
  @d INT, @pid CHAR(6), @doc CHAR(6), @rn INT,
  @Details NVARCHAR(MAX);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
  SELECT DiagID, PatientID, DoctorID, rn
  FROM @Targets
  ORDER BY PatientID, rn;

OPEN cur;
FETCH NEXT FROM cur INTO @d, @pid, @doc, @rn;

WHILE @@FETCH_STATUS = 0
BEGIN
  -- sample demo texts (vary per patient/slot)
  SET @Details = CASE 
      WHEN @pid='P3001' AND @rn=1 THEN N'Initial visit: mild gastritis; PPI 20mg daily.'
      WHEN @pid='P3001' AND @rn=2 THEN N'Follow-up: symptoms improving; continue meds.'
      WHEN @pid='P3001' AND @rn=3 THEN N'Demo note.'
      WHEN @pid='P3002' AND @rn=1 THEN N'Annual physical: healthy; encourage exercise.'
      WHEN @pid='P3002' AND @rn=2 THEN N'Dental check: minor cavity; scheduled filling.'
      WHEN @pid='P3002' AND @rn=3 THEN N'Follow-up review: stable.'
      ELSE N'Demo note.'
  END;

  IF EXISTS (SELECT 1 FROM app.AppointmentAndDiagnosis WHERE DiagID=@d AND DiagDetails_Enc IS NULL)
      EXEC api.usp_Diag_Add_ByDoctor        @DiagID=@d, @DoctorID=@doc, @DiagDetails=@Details;
  ELSE
      EXEC api.usp_Diag_Update_BySameDoctor @DiagID=@d, @DoctorID=@doc, @NewDetails=@Details;

  FETCH NEXT FROM cur INTO @d, @pid, @doc, @rn;
END
CLOSE cur; DEALLOCATE cur;

-- Doctor verification (decrypted)
EXEC api.usp_Diag_Select_All_ForDoctors;

-- Patient self-verification (decrypted)
EXECUTE AS USER='user_pt_3001';
EXEC api.usp_Diag_Select_PatientSelf @PatientID='P3001';
REVERT;

EXECUTE AS USER='user_pt_3002';
EXEC api.usp_Diag_Select_PatientSelf @PatientID='P3002';
REVERT;

-- Ciphertext peek (hex blobs at rest)
SELECT TOP 10
  A.PatientID, A.DiagID,
  A.DiagDetails_Enc AS Cipher,
  sys.fn_varbintohexsubstring(1, A.DiagDetails_Enc, 1, 0) AS HexString
FROM app.AppointmentAndDiagnosis A
WHERE A.PatientID IN ('P3001','P3002')
  AND A.DiagDetails_Enc IS NOT NULL
ORDER BY A.PatientID, A.DiagID DESC;

GO

/* ========== PART 6 — Auditing.sql ========== */
/* =========================================================
   PHASE 7- Auditing

   ========================================================= */

Use MedicalInfoSystem
Go



If Not Exists (Select 1 From sys.schemas Where name ='audit')
	Exec('Create Schema Audit;');
Go



--DML Log
IF OBJECT_ID('audit.AuditLog_DML') is null
Create table audit.AuditLog_DML(
	LogID INT identity(1,1) Primary key,
	LogDateTime Datetime2 default sysutcdatetime(),
	UserName Sysname Default Original_Login(),
	ActionType Varchar(20),
	TableName Sysname,
	KeyValue Varchar(50),
	SqlCmd Nvarchar(max)
);


--DDL LOG
If OBJECT_ID('audit.AuditLog_DDL', 'U') is null
Begin
	create table audit.AuditLog_DDL(
		LogID int identity(1,1) primary key,
		LogDateTime Datetime2 default sysutcdatetime(),
		UserName Sysname Default Original_Login(),
		SqlCmd Nvarchar(max)
	);
End;
Go


--Logon Log
If OBJECT_ID('audit.AuditLog_Logon', 'U') is null
create table audit.AuditLog_Logon(
	LogID int identity(1,1) primary key,
	LogDateTime Datetime2 default sysutcdatetime(),
	UserName Sysname Default Original_Login(),
	HostName nvarchar(100),
	AppName Nvarchar(100)
);

--DCL Log
If OBJECT_ID('audit.AuditLogDCL', 'U') is null
Begin
	Create Table audit.AuditLogDCL(
		LogID       INT IDENTITY(1,1) PRIMARY KEY,
        EventType   NVARCHAR(100),
        DatabaseName NVARCHAR(100),
        ObjectName  NVARCHAR(200),
        LoginName   NVARCHAR(100),
        SqlCmd      NVARCHAR(MAX),
        LogDate     DATETIME2 DEFAULT SYSUTCDATETIME()
	);
End;
Go


/* =========================================================
	DML TRIGGERS
   ========================================================= */

--Staff table
DROP TRIGGER IF EXISTS app.trg_StaffAudit;
Go
 create or alter trigger trg_StaffAudit
 on app.Staff
 After insert, update, delete
 as
 begin
	Set NoCount On;
	Insert into audit.AuditLog_DML(ActionType, TableName, KeyValue, SqlCmd)
	Select
		Case
			When i.StaffID is Not Null and d.StaffID is Not Null then 'UPDATE'
			When i.StaffID is Not Null then 'INSERT'
			Else 'DELETE'
		End,
		'Staff',
		Coalesce(Convert(Varchar(50),i.StaffID), Convert(Varchar(50),d.StaffID)),
		Null
	From inserted i
	Full Join deleted d On i.StaffID=d.StaffID;
End;
Go

--Patient Table
DROP TRIGGER IF EXISTS app.trg_PatientAudit;
GO
 create or alter trigger trg_PatientAudit
 on app.Patient
 After insert, update, delete
 as
 begin
	Set NoCount On;

	Insert into audit.AuditLog_DML(ActionType, TableName, KeyValue, SqlCmd)
	Select
		Case
			When i.PatientID is not null and d.PatientID is not null then 'UPDATE'
			When i.PatientID is not null then 'INSERT'
			Else 'DELETE'
		End,
		'Patient',
		Coalesce(i.PatientID, d.PatientID),
		Null
	From inserted i
	Full Join deleted d On i.PatientID=d.PatientID;
End;
Go


--Appointment and Diagnosis Table
DROP TRIGGER IF EXISTS app.trg_AppDiagAudit;
GO
 create or alter trigger trg_AppDiagAudit
 on app.AppointmentAndDiagnosis
 After insert, update, delete
 as
 begin
	Set NoCount On;

	Insert into audit.AuditLog_DML(ActionType, TableName, KeyValue, SqlCmd)
	Select
		Case
			When i.DiagID is not null and d.DiagID is not null then 'UPDATE'
			When i.DiagID is not null then 'INSERT'
			Else 'DELETE'
		End,
		'AppointmentAndDiagnosis',
		Coalesce(i.DiagID, d.DiagID),
		Null
	From inserted i
	Full Join deleted d On i.DiagID=d.DiagID;
End;
Go


/* =========================================================
	DDL TRIGGERS
   ========================================================= */
DROP TRIGGER IF EXISTS trg_DDLAudit ON DATABASE;
GO
Create or Alter Trigger trg_DDLAudit
On Database
For Create_Table, Alter_Table, Drop_Table,
	Create_Procedure, Alter_Procedure, Drop_Procedure
As
Begin
	Declare @cmd Nvarchar(MAX)=
	      EVENTDATA().value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]','NVARCHAR(MAX)');
	Insert into audit.AuditLog_DDL(SqlCmd) Values (@cmd);
END;
GO


/* =========================================================
	Logon TRIGGERS
   ========================================================= */
DROP TRIGGER IF EXISTS trg_LogOnAudit ON ALL SERVER;
GO
Create or Alter Trigger trg_LogOnAudit
On All Server
For Logon
As 
Begin
	Begin try
		Insert Into MedicalInfoSystem.audit.AuditLog_Logon(UserName, HostName, AppName)
		Select Original_Login(), HOST_NAME(), APP_NAME();
	End Try
	Begin Catch

	End Catch;
End;
Go


/* =========================================================
	DCL TRIGGERS
   ========================================================= */
DROP TRIGGER IF EXISTS trg_AuditDCL ON DATABASE;
GO
Create or Alter Trigger trg_AuditDCL
On Database
For Grant_Database, Revoke_Database, Deny_Database
As
Begin
	Set NoCount On;

	Insert into audit.AuditLogDCL(EventType,DatabaseName,ObjectName,LoginName,SqlCmd)
	Select
		EVENTDATA().value('(/EVENT_INSTANCE/EventType)[1]','NVARCHAR(100)'),
        EVENTDATA().value('(/EVENT_INSTANCE/DatabaseName)[1]','NVARCHAR(100)'),
        EVENTDATA().value('(/EVENT_INSTANCE/ObjectName)[1]','NVARCHAR(200)'),
        SUSER_SNAME(),
        EVENTDATA().value('(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]','NVARCHAR(MAX)');
End;
Go


/* =========================================================
	Temporal Table Auditing
   ========================================================= */
   -- Patient History
IF OBJECT_ID('audit.PatientHistory', 'U') IS NULL
BEGIN
    CREATE TABLE audit.PatientHistory
    (
        PatientID    NVARCHAR(10) NOT NULL,
        PatientName  NVARCHAR(100),
        Phone_Enc    VARBINARY(MAX),
        SysStartTime DATETIME2 NOT NULL,
        SysEndTime   DATETIME2 NOT NULL
    );
END;
GO

-- Staff History
IF OBJECT_ID('audit.StaffHistory', 'U') IS NULL
BEGIN
    CREATE TABLE audit.StaffHistory
    (
        StaffID      NVARCHAR(10) NOT NULL,
        StaffName    NVARCHAR(100),
        Position     NVARCHAR(50),
        OfficePhone  NVARCHAR(20),
        SysStartTime DATETIME2 NOT NULL,
        SysEndTime   DATETIME2 NOT NULL
    );
END;
GO

-- AppointmentAndDiagnosis History
IF OBJECT_ID('audit.AppointmentAndDiagnosisHistory', 'U') IS NULL
BEGIN
    CREATE TABLE audit.AppointmentAndDiagnosisHistory
    (
        DiagID       INT NOT NULL,
        AppDateTime  DATETIME2 NOT NULL,
        PatientID    NVARCHAR(10) NOT NULL,
        DoctorID     NVARCHAR(10) NOT NULL,
        DiagDetails_Enc VARBINARY(MAX) NULL,
        SysStartTime DATETIME2 NOT NULL,
        SysEndTime   DATETIME2 NOT NULL
    );
END;
GO

   -- Patient
If COL_LENGTH('app.Patient', 'SysStartTime') Is Null
Begin
	Alter Table app.Patient
	Add
		SysStartTime DateTime2 Generated Always As Row Start Hidden Not Null
			Constraint DF_Patient_SysStart Default SYSUTCDATETIME(),
		SysEndTime Datetime2 Generated Always as Row End Hidden Not Null
			Constraint Df_Patient_SysEnd Default Convert(Datetime2, '9999-12-31 23:59:59.9999999'),
		Period for System_time(SysStartTime, SysEndTime);
END;
GO

If Not Exists(
	Select 1 From sys.tables t
	Join sys.periods p on t.object_id = p.object_id
	Where t.name= 'Patient' and SCHEMA_NAME(t.schema_id) = 'app'
)
Begin 
	Alter Table app.Patient
	Set(System_Versioning = On(History_table = audit.PatientHistory));
End;
Go

--Staff
If COL_LENGTH('app.Staff', 'SysStartTime') Is Null
Begin
	ALTER TABLE app.Staff
	ADD
		SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
			CONSTRAINT DF_Staff_SysStart DEFAULT SYSUTCDATETIME(),
		SysEndTime   DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL
			CONSTRAINT DF_Staff_SysEnd DEFAULT CONVERT(DATETIME2, '9999-12-31 23:59:59.9999999'),
		PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime);
End;
Go

IF NOT EXISTS (
  SELECT 1 FROM sys.tables t
  JOIN sys.periods p ON t.object_id = p.object_id
  WHERE t.name = 'Staff' AND SCHEMA_NAME(t.schema_id) = 'app'
)
BEGIN
  ALTER TABLE app.Staff
  SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = audit.StaffHistory));
END;
GO

--Appointment and Diagnosis
If COL_LENGTH('app.AppointmentAndDiagnosis', 'SysStartTime') Is Null
Begin
	ALTER TABLE app.AppointmentAndDiagnosis
	ADD
		SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
			CONSTRAINT DF_AAD_SysStart DEFAULT SYSUTCDATETIME(),
		SysEndTime   DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL
			CONSTRAINT DF_AAD_SysEnd DEFAULT CONVERT(DATETIME2, '9999-12-31 23:59:59.9999999'),
		PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime);
End;
Go

IF NOT EXISTS (
  SELECT 1 FROM sys.tables t
  JOIN sys.periods p ON t.object_id = p.object_id
  WHERE t.name = 'AppointmentAndDiagnosis' AND SCHEMA_NAME(t.schema_id) = 'app'
)
BEGIN
  ALTER TABLE app.AppointmentAndDiagnosis
  SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = audit.AppointmentAndDiagnosisHistory));
END;
GO

Print 'Phase 7 and Temporal Complete';

GO

/* ========== PART 7 — Auditing Test.sql ========== */-- 
-- 
-- /* =========================================================
--    PHASE 7 � Auditing Test Script
--    ========================================================= */
-- USE MedicalInfoSystem;
-- GO
-- 
-- PRINT '--- TESTING AUDITING START ---';
-- 
-- /* =========================================================
--    1) TEST DML TRIGGERS
--    ========================================================= */
-- 
-- Insert into Staff
-- INSERT INTO app.Staff(StaffID, StaffName, Position, OfficePhone)
-- VALUES('T9001', 'Audit Tester', 'Nurse', '0123456789');
-- 
-- Update Staff
-- UPDATE app.Staff
-- SET OfficePhone = '0987654321'
-- WHERE StaffID = 'T9001';
-- 
-- Delete Staff
-- DELETE FROM app.Staff
-- WHERE StaffID = 'T9001';
-- 
-- Insert into Patient
-- INSERT INTO app.Patient(PatientID, PatientName, Phone_Enc)
-- VALUES('PT9001', 'Audit Patient', CONVERT(VARBINARY(MAX), '0111111111'));
-- 
-- Update Patient
-- UPDATE app.Patient
-- SET Phone_Enc = CONVERT(VARBINARY(MAX), '0222222222')
-- WHERE PatientID = 'PT9001';
-- 
-- Delete Patient
-- DELETE FROM app.Patient
-- WHERE PatientID = 'PT9001';
-- 
-- Insert into AppointmentAndDiagnosis
-- DECLARE @t DATETIME2 = DATEADD(MINUTE, 5, SYSUTCDATETIME());
-- INSERT INTO app.AppointmentAndDiagnosis(AppDateTime, PatientID, DoctorID)
-- VALUES(@t, 'P3001', 'D1001');
-- 
-- Update AppointmentAndDiagnosis
-- UPDATE app.AppointmentAndDiagnosis
-- SET AppDateTime = DATEADD(MINUTE, 10, AppDateTime)
-- WHERE PatientID = 'P3001' AND DoctorID = 'D1001'
--   AND AppDateTime = @t;
-- 
-- Delete AppointmentAndDiagnosis (only works if no diagnosis recorded)
-- DELETE FROM app.AppointmentAndDiagnosis
-- WHERE PatientID = 'P3001' AND DoctorID = 'D1001'
--   AND AppDateTime = DATEADD(MINUTE, 10, @t);
-- 
-- PRINT 'DML triggers tested � check audit.AuditLog_DML';
-- GO
-- 
-- 
-- /* =========================================================
--    2) TEST DDL TRIGGER
--    ========================================================= */
-- CREATE TABLE app.DummyAuditTest(
--     TestID INT PRIMARY KEY,
--     Note NVARCHAR(100)
-- );
-- DROP TABLE app.DummyAuditTest;
-- 
-- PRINT 'DDL trigger tested � check audit.AuditLog_DDL';
-- GO
-- 
-- 
-- /* =========================================================
--    3) TEST DCL TRIGGER
--    ========================================================= */
-- Grant and revoke a permission to test
-- GRANT SELECT ON OBJECT::app.Patient TO r_nurse;
-- REVOKE SELECT ON OBJECT::app.Patient TO r_nurse;
-- 
-- PRINT 'DCL trigger tested � check audit.AuditLog_DCL';
-- GO
-- 
-- 
-- /* =========================================================
--    4) TEST LOGON TRIGGER
--    ========================================================= */
-- Logon trigger fires when a new connection is made.
-- To test: 
-- 1) Disconnect from SQL Server in SSMS
-- 2) Reconnect using your login
-- 3) Then run:
-- SELECT TOP 5 * FROM audit.AuditLog_Logon ORDER BY LogID DESC;
-- 
-- PRINT 'Logon trigger tested � reconnect required to see effect';
-- GO
-- 
-- 
-- /* =========================================================
--    5) TEST TEMPORAL TABLES
--    ========================================================= */
-- PRINT '--- TESTING TEMPORAL TABLES START ---';
-- 
-- /* Patient Temporal Test */
-- INSERT INTO app.Patient(PatientID, PatientName, Phone_Enc)
-- VALUES('PT9101', 'Temporal Patient', CONVERT(VARBINARY(MAX), '0333333333'));
-- 
-- Update Patient (should create a row in audit.PatientHistory)
-- UPDATE app.Patient
-- SET PatientName = 'Temporal Patient Updated',
--     Phone_Enc = CONVERT(VARBINARY(MAX), '0444444444')
-- WHERE PatientID = 'PT9101';
-- 
-- Delete Patient (should create another row in history)
-- DELETE FROM app.Patient
-- WHERE PatientID = 'PT9101';
-- 
-- Check history
-- SELECT * FROM audit.PatientHistory WHERE PatientID = 'PT9101';
-- 
-- 
-- /* Staff Temporal Test */
-- INSERT INTO app.Staff(StaffID, StaffName, Position, OfficePhone)
-- VALUES('T9101', 'Temporal Staff', 'Nurse', '0120000000');
-- 
-- UPDATE app.Staff
-- SET OfficePhone = '0130000000'
-- WHERE StaffID = 'T9101';
-- 
-- DELETE FROM app.Staff
-- WHERE StaffID = 'T9101';
-- 
-- SELECT * FROM audit.StaffHistory WHERE StaffID = 'T9101';
-- 
-- 
-- /* AppointmentAndDiagnosis Temporal Test */
-- DECLARE @tt DATETIME2 = SYSUTCDATETIME();
-- INSERT INTO app.AppointmentAndDiagnosis(AppDateTime, PatientID, DoctorID)
-- VALUES(@tt, 'P3001', 'D1001');
-- 
-- UPDATE app.AppointmentAndDiagnosis
-- SET AppDateTime = DATEADD(HOUR, 1, AppDateTime)
-- WHERE PatientID = 'P3001' AND DoctorID = 'D1001' AND AppDateTime = @tt;
-- 
-- DELETE FROM app.AppointmentAndDiagnosis
-- WHERE PatientID = 'P3001' AND DoctorID = 'D1001'
--   AND AppDateTime = DATEADD(HOUR, 1, @tt);
-- 
-- SELECT * FROM audit.AppointmentAndDiagnosisHistory
-- WHERE PatientID = 'P3001' AND DoctorID = 'D1001';
-- 
-- PRINT '--- TESTING TEMPORAL TABLES END ---';
-- GO
-- 
-- SELECT TOP 10 * FROM audit.PatientHistory ORDER BY SysStartTime DESC;
-- SELECT TOP 10 * FROM audit.StaffHistory ORDER BY SysStartTime DESC;
-- SELECT TOP 10 * FROM audit.AppointmentAndDiagnosisHistory ORDER BY SysStartTime DESC;
-- 
-- GO
-- 
-- 
/* ========== PART 8 — Recovery and Backup Part .sql ========== */
/* ==========================================
   FILE: Part 7 � Backup & Recovery.sql
   DB:   MedicalInfoSystem
   PURPOSE:
     - MASTER/WEEKLY FULL, DAILY DIFF, HOURLY LOG backups (checksum + verify)
     - Integrity check (DBCC CHECKDB)
     - Backup CLE keys (Cert + Private Key) and DB Master Key (DMK)
     - msdb history quick report
     - Recovery templates (commented): PITR + restore test to scratch DB
   PRE-REQS:
     - Database exists; Recovery Model FULL
     - Part 4 (Encryption) already created CertForCLE & DMK (for key backups)
   RUNNING:
     - Execute the whole file or run sections individually in order
     - Restore sections are commented (DO NOT run on production)
   ========================================== */

USE [master];
GO

DECLARE @DB sysname              = N'MedicalInfoSystem';
DECLARE @BackupRoot nvarchar(260)= N'C:\Users\ameer\Desktop\SQLBackups';  -- <<< change to an existing folder
DECLARE @NowSuffix varchar(19)   = REPLACE(CONVERT(varchar(19), GETDATE(), 120), ':','-'); -- yyyy-mm-dd hh-mm-ss

-- Derived file paths
DECLARE @FullMasterPath nvarchar(400) = @BackupRoot + N'\FULL_Master_'  + @NowSuffix + N'.bak';
DECLARE @FullWeeklyPath nvarchar(400) = @BackupRoot + N'\FULL_Weekly_'  + @NowSuffix + N'.bak';
DECLARE @DiffDailyPath  nvarchar(400) = @BackupRoot + N'\DIFF_Daily_'   + @NowSuffix + N'.bak';
DECLARE @LogHourlyPath  nvarchar(400) = @BackupRoot + N'\LOG_Hourly_'   + @NowSuffix + N'.trn';
DECLARE @CertFile       nvarchar(400) = @BackupRoot + N'\CertForCLE_'   + @NowSuffix + N'.cer';
DECLARE @PvkFile        nvarchar(400) = @BackupRoot + N'\CertForCLE_'   + @NowSuffix + N'.pvk';
DECLARE @DMKFile        nvarchar(400) = @BackupRoot + N'\DMK_'          + @NowSuffix + N'.bak';

-- OPTIONAL: Enable if you want "ad-hoc" FULLs to not disturb DIFF base
DECLARE @UseCopyOnlyFull bit = 1;

/* ------------------------------------------
   1) HARDEN DEFAULTS (recovery model, page verify, compression)
   ------------------------------------------ */
PRINT '===> 1) Hardening defaults...';

-- 1.1 FULL recovery model (required for LOG backups / PITR)
IF (SELECT recovery_model_desc FROM sys.databases WHERE name=@DB) <> 'FULL'
BEGIN
  DECLARE @sql1 nvarchar(max) = N'ALTER DATABASE [' + @DB + N'] SET RECOVERY FULL;';
  EXEC(@sql1);
END

-- 1.2 PAGE_VERIFY CHECKSUM (detects page corruption)
DECLARE @sql2 nvarchar(max) = N'ALTER DATABASE [' + @DB + N'] SET PAGE_VERIFY CHECKSUM;';
EXEC(@sql2);

-- 1.3 Prefer backup compression by default (server-wide)
EXEC sp_configure 'show advanced options', 1; RECONFIGURE WITH OVERRIDE;
EXEC sp_configure 'backup compression default', 1; RECONFIGURE WITH OVERRIDE;

/* ------------------------------------------
   2) INTEGRITY CHECK (pre-backup)
   ------------------------------------------ */
PRINT '===> 2) Running DBCC CHECKDB (NO_INFOMSGS)...';
DECLARE @sqlCheck nvarchar(max) = N'DBCC CHECKDB([' + @DB + N']) WITH NO_INFOMSGS;';
EXEC(@sqlCheck);

/* ------------------------------------------
   3) MASTER / WEEKLY FULL BACKUP (+VERIFY)
      - MASTER FULL: run when setting up or before major changes
      - WEEKLY FULL: create a new base for DIFFs
   ------------------------------------------ */
PRINT '===> 3) FULL backup(s) + VERIFY...';

-- MASTER FULL (Copy-Only optional)
DECLARE @fullOpts nvarchar(max) =
  CASE WHEN @UseCopyOnlyFull=1 THEN N'WITH COPY_ONLY, INIT, COMPRESSION, CHECKSUM, STATS=5;'
       ELSE N'WITH INIT, COMPRESSION, CHECKSUM, STATS=5;' END;

DECLARE @sqlFullMaster nvarchar(max) =
N'BACKUP DATABASE [' + @DB + N']
   TO DISK = N''' + @FullMasterPath + N'''
   ' + @fullOpts;
EXEC(@sqlFullMaster);

DECLARE @sqlVerifyFullMaster nvarchar(max) =
N'RESTORE VERIFYONLY FROM DISK = N''' + @FullMasterPath + N''' WITH CHECKSUM;';
EXEC(@sqlVerifyFullMaster);

-- WEEKLY FULL (non-copy-only is typical for schedule)
DECLARE @sqlFullWeekly nvarchar(max) =
N'BACKUP DATABASE [' + @DB + N']
   TO DISK = N''' + @FullWeeklyPath + N'''
   WITH INIT, COMPRESSION, CHECKSUM, STATS=5;';
EXEC(@sqlFullWeekly);

DECLARE @sqlVerifyFullWeekly nvarchar(max) =
N'RESTORE VERIFYONLY FROM DISK = N''' + @FullWeeklyPath + N''' WITH CHECKSUM;';
EXEC(@sqlVerifyFullWeekly);

/* ------------------------------------------
   4) DAILY DIFFERENTIAL BACKUP (+VERIFY)
      - captures changes since the last non-copy-only FULL
   ------------------------------------------ */
PRINT '===> 4) DIFFERENTIAL (daily) + VERIFY...';

DECLARE @sqlDiff nvarchar(max) =
N'BACKUP DATABASE [' + @DB + N']
   TO DISK = N''' + @DiffDailyPath + N'''
   WITH DIFFERENTIAL, INIT, COMPRESSION, CHECKSUM, STATS=5;';
EXEC(@sqlDiff);

DECLARE @sqlVerifyDiff nvarchar(max) =
N'RESTORE VERIFYONLY FROM DISK = N''' + @DiffDailyPath + N''' WITH CHECKSUM;';
EXEC(@sqlVerifyDiff);

/* ------------------------------------------
   5) HOURLY LOG BACKUP (+VERIFY)
      - enables point-in-time restore; run frequently (e.g., hourly)
   ------------------------------------------ */
PRINT '===> 5) LOG (hourly) + VERIFY...';

DECLARE @sqlLog nvarchar(max) =
N'BACKUP LOG [' + @DB + N']
   TO DISK = N''' + @LogHourlyPath + N'''
   WITH INIT, COMPRESSION, CHECKSUM, STATS=5;';
EXEC(@sqlLog);

DECLARE @sqlVerifyLog nvarchar(max) =
N'RESTORE VERIFYONLY FROM DISK = N''' + @LogHourlyPath + N''' WITH CHECKSUM;';
EXEC(@sqlVerifyLog);

/* ------------------------------------------
   6) BACKUP CLE KEYS (CERT + PVK) and DMK
      - Needed to read encrypted data after restore to a new server
      - Store these files securely; DO NOT commit to source control
   ------------------------------------------ */
PRINT '===> 6) Backing up CLE keys and DMK...';

BEGIN TRY
  -- Certificate + Private Key (choose strong password)
  DECLARE @sqlCert nvarchar(max) = N'
    USE [' + @DB + N'];
    BACKUP CERTIFICATE CertForCLE
      TO FILE = N''' + @CertFile + N'''
      WITH PRIVATE KEY (
        FILE = N''' + @PvkFile + N''',
        ENCRYPTION BY PASSWORD = ''ChangeThis_PrivateKey#2025!''
      );';
  EXEC(@sqlCert);
END TRY
BEGIN CATCH
  PRINT 'Cert backup skipped or failed: ' + ERROR_MESSAGE();
END CATCH;

BEGIN TRY
  -- Database Master Key (DMK)
  DECLARE @sqlDMK nvarchar(max) = N'
    USE [' + @DB + N'];
    BACKUP MASTER KEY
      TO FILE = N''' + @DMKFile + N'''
      ENCRYPTION BY PASSWORD = ''ChangeThis_DMKbackup#2025!'';';
  EXEC(@sqlDMK);
END TRY
BEGIN CATCH
  PRINT 'DMK backup skipped or failed: ' + ERROR_MESSAGE();
END CATCH;

/* ------------------------------------------
   7) BACKUP HISTORY � quick health report
   ------------------------------------------ */
PRINT '===> 7) msdb backup history (last 20 for this DB)...';

SELECT TOP 20
   b.database_name,
   b.backup_start_date,
   b.backup_finish_date,
   CASE b.type WHEN 'D' THEN 'FULL'
               WHEN 'I' THEN 'DIFF'
               WHEN 'L' THEN 'LOG'
               ELSE b.type END AS backup_type,
   CAST(b.backup_size/1048576.0 AS decimal(18,2)) AS size_mb,
   mf.physical_device_name
FROM msdb.dbo.backupset b
JOIN msdb.dbo.backupmediafamily mf ON b.media_set_id = mf.media_set_id
WHERE b.database_name = @DB
ORDER BY b.backup_finish_date DESC;
GO

/* 
   8) RECOVERY TEMPLATES (COMMENTED) � DO NOT RUN ON PRODUCTION
      SCENARIOS:
        A) Point-In-Time Restore (PITR) to a NEW DB (Full -> Diff -> Logs)
        B) Quick restore test (FULL only) to prove backups are restorable
      HOW TO USE:
        - Identify correct FULL (weekly), latest DIFF, and a sequence of LOGs
        - Edit the file paths & logical names, then run on a non-prod server
                                                                             */

/* 
   A) POINT-IN-TIME RESTORE (PITR) � TEMPLATE
   PURPOSE: Recover to a time T by applying FULL -> DIFF -> LOGs (STOPAT)
                                                                           */
/*
DECLARE @RestoreDB sysname = N'MedicalInfoSystem_RestoreTest';
DECLARE @FullPath   nvarchar(400) = N'C:\SQLBackups\MedicalInfoSystem\FULL_Weekly_YYYYMMDD.bak'; -- pick from history
DECLARE @DiffPath   nvarchar(400) = N'C:\SQLBackups\MedicalInfoSystem\DIFF_Daily_YYYYMMDD.bak';  -- optional if exists after that full
DECLARE @LogFolder  nvarchar(400) = N'C:\SQLBackups\MedicalInfoSystem';                          -- where LOG_*.trn files live
DECLARE @StopAt     datetime      = DATEADD(MINUTE, -5, GETDATE());   -- e.g., 5 minutes ago

   1) Get logical file names from FULL (edit MOVE names below accordingly)
RESTORE FILELISTONLY
  FROM DISK = @FullPath;

   2) Restore FULL to new DB, NORECOVERY (stays non-operational, ready to roll forward)
RESTORE DATABASE [MedicalInfoSystem_RestoreTest]
  FROM DISK = @FullPath
  WITH NORECOVERY,
       MOVE N'MedicalInfoSystem'     TO N'C:\SQLBackups\MedicalInfoSystem\RestoreTest_data.mdf',
       MOVE N'MedicalInfoSystem_log' TO N'C:\SQLBackups\MedicalInfoSystem\RestoreTest_log.ldf',
       REPLACE, STATS=5;

   3) Restore DIFF (if available), NORECOVERY
RESTORE DATABASE [MedicalInfoSystem_RestoreTest]
  FROM DISK = @DiffPath
  WITH NORECOVERY, STATS=5;

   4) Apply LOG backups in order, with STOPAT on the last one
     Example for a single log file; repeat per log or build a loop:
RESTORE LOG [MedicalInfoSystem_RestoreTest]
  FROM DISK = N'C:\SQLBackups\MedicalInfoSystem\LOG_Hourly_YYYY-MM-DD hh-mm-ss.trn'
  WITH STOPAT = @StopAt, RECOVERY, STATS=5;
  If multiple logs, apply NORECOVERY on earlier ones and STOPAT on the final.

  5) If database uses CLE and you are restoring to a DIFFERENT server:
USE [MedicalInfoSystem_RestoreTest];
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'AnyStrongPass#ForRestore';
CREATE CERTIFICATE CertForCLE
FROM FILE = N'C:\SQLBackups\MedicalInfoSystem\CertForCLE_yyyy-mm-dd hh-mm-ss.cer'
WITH PRIVATE KEY (
  FILE = N'C:\SQLBackups\MedicalInfoSystem\CertForCLE_yyyy-mm-dd hh-mm-ss.pvk',
  DECRYPTION BY PASSWORD = 'ChangeThis_PrivateKey#2025!'
);
   Now Part 4/5 procs can OPEN SYMMETRIC KEY and decrypt data as normal.
*/

 /* 
    B) QUICK RESTORE TEST � FULL ONLY to scratch DB
    PURPOSE: Regularly prove that your FULL backups can be restored
                                                                    */
 /*
DECLARE @RestoreDB2 sysname = N'MedicalInfoSystem_RestoreCheck';
DECLARE @FullPath2  nvarchar(400) = N'C:\SQLBackups\MedicalInfoSystem\FULL_Weekly_YYYYMMDD.bak'; -- pick from history

   Get logical file names once (use from FILELISTONLY)
RESTORE FILELISTONLY FROM DISK = @FullPath2;

RESTORE DATABASE [MedicalInfoSystem_RestoreCheck]
  FROM DISK = @FullPath2
  WITH MOVE N'MedicalInfoSystem'     TO N'C:\SQLBackups\MedicalInfoSystem\RestoreCheck_data.mdf',
       MOVE N'MedicalInfoSystem_log' TO N'C:\SQLBackups\MedicalInfoSystem\RestoreCheck_log.ldf',
       REPLACE, RECOVERY, STATS=5;

 

 /* --
    BACKUP ENCRYPTION (for backup files themselves)
    NOTE: Requires a separate server certificate for backup encryption.
          Kept here as a pointer; not enabled by default.
    EXAMPLE:
    BACKUP DATABASE [MedicalInfoSystem]
      TO DISK = N'...\FULL_Encrypted.bak'
      WITH INIT, COMPRESSION, CHECKSUM,
           ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = BackupEncryptCert),
           STATS=5;
                                                                                      */

 /* 
    D) OPERATIONAL NOTES (not code)
    - Schedule these T-SQL sections via SQL Server Agent:
        * Weekly FULL (e.g., Sun 02:00)
        * Daily DIFF  (e.g., daily 01:00)
        * Hourly LOG  (every hour)
        * Weekly integrity check (DBCC CHECKDB on a non-peak window)
    - Copy backup files off-server (offsite/secondary storage).
    - Apply retention (e.g., keep 4 weeks of weekly sets).
    - Protect backup files with filesystem ACLs and/or backup encryption.
                                                                          */
																		        */

GO
