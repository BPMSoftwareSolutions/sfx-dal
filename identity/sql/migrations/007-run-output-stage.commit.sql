-- Staged run output for run admission through the declared API (sfx-api admit-api-run).
-- A fan-out join carries a leg outcome only up to the kernel bound (16 KB), so the leg that
-- runs the admitted capability stages the output here under its SHA-256 digest and settles
-- only the digest; the join completes the run from the staged output. Staging an existing
-- digest refreshes it, and staging removes rows older than one hour, so a completion never
-- loses a row it was handed. evidence.run_completion remains the observed truth.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME()<>N'sfx-identity' THROW 51000,'IDENTITY_DATABASE_MISMATCH',1;
IF @@TRANCOUNT<>0 THROW 51000,'IDENTITY_MIGRATION_REQUIRES_NO_OUTER_TRANSACTION',1;
BEGIN TRANSACTION;
BEGIN TRY
IF OBJECT_ID(N'evidence.run_output_stage',N'U') IS NULL
CREATE TABLE evidence.run_output_stage(
 content_digest binary(32) NOT NULL,
 content nvarchar(max) NOT NULL,
 staged_at datetimeoffset(7) NOT NULL CONSTRAINT DF_evidence_run_output_stage_staged DEFAULT SYSUTCDATETIME(),
 CONSTRAINT PK_evidence_run_output_stage PRIMARY KEY(content_digest),
 CONSTRAINT CK_evidence_run_output_stage_content CHECK(ISJSON(content)=1));
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[stage_run_output]
 @input nvarchar(max)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY
 DECLARE @content nvarchar(max)=JSON_QUERY(@input,''$.output'');
 IF @content IS NULL THROW 51000,''EVIDENCE_OUTPUT_INVALID'',1;
 DECLARE @digest binary(32)=HASHBYTES(''SHA2_256'',@content);
 DELETE evidence.run_output_stage WHERE staged_at<DATEADD(hour,-1,SYSUTCDATETIME()) AND content_digest<>@digest;
 IF EXISTS(SELECT 1 FROM evidence.run_output_stage WITH(UPDLOCK,HOLDLOCK) WHERE content_digest=@digest)
  UPDATE evidence.run_output_stage SET staged_at=SYSUTCDATETIME() WHERE content_digest=@digest;
 ELSE INSERT evidence.run_output_stage(content_digest,content) VALUES(@digest,@content);
 SELECT (SELECT LOWER(CONVERT(varchar(64),@digest,2)) AS outputDigest,LEN(@content) AS outputLength FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) AS value;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[complete_staged_run]
 @input nvarchar(max)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY
 DECLARE @run_id varchar(128)=JSON_VALUE(@input,''$.runId'');
 DECLARE @writer_id varchar(64)=JSON_VALUE(@input,''$.writerId'');
 DECLARE @run_json nvarchar(max)=JSON_QUERY(@input,''$.run'');
 DECLARE @digest binary(32)=TRY_CONVERT(binary(32),JSON_VALUE(@input,''$.outputDigest''),2);
 DECLARE @output_json nvarchar(max)=(SELECT content FROM evidence.run_output_stage WHERE content_digest=@digest);
 IF @digest IS NOT NULL AND @output_json IS NULL THROW 51000,''EVIDENCE_STAGED_OUTPUT_NOT_FOUND'',1;
 DECLARE @latest_cursor bigint=COALESCE(TRY_CONVERT(bigint,JSON_VALUE(@input,''$.latestCursor'')),0);
 DECLARE @r TABLE(trace_complete bit,material_digest binary(32));
 INSERT @r EXEC evidence.complete_run @run_id=@run_id,@writer_id=@writer_id,@run_json=@run_json,@graph_json=NULL,@output_json=@output_json,@latest_cursor=@latest_cursor;
 SELECT (SELECT N''COMPLETED'' AS status,@run_id AS runId,JSON_VALUE(@run_json,''$.state'') AS state,JSON_VALUE(@input,''$.admittedAt'') AS admittedAt,r.trace_complete AS traceComplete FROM @r r FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) AS value;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
IF DATABASE_PRINCIPAL_ID(N'sfx_evidence_runtime') IS NULL CREATE ROLE sfx_evidence_runtime AUTHORIZATION dbo;
GRANT EXECUTE ON OBJECT::evidence.stage_run_output TO sfx_evidence_runtime;
GRANT EXECUTE ON OBJECT::evidence.complete_staged_run TO sfx_evidence_runtime;
IF OBJECT_ID(N'evidence.run_output_stage',N'U') IS NULL THROW 51000,'RUN_OUTPUT_STAGE_TABLE_MISSING',1;
IF (SELECT COUNT(*) FROM sys.procedures WHERE schema_id=SCHEMA_ID(N'evidence') AND name IN (N'stage_run_output',N'complete_staged_run'))<>2 THROW 51000,'RUN_OUTPUT_STAGE_PROCEDURES_MISSING',1;
SELECT (SELECT N'007-run-output-stage' AS migration,CONVERT(int,1) AS added_tables,CONVERT(int,2) AS added_procedures FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) AS value;
COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH
