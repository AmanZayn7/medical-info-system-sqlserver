"""Integration checks against the disposable SQL Server container used by CI."""
import os
import subprocess
import time
from pathlib import Path

CONTAINER = os.environ['SQLSERVER_CONTAINER']
SA_PASSWORD = os.environ['SQLSERVER_SA_PASSWORD']
ROOT = Path(__file__).resolve().parents[1]
TOOL = '/opt/mssql-tools18/bin/sqlcmd'
PASSED = 0


def query(text, user='sa', password=None, expected_error=None):
    global PASSED
    command = ['docker', 'exec', '-i', '-e', 'SQLCMDPASSWORD='+ (password or SA_PASSWORD), CONTAINER,
               TOOL, '-S', 'localhost', '-U', user, '-C', '-b', '-V', '11', '-r', '1', '-d', 'MedicalInfoSystem']
    result = subprocess.run(command, input=text, text=True, capture_output=True)
    output = result.stdout + result.stderr
    if expected_error is None:
        assert result.returncode == 0, output
    else:
        assert result.returncode != 0 and str(expected_error) in output, output
    PASSED += 1
    print(f'PASS {PASSED}: user={user}, expected_error={expected_error}', flush=True)
    return output


for attempt in range(90):
    result = subprocess.run(['docker','exec','-e','SQLCMDPASSWORD='+SA_PASSWORD,CONTAINER,TOOL,
                             '-S','localhost','-U','sa','-C','-Q','SELECT 1','-b'],capture_output=True)
    if result.returncode == 0:
        break
    time.sleep(2)
else:
    raise RuntimeError('SQL Server did not become ready')
setup=(ROOT/'sql/MedicalInfoSystem.sql').read_text()
# Initial install connects to master because the target does not exist yet.
result=subprocess.run(['docker','exec','-i','-e','SQLCMDPASSWORD='+SA_PASSWORD,CONTAINER,TOOL,
                       '-S','localhost','-U','sa','-C','-b','-r','1'],input=setup,text=True,capture_output=True)
assert result.returncode == 0, result.stdout+result.stderr
print('PASS: initial install',flush=True)
query(setup)
print('PASS: second install',flush=True)
query("IF (SELECT COUNT(*) FROM sys.tables WHERE schema_id=SCHEMA_ID('app') AND temporal_type=2)<>3 THROW 55001,'Three temporal tables required',1;")
query("IF EXISTS(SELECT 1 FROM app.AppointmentAndDiagnosis) THROW 55002,'Install must not create demo appointments',1;")
query("SELECT * FROM app.Patient",'P3001','Patient1#2025!',229)
query("EXEC api.usp_Patient_Self_Update @PatientID='P3001',@PhonePlain='0123456789',@AddressPlain=N'Audit address';",'P3001','Patient1#2025!')
query("EXEC api.usp_Patient_Self_Select @PatientID='P3002';",'P3001','Patient1#2025!',54001)
query("EXEC api.usp_Patient_Self_Update @PatientID='P3002',@PhonePlain='bad';",'P3001','Patient1#2025!',54001)
query("EXEC api.usp_Staff_Self_Select @StaffID='N2001';",'D1001','Doctor#2025!',54001)
query("EXEC api.usp_Staff_Self_Update @StaffID='N2001',@PhonePlain='bad';",'D1001','Doctor#2025!',54001)
query("EXEC api.usp_Patient_Directory;",'D1001','Doctor#2025!')
query("EXEC api.usp_Patient_Directory;",'P3001','Patient1#2025!',229)
query("EXEC api.usp_App_Add @PatientID='P3001',@DoctorID='D1001',@AppDateTime='2030-01-01';",'P3001','Patient1#2025!',229)
query("EXEC api.usp_App_Add @PatientID='P3001',@DoctorID='D1001',@AppDateTime='2030-01-01';",'N2001','Nurse#2025!')
query("DECLARE @id INT=(SELECT DiagID FROM app.AppointmentAndDiagnosis WHERE AppDateTime='2030-01-01'); IF @id<>1 THROW 55003,'Expected first appointment',1;")
query("EXEC api.usp_Diag_Select_All_ForDoctors;",'N2001','Nurse#2025!',229)
query("EXEC api.usp_Diag_Select_All_ForDoctors;",'P3001','Patient1#2025!',229)
query("EXEC api.usp_Diag_Add_ByDoctor @DiagID=1,@DoctorID='D1001',@DiagDetails=N'Audit diagnosis';",'D1001','Doctor#2025!')
query("EXEC api.usp_Diag_Select_PatientSelf @PatientID='P3002';",'P3001','Patient1#2025!',54001)
query("EXEC api.usp_Diag_Select_PatientSelf @PatientID='P3001';",'P3001','Patient1#2025!')
query("EXEC api.usp_App_Reschedule @DiagID=1,@NewAppDateTime='2030-01-02';",'N2001','Nurse#2025!',54002)
query("EXEC api.usp_App_Cancel @DiagID=1;",'N2001','Nurse#2025!',54002)
query("EXEC api.usp_Diag_Add_ByDoctor @DiagID=1,@DoctorID='D1001',@DiagDetails=N'overwrite';",'D1001','Doctor#2025!',54005)
query("EXEC api.usp_Diag_Update_BySameDoctor @DiagID=1,@DoctorID='D1001',@NewDetails=N'Updated audit diagnosis';",'D1001','Doctor#2025!')
query("DECLARE @long NVARCHAR(MAX)=REPLICATE(CAST(N'x' AS NVARCHAR(MAX)),3501); EXEC api.usp_Diag_Update_BySameDoctor @DiagID=1,@DoctorID='D1001',@NewDetails=@long;",'D1001','Doctor#2025!',54003)
query("IF NOT EXISTS(SELECT 1 FROM audit.PatientHistory WHERE PatientID='P3001') THROW 55004,'Missing patient history',1; IF NOT EXISTS(SELECT 1 FROM audit.AppointmentAndDiagnosisHistory WHERE DiagID=1) THROW 55005,'Missing diagnosis history',1; IF NOT EXISTS(SELECT 1 FROM audit.AuditLog_DML WHERE UserName='D1001') THROW 55006,'Missing original doctor identity',1;")
query("OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE; IF (SELECT CONVERT(NVARCHAR(MAX),DECRYPTBYKEY(DiagDetails_Enc)) FROM app.AppointmentAndDiagnosis WHERE DiagID=1)<>N'Updated audit diagnosis' THROW 55007,'Decryption mismatch',1; CLOSE SYMMETRIC KEY SimKey1;")
query("CREATE LOGIN D1002 WITH PASSWORD='Doctor2#2025!',CHECK_POLICY=OFF; CREATE USER doctor_two FOR LOGIN D1002; ALTER ROLE r_doctor ADD MEMBER doctor_two; INSERT app.Staff(StaffID,StaffName,Position) VALUES('D1002','Second audit doctor','Doctor');")
query("EXEC api.usp_Diag_Update_BySameDoctor @DiagID=1,@DoctorID='D1001',@NewDetails=N'bad';",'D1002','Doctor2#2025!',54001)
query("EXEC api.usp_Diag_Update_BySameDoctor @DiagID=1,@DoctorID='D1002',@NewDetails=N'bad';",'D1002','Doctor2#2025!',53101)
query("EXEC api.usp_App_Add @PatientID='P3002',@DoctorID='D1001',@AppDateTime='2030-02-01';",'N2001','Nurse#2025!')
query("EXEC api.usp_App_Reschedule @DiagID=2,@NewAppDateTime='2030-02-02'; EXEC api.usp_App_Cancel @DiagID=2;",'N2001','Nurse#2025!')
query("EXEC api.usp_Staff_Self_Update @StaffID='D1001',@PhonePlain='0312345678',@AddressPlain=N'Audit staff address';",'D1001','Doctor#2025!')
query("IF NOT EXISTS(SELECT 1 FROM audit.StaffHistory WHERE StaffID='D1001') THROW 55008,'Missing staff history',1; IF NOT EXISTS(SELECT 1 FROM audit.AuditLog_Logon WHERE UserName='P3001') THROW 55009,'Missing patient logon audit',1;")
# Exercise full/differential/log and key backups in the disposable server only.
query("EXEC sys.sp_set_session_context @key=N'run_backup_demo',@value=1;\nGO\n"+setup[setup.index('/* ========== PART 8'):])
query("USE master; DECLARE @path NVARCHAR(4000)=(SELECT TOP 1 mf.physical_device_name FROM msdb.dbo.backupset b JOIN msdb.dbo.backupmediafamily mf ON b.media_set_id=mf.media_set_id WHERE b.database_name='MedicalInfoSystem' AND b.type='D' AND b.is_copy_only=0 ORDER BY b.backup_finish_date DESC); RESTORE DATABASE MedicalInfoSystem_AuditRestore FROM DISK=@path WITH MOVE 'MedicalInfoSystem' TO '/var/opt/mssql/data/audit_restore.mdf',MOVE 'MedicalInfoSystem_log' TO '/var/opt/mssql/data/audit_restore.ldf';")
query("USE MedicalInfoSystem_AuditRestore; OPEN MASTER KEY DECRYPTION BY PASSWORD='Strong#DMK#2025!'; OPEN SYMMETRIC KEY SimKey1 DECRYPTION BY CERTIFICATE CertForCLE; IF NOT EXISTS(SELECT 1 FROM app.AppointmentAndDiagnosis WHERE DiagID=1 AND CONVERT(NVARCHAR(MAX),DECRYPTBYKEY(DiagDetails_Enc))=N'Updated audit diagnosis') THROW 55010,'Restored diagnosis decryption mismatch',1; CLOSE SYMMETRIC KEY SimKey1; CLOSE MASTER KEY; DBCC CHECKDB WITH NO_INFOMSGS;")
print(f'PASS: {PASSED} integration queries plus initial installation',flush=True)
