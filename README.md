# Medical Information System (SQL Server)
A secure, role-based, encrypted, auditable, and fully recoverable medical database system implemented in Microsoft SQL Server.

This project demonstrates practical implementation of:
Schema-level security isolation
Role-Based Access Control (RBAC)
Column-level encryption (AES-256)
Secure stored procedure APIs
DML / DDL / DCL / Logon auditing
Temporal system-versioned tables
Full, Differential, and Log backup strategy
Restore validation and key recovery

The objective is not just data storage — but secure, compliant, operational database design.

## Problem Context
APU Hospital (Bukit Jalil, Kuala Lumpur) operates a medical database system to manage:
Staff (Doctors, Nurses)
Patients
Appointments
Diagnosis records

The original system was functionally complete but lacked a structured security architecture.

## A security review was commissioned to:
Identify potential weaknesses
Strengthen access control
Protect sensitive medical data
Ensure traceability and recoverability
Preserve usability for all authenticated users

All users connect via SQL Server Management Studio (SSMS) and are expected to execute SQL queries relevant to their roles.

## The database must continuously satisfy:
Confidentiality
Integrity
Availability
Functionality
Usability
Security Objectives

The implemented solution addresses the following mandatory requirements of the project:

## General Objectives

Enforce strong confidentiality, integrity, and availability controls.
Ensure Superadmin can perform all required DDL and DML operations
Prevent unauthorized exposure or deletion of sensitive data.
Guarantee full traceability and recoverability of all data changes.
Allow all users to log in and perform their designated tasks.
Track all user activities, including attempted actions.

## Staff Table Objectives

Enforce two staff roles: Doctor and Nurse.
Staff can view their own full details in plaintext.
Staff can update their own details.
All authenticated users can view staff name and office phone only.

## Patient Table Objectives

Patients can view their own full details in plaintext.
Patients can update their own details.
Doctors and nurses can view all patient names and phone numbers.
Only nurses can update patient name and phone.

## Appointment & Diagnosis Objectives

Only nurses can add or cancel appointments.
Nurses may modify appointments only if diagnosis has not been added.
Doctors may add diagnosis only after appointment exists.
Patients can view all of their own diagnosis records.
Doctors can view all diagnosis records.
Doctors may update only diagnosis they created.
Nurses must not view diagnosis details.

## Implementation Scope

This project delivers complete and tested solutions covering:
Role-based access control (RBAC)
Schema isolation (app vs api)
Controlled API-layer execution
Column-level encryption (AES-256)
Secure diagnosis workflows
DML / DDL / DCL / Logon auditing
Temporal table versioning
Full, Differential, and Log backup strategy
Restore validation and encryption key backup

## Architecture
### Schema Isolation

Two schemas are used:

- `app` → Internal data tables  
- `api` → Controlled access layer (views and stored procedures)

Direct access to base tables in `app` is denied to non-admin roles.  
All operations occur through controlled objects in `api`.


### Role-Based Access Control (RBAC)
Roles implemented:

- `r_doctor`
- `r_nurse`
- `r_patient`
- `superadmin` (`db_owner`)

Security model:
- `DENY` on `app` schema
- `GRANT SELECT, EXECUTE` on `api` schema

This enforces least privilege and prevents raw table access.

## Appointment & Diagnosis Logic
Business rules enforced via stored procedures (`EXECUTE AS OWNER`):

- Only nurses can add, reschedule, or cancel appointments.
- Doctors can add diagnosis only after an appointment exists.
- Doctors can update only their own diagnosis records.
- Patients can view only their own diagnosis records.
- Nurses cannot view diagnosis details.


## Column-Level Encryption
Sensitive fields are encrypted at rest using:

- Database Master Key (DMK)
- Certificate
- AES-256 Symmetric Key

Encrypted columns include:

- Patient phone and address  
- Staff personal details  
- Diagnosis notes  

Data is stored as `VARBINARY(MAX)` and decrypted only within authorized procedures.



## Auditing & Traceability
The system tracks:

- DML operations (INSERT / UPDATE / DELETE)
- DDL changes (CREATE / ALTER / DROP)
- DCL actions (GRANT / REVOKE / DENY)
- Logon events
- Historical row versions (Temporal Tables)

All activities are traceable and recoverable.


## Temporal Tables
System-versioned temporal tables are enabled for:

- Patient
- Staff
- AppointmentAndDiagnosis

Historical versions are automatically preserved using:

- `SysStartTime`
- `SysEndTime`


## Backup & Recovery Strategy

- FULL recovery model
- Full, Differential, and Transaction Log backups
- `DBCC CHECKDB` integrity validation
- `RESTORE VERIFYONLY` backup verification
- Restore test database (`MedicalInfoSystem_RestoreCheck`)
- Encryption key backup (Certificate + DMK)

This ensures availability and business continuity.

## Security Model Summary

The implementation achieves:

- **Confidentiality** → Encryption + RBAC  
- **Integrity** → Constraints + Auditing + CHECKDB  
- **Availability** → Backup + Restore validation  
- **Accountability** → Audit logs + Temporal history  

The SQL script is idempotent and includes:

- Database setup  
- Security configuration  
- Encryption  
- Diagnosis APIs  
- Auditing  
- Backup templates  

## Conclusion
This project implements a secure, encrypted, auditable, and recoverable medical database

