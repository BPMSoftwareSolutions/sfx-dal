-- draft emitted by Codelightly; promote through the deployment lifecycle
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF @@TRANCOUNT=0 BEGIN TRANSACTION;
DECLARE @lock int;
EXEC @lock=sys.sp_getapplock @Resource=N'sidefx:model-write',@LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=60000;
IF @lock<0 THROW 51000,N'PROVIDER_IDENTITY_LOCK_FAILED',1;
IF NOT EXISTS (SELECT 1 FROM [model].[provider] WHERE [namespace_pk] = 3778 AND [provider_id] = N'ScenarioKernel.NodePlatform' AND [semantic_object_pk] = 8756 AND [object_kind] = N'PROVIDER') BEGIN INSERT INTO [model].[provider] ([namespace_pk], [provider_id], [semantic_object_pk], [object_kind]) VALUES (3778, N'ScenarioKernel.NodePlatform', 8756, N'PROVIDER'); END;
SELECT 'provider-identity' AS result_set, COUNT_BIG(*) AS row_count FROM [model].[provider];
ROLLBACK TRANSACTION;
