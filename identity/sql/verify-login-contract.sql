-- Database contract preflight only. Test state is rolled back by the migration.
-- Uses a throwaway verifier-shaped value, not a password/authentication claim.
DECLARE @realm nvarchar(128)=N'preflight-'+CONVERT(nvarchar(36),NEWID()),@principal uniqueidentifier,
 @attempt uniqueidentifier,@expires datetimeoffset(7)=DATEADD(second,90,SYSUTCDATETIME()),
 @session_expiry datetimeoffset(7)=DATEADD(second,600,SYSUTCDATETIME()),@token_hash varbinary(32)=CRYPT_GEN_RANDOM(32);
DECLARE @verifier nvarchar(256)=N'$argon2id$v=19$m=19456,t=2,p=1$'+CONVERT(nvarchar(32),CRYPT_GEN_RANDOM(16),2)+N'$'+CONVERT(nvarchar(64),CRYPT_GEN_RANDOM(32),2);
DECLARE @enrolled TABLE(principal_id uniqueidentifier,credential_version bigint);
INSERT @enrolled EXEC [identity].provision_principal_credential @realm,N'PreflightUser',@verifier;
SELECT @principal=principal_id FROM @enrolled;
IF @principal IS NULL THROW 51000,'PREFLIGHT_ENROLLMENT_FAILED',1;
DECLARE @attempts TABLE(attempt_id uniqueidentifier,expires_at datetimeoffset(7),allowed bit);
INSERT @attempts EXEC [identity].begin_authentication_attempt @realm,N' preflightuser ',@realm,@expires;
IF NOT EXISTS(SELECT 1 FROM @attempts WHERE allowed=1) THROW 51000,'PREFLIGHT_ATTEMPT_FAILED',1;
SELECT @attempt=attempt_id FROM @attempts;
DECLARE @principals TABLE(principal_id uniqueidentifier,active bit,security_version bigint,credential_version bigint);
INSERT @principals EXEC [identity].resolve_login_principal @attempt,@realm,N'PREFLIGHTUSER';
IF NOT EXISTS(SELECT 1 FROM @principals WHERE principal_id=@principal AND active=1 AND security_version=1 AND credential_version=1)
 THROW 51000,'PREFLIGHT_PRINCIPAL_FAILED',1;
DECLARE @verifiers TABLE(verifier nvarchar(256));
INSERT @verifiers EXEC [identity].read_password_verifier @attempt,@principal,1;
IF NOT EXISTS(SELECT 1 FROM @verifiers WHERE verifier=@verifier) THROW 51000,'PREFLIGHT_VERIFIER_FAILED',1;
DECLARE @accepted TABLE(accepted bit);
INSERT @accepted EXEC [identity].complete_credential_verification @attempt,@principal,1,1,1;
IF NOT EXISTS(SELECT 1 FROM @accepted WHERE accepted=1) THROW 51000,'PREFLIGHT_VERIFICATION_FAILED',1;
DELETE @accepted;
INSERT @accepted EXEC [identity].complete_credential_verification @attempt,@principal,1,1,1;
IF EXISTS(SELECT 1 FROM @accepted WHERE accepted=1) THROW 51000,'PREFLIGHT_VERIFICATION_REPLAY',1;
DECLARE @sessions TABLE(established bit,session_id uniqueidentifier,principal_id uniqueidentifier,expires_at datetimeoffset(7));
INSERT @sessions EXEC [identity].establish_session @attempt,@principal,1,1,@token_hash,@session_expiry;
IF NOT EXISTS(SELECT 1 FROM @sessions WHERE established=1 AND principal_id=@principal) THROW 51000,'PREFLIGHT_SESSION_FAILED',1;
DELETE @sessions;
INSERT @sessions EXEC [identity].establish_session @attempt,@principal,1,1,@token_hash,@session_expiry;
IF EXISTS(SELECT 1 FROM @sessions WHERE established=1) THROW 51000,'PREFLIGHT_SESSION_REPLAY',1;
DECLARE @valid TABLE(session_id uniqueidentifier,principal_id uniqueidentifier,expires_at datetimeoffset(7));
INSERT @valid EXEC [identity].validate_session @token_hash;
IF (SELECT COUNT(*) FROM @valid)<>1 THROW 51000,'PREFLIGHT_VALIDATION_FAILED',1;
EXEC [identity].revoke_session @token_hash;
DELETE @valid;
INSERT @valid EXEC [identity].validate_session @token_hash;
IF EXISTS(SELECT 1 FROM @valid) THROW 51000,'PREFLIGHT_REVOCATION_FAILED',1;
IF (SELECT COUNT(*) FROM [identity].authentication_audit WHERE principal_id=@principal)<>4 THROW 51000,'PREFLIGHT_AUDIT_FAILED',1;
SELECT N'database-contract-preflight' AS check_name,CONVERT(bit,1) AS passed,CONVERT(int,10) AS assertion_count;

