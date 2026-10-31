-- The authenticated ingress of the declared API now digests the session carrier in the kernel (sfx-api,
-- DEPENDENCY sfx-api-ingress, operation resolve-request), which writes the digest as base64; the former
-- host wrote it as hexadecimal. resolve_api_session reads either form of $.caller.sessionDigest: 64
-- hexadecimal characters, or 44 base64 characters with the padding only at the end. A digest in
-- neither form resolves no caller; without a digest the caller it was given passes through, as in 008.
-- Everything else is 008 unchanged: the checks of validate_session, last_seen_at, and the answer
-- carrying the request and the resolved caller.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME()<>N'sfx-identity' THROW 51000,'IDENTITY_DATABASE_MISMATCH',1;
IF @@TRANCOUNT<>0 THROW 51000,'IDENTITY_MIGRATION_REQUIRES_NO_OUTER_TRANSACTION',1;
BEGIN TRANSACTION;
BEGIN TRY
IF COL_LENGTH(N'identity.session',N'verifier_digest') IS NULL THROW 51000,'SESSION_VERIFIER_DIGEST_MISSING',1;
EXEC(N'CREATE OR ALTER PROCEDURE [identity].[resolve_api_session]
 @input nvarchar(max)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit=CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY
 DECLARE @presented nvarchar(4000)=JSON_VALUE(@input,''$.caller.sessionDigest'');
 DECLARE @digest binary(32)=CASE
  WHEN LEN(@presented)=64 AND @presented NOT LIKE N''%[^0-9A-Fa-f]%'' COLLATE Latin1_General_100_BIN2
   THEN CONVERT(binary(32),@presented,2)
  WHEN LEN(@presented)=44 AND CHARINDEX(N''='',@presented)=44 AND @presented NOT LIKE N''%[^A-Za-z0-9+/=]%'' COLLATE Latin1_General_100_BIN2
   THEN CAST(N'''' AS xml).value(''xs:base64Binary(sql:variable("@presented"))'',''varbinary(32)'') END;
 DECLARE @now datetimeoffset(7)=SYSUTCDATETIME(),@idle int;
 SELECT @idle=idle_seconds FROM [identity].login_policy WHERE policy_id=1;
 DECLARE @resolved TABLE(session_id uniqueidentifier,principal_id uniqueidentifier,expires_at datetimeoffset(7));
 IF @digest IS NOT NULL
  UPDATE s WITH(UPDLOCK) SET last_seen_at=@now
  OUTPUT inserted.session_id,inserted.principal_id,inserted.expires_at INTO @resolved
  FROM [identity].session s
  JOIN [identity].principal p WITH(HOLDLOCK) ON p.principal_id=s.principal_id AND p.security_version=s.security_version
  JOIN [identity].password_credential c WITH(HOLDLOCK) ON c.principal_id=s.principal_id AND c.credential_version=s.credential_version
  WHERE s.verifier_digest=@digest AND p.active=1 AND s.revoked_at IS NULL
  AND s.expires_at>@now AND s.last_seen_at>DATEADD(second,-@idle,@now);
 SELECT (SELECT JSON_QUERY(@input,''$.request'') AS request,
  JSON_QUERY(CASE WHEN @presented IS NULL THEN JSON_QUERY(@input,''$.caller'') ELSE (SELECT N''user'' AS kind,LOWER(CONVERT(varchar(36),r.principal_id)) AS principalId,
   LOWER(CONVERT(varchar(36),r.session_id)) AS sessionId,r.expires_at AS sessionExpiresAt
   FROM @resolved r FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) END) AS caller
  FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) AS value;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END');
GRANT EXECUTE ON OBJECT::[identity].resolve_api_session TO sfx_identity_runtime;
IF OBJECT_ID(N'identity.resolve_api_session',N'P') IS NULL THROW 51000,'RESOLVE_API_SESSION_MISSING',1;
SELECT (SELECT N'010-api-session-digest-base64' AS migration,CONVERT(int,1) AS altered_procedures FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) AS value;
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH
