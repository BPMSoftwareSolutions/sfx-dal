-- Durable run material only. Claims await exact identities and estate-declared rules.
-- No inputs, credentials, inferred outcomes or trust dispositions are written.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME()<>N'sfx-identity' THROW 51000,'IDENTITY_DATABASE_MISMATCH',1;
IF @@TRANCOUNT<>0 THROW 51000,'IDENTITY_MIGRATION_REQUIRES_NO_OUTER_TRANSACTION',1;
BEGIN TRANSACTION;
BEGIN TRY

IF SCHEMA_ID(N'evidence') IS NULL EXEC(N'CREATE SCHEMA [evidence] AUTHORIZATION dbo;');
IF OBJECT_ID(N'evidence.run',N'U') IS NULL
CREATE TABLE evidence.run(
 run_id varchar(128) NOT NULL CONSTRAINT PK_evidence_run PRIMARY KEY,
 principal_id uniqueidentifier NOT NULL REFERENCES [identity].principal(principal_id),
 session_id uniqueidentifier NOT NULL REFERENCES [identity].session(session_id),
 capability_id nvarchar(512) NOT NULL, namespace_id nvarchar(256) NOT NULL,
 writer_id varchar(64) NOT NULL, admitted_at datetimeoffset(7) NOT NULL,
 CONSTRAINT CK_evidence_run_identity CHECK(LEN(run_id)>0 AND LEN(capability_id)>0 AND LEN(writer_id)>0));
IF OBJECT_ID(N'evidence.run_trace_chunk',N'U') IS NULL
CREATE TABLE evidence.run_trace_chunk(
 run_id varchar(128) NOT NULL REFERENCES evidence.run(run_id),
 first_cursor bigint NOT NULL, last_cursor bigint NOT NULL, record_count int NOT NULL,
 content_digest binary(32) NOT NULL, content varbinary(max) NOT NULL, received_at datetimeoffset(7) NOT NULL,
 CONSTRAINT PK_evidence_trace PRIMARY KEY(run_id,first_cursor),
 CONSTRAINT CK_evidence_trace_range CHECK(first_cursor>0 AND last_cursor>=first_cursor AND record_count=last_cursor-first_cursor+1),
 CONSTRAINT CK_evidence_trace_size CHECK(DATALENGTH(content) BETWEEN 1 AND 1048576));
IF OBJECT_ID(N'evidence.run_completion',N'U') IS NULL
CREATE TABLE evidence.run_completion(
 run_id varchar(128) NOT NULL CONSTRAINT PK_evidence_completion PRIMARY KEY REFERENCES evidence.run(run_id),
 run_json nvarchar(max) NOT NULL CHECK(ISJSON(run_json)=1),
 graph_json nvarchar(max) NULL CHECK(graph_json IS NULL OR ISJSON(graph_json)=1),
 output_json nvarchar(max) NULL CHECK(output_json IS NULL OR ISJSON(output_json)=1),
 latest_cursor bigint NOT NULL CHECK(latest_cursor>=0),
 trace_complete bit NOT NULL,
 material_digest binary(32) NOT NULL,
 completed_at datetimeoffset(7) NOT NULL);
IF OBJECT_ID(N'evidence.run_capture_issue',N'U') IS NULL
CREATE TABLE evidence.run_capture_issue(
 issue_id bigint IDENTITY NOT NULL CONSTRAINT PK_evidence_issue PRIMARY KEY,
 run_id varchar(128) NOT NULL REFERENCES evidence.run(run_id), code varchar(64) NOT NULL,
 first_cursor bigint NULL,last_cursor bigint NULL, recorded_at datetimeoffset(7) NOT NULL);
IF OBJECT_ID(N'evidence.access_audit',N'U') IS NULL
CREATE TABLE evidence.access_audit(
 audit_id bigint IDENTITY NOT NULL CONSTRAINT PK_evidence_audit PRIMARY KEY,
 principal_id uniqueidentifier NOT NULL REFERENCES [identity].principal(principal_id),
 run_id varchar(128) NOT NULL REFERENCES evidence.run(run_id),
 read_at datetimeoffset(7) NOT NULL);
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[register_run]
 @run_id varchar(128), @principal_id uniqueidentifier, @session_id uniqueidentifier,
 @capability_id nvarchar(512), @namespace_id nvarchar(256), @writer_id varchar(64)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY
 
 IF NOT EXISTS(SELECT 1 FROM [identity].session s JOIN [identity].principal p ON p.principal_id=s.principal_id
  WHERE s.session_id=@session_id AND s.principal_id=@principal_id AND s.revoked_at IS NULL AND s.expires_at>SYSUTCDATETIME() AND p.active=1)
  THROW 51000,''EVIDENCE_SESSION_REQUIRED'',1;
 IF @run_id IS NULL OR LEN(@run_id)=0 OR @capability_id IS NULL OR LEN(@capability_id)=0 OR @namespace_id IS NULL OR @writer_id IS NULL OR LEN(@writer_id)=0
  THROW 51000,''EVIDENCE_INPUT_INVALID'',1;
 IF EXISTS(SELECT 1 FROM evidence.run WITH(UPDLOCK,HOLDLOCK) WHERE run_id=@run_id)
 BEGIN
  IF NOT EXISTS(SELECT 1 FROM evidence.run WHERE run_id=@run_id AND principal_id=@principal_id AND capability_id=@capability_id AND namespace_id=@namespace_id AND writer_id=@writer_id)
   THROW 51000,''EVIDENCE_CONFLICT'',1;
 END
 ELSE INSERT evidence.run VALUES(@run_id,@principal_id,@session_id,@capability_id,@namespace_id,@writer_id,SYSUTCDATETIME());
 SELECT run_id,admitted_at FROM evidence.run WHERE run_id=@run_id;

 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[append_trace_chunk]
 @run_id varchar(128), @writer_id varchar(64), @first_cursor bigint, @last_cursor bigint,
 @record_count int, @content_digest varbinary(32), @content varbinary(max)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 IF NOT EXISTS(SELECT 1 FROM evidence.run WITH(UPDLOCK,HOLDLOCK) WHERE run_id=@run_id AND writer_id=@writer_id)
  THROW 51000,''EVIDENCE_RUN_NOT_FOUND'',1;
 IF @content IS NULL OR DATALENGTH(@content) NOT BETWEEN 1 AND 1048576 OR DATALENGTH(@content_digest)<>32 OR @content_digest IS NULL
 OR HASHBYTES(''SHA2_256'',@content)<>@content_digest OR @first_cursor IS NULL OR @first_cursor<1 OR @last_cursor IS NULL OR @last_cursor<@first_cursor
 OR @record_count IS NULL OR @record_count<>@last_cursor-@first_cursor+1
  THROW 51000,''EVIDENCE_CHUNK_INVALID'',1;
 IF EXISTS(SELECT 1 FROM evidence.run_trace_chunk WHERE run_id=@run_id AND first_cursor=@first_cursor)
 BEGIN
  IF NOT EXISTS(SELECT 1 FROM evidence.run_trace_chunk WHERE run_id=@run_id AND first_cursor=@first_cursor AND last_cursor=@last_cursor
   AND record_count=@record_count AND content_digest=@content_digest AND content=@content)
   THROW 51000,''EVIDENCE_CONFLICT'',1;
 END
 ELSE
 BEGIN
  IF EXISTS(SELECT 1 FROM evidence.run_completion WHERE run_id=@run_id) THROW 51000,''EVIDENCE_RUN_CLOSED'',1;
  IF EXISTS(SELECT 1 FROM evidence.run_trace_chunk WHERE run_id=@run_id AND first_cursor<=@last_cursor AND last_cursor>=@first_cursor)
   THROW 51000,''EVIDENCE_CHUNK_OVERLAP'',1;
  INSERT evidence.run_trace_chunk VALUES(@run_id,@first_cursor,@last_cursor,@record_count,@content_digest,@content,SYSUTCDATETIME());
 END
 SELECT CONVERT(bit,1) AS stored;

 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[complete_run]
 @run_id varchar(128), @writer_id varchar(64), @run_json nvarchar(max), @graph_json nvarchar(max),
 @output_json nvarchar(max), @latest_cursor bigint
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 IF NOT EXISTS(SELECT 1 FROM evidence.run WITH(UPDLOCK,HOLDLOCK) WHERE run_id=@run_id AND writer_id=@writer_id)
  THROW 51000,''EVIDENCE_RUN_NOT_FOUND'',1;
 IF ISJSON(@run_json)<>1 OR @run_json IS NULL OR JSON_VALUE(@run_json,''$.runId'')<>@run_id OR JSON_VALUE(@run_json,''$.runId'') IS NULL
 OR JSON_VALUE(@run_json,''$.state'') NOT IN (''completed'',''failed'',''cancelled'',''timed-out'',''timed_out'') OR JSON_VALUE(@run_json,''$.state'') IS NULL
 OR (@graph_json IS NOT NULL AND ISJSON(@graph_json)<>1) OR (@output_json IS NOT NULL AND ISJSON(@output_json)<>1)
 OR @latest_cursor IS NULL OR @latest_cursor<0
  THROW 51000,''EVIDENCE_COMPLETION_INVALID'',1;
 DECLARE @digest binary(32)=HASHBYTES(''SHA2_256'',CONCAT(LEN(@run_json),'':'',@run_json,'':'',COALESCE(LEN(@graph_json),-1),'':'',@graph_json,'':'',COALESCE(LEN(@output_json),-1),'':'',@output_json,'':'',@latest_cursor));
 DECLARE @count bigint=(SELECT COALESCE(SUM(CONVERT(bigint,record_count)),0) FROM evidence.run_trace_chunk WHERE run_id=@run_id);
 DECLARE @complete bit=CASE WHEN @count=@latest_cursor AND @latest_cursor>0
  AND (SELECT MIN(first_cursor) FROM evidence.run_trace_chunk WHERE run_id=@run_id)=1
  AND (SELECT MAX(last_cursor) FROM evidence.run_trace_chunk WHERE run_id=@run_id)=@latest_cursor
  AND COALESCE(JSON_VALUE(@run_json,''$.partial''),''false'')=''false'' THEN 1 ELSE 0 END;
 IF EXISTS(SELECT 1 FROM evidence.run_completion WHERE run_id=@run_id)
 BEGIN
  IF NOT EXISTS(SELECT 1 FROM evidence.run_completion WHERE run_id=@run_id AND material_digest=@digest)
   THROW 51000,''EVIDENCE_CONFLICT'',1;
 END
 ELSE
 BEGIN
  INSERT evidence.run_completion VALUES(@run_id,@run_json,@graph_json,@output_json,@latest_cursor,@complete,@digest,SYSUTCDATETIME());
  IF @complete=0 INSERT evidence.run_capture_issue VALUES(@run_id,''TRACE_INCOMPLETE'',NULL,@latest_cursor,SYSUTCDATETIME());
 END
 SELECT trace_complete,material_digest FROM evidence.run_completion WHERE run_id=@run_id;

 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[list_runs]
 @principal_id uniqueidentifier
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 SELECT r.run_id,r.capability_id,r.namespace_id,r.admitted_at,r.session_id,
  CASE WHEN c.run_id IS NULL THEN ''capturing'' WHEN c.trace_complete=1 THEN ''complete'' ELSE ''incomplete'' END AS capture_status
 FROM evidence.run r LEFT JOIN evidence.run_completion c ON c.run_id=r.run_id
 WHERE r.principal_id=@principal_id ORDER BY r.admitted_at DESC,r.run_id;

 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[read_run]
 @principal_id uniqueidentifier, @run_id varchar(128)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 INSERT evidence.access_audit(principal_id,run_id,read_at)
 SELECT @principal_id,run_id,SYSUTCDATETIME() FROM evidence.run WHERE run_id=@run_id AND principal_id=@principal_id;
 SELECT r.run_id,r.capability_id,r.namespace_id,r.admitted_at,r.session_id,c.run_json,c.graph_json,c.output_json,
  c.latest_cursor,c.trace_complete,c.material_digest,
  CASE WHEN c.run_id IS NULL THEN ''capturing'' WHEN c.trace_complete=1 THEN ''complete'' ELSE ''incomplete'' END AS capture_status
 FROM evidence.run r LEFT JOIN evidence.run_completion c ON c.run_id=r.run_id WHERE r.run_id=@run_id AND r.principal_id=@principal_id;

 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[read_trace_chunks]
 @principal_id uniqueidentifier, @run_id varchar(128), @after_cursor bigint
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 SELECT c.first_cursor,c.last_cursor,c.record_count,c.content_digest,c.content
 FROM evidence.run_trace_chunk c JOIN evidence.run r ON r.run_id=c.run_id
 WHERE r.run_id=@run_id AND r.principal_id=@principal_id AND c.last_cursor>@after_cursor ORDER BY c.first_cursor;

 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
IF DATABASE_PRINCIPAL_ID(N'sfx_evidence_runtime') IS NULL CREATE ROLE sfx_evidence_runtime AUTHORIZATION dbo;
DENY SELECT,INSERT,UPDATE,DELETE ON SCHEMA::evidence TO sfx_evidence_runtime;
GRANT EXECUTE ON OBJECT::evidence.register_run TO sfx_evidence_runtime;
GRANT EXECUTE ON OBJECT::evidence.append_trace_chunk TO sfx_evidence_runtime;
GRANT EXECUTE ON OBJECT::evidence.complete_run TO sfx_evidence_runtime;
GRANT EXECUTE ON OBJECT::evidence.list_runs TO sfx_evidence_runtime;
GRANT EXECUTE ON OBJECT::evidence.read_run TO sfx_evidence_runtime;
GRANT EXECUTE ON OBJECT::evidence.read_trace_chunks TO sfx_evidence_runtime;
IF (SELECT COUNT(*) FROM sys.tables WHERE schema_id=SCHEMA_ID(N'evidence'))<>5 THROW 51000,'EVIDENCE_TABLE_COUNT',1;
SELECT N'002-run-evidence' AS migration,CONVERT(int,5) AS table_count,CONVERT(int,6) AS procedure_count;
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH
