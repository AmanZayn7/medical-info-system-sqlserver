# Medical Information System — SQL Server

A SQL Server coursework project demonstrating role-based access, encrypted patient and diagnosis fields, controlled stored procedures, audit triggers, temporal history, and backup/restore operations using synthetic records.

[SQL implementation](sql/MedicalInfoSystem.sql) · [Automated SQL Server checks](.github/workflows/verify.yml) · [Original coursework report](Database%20Security%20Report.pdf)

## What the system does

Doctors, nurses, and patients access a medical database through an `api` schema. Base tables live in `app`; audit logs and temporal history live in `audit`. Application roles are denied direct access to `app` and receive permissions on specific API objects, rather than every procedure in the schema.

| Role | Permitted operations |
| --- | --- |
| Patient | Read and update their own contact details; read their own diagnosis records; read the staff name/office-phone directory. |
| Doctor | Read and update their own personal details; read the patient name/phone directory and diagnoses; add or update diagnoses for appointments assigned to them. |
| Nurse | Read and update their own personal details; read/update patient name and phone; create appointments and reschedule or cancel appointments that have no diagnosis. |
| Demonstration administrator | Database administration and privileged API access. |

Self-service and doctor identity checks use the original SQL login. Demonstration patient and staff logins match their record IDs; specifying somebody else's ID does not grant access to that record. A doctor cannot overwrite an existing diagnosis through the add procedure.

## Encryption and history

Patient phone/address, staff personal details, and diagnosis notes use a certificate and AES-256 symmetric key. Authorized procedures open the key, encrypt or decrypt the required fields, and close it. Diagnosis text is limited to 7,000 bytes before encryption.

System-versioned temporal history is enabled for `Patient`, `Staff`, and `AppointmentAndDiagnosis`. DML triggers record inserts, updates and deletes; additional triggers record selected table/procedure DDL, database permission events and successful logons. Original login identity is retained when procedures execute as their owner.

Column encryption does not encrypt every database field or backup file. These triggers do not capture every activity, SELECT, rejected request or failed authentication, and do not constitute a tamper-proof security audit.

## Run the demonstration

1. Use a disposable SQL Server instance. The automated checks use SQL Server 2022 Developer on Linux.
2. Open [MedicalInfoSystem.sql](sql/MedicalInfoSystem.sql) in SSMS as an administrator with permission to create databases, logins and server triggers. Execute the full script in order. Alternatively, use `sqlcmd` with batch support.
3. Connect separately as the demonstration doctor, nurse or patient to exercise the permitted procedures. Identity checks refer to the original login; administrator-side `EXECUTE AS USER` does not simulate a separate authenticated login.
4. Optional example operations remain commented out. The setup seeds one doctor, one nurse and two patients, but does not create demo appointments.

The script includes public demonstration passwords and disables password-policy checks for its sample logins. Use synthetic data on an isolated instance. The logon trigger is server-scoped and depends on this database; remove or disable it before removing the demonstration database. This is an educational implementation, not a production deployment or compliance certification.

Fresh installation and a second execution are tested. Automatic migration from arbitrary older schemas, including incompatible manually created history tables, is not covered.

## Backup and recovery

The backup section is skipped unless `run_backup_demo` is enabled in the current session. To opt in, run this before the script, using the same connection:

```sql
EXEC sys.sp_set_session_context @key=N'run_backup_demo', @value=1;
GO
```

It uses the instance's default backup directory, sets the demonstration database to FULL recovery with page checksums, performs full/differential/log backups with verification, and exports the encryption certificate/private key and database master key. File access occurs on the database server. The section does not create an automatic backup schedule; weekly/daily/hourly labels describe intended scheduling roles.

Backup exports use public demonstration passwords. Keep generated database/key files out of Git and replace the example credentials for any adaptation. Point-in-time and cross-server recovery instructions remain templates; they are not certified by this project's tests.

## Automated verification

The [GitHub Actions workflow](.github/workflows/verify.yml) starts a disposable SQL Server 2022 container and runs [the integration checks](tests/check_sqlserver.py). It checks:

- Initial installation and repeat installation.
- Direct-table denial, per-role procedure permissions and cross-user access rejection.
- Diagnosis ownership, input size and protection of diagnosed appointments.
- Encryption/decryption, temporal history and original audit identity.
- Full, differential and log backup verification, key exports, and a full restore to a separate test database.

The workflow also verifies successful-logon auditing and that the restored diagnosis decrypts correctly. These tests cover specific demonstrated behavior, not every possible attack, concurrent workload or recovery scenario. Current results are available in the repository's Actions tab.

## Original report

The PDF is the original coursework submission and has been retained as a historical artifact. The maintained SQL and this README include subsequent integrity fixes and testing; the PDF should not be treated as evidence that all current controls or production-security claims have been independently certified.
