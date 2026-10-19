-- Flight plan and flight recording for a Frontier agent work session.
-- The plan is intended; the recording is an immutable snapshot; the response is
-- a claim; evidence.run/run_trace_chunk/run_completion remain the observed truth.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME()<>N'sfx-identity' THROW 51000,'IDENTITY_DATABASE_MISMATCH',1;
IF @@TRANCOUNT<>0 THROW 51000,'IDENTITY_MIGRATION_REQUIRES_NO_OUTER_TRANSACTION',1;
BEGIN TRANSACTION;
BEGIN TRY
IF OBJECT_ID(N'evidence.flight_plan',N'U') IS NULL
CREATE TABLE evidence.flight_plan(
 principal_id uniqueidentifier NOT NULL,
 agent_id nvarchar(255) COLLATE Latin1_General_100_BIN2 NOT NULL,
 plan_revision bigint NOT NULL CONSTRAINT DF_evidence_flight_plan_revision DEFAULT 1,
 objective nvarchar(2000) NOT NULL,
 steps_json nvarchar(max) NOT NULL,
 plan_digest binary(32) NOT NULL,
 updated_at datetimeoffset(7) NOT NULL CONSTRAINT DF_evidence_flight_plan_updated DEFAULT SYSUTCDATETIME(),
 CONSTRAINT PK_evidence_flight_plan PRIMARY KEY(principal_id,agent_id),
 CONSTRAINT FK_evidence_flight_plan_principal FOREIGN KEY(principal_id) REFERENCES [identity].principal(principal_id),
 CONSTRAINT CK_evidence_flight_plan_revision CHECK(plan_revision>0),
 CONSTRAINT CK_evidence_flight_plan_steps CHECK(ISJSON(steps_json)=1));
IF OBJECT_ID(N'evidence.flight_recording',N'U') IS NULL
CREATE TABLE evidence.flight_recording(
 flight_recording_id uniqueidentifier NOT NULL,
 principal_id uniqueidentifier NOT NULL,
 agent_id nvarchar(255) COLLATE Latin1_General_100_BIN2 NOT NULL,
 plan_revision bigint NOT NULL,
 objective_snapshot nvarchar(2000) NOT NULL,
 steps_snapshot nvarchar(max) NOT NULL,
 plan_digest binary(32) NOT NULL,
 started_at datetimeoffset(7) NOT NULL,
 completed_at datetimeoffset(7) NULL,
 frontier_response nvarchar(max) NULL,
 response_recorded_at datetimeoffset(7) NULL,
 CONSTRAINT PK_evidence_flight_recording PRIMARY KEY(flight_recording_id),
 CONSTRAINT UQ_evidence_flight_recording_principal UNIQUE(flight_recording_id,principal_id),
 CONSTRAINT FK_evidence_flight_recording_principal FOREIGN KEY(principal_id) REFERENCES [identity].principal(principal_id),
 CONSTRAINT FK_evidence_flight_recording_plan FOREIGN KEY(principal_id,agent_id) REFERENCES evidence.flight_plan(principal_id,agent_id),
 CONSTRAINT CK_evidence_flight_recording_revision CHECK(plan_revision>0),
 CONSTRAINT CK_evidence_flight_recording_steps CHECK(ISJSON(steps_snapshot)=1));
IF COL_LENGTH(N'evidence.run',N'flight_recording_id') IS NULL
 ALTER TABLE evidence.run ADD flight_recording_id uniqueidentifier NULL;
IF COL_LENGTH(N'evidence.run',N'flight_recording_id') IS NULL THROW 51000,'FLIGHT_RECORDING_RUN_COLUMN_MISSING',1;
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'evidence.run') AND name=N'UX_evidence_run_principal')
 CREATE UNIQUE INDEX UX_evidence_run_principal ON evidence.run(run_id,principal_id);
IF NOT EXISTS(SELECT 1 FROM sys.foreign_keys WHERE name=N'FK_evidence_run_flight_recording')
 ALTER TABLE evidence.run ADD CONSTRAINT FK_evidence_run_flight_recording FOREIGN KEY(flight_recording_id,principal_id)
  REFERENCES evidence.flight_recording(flight_recording_id,principal_id);EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[upsert_flight_plan]
 @principal_id uniqueidentifier,@agent_id nvarchar(255),@objective nvarchar(2000),@steps_json nvarchar(max)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY
 IF @principal_id IS NULL OR NOT EXISTS(SELECT 1 FROM [identity].principal WHERE principal_id=@principal_id AND active=1)
  THROW 51000,''FLIGHT_PLAN_PRINCIPAL_REQUIRED'',1;
 IF @agent_id IS NULL OR LEN(LTRIM(RTRIM(@agent_id))) NOT BETWEEN 1 AND 255
  THROW 51000,''FLIGHT_PLAN_AGENT_REQUIRED'',1;
 IF @objective IS NULL OR LEN(@objective) NOT BETWEEN 1 AND 2000
  THROW 51000,''FLIGHT_PLAN_OBJECTIVE_REQUIRED'',1;
 IF @steps_json IS NULL OR ISJSON(@steps_json)<>1 OR LEFT(LTRIM(@steps_json),1)<>''[''
  THROW 51000,''FLIGHT_PLAN_STEPS_INVALID'',1;
 DECLARE @digest binary(32)=HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),CONVERT(varchar(max),CONCAT(@objective,NCHAR(0),@steps_json) COLLATE Latin1_General_100_BIN2_UTF8)));
 DECLARE @revision bigint,@existing binary(32);
 SELECT @revision=plan_revision,@existing=plan_digest FROM evidence.flight_plan WITH(UPDLOCK,HOLDLOCK)
  WHERE principal_id=@principal_id AND agent_id=@agent_id COLLATE Latin1_General_100_BIN2;
 IF @revision IS NULL
 BEGIN
  SET @revision=1;
  INSERT evidence.flight_plan(principal_id,agent_id,plan_revision,objective,steps_json,plan_digest,updated_at)
   VALUES(@principal_id,@agent_id,@revision,@objective,@steps_json,@digest,SYSUTCDATETIME());
 END
 ELSE IF @existing<>@digest
 BEGIN
  SET @revision=@revision+1;
  UPDATE evidence.flight_plan SET plan_revision=@revision,objective=@objective,steps_json=@steps_json,plan_digest=@digest,updated_at=SYSUTCDATETIME()
   WHERE principal_id=@principal_id AND agent_id=@agent_id COLLATE Latin1_General_100_BIN2;
 END
 SELECT plan_revision,plan_digest,updated_at FROM evidence.flight_plan
  WHERE principal_id=@principal_id AND agent_id=@agent_id COLLATE Latin1_General_100_BIN2;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[begin_flight_recording]
 @principal_id uniqueidentifier,@agent_id nvarchar(255),@flight_recording_id uniqueidentifier=NULL
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY
 IF @principal_id IS NULL OR NOT EXISTS(SELECT 1 FROM [identity].principal WHERE principal_id=@principal_id AND active=1)
  THROW 51000,''FLIGHT_RECORDING_PRINCIPAL_REQUIRED'',1;
 IF @agent_id IS NULL OR LEN(LTRIM(RTRIM(@agent_id))) NOT BETWEEN 1 AND 255
  THROW 51000,''FLIGHT_RECORDING_AGENT_REQUIRED'',1;
 IF @flight_recording_id IS NULL SET @flight_recording_id=NEWID();
 IF EXISTS(SELECT 1 FROM evidence.flight_recording WITH(UPDLOCK,HOLDLOCK) WHERE flight_recording_id=@flight_recording_id)
 BEGIN
  IF NOT EXISTS(SELECT 1 FROM evidence.flight_recording WHERE flight_recording_id=@flight_recording_id
    AND principal_id=@principal_id AND agent_id=@agent_id COLLATE Latin1_General_100_BIN2)
   THROW 51000,''FLIGHT_RECORDING_CONFLICT'',1;
  SELECT flight_recording_id,plan_revision,plan_digest,started_at,completed_at,frontier_response
   FROM evidence.flight_recording WHERE flight_recording_id=@flight_recording_id;
  IF @owns_transaction=1 COMMIT TRANSACTION;
  RETURN;
 END
 DECLARE @revision bigint,@objective nvarchar(2000),@steps nvarchar(max),@digest binary(32);
 SELECT TOP (1) @revision=plan_revision,@objective=objective,@steps=steps_json,@digest=plan_digest
  FROM evidence.flight_plan WHERE principal_id=@principal_id AND agent_id=@agent_id COLLATE Latin1_General_100_BIN2;
 IF @revision IS NULL THROW 51000,''FLIGHT_PLAN_NOT_FOUND'',1;
 INSERT evidence.flight_recording(flight_recording_id,principal_id,agent_id,plan_revision,objective_snapshot,steps_snapshot,plan_digest,started_at)
  VALUES(@flight_recording_id,@principal_id,@agent_id,@revision,@objective,@steps,@digest,SYSUTCDATETIME());
 SELECT flight_recording_id,plan_revision,plan_digest,started_at,completed_at,frontier_response
  FROM evidence.flight_recording WHERE flight_recording_id=@flight_recording_id;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[attach_run_to_recording]
 @principal_id uniqueidentifier,@run_id varchar(128),@flight_recording_id uniqueidentifier
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY
 IF @principal_id IS NULL OR @run_id IS NULL OR @flight_recording_id IS NULL
  THROW 51000,''FLIGHT_RECORDING_ATTACH_INPUT_REQUIRED'',1;
 IF NOT EXISTS(SELECT 1 FROM evidence.run WITH(UPDLOCK,HOLDLOCK) WHERE run_id=@run_id AND principal_id=@principal_id)
  THROW 51000,''FLIGHT_RECORDING_RUN_NOT_FOUND'',1;
 IF NOT EXISTS(SELECT 1 FROM evidence.flight_recording WHERE flight_recording_id=@flight_recording_id AND principal_id=@principal_id)
  THROW 51000,''FLIGHT_RECORDING_NOT_FOUND'',1;
 DECLARE @existing uniqueidentifier=(SELECT flight_recording_id FROM evidence.run WHERE run_id=@run_id AND principal_id=@principal_id);
 IF @existing IS NOT NULL AND @existing<>@flight_recording_id THROW 51000,''FLIGHT_RECORDING_RUN_CONFLICT'',1;
 IF @existing IS NULL UPDATE evidence.run SET flight_recording_id=@flight_recording_id WHERE run_id=@run_id AND principal_id=@principal_id;
 SELECT run_id,flight_recording_id FROM evidence.run WHERE run_id=@run_id AND principal_id=@principal_id;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[complete_flight_recording]
 @principal_id uniqueidentifier,@flight_recording_id uniqueidentifier,@frontier_response nvarchar(max)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY
 IF @principal_id IS NULL OR @flight_recording_id IS NULL OR @frontier_response IS NULL
  THROW 51000,''FLIGHT_RECORDING_COMPLETION_INPUT_REQUIRED'',1;
 IF NOT EXISTS(SELECT 1 FROM evidence.flight_recording WITH(UPDLOCK,HOLDLOCK) WHERE flight_recording_id=@flight_recording_id AND principal_id=@principal_id)
  THROW 51000,''FLIGHT_RECORDING_NOT_FOUND'',1;
 DECLARE @existing nvarchar(max)=(SELECT frontier_response FROM evidence.flight_recording WHERE flight_recording_id=@flight_recording_id);
 IF @existing IS NOT NULL AND @existing<>@frontier_response THROW 51000,''FLIGHT_RECORDING_RESPONSE_CONFLICT'',1;
 IF @existing IS NULL UPDATE evidence.flight_recording SET completed_at=SYSUTCDATETIME(),frontier_response=@frontier_response,response_recorded_at=SYSUTCDATETIME()
  WHERE flight_recording_id=@flight_recording_id AND principal_id=@principal_id;
 SELECT flight_recording_id,completed_at,frontier_response,response_recorded_at FROM evidence.flight_recording
  WHERE flight_recording_id=@flight_recording_id AND principal_id=@principal_id;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
EXEC(N'CREATE OR ALTER PROCEDURE [evidence].[read_flight_recording]
 @principal_id uniqueidentifier,@flight_recording_id uniqueidentifier
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY
 SELECT (SELECT r.flight_recording_id,r.principal_id,r.agent_id,r.plan_revision,r.objective_snapshot,r.steps_snapshot,r.plan_digest,r.started_at,r.completed_at,r.frontier_response,r.response_recorded_at,
   JSON_QUERY((SELECT x.run_id,x.session_id,x.capability_id,x.namespace_id,x.writer_id,x.admitted_at,x.flight_recording_id,
     JSON_QUERY(c.run_json) AS run_json,JSON_QUERY(c.graph_json) AS graph_json,JSON_QUERY(c.graphs_json) AS graphs_json,JSON_QUERY(c.output_json) AS output_json,
     c.latest_cursor,c.trace_complete,c.completed_at AS completed_at
    FROM evidence.run x LEFT JOIN evidence.run_completion c ON c.run_id=x.run_id
    WHERE x.flight_recording_id=r.flight_recording_id ORDER BY x.admitted_at,x.run_id FOR JSON PATH)) AS runs
  FROM evidence.flight_recording r WHERE r.flight_recording_id=@flight_recording_id AND r.principal_id=@principal_id
  FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) AS value;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
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
 ELSE INSERT evidence.run(run_id,principal_id,session_id,capability_id,namespace_id,writer_id,admitted_at)
  VALUES(@run_id,@principal_id,@session_id,@capability_id,@namespace_id,@writer_id,SYSUTCDATETIME());
 SELECT run_id,admitted_at FROM evidence.run WHERE run_id=@run_id;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
IF DATABASE_PRINCIPAL_ID(N'sfx_evidence_runtime') IS NULL CREATE ROLE sfx_evidence_runtime AUTHORIZATION dbo;
GRANT EXECUTE ON OBJECT::evidence.upsert_flight_plan TO sfx_evidence_runtime;
GRANT EXECUTE ON OBJECT::evidence.begin_flight_recording TO sfx_evidence_runtime;
GRANT EXECUTE ON OBJECT::evidence.attach_run_to_recording TO sfx_evidence_runtime;
GRANT EXECUTE ON OBJECT::evidence.complete_flight_recording TO sfx_evidence_runtime;
GRANT EXECUTE ON OBJECT::evidence.read_flight_recording TO sfx_evidence_runtime;
IF (SELECT COUNT(*) FROM sys.tables WHERE schema_id=SCHEMA_ID(N'evidence') AND name IN (N'flight_plan',N'flight_recording'))<>2 THROW 51000,'FLIGHT_RECORDING_TABLES_MISSING',1;
SELECT N'006-flight-recording' AS migration,CONVERT(int,2) AS added_tables,CONVERT(int,5) AS added_procedures;
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH