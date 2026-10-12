-- Retain the complete per-root graph collection alongside the parent projection.
-- Existing completions and callers without graphs keep their original digest.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME()<>N'sfx-identity' THROW 51000,'IDENTITY_DATABASE_MISMATCH',1;
IF @@TRANCOUNT<>0 THROW 51000,'IDENTITY_MIGRATION_REQUIRES_NO_OUTER_TRANSACTION',1;
BEGIN TRANSACTION;
BEGIN TRY
IF COL_LENGTH(N'evidence.run_completion',N'graphs_json') IS NULL
 ALTER TABLE evidence.run_completion ADD graphs_json nvarchar(max) NULL
  CONSTRAINT CK_evidence_completion_graphs CHECK(graphs_json IS NULL OR ISJSON(graphs_json)=1);
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[complete_run]
 @run_id varchar(128), @writer_id varchar(64), @run_json nvarchar(max), @graph_json nvarchar(max),
 @output_json nvarchar(max), @latest_cursor bigint, @graphs_json nvarchar(max)=NULL
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
 OR (@graphs_json IS NOT NULL AND ISJSON(@graphs_json)<>1)
 OR @latest_cursor IS NULL OR @latest_cursor<0
  THROW 51000,''EVIDENCE_COMPLETION_INVALID'',1;
 DECLARE @digest binary(32)=HASHBYTES(''SHA2_256'',CONCAT(LEN(@run_json),'':'',@run_json,'':'',COALESCE(LEN(@graph_json),-1),'':'',@graph_json,'':'',COALESCE(LEN(@output_json),-1),'':'',@output_json,'':'',@latest_cursor,
  CASE WHEN @graphs_json IS NULL THEN N'''' ELSE CONCAT('':'',LEN(@graphs_json),'':'',@graphs_json) END));
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
  INSERT evidence.run_completion(run_id,run_json,graph_json,output_json,latest_cursor,trace_complete,material_digest,completed_at,graphs_json)
  VALUES(@run_id,@run_json,@graph_json,@output_json,@latest_cursor,@complete,@digest,SYSUTCDATETIME(),@graphs_json);
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
  c.latest_cursor,c.trace_complete,c.material_digest,c.graphs_json,
  CASE WHEN c.run_id IS NULL THEN ''capturing'' WHEN c.trace_complete=1 THEN ''complete'' ELSE ''incomplete'' END AS capture_status
 FROM evidence.run r LEFT JOIN evidence.run_completion c ON c.run_id=r.run_id WHERE r.run_id=@run_id AND r.principal_id=@principal_id;

 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND @@TRANCOUNT>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
SELECT N'005-per-root-run-graphs' AS migration,CONVERT(int,1) AS added_column,CONVERT(int,2) AS procedure_count;
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH
