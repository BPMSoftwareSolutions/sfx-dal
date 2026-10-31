-- API sign-in for the declared API (sfx-api open-api-session). Two procedures wrap the five login
-- procedures of 001 unchanged, so the estate's sign-in program sends sfx-identity only what is not a
-- secret: the realm, the identifier and the source to begin, then the attempt, the match and the new
-- bearer's SHA-256 to complete. The password and the stored verifier meet only inside that program.
--
-- begin_api_login(@input {realm, identifier, sourceKey}): begin_authentication_attempt (the throttle),
-- resolve_login_principal and read_password_verifier, answering one row: attemptId, allowed, and the
-- salt and expected tag of the verifier as base64. A verifier that cannot be checked (throttled, an
-- unknown principal, no credential, or not argon2id m=19456,t=2,p=1 with a 16-byte salt and a 32-byte
-- tag) answers a random salt and tag, so the program always derives once and never matches.
--
-- complete_api_login(@attempt_id, @allowed, @equals, @verifier_hash): THROTTLED when the attempt was
-- not allowed; otherwise complete_credential_verification with the match, and establish_session for
-- an accepted credential with the policy's session lifetime. One row: disposition (AUTHENTICATED or
-- AUTHENTICATION_REJECTED), sessionId, principalId and expiresAt, empty when no session was established.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME()<>N'sfx-identity' THROW 51000,'IDENTITY_DATABASE_MISMATCH',1;
IF @@TRANCOUNT<>0 THROW 51000,'IDENTITY_MIGRATION_REQUIRES_NO_OUTER_TRANSACTION',1;
BEGIN TRANSACTION;
BEGIN TRY
IF OBJECT_ID(N'identity.begin_authentication_attempt',N'P') IS NULL OR OBJECT_ID(N'identity.establish_session',N'P') IS NULL
 THROW 51000,'IDENTITY_LOGIN_PROCEDURES_MISSING',1;
EXEC(N'CREATE OR ALTER PROCEDURE [identity].[begin_api_login]
 @input nvarchar(max)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @realm nvarchar(128)=JSON_VALUE(@input,''$.realm''),@identifier nvarchar(254)=JSON_VALUE(@input,''$.identifier''),
  @source_key nvarchar(256)=JSON_VALUE(@input,''$.sourceKey''),@attempt_seconds int;
 SELECT @attempt_seconds=attempt_seconds FROM [identity].login_policy WHERE policy_id=1;
 DECLARE @expires datetimeoffset(7)=DATEADD(second,@attempt_seconds,SYSUTCDATETIME());
 DECLARE @begun TABLE(attempt_id uniqueidentifier,expires_at datetimeoffset(7),allowed bit);
 INSERT @begun EXEC [identity].begin_authentication_attempt @realm=@realm,@identifier=@identifier,@source_key=@source_key,@expires_at=@expires;
 DECLARE @attempt uniqueidentifier,@allowed bit;
 SELECT @attempt=attempt_id,@allowed=allowed FROM @begun;
 DECLARE @principal TABLE(principal_id uniqueidentifier,active bit,security_version bigint,credential_version bigint);
 IF @allowed=1
  INSERT @principal EXEC [identity].resolve_login_principal @attempt_id=@attempt,@realm=@realm,@identifier=@identifier;
 DECLARE @principal_id uniqueidentifier,@credential_version bigint;
 SELECT @principal_id=principal_id,@credential_version=credential_version FROM @principal;
 DECLARE @stored TABLE(verifier nvarchar(256));
 IF @principal_id IS NOT NULL
  INSERT @stored EXEC [identity].read_password_verifier @attempt_id=@attempt,@principal_id=@principal_id,@credential_version=@credential_version;
 DECLARE @verifier nvarchar(256)=(SELECT TOP (1) verifier FROM @stored),@prefix nvarchar(64)=N''$argon2id$v=19$m=19456,t=2,p=1$'';
 DECLARE @rest nvarchar(256)=CASE WHEN LEFT(@verifier,LEN(@prefix))=@prefix COLLATE Latin1_General_100_BIN2 THEN SUBSTRING(@verifier,LEN(@prefix)+1,256) END;
 DECLARE @cut int=CHARINDEX(N''$'',@rest);
 DECLARE @salt_text nvarchar(128)=CASE WHEN @cut>1 THEN LEFT(@rest,@cut-1) END,@tag_text nvarchar(128)=CASE WHEN @cut>1 THEN SUBSTRING(@rest,@cut+1,128) END;
 IF @salt_text LIKE N''%[^A-Za-z0-9+/]%'' COLLATE Latin1_General_100_BIN2 OR @tag_text LIKE N''%[^A-Za-z0-9+/]%'' COLLATE Latin1_General_100_BIN2
  SELECT @salt_text=NULL,@tag_text=NULL;
 SELECT @salt_text=@salt_text+REPLICATE(N''='',(4-LEN(@salt_text)%4)%4),@tag_text=@tag_text+REPLICATE(N''='',(4-LEN(@tag_text)%4)%4);
 DECLARE @salt varbinary(64)=CAST(N'''' AS xml).value(''xs:base64Binary(sql:variable("@salt_text"))'',''varbinary(64)''),
  @tag varbinary(64)=CAST(N'''' AS xml).value(''xs:base64Binary(sql:variable("@tag_text"))'',''varbinary(64)'');
 IF NOT (ISNULL(DATALENGTH(@salt),0)=16 AND ISNULL(DATALENGTH(@tag),0)=32 AND ISNULL(@allowed,0)=1)
  SELECT @salt=CRYPT_GEN_RANDOM(16),@tag=CRYPT_GEN_RANDOM(32);
 SELECT LOWER(CONVERT(varchar(36),@attempt)) AS attemptId,ISNULL(@allowed,0) AS allowed,
  CAST(N'''' AS xml).value(''xs:base64Binary(sql:variable("@salt"))'',''varchar(64)'') AS salt,
  CAST(N'''' AS xml).value(''xs:base64Binary(sql:variable("@tag"))'',''varchar(64)'') AS expected;
END');
EXEC(N'CREATE OR ALTER PROCEDURE [identity].[complete_api_login]
 @attempt_id uniqueidentifier,@allowed bit,@equals bit,@verifier_hash varbinary(32)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @principal_id uniqueidentifier,@security_version bigint,@credential_version bigint,@session_seconds int;
 SELECT @principal_id=principal_id,@security_version=security_version,@credential_version=credential_version
 FROM [identity].authentication_attempt WHERE attempt_id=@attempt_id;
 SELECT @session_seconds=session_seconds FROM [identity].login_policy WHERE policy_id=1;
 DECLARE @accepted TABLE(accepted bit);
 IF @allowed=1
  INSERT @accepted EXEC [identity].complete_credential_verification @attempt_id=@attempt_id,@principal_id=@principal_id,
   @security_version=@security_version,@credential_version=@credential_version,@matched=@equals;
 DECLARE @established TABLE(established bit,session_id uniqueidentifier,principal_id uniqueidentifier,expires_at datetimeoffset(7));
 IF EXISTS(SELECT 1 FROM @accepted WHERE accepted=1)
 BEGIN
  DECLARE @expires datetimeoffset(7)=DATEADD(second,@session_seconds,SYSUTCDATETIME());
  INSERT @established EXEC [identity].establish_session @attempt_id=@attempt_id,@principal_id=@principal_id,
   @security_version=@security_version,@credential_version=@credential_version,@verifier_hash=@verifier_hash,@expires_at=@expires;
 END
 SELECT CASE WHEN ISNULL(@allowed,0)=0 THEN N''THROTTLED''
   WHEN EXISTS(SELECT 1 FROM @established WHERE established=1) THEN N''AUTHENTICATED'' ELSE N''AUTHENTICATION_REJECTED'' END AS disposition,
  ISNULL((SELECT TOP (1) LOWER(CONVERT(varchar(36),session_id)) FROM @established WHERE established=1),'''') AS sessionId,
  ISNULL((SELECT TOP (1) LOWER(CONVERT(varchar(36),principal_id)) FROM @established WHERE established=1),'''') AS principalId,
  ISNULL((SELECT TOP (1) CONVERT(varchar(40),expires_at,127) FROM @established WHERE established=1),'''') AS expiresAt;
END');
IF DATABASE_PRINCIPAL_ID(N'sfx_identity_runtime') IS NULL CREATE ROLE sfx_identity_runtime AUTHORIZATION dbo;
GRANT EXECUTE ON OBJECT::[identity].begin_api_login TO sfx_identity_runtime;
GRANT EXECUTE ON OBJECT::[identity].complete_api_login TO sfx_identity_runtime;
IF OBJECT_ID(N'identity.begin_api_login',N'P') IS NULL OR OBJECT_ID(N'identity.complete_api_login',N'P') IS NULL
 THROW 51000,'API_LOGIN_PROCEDURES_MISSING',1;
SELECT (SELECT N'011-api-login' AS migration,CONVERT(int,2) AS added_procedures FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) AS value;
COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH
