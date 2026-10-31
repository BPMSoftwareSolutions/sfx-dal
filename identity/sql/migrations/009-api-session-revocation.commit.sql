-- API sign-out for the authenticated ingress of the declared API (sfx-api). The ingress has resolved
-- the caller's session (008, resolve_api_session), so the session is revoked by its id and principal,
-- never by a verifier hash; the revocation is audited as revoke_session audits it. A repeated sign-out
-- is safe and answers the same status.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME()<>N'sfx-identity' THROW 51000,'IDENTITY_DATABASE_MISMATCH',1;
IF @@TRANCOUNT<>0 THROW 51000,'IDENTITY_MIGRATION_REQUIRES_NO_OUTER_TRANSACTION',1;
BEGIN TRANSACTION;
BEGIN TRY
EXEC(N'CREATE OR ALTER PROCEDURE [identity].[revoke_api_session]
 @input nvarchar(max)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY
 DECLARE @session_id uniqueidentifier=TRY_CONVERT(uniqueidentifier,JSON_VALUE(@input,''$.sessionId''));
 DECLARE @principal_id uniqueidentifier=TRY_CONVERT(uniqueidentifier,JSON_VALUE(@input,''$.principalId''));
 IF @session_id IS NULL OR @principal_id IS NULL THROW 51000,''IDENTITY_SESSION_REQUIRED'',1;
 DECLARE @now datetimeoffset(7)=SYSUTCDATETIME();
 DECLARE @revoked TABLE(attempt_id uniqueidentifier,principal_id uniqueidentifier);
 UPDATE [identity].session SET revoked_at=@now
 OUTPUT inserted.attempt_id,inserted.principal_id INTO @revoked
 WHERE session_id=@session_id AND principal_id=@principal_id AND revoked_at IS NULL;
 INSERT [identity].authentication_audit(attempt_id,principal_id,event_kind,occurred_at)
 SELECT attempt_id,principal_id,''session_revoked'',@now FROM @revoked;
 SELECT (SELECT N''REVOKED'' AS status,LOWER(CONVERT(varchar(36),@session_id)) AS sessionId,
  (SELECT COUNT(*) FROM @revoked) AS revokedNow FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) AS value;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
IF DATABASE_PRINCIPAL_ID(N'sfx_identity_runtime') IS NULL CREATE ROLE sfx_identity_runtime AUTHORIZATION dbo;
GRANT EXECUTE ON OBJECT::[identity].revoke_api_session TO sfx_identity_runtime;
IF OBJECT_ID(N'identity.revoke_api_session',N'P') IS NULL THROW 51000,'REVOKE_API_SESSION_MISSING',1;
SELECT (SELECT N'009-api-session-revocation' AS migration,CONVERT(int,1) AS added_procedures FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) AS value;
COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH
