/* Run in sfx-identity after 01-install.sql. All test state is rolled back.
   Uses the requesting owner's existing principal; change only @principal if needed.
   Does not invoke a model or execute an external capability.
*/
SET NOCOUNT ON;
IF DB_NAME()<>N'sfx-identity' THROW 51000,'CM_WRONG_DATABASE_EXPECTED_SFX_IDENTITY',1;
IF @@TRANCOUNT<>0 THROW 51000,'CM_VERIFY_REQUIRES_OWN_TRANSACTION',1;
DECLARE @principal uniqueidentifier='565de6d4-ebcd-408b-9359-04d21dc62183';
IF NOT EXISTS(SELECT 1 FROM [identity].principal WHERE principal_id=@principal AND active=1)
 THROW 51000,'CM_VERIFY_SET_AN_EXISTING_ACTIVE_PRINCIPAL',1;
DECLARE @conv uniqueidentifier=NEWID(),@child uniqueidentifier=NEWID(),@turn uniqueidentifier=NEWID(),
 @binding uniqueidentifier=NEWID(),@model nvarchar(255)=N'test-only/'+CONVERT(nvarchar(36),NEWID()),
 @in nvarchar(max),@out nvarchar(max),@response nvarchar(max),@revision bigint;
DECLARE @checks TABLE(check_name nvarchar(100),result varchar(10));
BEGIN TRY
 BEGIN TRAN;
 EXEC [identity].register_conversation_model @model_id=@model,@provider_id=N'test-only',@definition_json=N'{"testOnly":true}';
 EXEC [identity].register_conversation_binding @binding_id=@binding,@workflow_id=N'test-only',@workflow_revision=N'test-revision',
  @scenario_id=N'root',@operation_id=N'reason',@role_id=N'coordinator',@model_id=@model,@binding_json=N'{"testOnly":true}';
 DECLARE @longObjective nvarchar(max)=N'Keep this original objective: '+REPLICATE(CONVERT(nvarchar(max),N'Unicode evidence 漢字 '),600);
 SET @in=(SELECT N'open' action,@principal principalId,@conv conversationId,@longObjective objective,
  @binding bindingId,JSON_QUERY(N'[{"artifactId":"existing-reference","digest":"reference-only"}]') sourceRefs FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 IF (SELECT objective FROM conversation.conversation WHERE conversation_id=@conv)<>@longObjective THROW 51000,'CM_TEST_LONG_OBJECTIVE_TRUNCATED',1;
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 IF JSON_VALUE(@out,'$.conversationRevision')<>N'1' THROW 51000,'CM_TEST_OPEN_NOT_IDEMPOTENT',1;
 INSERT @checks VALUES(N'Long Unicode objective and idempotent open','PASS');

 SET @in=(SELECT N'fork' action,@principal principalId,@conv conversationId,@child threadId,@conv parentThreadId,
  N'Only the assigned responsibility' responsibility FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 IF JSON_QUERY(@out,'$.inheritedContext')<>N'{}' OR JSON_VALUE(@out,'$.parentThreadId')<>CONVERT(nvarchar(36),@conv)
  THROW 51000,'CM_TEST_CHILD_CONTEXT_NOT_ISOLATED',1;
 INSERT @checks VALUES(N'Child thread starts with explicit empty inherited context','PASS');

 SET @in=(SELECT N'prepare' action,@principal principalId,@conv conversationId,@turn turnId,N'First turn' message FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 IF JSON_VALUE(@out,'$.status')<>N'PREPARED' OR JSON_VALUE(@out,'$.request.conversationId')<>CONVERT(nvarchar(36),@turn)
  THROW 51000,'CM_TEST_FRESH_INFERENCE_ID_MISSING',1;
 SET @response=(SELECT @principal principalId,@turn conversationId,N'ANSWERED' pursuitDisposition,N'Test response' reply FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 SET @in=(SELECT N'record' action,@principal principalId,@turn turnId,JSON_QUERY(@response) response FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 IF (SELECT COUNT(*) FROM conversation.turn WHERE thread_id=@conv)<>1 OR JSON_VALUE(@out,'$.conversationState')<>N'OPEN'
  THROW 51000,'CM_TEST_RECORD_DUPLICATED_OR_CLOSED',1;
 SET @in=(SELECT N'prepare' action,@principal principalId,@conv conversationId,@turn turnId,N'First turn' message FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 IF JSON_VALUE(@out,'$.status')<>N'REPLAY' THROW 51000,'CM_TEST_COMPLETED_TURN_REPLAY_FAILED',1;
 INSERT @checks VALUES(N'Fresh inference ID, idempotent result and no implicit closure','PASS');

 SELECT @revision=revision FROM conversation.thread WHERE thread_id=@conv;
 SET @in=(SELECT N'checkpoint' action,@principal principalId,@conv conversationId,@revision expectedRevision,1 coveredThroughSequence,
  JSON_QUERY(N'{"summary":"Test response retained","obligations":[{"id":"test","status":"OPEN"}],"evidenceRefs":["test-receipt"]}') [checkpoint]
  FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 SET @turn=NEWID();
 SET @in=(SELECT N'prepare' action,@principal principalId,@conv conversationId,@turn turnId,N'Continue' message FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 IF JSON_QUERY(@out,'$.contextManifest.history')<>N'[]' OR JSON_VALUE(@out,'$.contextManifest.checkpoint.summary')<>N'Test response retained'
  THROW 51000,'CM_TEST_CHECKPOINT_NOT_USED',1;
 IF (SELECT COUNT(*) FROM conversation.turn WHERE thread_id=@conv)<>2 THROW 51000,'CM_TEST_HISTORY_NOT_RETAINED',1;
 INSERT @checks VALUES(N'Checkpoint changes context without deleting full history','PASS');

 SET @in=(SELECT N'interrupt' action,@principal principalId,@conv conversationId,@turn turnId FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 SELECT @revision=revision FROM conversation.thread WHERE thread_id=@conv;
 SET @in=(SELECT N'reconcile' action,@principal principalId,@conv conversationId,@turn turnId,@revision expectedRevision,
  JSON_QUERY(N'{"disposition":"NO_EFFECTS_VERIFIED","evidenceRefs":["test-only-readback"],"nextAction":"Start a new turn after readback"}') reconciliation
  FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 IF (SELECT state FROM conversation.turn WHERE turn_id=@turn)<>'RETURNED' THROW 51000,'CM_TEST_RECONCILIATION_FAILED',1;
 INSERT @checks VALUES(N'Interrupted turn reconciles with evidence before continuation','PASS');

 -- Replaying a completed result must report the actual state after explicit closure.
 SELECT @revision=revision FROM conversation.thread WHERE thread_id=@child;
 SET @in=(SELECT N'close' action,@principal principalId,@conv conversationId,@child threadId,
  @revision expectedRevision,N'CANCELLED' state,JSON_QUERY(N'{"reason":"test finished"}') completion FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 SELECT @revision=revision FROM conversation.thread WHERE thread_id=@conv;
 SET @in=(SELECT N'close' action,@principal principalId,@conv conversationId,@revision expectedRevision,
  N'CANCELLED' state,JSON_QUERY(N'{"reason":"test finished"}') completion FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 SELECT @response=response_json FROM conversation.turn WHERE turn_id=@turn;
 SET @in=(SELECT N'record' action,@principal principalId,@turn turnId,JSON_QUERY(@response) response FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 EXEC conversation.manage @input=@in,@result=@out OUTPUT;
 IF JSON_VALUE(@out,'$.conversationState')<>N'CANCELLED' THROW 51000,'CM_TEST_REPLAY_CHANGED_CLOSED_STATE',1;
 INSERT @checks VALUES(N'Replayed receipt preserves and reports closed state','PASS');
 ROLLBACK;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;

-- Expected failures each get their own transaction. No invalid fixture survives an error.
DECLARE @cases TABLE(id int PRIMARY KEY,name nvarchar(100),expected nvarchar(100));
INSERT @cases VALUES
 (1,N'Unresolved turn cannot be dispatched twice',N'CM_TURN_RECONCILIATION_REQUIRED_NO_AUTOMATIC_REPLAY'),
 (2,N'Context budget overflow preserves full source',N'CM_CONTEXT_SELECTION_REQUIRED_CHECKPOINT_OR_FORK_NO_TRUNCATION'),
 (3,N'Stale checkpoint cannot overwrite state',N'CM_STALE_THREAD_REVISION'),
 (4,N'Turn identity cannot be reused for a different request',N'CM_TURN_ID_CONFLICT'),
 (5,N'Completion needs evidence',N'CM_COMPLETION_EVIDENCE_AND_OBLIGATIONS_REQUIRED'),
 (6,N'Owner mismatch is refused',N'CM_CONVERSATION_NOT_ACCESSIBLE');
DECLARE @case int=1,@expectedError nvarchar(100),@caseName nvarchar(100),@actualError nvarchar(2048),@other uniqueidentifier;
WHILE @case<=6
BEGIN
 SELECT @expectedError=expected,@caseName=name FROM @cases WHERE id=@case;
 SET @actualError=NULL; SET @conv=NEWID(); SET @turn=NEWID();
 BEGIN TRY
  BEGIN TRAN;
  SET @in=(SELECT N'open' action,@principal principalId,@conv conversationId,N'Test objective' objective FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
  EXEC conversation.manage @input=@in,@result=@out OUTPUT;
  IF @case IN (1,4)
  BEGIN
   SET @in=(SELECT N'prepare' action,@principal principalId,@conv conversationId,@turn turnId,N'Test' message FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   EXEC conversation.manage @input=@in,@result=@out OUTPUT;
   IF @case=4 SET @in=JSON_MODIFY(@in,'$.message',N'Different');
   EXEC conversation.manage @input=@in,@result=@out OUTPUT;
  END;
  IF @case=2
  BEGIN
   SET @in=(SELECT N'prepare' action,@principal principalId,@conv conversationId,@turn turnId,N'Test' message,1 maxContextChars FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   EXEC conversation.manage @input=@in,@result=@out OUTPUT;
  END;
  IF @case=3
  BEGIN
   SET @in=(SELECT N'checkpoint' action,@principal principalId,@conv conversationId,99 expectedRevision,0 coveredThroughSequence,
    JSON_QUERY(N'{"obligations":[],"evidenceRefs":[]}') [checkpoint] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   EXEC conversation.manage @input=@in,@result=@out OUTPUT;
  END;
  IF @case=5
  BEGIN
   SET @in=(SELECT N'close' action,@principal principalId,@conv conversationId,1 expectedRevision,N'COMPLETED' state,
    JSON_QUERY(N'{}') completion FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   EXEC conversation.manage @input=@in,@result=@out OUTPUT;
  END;
  IF @case=6
  BEGIN
   -- Fixture-only principal, removed with this transaction. Never grants login or API access.
   SET @other=NEWID();
   INSERT [identity].principal(principal_id,realm,identifier,active,security_version,created_at)
    VALUES(@other,N'cm-test-only',CONVERT(nvarchar(36),@other),1,1,SYSDATETIMEOFFSET());
   SET @in=(SELECT N'read' action,@other principalId,@conv conversationId FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
   EXEC conversation.manage @input=@in,@result=@out OUTPUT;
  END;
  THROW 51000,'CM_TEST_EXPECTED_REFUSAL_MISSING',1;
 END TRY
 BEGIN CATCH
  SET @actualError=ERROR_MESSAGE();
  IF XACT_STATE()<>0 ROLLBACK;
 END CATCH;
 IF @actualError<>@expectedError
 BEGIN
  DECLARE @failure nvarchar(2048)=CONCAT(@caseName,N': expected ',@expectedError,N'; received ',@actualError);
  THROW 51000,@failure,1;
 END;
 INSERT @checks VALUES(@caseName,'PASS');
 SET @case+=1;
END;
SELECT check_name,result FROM @checks;
SELECT N'ROLLED_BACK' fixtureDisposition,@@TRANCOUNT remainingTransactions;
