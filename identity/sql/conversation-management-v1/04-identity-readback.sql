/* Read only. Run in sfx-identity after installation. */
SET NOCOUNT ON;
IF DB_NAME()<>N'sfx-identity' THROW 51000,'CM_WRONG_DATABASE_EXPECTED_SFX_IDENTITY',1;
DECLARE @required TABLE(name sysname,kind char(2));
INSERT @required VALUES
 (N'identity.inference_model','U'),(N'identity.inference_role','U'),(N'identity.workflow_model_binding','U'),
 (N'conversation.conversation','U'),(N'conversation.thread','U'),(N'conversation.turn','U'),(N'conversation.installation','U'),
 (N'identity.register_conversation_model','P'),(N'identity.register_conversation_binding','P'),(N'conversation.manage','P');
IF EXISTS(SELECT 1 FROM @required WHERE OBJECT_ID(name,kind) IS NULL)
 THROW 51000,'CM_INSTALLATION_OBJECT_MISSING',1;
SELECT name,kind,N'PRESENT' status FROM @required ORDER BY kind,name;
SELECT package_id,installed_at,description FROM conversation.installation WHERE package_id='conversation-management.v1';
SELECT role_id,description FROM [identity].inference_role ORDER BY role_id;
SELECT (SELECT COUNT_BIG(*) FROM [identity].inference_model) modelIdentities,
 (SELECT COUNT_BIG(*) FROM [identity].workflow_model_binding) workflowBindings,
 (SELECT COUNT_BIG(*) FROM conversation.conversation) conversations,
 (SELECT COUNT_BIG(*) FROM conversation.thread) threads,
 (SELECT COUNT_BIG(*) FROM conversation.turn) turns;
SELECT USER_NAME() currentDatabaseUser,HAS_PERMS_BY_NAME(N'conversation.manage',N'OBJECT',N'EXECUTE') currentUserCanExecute;
SELECT N'IDENTITY_READBACK_PASSED' status;
