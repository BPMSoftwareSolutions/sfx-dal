-- Runs inside the rollback twin only. All generated fixture rows are rolled back.
-- Verify SQL persistence/expiry, not password hashing (covered by provider tests).
DECLARE @realm nvarchar(128)=N'one-day-preflight-'+CONVERT(nvarchar(36),NEWID()),
 @principal uniqueidentifier,@attempt uniqueidentifier,@session uniqueidentifier,
 @now datetimeoffset(7)=SYSUTCDATETIME(),@token_hash varbinary(32)=CRYPT_GEN_RANDOM(32);
DECLARE @requested datetimeoffset(7)=DATEADD(day,2,@now),@attempt_expiry datetimeoffset(7)=DATEADD(second,90,@now);
DECLARE @verifier nvarchar(256)=N'$argon2id$v=19$m=19456,t=2,p=1$'+CONVERT(nvarchar(32),CRYPT_GEN_RANDOM(16),2)+N'$'+CONVERT(nvarchar(64),CRYPT_GEN_RANDOM(32),2);
DECLARE @enrolled TABLE(principal_id uniqueidentifier,credential_version bigint);
INSERT @enrolled EXEC [identity].provision_principal_credential @realm,N'PreflightUser',@verifier;
SELECT @principal=principal_id FROM @enrolled;
DECLARE @attempts TABLE(attempt_id uniqueidentifier,expires_at datetimeoffset(7),allowed bit);
INSERT @attempts EXEC [identity].begin_authentication_attempt @realm,N'PreflightUser',@realm,@attempt_expiry;
SELECT @attempt=attempt_id FROM @attempts WHERE allowed=1;
IF @attempt IS NULL THROW 51000,'ONE_DAY_ATTEMPT_FAILED',1;
DECLARE @principals TABLE(principal_id uniqueidentifier,active bit,security_version bigint,credential_version bigint);
INSERT @principals EXEC [identity].resolve_login_principal @attempt,@realm,N'PreflightUser';
DECLARE @accepted TABLE(accepted bit);
INSERT @accepted EXEC [identity].complete_credential_verification @attempt,@principal,1,1,1;
DECLARE @sessions TABLE(established bit,session_id uniqueidentifier,principal_id uniqueidentifier,expires_at datetimeoffset(7));
INSERT @sessions EXEC [identity].establish_session @attempt,@principal,1,1,@token_hash,@requested;
SELECT @session=session_id FROM @sessions WHERE established=1;
IF @session IS NULL THROW 51000,'ONE_DAY_SESSION_FAILED',1;
IF NOT EXISTS(SELECT 1 FROM [identity].session WHERE session_id=@session AND DATEDIFF(second,created_at,expires_at)=86400)
 THROW 51000,'ONE_DAY_EXPIRY_NOT_CLAMPED',1;
DECLARE @valid TABLE(session_id uniqueidentifier,principal_id uniqueidentifier,expires_at datetimeoffset(7));
UPDATE [identity].session SET created_at=DATEADD(hour,-23,SYSUTCDATETIME()),last_seen_at=DATEADD(hour,-23,SYSUTCDATETIME()),expires_at=DATEADD(hour,1,SYSUTCDATETIME()) WHERE session_id=@session;
INSERT @valid EXEC [identity].validate_session @token_hash;
IF (SELECT COUNT(*) FROM @valid)<>1 THROW 51000,'ONE_DAY_SESSION_REJECTED_AT_23_HOURS',1;
DELETE @valid;
UPDATE [identity].session SET last_seen_at=DATEADD(second,-86401,SYSUTCDATETIME()) WHERE session_id=@session;
INSERT @valid EXEC [identity].validate_session @token_hash;
IF EXISTS(SELECT 1 FROM @valid) THROW 51000,'ONE_DAY_IDLE_EXPIRY_NOT_ENFORCED',1;
UPDATE [identity].session SET last_seen_at=SYSUTCDATETIME(),expires_at=DATEADD(second,-1,SYSUTCDATETIME()) WHERE session_id=@session;
INSERT @valid EXEC [identity].validate_session @token_hash;
IF EXISTS(SELECT 1 FROM @valid) THROW 51000,'ONE_DAY_ABSOLUTE_EXPIRY_NOT_ENFORCED',1;
UPDATE [identity].session SET last_seen_at=SYSUTCDATETIME(),expires_at=DATEADD(hour,1,SYSUTCDATETIME()) WHERE session_id=@session;
EXEC [identity].revoke_session @token_hash;
INSERT @valid EXEC [identity].validate_session @token_hash;
IF EXISTS(SELECT 1 FROM @valid) THROW 51000,'ONE_DAY_REVOCATION_NOT_ENFORCED',1;
SELECT N'one-day-session-contract' AS check_name,CONVERT(bit,1) AS passed,
 N'86400-second cap; valid after 23h idle; reject after 24h idle; reject absolute expiry; reject revocation' AS assertions;
