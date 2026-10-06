-- Read-only schema inventory; no principal, verifier or session rows.
IF DB_NAME() <> N'sfx-identity' THROW 51000, 'Identity database target mismatch.', 1;
SELECT DB_NAME() AS database_name, HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DEFINITION') AS has_view_definition,
 (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0) AS table_count,
 (SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0) AS procedure_count,
 (SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0) AS view_count,
 (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type IN ('FN','IF','TF')) AS function_count;
SELECT s.name AS schema_name, o.name AS object_name, o.type_desc
FROM sys.objects o JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0 AND o.type IN ('U','P','V','FN','IF','TF') ORDER BY s.name,o.name;
SELECT s.name AS schema_name,t.name AS table_name,c.column_id,c.name AS column_name,ty.name AS data_type,
 c.max_length,c.precision,c.scale,c.is_nullable,c.is_identity,c.is_computed,OBJECT_DEFINITION(c.default_object_id) AS default_definition
FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id JOIN sys.columns c ON c.object_id=t.object_id
JOIN sys.types ty ON ty.user_type_id=c.user_type_id WHERE t.is_ms_shipped=0 ORDER BY s.name,t.name,c.column_id;
SELECT s.name AS schema_name,t.name AS table_name,i.name AS index_name,i.is_primary_key,i.is_unique,
 ic.key_ordinal,c.name AS column_name
FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id JOIN sys.indexes i ON i.object_id=t.object_id
JOIN sys.index_columns ic ON ic.object_id=i.object_id AND ic.index_id=i.index_id JOIN sys.columns c ON c.object_id=ic.object_id AND c.column_id=ic.column_id
WHERE t.is_ms_shipped=0 AND ic.key_ordinal>0 ORDER BY s.name,t.name,i.name,ic.key_ordinal;
SELECT f.name AS fk_name,ps.name AS parent_schema,pt.name AS parent_table,pc.name AS parent_column,
 rs.name AS reference_schema,rt.name AS reference_table,rc.name AS reference_column,f.is_disabled,f.is_not_trusted
FROM sys.foreign_keys f JOIN sys.foreign_key_columns k ON k.constraint_object_id=f.object_id
JOIN sys.tables pt ON pt.object_id=k.parent_object_id JOIN sys.schemas ps ON ps.schema_id=pt.schema_id
JOIN sys.columns pc ON pc.object_id=pt.object_id AND pc.column_id=k.parent_column_id
JOIN sys.tables rt ON rt.object_id=k.referenced_object_id JOIN sys.schemas rs ON rs.schema_id=rt.schema_id
JOIN sys.columns rc ON rc.object_id=rt.object_id AND rc.column_id=k.referenced_column_id ORDER BY ps.name,pt.name,f.name,k.constraint_column_id;
SELECT s.name AS schema_name,p.name AS procedure_name,a.parameter_id,a.name AS parameter_name,ty.name AS data_type,
 a.max_length,a.precision,a.scale,a.is_output
FROM sys.procedures p JOIN sys.schemas s ON s.schema_id=p.schema_id LEFT JOIN sys.parameters a ON a.object_id=p.object_id
LEFT JOIN sys.types ty ON ty.user_type_id=a.user_type_id WHERE p.is_ms_shipped=0 ORDER BY s.name,p.name,a.parameter_id;
SELECT s.name AS schema_name,p.name AS procedure_name,
 CONVERT(varchar(64),HASHBYTES('SHA2_256',m.definition),2) AS definition_sha256,
 p.create_date,p.modify_date
FROM sys.procedures p JOIN sys.schemas s ON s.schema_id=p.schema_id JOIN sys.sql_modules m ON m.object_id=p.object_id
WHERE s.name IN(N'identity',N'evidence',N'ledger') ORDER BY s.name,p.name;
SELECT p.name AS role_name,dp.class_desc AS securable_class,dp.state_desc,dp.permission_name,
 CASE WHEN dp.class=3 THEN SCHEMA_NAME(dp.major_id) WHEN dp.class=1 THEN OBJECT_SCHEMA_NAME(dp.major_id) END AS schema_name,
 CASE WHEN dp.class=1 THEN OBJECT_NAME(dp.major_id) END AS object_name
FROM sys.database_permissions dp JOIN sys.database_principals p ON p.principal_id=dp.grantee_principal_id
WHERE p.name IN (N'sfx_identity_runtime',N'sfx_identity_enrollment',N'sfx_evidence_runtime',N'sfx_ledger_runtime') ORDER BY p.name,dp.class,dp.major_id,dp.permission_name;
SELECT (SELECT COUNT(*) FROM [identity].principal) AS principal_count,
 (SELECT COUNT(*) FROM [identity].password_credential) AS credential_count,
 (SELECT COUNT(*) FROM [identity].session) AS session_count;
