/* Conversation management v1. Run in sfx-identity. User-directed installation.
   Re-runnable, additive. Does not delete existing history or provision credentials.
   Principal authorization is supplied by the existing authenticated capability boundary.
   All body digests in this package hash SQL nvarchar UTF-16LE bytes; they are NOT artifact-store digests.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;
IF DB_NAME() <> N'sfx-identity' THROW 51000, 'CM_WRONG_DATABASE_EXPECTED_SFX_IDENTITY', 1;
IF OBJECT_ID(N'[identity].principal',N'U') IS NULL THROW 51000,'CM_PRINCIPAL_TABLE_REQUIRED',1;
IF @@TRANCOUNT <> 0 THROW 51000,'CM_INSTALL_REQUIRES_OWN_TRANSACTION',1;

BEGIN TRANSACTION;
BEGIN TRY
 IF SCHEMA_ID(N'conversation') IS NULL EXEC(N'CREATE SCHEMA conversation AUTHORIZATION dbo');

 IF OBJECT_ID(N'[identity].inference_model',N'U') IS NULL
 CREATE TABLE [identity].inference_model(
   model_id nvarchar(255) COLLATE Latin1_General_100_BIN2 NOT NULL PRIMARY KEY,
   provider_id nvarchar(255) NOT NULL,
   declared_version nvarchar(255) NULL,
   definition_json nvarchar(max) NOT NULL CHECK(ISJSON(definition_json)=1),
   definition_digest binary(32) NOT NULL,
   registered_at datetimeoffset(7) NOT NULL DEFAULT SYSDATETIMEOFFSET());

 IF OBJECT_ID(N'[identity].inference_role',N'U') IS NULL
 CREATE TABLE [identity].inference_role(
   role_id nvarchar(128) COLLATE Latin1_General_100_BIN2 NOT NULL PRIMARY KEY,
   description nvarchar(1000) NOT NULL);
 INSERT [identity].inference_role(role_id,description)
 SELECT r.id,r.description FROM (VALUES
   (N'coordinator',N'Own objective-level coordination and delegation.'),
   (N'evidence-selector',N'Select relevant evidence with provenance and coverage.'),
   (N'author',N'Propose canonical feature or capability authority.'),
   (N'reviewer',N'Provide review testimony against declared criteria.'),
   (N'executor',N'Reason within an assigned workflow execution responsibility.')) r(id,description)
 WHERE NOT EXISTS(SELECT 1 FROM [identity].inference_role x WHERE x.role_id=r.id);

 IF OBJECT_ID(N'[identity].workflow_model_binding',N'U') IS NULL
 CREATE TABLE [identity].workflow_model_binding(
   binding_id uniqueidentifier NOT NULL PRIMARY KEY,
   workflow_id nvarchar(400) NOT NULL,
   workflow_revision nvarchar(128) NOT NULL,
   scenario_id nvarchar(400) NOT NULL,
   operation_id nvarchar(400) NOT NULL,
   role_id nvarchar(128) COLLATE Latin1_General_100_BIN2 NOT NULL REFERENCES [identity].inference_role(role_id),
   model_id nvarchar(255) COLLATE Latin1_General_100_BIN2 NOT NULL REFERENCES [identity].inference_model(model_id),
   binding_json nvarchar(max) NOT NULL CHECK(ISJSON(binding_json)=1),
   binding_digest binary(32) NOT NULL,
   registered_at datetimeoffset(7) NOT NULL DEFAULT SYSDATETIMEOFFSET());

 IF OBJECT_ID(N'conversation.conversation',N'U') IS NULL
 CREATE TABLE conversation.conversation(
   conversation_id uniqueidentifier NOT NULL PRIMARY KEY,
   principal_id uniqueidentifier NOT NULL REFERENCES [identity].principal(principal_id),
   objective nvarchar(max) NOT NULL,
   source_refs_json nvarchar(max) NOT NULL CHECK(ISJSON(source_refs_json)=1),
   state varchar(16) NOT NULL CHECK(state IN ('OPEN','WAITING','COMPLETED','CANCELLED')),
   revision bigint NOT NULL CHECK(revision>0),
   completion_json nvarchar(max) NULL CHECK(completion_json IS NULL OR ISJSON(completion_json)=1),
   created_at datetimeoffset(7) NOT NULL,
   updated_at datetimeoffset(7) NOT NULL);

 IF OBJECT_ID(N'conversation.thread',N'U') IS NULL
 CREATE TABLE conversation.thread(
   thread_id uniqueidentifier NOT NULL PRIMARY KEY,
   conversation_id uniqueidentifier NOT NULL REFERENCES conversation.conversation(conversation_id),
   parent_thread_id uniqueidentifier NULL,
   responsibility nvarchar(max) NOT NULL,
   agent_id nvarchar(255) NULL,
   binding_id uniqueidentifier NULL REFERENCES [identity].workflow_model_binding(binding_id),
   inherited_context_json nvarchar(max) NOT NULL CHECK(ISJSON(inherited_context_json)=1),
   checkpoint_json nvarchar(max) NOT NULL CHECK(ISJSON(checkpoint_json)=1),
   covered_through_sequence bigint NOT NULL DEFAULT 0,
   next_sequence bigint NOT NULL DEFAULT 1,
   state varchar(16) NOT NULL CHECK(state IN ('OPEN','WAITING','COMPLETED','CANCELLED')),
   revision bigint NOT NULL CHECK(revision>0),
   created_at datetimeoffset(7) NOT NULL,
   updated_at datetimeoffset(7) NOT NULL,
   CONSTRAINT uq_cm_thread_conversation UNIQUE(conversation_id,thread_id),
   CONSTRAINT fk_cm_thread_parent FOREIGN KEY(conversation_id,parent_thread_id)
     REFERENCES conversation.thread(conversation_id,thread_id),
   CONSTRAINT ck_cm_thread_parent CHECK(parent_thread_id IS NULL OR parent_thread_id<>thread_id));

 IF OBJECT_ID(N'conversation.turn',N'U') IS NULL
 CREATE TABLE conversation.turn(
   turn_id uniqueidentifier NOT NULL PRIMARY KEY,
   thread_id uniqueidentifier NOT NULL REFERENCES conversation.thread(thread_id),
   sequence_number bigint NOT NULL,
   request_digest binary(32) NOT NULL,
   message nvarchar(max) NOT NULL,
   context_json nvarchar(max) NOT NULL CHECK(ISJSON(context_json)=1),
   ov3_request_json nvarchar(max) NOT NULL CHECK(ISJSON(ov3_request_json)=1),
   response_json nvarchar(max) NULL CHECK(response_json IS NULL OR ISJSON(response_json)=1),
   response_digest binary(32) NULL,
   inference_evidence_json nvarchar(max) NULL CHECK(inference_evidence_json IS NULL OR ISJSON(inference_evidence_json)=1),
   state varchar(24) NOT NULL CHECK(state IN ('PREPARED','RETURNED','RECONCILIATION_REQUIRED')),
   created_at datetimeoffset(7) NOT NULL,
   completed_at datetimeoffset(7) NULL,
   CONSTRAINT uq_cm_turn_sequence UNIQUE(thread_id,sequence_number));

 IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'conversation.conversation') AND name=N'ix_cm_owner_updated')
   CREATE INDEX ix_cm_owner_updated ON conversation.conversation(principal_id,updated_at DESC);
 IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'conversation.thread') AND name=N'ix_cm_threads')
   CREATE INDEX ix_cm_threads ON conversation.thread(conversation_id,parent_thread_id);

 -- Reruns preserve the original installation timestamp and all conversation history.
 IF OBJECT_ID(N'conversation.installation',N'U') IS NULL
 CREATE TABLE conversation.installation(
   package_id varchar(64) NOT NULL PRIMARY KEY,
   installed_at datetimeoffset(7) NOT NULL,
   description nvarchar(1000) NOT NULL);
 IF NOT EXISTS(SELECT 1 FROM conversation.installation WHERE package_id='conversation-management.v1')
 INSERT conversation.installation VALUES('conversation-management.v1',SYSDATETIMEOFFSET(),N'User-executed SQL package; identity and conversation persistence.');

/* Operator-only registration. No API secrets belong in definition_json or binding_json.
   Immutable IDs: use a new model identity for a distinct declared version, and a new binding ID for changes.
   A vendor alias may be recorded, but must not be presented as an observed immutable vendor version. */

 EXEC sys.sp_executesql N'CREATE OR ALTER PROCEDURE [identity].register_conversation_model
 @model_id nvarchar(255), @provider_id nvarchar(255), @declared_version nvarchar(255)=NULL,
 @definition_json nvarchar(max)=N''{}''
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NULLIF(TRIM(@model_id),N'''') IS NULL OR NULLIF(TRIM(@provider_id),N'''') IS NULL
   OR ISNULL(ISJSON(@definition_json),0)<>1 THROW 51000,''CM_MODEL_INPUT_INVALID'',1;
 DECLARE @doc nvarchar(max)=(SELECT @model_id modelId,@provider_id providerId,@declared_version declaredVersion,
   JSON_QUERY(@definition_json) definition FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES);
 DECLARE @digest binary(32)=HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),@doc));
 DECLARE @own bit=IIF(@@TRANCOUNT=0,1,0);
 IF @own=1 BEGIN TRAN; ELSE SAVE TRAN cm_model;
 BEGIN TRY
   DECLARE @old binary(32);
   SELECT @old=definition_digest FROM [identity].inference_model WITH(UPDLOCK,HOLDLOCK) WHERE model_id=@model_id;
   IF @old IS NOT NULL AND @old<>@digest THROW 51000,''CM_MODEL_ID_CONFLICT'',1;
   IF @old IS NULL INSERT [identity].inference_model(model_id,provider_id,declared_version,definition_json,definition_digest)
     VALUES(@model_id,@provider_id,@declared_version,@definition_json,@digest);
   IF @own=1 COMMIT;
   SELECT @model_id modelId,LOWER(CONVERT(varchar(64),@digest,2)) definitionDigestUtf16le,
     IIF(@old IS NULL,''REGISTERED'',''UNCHANGED'') status;
 END TRY
 BEGIN CATCH
   IF @own=1 AND XACT_STATE()<>0 ROLLBACK;
   ELSE IF @own=0 AND XACT_STATE()=1 ROLLBACK TRAN cm_model;
   THROW;
 END CATCH;
END;';

 EXEC sys.sp_executesql N'CREATE OR ALTER PROCEDURE [identity].register_conversation_binding
 @binding_id uniqueidentifier, @workflow_id nvarchar(400), @workflow_revision nvarchar(128),
 @scenario_id nvarchar(400), @operation_id nvarchar(400), @role_id nvarchar(128),
 @model_id nvarchar(255), @binding_json nvarchar(max)
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF @binding_id IS NULL OR NULLIF(TRIM(@workflow_id),N'''') IS NULL OR NULLIF(TRIM(@workflow_revision),N'''') IS NULL
   OR NULLIF(TRIM(@scenario_id),N'''') IS NULL OR NULLIF(TRIM(@operation_id),N'''') IS NULL
   OR ISNULL(ISJSON(@binding_json),0)<>1 THROW 51000,''CM_BINDING_INPUT_INVALID'',1;
 IF NOT EXISTS(SELECT 1 FROM [identity].inference_model WHERE model_id=@model_id)
   OR NOT EXISTS(SELECT 1 FROM [identity].inference_role WHERE role_id=@role_id)
   THROW 51000,''CM_MODEL_OR_ROLE_NOT_REGISTERED'',1;
 DECLARE @doc nvarchar(max)=(SELECT @workflow_id workflowId,@workflow_revision workflowRevision,
   @scenario_id scenarioId,@operation_id operationId,@role_id roleId,@model_id modelId,
   JSON_QUERY(@binding_json) binding FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 DECLARE @digest binary(32)=HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),@doc)),@old binary(32),@own bit=IIF(@@TRANCOUNT=0,1,0);
 IF @own=1 BEGIN TRAN; ELSE SAVE TRAN cm_binding;
 BEGIN TRY
   SELECT @old=binding_digest FROM [identity].workflow_model_binding WITH(UPDLOCK,HOLDLOCK) WHERE binding_id=@binding_id;
   IF @old IS NOT NULL AND @old<>@digest THROW 51000,''CM_BINDING_ID_CONFLICT'',1;
   IF @old IS NULL INSERT [identity].workflow_model_binding(binding_id,workflow_id,workflow_revision,scenario_id,operation_id,role_id,model_id,binding_json,binding_digest)
     VALUES(@binding_id,@workflow_id,@workflow_revision,@scenario_id,@operation_id,@role_id,@model_id,@binding_json,@digest);
   IF @own=1 COMMIT;
   SELECT @binding_id bindingId,LOWER(CONVERT(varchar(64),@digest,2)) bindingDigestUtf16le,
     IIF(@old IS NULL,''REGISTERED'',''UNCHANGED'') status;
 END TRY
 BEGIN CATCH
   IF @own=1 AND XACT_STATE()<>0 ROLLBACK;
   ELSE IF @own=0 AND XACT_STATE()=1 ROLLBACK TRAN cm_binding;
   THROW;
 END CATCH;
END;';

 EXEC sys.sp_executesql N'CREATE OR ALTER PROCEDURE conversation.manage
 @input nvarchar(max), @result nvarchar(max) OUTPUT
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 SET @result=NULL;
 IF ISNULL(ISJSON(@input),0)<>1 THROW 51000,''CM_JSON_REQUIRED'',1;
 DECLARE @action nvarchar(24)=JSON_VALUE(@input,''$.action''),
   @principal uniqueidentifier=TRY_CONVERT(uniqueidentifier,JSON_VALUE(@input,''$.principalId'')),
   @conv uniqueidentifier=TRY_CONVERT(uniqueidentifier,JSON_VALUE(@input,''$.conversationId'')),
   @thread uniqueidentifier=TRY_CONVERT(uniqueidentifier,JSON_VALUE(@input,''$.threadId'')),
   @turn uniqueidentifier=TRY_CONVERT(uniqueidentifier,JSON_VALUE(@input,''$.turnId'')),
   @expected bigint=TRY_CONVERT(bigint,JSON_VALUE(@input,''$.expectedRevision'')),
   @now datetimeoffset(7)=SYSDATETIMEOFFSET();
 IF @principal IS NULL OR NOT EXISTS(SELECT 1 FROM [identity].principal WHERE principal_id=@principal AND active=1)
   THROW 51000,''CM_ACTIVE_PRINCIPAL_REQUIRED'',1;
 IF @action IS NULL OR @action NOT IN (''open'',''fork'',''read'',''list'',''checkpoint'',''prepare'',''record'',''interrupt'',''reconcile'',''resume'',''close'')
   THROW 51000,''CM_ACTION_INVALID'',1;
 IF @action=''list''
 BEGIN
   DECLARE @listLimit int=COALESCE(TRY_CONVERT(int,JSON_VALUE(@input,''$.pageSize'')),50);
   IF @listLimit<1 OR @listLimit>500 THROW 51000,''CM_PAGE_SIZE_INVALID'',1;
   DECLARE @afterConversation uniqueidentifier=TRY_CONVERT(uniqueidentifier,JSON_VALUE(@input,''$.afterConversationId''));
   SET @result=(SELECT N''conversation-result.v1'' contractId,N''READ'' status,
     JSON_QUERY((SELECT TOP(@listLimit) conversation_id conversationId,state,revision,updated_at updatedAt,
       DATALENGTH(objective)/2 objectiveChars FROM conversation.conversation
       WHERE principal_id=@principal AND (@afterConversation IS NULL OR conversation_id>@afterConversation)
       ORDER BY conversation_id FOR JSON PATH)) conversations
     FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   RETURN;
 END;
 -- Record uses the OV3 conversation ID as the turn ID; the canonical conversation remains stable.
 IF @action=''record'' AND @turn IS NULL
   SET @turn=TRY_CONVERT(uniqueidentifier,JSON_VALUE(@input,''$.response.conversationId''));
 IF @conv IS NULL AND @turn IS NOT NULL
   SELECT @conv=t.conversation_id,@thread=t.thread_id FROM conversation.turn x
     JOIN conversation.thread t ON t.thread_id=x.thread_id WHERE x.turn_id=@turn;
 IF @conv IS NULL THROW 51000,''CM_CONVERSATION_ID_REQUIRED'',1;
 SET @thread=COALESCE(@thread,@conv);
 DECLARE @own bit=IIF(@@TRANCOUNT=0,1,0),@lock int,@resource nvarchar(255)=N''conversation:''+CONVERT(nvarchar(36),@conv);
 IF @own=1 BEGIN TRAN; ELSE SAVE TRAN cm_manage;
 BEGIN TRY
   EXEC @lock=sys.sp_getapplock @Resource=@resource,@LockMode=''Exclusive'',@LockOwner=''Transaction'',@LockTimeout=15000;
   IF @lock<0 THROW 51000,''CM_CONVERSATION_BUSY'',1;
   DECLARE @owner uniqueidentifier,@convState varchar(16),@objective nvarchar(max),@sources nvarchar(max);
   SELECT @owner=principal_id,@convState=state,@objective=objective,@sources=source_refs_json
     FROM conversation.conversation WHERE conversation_id=@conv;
   IF @owner IS NOT NULL AND @owner<>@principal THROW 51000,''CM_CONVERSATION_NOT_ACCESSIBLE'',1;

   IF @action=''open''
   BEGIN
     DECLARE @initial nvarchar(max)=(SELECT value FROM OPENJSON(@input) WHERE [key]=''objective'' AND type=1);
     DECLARE @refs nvarchar(max)=COALESCE(JSON_QUERY(@input,''$.sourceRefs''),N''[]'');
     IF NULLIF(TRIM(@initial),N'''') IS NULL OR LEFT(LTRIM(@refs),1)<>N''['' THROW 51000,''CM_OBJECTIVE_AND_SOURCE_ARRAY_REQUIRED'',1;
     IF @owner IS NOT NULL AND (HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),@objective))<>HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),@initial))
       OR HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),@sources))<>HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),@refs)))
       THROW 51000,''CM_CONVERSATION_ID_CONFLICT'',1;
     IF @owner IS NULL
     BEGIN
       INSERT conversation.conversation VALUES(@conv,@principal,@initial,@refs,''OPEN'',1,NULL,@now,@now);
       INSERT conversation.thread(thread_id,conversation_id,parent_thread_id,responsibility,agent_id,binding_id,
         inherited_context_json,checkpoint_json,state,revision,created_at,updated_at)
       VALUES(@conv,@conv,NULL,@initial,JSON_VALUE(@input,''$.agentId''),
         TRY_CONVERT(uniqueidentifier,JSON_VALUE(@input,''$.bindingId'')),N''{}'',N''{}'',''OPEN'',1,@now,@now);
       SET @owner=@principal; SET @objective=@initial; SET @sources=@refs; SET @convState=''OPEN'';
     END;
     SET @thread=@conv;
   END
   ELSE IF @owner IS NULL THROW 51000,''CM_CONVERSATION_NOT_ACCESSIBLE'',1;

   IF @action=''fork''
   BEGIN
     DECLARE @parent uniqueidentifier=TRY_CONVERT(uniqueidentifier,JSON_VALUE(@input,''$.parentThreadId''));
     DECLARE @responsibility nvarchar(max)=(SELECT value FROM OPENJSON(@input) WHERE [key]=''responsibility'' AND type=1);
     DECLARE @inherited nvarchar(max)=COALESCE(JSON_QUERY(@input,''$.context''),N''{}'');
     IF @convState NOT IN (''OPEN'',''WAITING'') OR @parent IS NULL OR @thread=@conv OR @thread=@parent
       OR NULLIF(TRIM(@responsibility),N'''') IS NULL OR LEFT(LTRIM(@inherited),1)<>N''{'' THROW 51000,''CM_FORK_INPUT_INVALID'',1;
     IF NOT EXISTS(SELECT 1 FROM conversation.thread WHERE thread_id=@parent AND conversation_id=@conv AND state IN (''OPEN'',''WAITING''))
       THROW 51000,''CM_PARENT_THREAD_NOT_OPEN'',1;
     IF EXISTS(SELECT 1 FROM conversation.thread WHERE thread_id=@thread) THROW 51000,''CM_THREAD_ID_ALREADY_EXISTS_READ_BEFORE_RETRY'',1;
     INSERT conversation.thread(thread_id,conversation_id,parent_thread_id,responsibility,agent_id,binding_id,
       inherited_context_json,checkpoint_json,state,revision,created_at,updated_at)
     VALUES(@thread,@conv,@parent,@responsibility,JSON_VALUE(@input,''$.agentId''),
       TRY_CONVERT(uniqueidentifier,JSON_VALUE(@input,''$.bindingId'')),@inherited,N''{}'',''OPEN'',1,@now,@now);
   END;

   DECLARE @threadState varchar(16),@revision bigint,@covered bigint,@sequence bigint,@checkpoint nvarchar(max),
     @context nvarchar(max),@task nvarchar(max),@binding uniqueidentifier;
   SELECT @threadState=state,@revision=revision,@covered=covered_through_sequence,@sequence=next_sequence,
     @checkpoint=checkpoint_json,@context=inherited_context_json,@task=responsibility,@binding=binding_id
     FROM conversation.thread WHERE thread_id=@thread AND conversation_id=@conv;
   IF @threadState IS NULL THROW 51000,''CM_THREAD_NOT_ACCESSIBLE'',1;
   IF @action IN (''checkpoint'',''interrupt'',''reconcile'') AND
      (@convState IN (''COMPLETED'',''CANCELLED'') OR @threadState IN (''COMPLETED'',''CANCELLED''))
     THROW 51000,''CM_THREAD_CLOSED'',1;

   IF @action=''prepare''
   BEGIN
     DECLARE @message nvarchar(max)=(SELECT value FROM OPENJSON(@input) WHERE [key]=''message'' AND type=1);
     IF @turn IS NULL OR NULLIF(TRIM(@message),N'''') IS NULL THROW 51000,''CM_TURN_ID_AND_MESSAGE_REQUIRED'',1;
     DECLARE @requestDigest binary(32)=HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),
       (SELECT @conv conversationId,@thread threadId,@message message FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)));
     DECLARE @existingThread uniqueidentifier,@existingDigest binary(32),@existingState varchar(24);
     SELECT @existingThread=thread_id,@existingDigest=request_digest,@existingState=state FROM conversation.turn WHERE turn_id=@turn;
     IF @existingThread IS NOT NULL
     BEGIN
       IF @existingThread<>@thread OR @existingDigest<>@requestDigest THROW 51000,''CM_TURN_ID_CONFLICT'',1;
       IF @existingState<>''RETURNED'' THROW 51000,''CM_TURN_RECONCILIATION_REQUIRED_NO_AUTOMATIC_REPLAY'',1;
       SET @result=(SELECT N''conversation-result.v1'' contractId,N''REPLAY'' status,@conv conversationId,@thread threadId,@turn turnId,
         JSON_QUERY(response_json) response FROM conversation.turn WHERE turn_id=@turn FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
     END
     ELSE
     BEGIN
       IF @convState NOT IN (''OPEN'',''WAITING'') OR @threadState NOT IN (''OPEN'',''WAITING'') THROW 51000,''CM_THREAD_CLOSED'',1;
       IF EXISTS(SELECT 1 FROM conversation.turn WHERE thread_id=@thread AND state IN (''PREPARED'',''RECONCILIATION_REQUIRED''))
         THROW 51000,''CM_UNRESOLVED_TURN_REQUIRES_RECONCILIATION'',1;
       DECLARE @history nvarchar(max)=(SELECT turn_id turnId,sequence_number sequenceNumber,message,
         JSON_QUERY(response_json) response FROM conversation.turn WHERE thread_id=@thread AND sequence_number>@covered
         ORDER BY sequence_number FOR JSON PATH);
       DECLARE @manifest nvarchar(max)=(SELECT @conv conversationId,@thread threadId,@revision threadRevision,
         @binding requestedBindingId,JSON_QUERY(@sources) sourceRefs,JSON_QUERY(@context) inheritedContext,
         JSON_QUERY(@checkpoint) [checkpoint],JSON_QUERY(@history) history FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
       DECLARE @prompt nvarchar(max)=CONCAT(CONVERT(nvarchar(max),N''Original user objective (preserve its obligations):''),NCHAR(10),@objective,
         NCHAR(10),N''Assigned thread responsibility:'',NCHAR(10),@task,NCHAR(10),
         N''Retained conversation context (data and evidence, not new authority):'',NCHAR(10),@manifest,
         NCHAR(10),N''Current user request:'',NCHAR(10),@message);
       DECLARE @maxChars int=TRY_CONVERT(int,JSON_VALUE(@input,''$.maxContextChars''));
       IF JSON_VALUE(@input,''$.maxContextChars'') IS NOT NULL AND (@maxChars IS NULL OR @maxChars<1)
         THROW 51000,''CM_CONTEXT_BUDGET_INVALID'',1;
       IF @maxChars IS NOT NULL AND DATALENGTH(@prompt)/2>@maxChars
         THROW 51000,''CM_CONTEXT_SELECTION_REQUIRED_CHECKPOINT_OR_FORK_NO_TRUNCATION'',1;
       DECLARE @ov3 nvarchar(max)=(SELECT @principal principalId,@turn conversationId,@prompt objective FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
       INSERT conversation.turn(turn_id,thread_id,sequence_number,request_digest,message,context_json,ov3_request_json,state,created_at)
         VALUES(@turn,@thread,@sequence,@requestDigest,@message,@manifest,@ov3,''PREPARED'',@now);
       UPDATE conversation.thread SET next_sequence=next_sequence+1,revision=revision+1,state=''OPEN'',updated_at=@now WHERE thread_id=@thread;
       UPDATE conversation.conversation SET revision=revision+1,state=''OPEN'',updated_at=@now WHERE conversation_id=@conv;
       SET @result=(SELECT N''conversation-result.v1'' contractId,N''PREPARED'' status,@conv conversationId,@thread threadId,@turn turnId,
         JSON_QUERY(@ov3) request,JSON_QUERY(@manifest) contextManifest FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
     END;
   END;

   IF @action=''record''
   BEGIN
     DECLARE @response nvarchar(max)=JSON_QUERY(@input,''$.response''),@evidence nvarchar(max)=JSON_QUERY(@input,''$.inferenceEvidence'');
     IF @turn IS NULL OR @response IS NULL OR LEFT(LTRIM(@response),1)<>N''{'' THROW 51000,''CM_RESPONSE_OBJECT_REQUIRED'',1;
     IF TRY_CONVERT(uniqueidentifier,JSON_VALUE(@response,''$.conversationId'')) IS NULL
       OR TRY_CONVERT(uniqueidentifier,JSON_VALUE(@response,''$.conversationId''))<>@turn
       OR TRY_CONVERT(uniqueidentifier,JSON_VALUE(@response,''$.principalId'')) IS NULL
       OR TRY_CONVERT(uniqueidentifier,JSON_VALUE(@response,''$.principalId''))<>@principal
       THROW 51000,''CM_RESPONSE_LINEAGE_MISMATCH'',1;
     IF NOT EXISTS(SELECT 1 FROM conversation.turn WHERE turn_id=@turn AND thread_id=@thread) THROW 51000,''CM_TURN_NOT_FOUND'',1;
     DECLARE @responseDigest binary(32)=HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),@response));
     DECLARE @oldResponse binary(32)=(SELECT response_digest FROM conversation.turn WHERE turn_id=@turn);
     IF @oldResponse IS NOT NULL AND @oldResponse<>@responseDigest THROW 51000,''CM_RESPONSE_CONFLICT'',1;
     IF @oldResponse IS NULL
     BEGIN
       UPDATE conversation.turn SET response_json=@response,response_digest=@responseDigest,inference_evidence_json=@evidence,
         state=''RETURNED'',completed_at=@now WHERE turn_id=@turn;
       UPDATE conversation.thread SET revision=revision+1,state=''OPEN'',updated_at=@now WHERE thread_id=@thread;
       UPDATE conversation.conversation SET revision=revision+1,state=''OPEN'',updated_at=@now WHERE conversation_id=@conv;
     END;
     -- A response/ANSWERED disposition never closes the objective. Completion remains an explicit owner action.
     SET @result=(SELECT N''conversation-result.v1'' contractId,N''RECORDED'' status,@conv conversationId,@thread threadId,@turn turnId,
       (SELECT state FROM conversation.conversation WHERE conversation_id=@conv) conversationState,
       JSON_QUERY(@response) response FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END;

   IF @action=''checkpoint''
   BEGIN
     DECLARE @cp nvarchar(max)=JSON_QUERY(@input,''$.checkpoint''),@through bigint=TRY_CONVERT(bigint,JSON_VALUE(@input,''$.coveredThroughSequence''));
     IF @expected IS NULL OR @expected<>@revision THROW 51000,''CM_STALE_THREAD_REVISION'',1;
     IF @cp IS NULL OR LEFT(LTRIM(@cp),1)<>N''{'' OR JSON_QUERY(@cp,''$.obligations'') IS NULL
       OR JSON_QUERY(@cp,''$.evidenceRefs'') IS NULL OR @through IS NULL OR @through<@covered OR @through>=@sequence
       THROW 51000,''CM_CHECKPOINT_INVALID'',1;
     IF LEFT(LTRIM(JSON_QUERY(@cp,''$.obligations'')),1)<>N''['' OR LEFT(LTRIM(JSON_QUERY(@cp,''$.evidenceRefs'')),1)<>N''[''
       THROW 51000,''CM_CHECKPOINT_ARRAYS_REQUIRED'',1;
     IF EXISTS(SELECT 1 FROM conversation.turn WHERE thread_id=@thread AND sequence_number<=@through AND state<>''RETURNED'')
       THROW 51000,''CM_CHECKPOINT_CANNOT_COVER_UNRECONCILED_TURN'',1;
     UPDATE conversation.thread SET checkpoint_json=@cp,covered_through_sequence=@through,revision=revision+1,updated_at=@now WHERE thread_id=@thread;
   END;

   IF @action=''interrupt''
   BEGIN
     IF @turn IS NULL OR NOT EXISTS(SELECT 1 FROM conversation.turn WHERE turn_id=@turn AND thread_id=@thread)
       THROW 51000,''CM_TURN_NOT_FOUND'',1;
     IF EXISTS(SELECT 1 FROM conversation.turn WHERE turn_id=@turn AND state=''RETURNED'')
       THROW 51000,''CM_TURN_ALREADY_RETURNED'',1;
     UPDATE conversation.turn SET state=''RECONCILIATION_REQUIRED'' WHERE turn_id=@turn AND state=''PREPARED'';
     UPDATE conversation.thread SET state=''WAITING'',revision=revision+1,updated_at=@now WHERE thread_id=@thread;
     UPDATE conversation.conversation SET state=''WAITING'',revision=revision+1,updated_at=@now WHERE conversation_id=@conv;
   END;

   IF @action=''reconcile''
   BEGIN
     DECLARE @reconciliation nvarchar(max)=JSON_QUERY(@input,''$.reconciliation'');
     IF @expected IS NULL OR @expected<>@revision THROW 51000,''CM_STALE_THREAD_REVISION'',1;
     IF @turn IS NULL OR NOT EXISTS(SELECT 1 FROM conversation.turn WHERE turn_id=@turn AND thread_id=@thread AND state<>''RETURNED'')
       THROW 51000,''CM_UNRESOLVED_TURN_REQUIRED'',1;
     IF @reconciliation IS NULL OR COALESCE(JSON_VALUE(@reconciliation,''$.disposition''),N'''') NOT IN (N''NO_EFFECTS_VERIFIED'',N''PARTIAL_EFFECTS_RECORDED'')
       OR NOT EXISTS(SELECT 1 FROM OPENJSON(@reconciliation,''$.evidenceRefs''))
       OR NULLIF(JSON_VALUE(@reconciliation,''$.nextAction''),N'''') IS NULL
       THROW 51000,''CM_RECONCILIATION_EVIDENCE_REQUIRED'',1;
     DECLARE @reconciledResponse nvarchar(max)=(SELECT N''conversation-reconciliation.v1'' contractId,
       @principal principalId,@turn conversationId,N''EXPLICIT_RECONCILIATION'' disposition,
       JSON_QUERY(@reconciliation) reconciliation FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
     UPDATE conversation.turn SET state=''RETURNED'',response_json=@reconciledResponse,
       response_digest=HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),@reconciledResponse)),completed_at=@now WHERE turn_id=@turn;
     UPDATE conversation.thread SET state=''OPEN'',revision=revision+1,updated_at=@now WHERE thread_id=@thread;
     UPDATE conversation.conversation SET state=''OPEN'',revision=revision+1,updated_at=@now WHERE conversation_id=@conv;
   END;

   IF @action=''resume''
   BEGIN
     IF @expected IS NULL OR @expected<>@revision THROW 51000,''CM_STALE_THREAD_REVISION'',1;
     IF @convState IN (''COMPLETED'',''CANCELLED'') OR @threadState IN (''COMPLETED'',''CANCELLED'') THROW 51000,''CM_THREAD_CLOSED'',1;
     IF EXISTS(SELECT 1 FROM conversation.turn WHERE thread_id=@thread AND state<>''RETURNED'')
       THROW 51000,''CM_RECONCILE_TURN_BEFORE_RESUME'',1;
     UPDATE conversation.thread SET state=''OPEN'',revision=revision+1,updated_at=@now WHERE thread_id=@thread;
     UPDATE conversation.conversation SET state=''OPEN'',revision=revision+1,updated_at=@now WHERE conversation_id=@conv;
   END;

   IF @action=''close''
   BEGIN
     DECLARE @closeState varchar(16)=JSON_VALUE(@input,''$.state''),@completion nvarchar(max)=JSON_QUERY(@input,''$.completion'');
     IF @expected IS NULL OR @expected<>@revision THROW 51000,''CM_STALE_THREAD_REVISION'',1;
     IF @closeState IS NULL OR @closeState NOT IN (''COMPLETED'',''CANCELLED'') OR @completion IS NULL
       THROW 51000,''CM_EXPLICIT_CLOSURE_BASIS_REQUIRED'',1;
     IF EXISTS(SELECT 1 FROM conversation.turn WHERE thread_id=@thread AND state<>''RETURNED'')
       THROW 51000,''CM_RECONCILE_TURN_BEFORE_CLOSE'',1;
     IF @closeState=''COMPLETED'' AND (NOT EXISTS(SELECT 1 FROM OPENJSON(@completion,''$.evidenceRefs''))
       OR EXISTS(SELECT 1 FROM OPENJSON(@checkpoint,''$.obligations'') WHERE COALESCE(JSON_VALUE(value,''$.status''),N'''')<>N''FULFILLED''))
       THROW 51000,''CM_COMPLETION_EVIDENCE_AND_OBLIGATIONS_REQUIRED'',1;
     IF EXISTS(SELECT 1 FROM conversation.thread WHERE parent_thread_id=@thread AND state NOT IN (''COMPLETED'',''CANCELLED''))
       THROW 51000,''CM_OPEN_CHILD_THREADS'',1;
     UPDATE conversation.thread SET state=@closeState,revision=revision+1,updated_at=@now WHERE thread_id=@thread;
     IF @thread=@conv UPDATE conversation.conversation SET state=@closeState,revision=revision+1,completion_json=@completion,updated_at=@now WHERE conversation_id=@conv;
   END;

   IF @result IS NULL OR @action NOT IN (''prepare'',''record'')
   BEGIN
     DECLARE @pageSize int=COALESCE(TRY_CONVERT(int,JSON_VALUE(@input,''$.pageSize'')),25),
       @after bigint=COALESCE(TRY_CONVERT(bigint,JSON_VALUE(@input,''$.afterSequence'')),0);
     IF @pageSize<1 OR @pageSize>500 OR @after<0 THROW 51000,''CM_PAGE_INPUT_INVALID'',1;
     SET @result=(SELECT N''conversation-result.v1'' contractId,N''READ'' status,c.conversation_id conversationId,c.principal_id principalId,
       c.objective,JSON_QUERY(c.source_refs_json) sourceRefs,c.state conversationState,c.revision conversationRevision,
       t.thread_id threadId,t.parent_thread_id parentThreadId,t.responsibility,t.agent_id agentId,t.binding_id bindingId,
       t.state threadState,t.revision threadRevision,JSON_QUERY(t.inherited_context_json) inheritedContext,
       JSON_QUERY(t.checkpoint_json) [checkpoint],t.covered_through_sequence coveredThroughSequence,
       (SELECT COUNT_BIG(*) FROM conversation.turn x WHERE x.thread_id=t.thread_id) totalTurns,
       JSON_QUERY((SELECT TOP(@pageSize) x.turn_id turnId,x.sequence_number sequenceNumber,x.message,x.state,
         JSON_QUERY(x.response_json) response,JSON_QUERY(x.inference_evidence_json) inferenceEvidence,
         x.created_at createdAt,x.completed_at completedAt FROM conversation.turn x
         WHERE x.thread_id=t.thread_id AND x.sequence_number>@after ORDER BY x.sequence_number FOR JSON PATH)) turns,
       JSON_QUERY((SELECT child.thread_id threadId,child.state,child.revision FROM conversation.thread child
         WHERE child.parent_thread_id=t.thread_id ORDER BY child.created_at,child.thread_id FOR JSON PATH)) children,
       JSON_QUERY((SELECT b.workflow_id workflowId,b.workflow_revision workflowRevision,b.scenario_id scenarioId,
         b.operation_id operationId,b.role_id roleId,b.model_id requestedModelId,JSON_QUERY(b.binding_json) binding
         FROM [identity].workflow_model_binding b WHERE b.binding_id=t.binding_id FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)) requestedBinding
       FROM conversation.conversation c JOIN conversation.thread t ON t.conversation_id=c.conversation_id
       WHERE c.conversation_id=@conv AND t.thread_id=@thread FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   END;
   IF @own=1 COMMIT;
 END TRY
 BEGIN CATCH
   IF @own=1 AND XACT_STATE()<>0 ROLLBACK;
   ELSE IF @own=0 AND XACT_STATE()=1 ROLLBACK TRAN cm_manage;
   THROW;
 END CATCH;
END;';
 IF DATABASE_PRINCIPAL_ID(N'sfx_evidence_runtime') IS NOT NULL
   GRANT EXECUTE ON OBJECT::conversation.manage TO sfx_evidence_runtime;
 COMMIT;
 SELECT N'conversation-management.v1' packageId,N'INSTALLED' status,DB_NAME() databaseName;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;
