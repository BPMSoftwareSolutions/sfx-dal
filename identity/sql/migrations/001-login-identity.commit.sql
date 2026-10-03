-- sfx-identity only. No estate rows or SDA Kernel changes.
-- Own transaction; the runner must not add an outer transaction.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME() <> N'sfx-identity' THROW 51000, 'IDENTITY_DATABASE_MISMATCH', 1;
IF @@TRANCOUNT <> 0 THROW 51000, 'IDENTITY_MIGRATION_REQUIRES_NO_OUTER_TRANSACTION', 1;
BEGIN TRANSACTION;
BEGIN TRY
IF SCHEMA_ID(N'identity') IS NULL EXEC(N'CREATE SCHEMA [identity] AUTHORIZATION dbo;');
IF OBJECT_ID(N'identity.login_policy',N'U') IS NULL
CREATE TABLE [identity].login_policy(
 policy_id tinyint NOT NULL CONSTRAINT PK_identity_login_policy PRIMARY KEY CHECK(policy_id=1),
 attempt_seconds int NOT NULL CHECK(attempt_seconds BETWEEN 1 AND 600),
 session_seconds int NOT NULL CHECK(session_seconds BETWEEN 1 AND 86400),
 idle_seconds int NOT NULL CHECK(idle_seconds BETWEEN 1 AND 86400),
 throttle_seconds int NOT NULL CHECK(throttle_seconds BETWEEN 1 AND 3600),
 account_limit int NOT NULL CHECK(account_limit BETWEEN 1 AND 1000),
 source_limit int NOT NULL CHECK(source_limit BETWEEN 1 AND 10000));
IF NOT EXISTS(SELECT 1 FROM [identity].login_policy WHERE policy_id=1)
INSERT [identity].login_policy VALUES(1,120,1800,900,300,5,25);
IF OBJECT_ID(N'identity.principal',N'U') IS NULL
CREATE TABLE [identity].principal(
 principal_id uniqueidentifier NOT NULL CONSTRAINT PK_identity_principal PRIMARY KEY,
 realm nvarchar(128) COLLATE Latin1_General_100_CI_AS NOT NULL,
 identifier nvarchar(254) COLLATE Latin1_General_100_CI_AS NOT NULL,
 normalized_identifier AS LOWER(LTRIM(RTRIM(identifier))) PERSISTED,
 active bit NOT NULL, security_version bigint NOT NULL CHECK(security_version>0),
 created_at datetimeoffset(7) NOT NULL,
 CONSTRAINT UQ_identity_principal_identifier UNIQUE(realm,normalized_identifier));
IF OBJECT_ID(N'identity.password_credential',N'U') IS NULL
CREATE TABLE [identity].password_credential(
 principal_id uniqueidentifier NOT NULL CONSTRAINT PK_identity_password_credential PRIMARY KEY
 CONSTRAINT FK_identity_credential_principal REFERENCES [identity].principal(principal_id),
 verifier nvarchar(256) NOT NULL, credential_version bigint NOT NULL CHECK(credential_version>0),
 updated_at datetimeoffset(7) NOT NULL);
IF OBJECT_ID(N'identity.authentication_attempt',N'U') IS NULL
CREATE TABLE [identity].authentication_attempt(
 attempt_id uniqueidentifier NOT NULL CONSTRAINT PK_identity_authentication_attempt PRIMARY KEY,
 realm nvarchar(128) COLLATE Latin1_General_100_CI_AS NOT NULL,
 normalized_identifier nvarchar(254) COLLATE Latin1_General_100_CI_AS NOT NULL,
 principal_id uniqueidentifier NULL CONSTRAINT FK_identity_attempt_principal REFERENCES [identity].principal(principal_id),
 security_version bigint NULL, credential_version bigint NULL,
 state tinyint NOT NULL CHECK(state BETWEEN 0 AND 4),
 created_at datetimeoffset(7) NOT NULL, expires_at datetimeoffset(7) NOT NULL);
IF OBJECT_ID(N'identity.authentication_throttle',N'U') IS NULL
CREATE TABLE [identity].authentication_throttle(
 scope tinyint NOT NULL CHECK(scope IN (1,2)), key_hash binary(32) NOT NULL,
 window_start datetimeoffset(7) NOT NULL, attempt_count int NOT NULL CHECK(attempt_count>=0),
 CONSTRAINT PK_identity_authentication_throttle PRIMARY KEY(scope,key_hash));
IF OBJECT_ID(N'identity.session',N'U') IS NULL
CREATE TABLE [identity].session(
 session_id uniqueidentifier NOT NULL CONSTRAINT PK_identity_session PRIMARY KEY,
 principal_id uniqueidentifier NOT NULL CONSTRAINT FK_identity_session_principal REFERENCES [identity].principal(principal_id),
 attempt_id uniqueidentifier NOT NULL CONSTRAINT FK_identity_session_attempt REFERENCES [identity].authentication_attempt(attempt_id),
 security_version bigint NOT NULL, credential_version bigint NOT NULL,
 verifier_hash binary(32) NOT NULL,
 created_at datetimeoffset(7) NOT NULL, expires_at datetimeoffset(7) NOT NULL,
 last_seen_at datetimeoffset(7) NOT NULL, revoked_at datetimeoffset(7) NULL,
 CONSTRAINT UQ_identity_session_attempt UNIQUE(attempt_id),
 CONSTRAINT UQ_identity_session_verifier UNIQUE(verifier_hash));
IF OBJECT_ID(N'identity.authentication_audit',N'U') IS NULL
CREATE TABLE [identity].authentication_audit(
 audit_id bigint IDENTITY NOT NULL CONSTRAINT PK_identity_authentication_audit PRIMARY KEY,
 attempt_id uniqueidentifier NULL CONSTRAINT FK_identity_audit_attempt REFERENCES [identity].authentication_attempt(attempt_id),
 principal_id uniqueidentifier NULL CONSTRAINT FK_identity_audit_principal REFERENCES [identity].principal(principal_id),
 event_kind varchar(32) NOT NULL CHECK(event_kind IN ('credential_accepted','credential_rejected','session_established','session_revoked','credential_provisioned','throttled')),
 occurred_at datetimeoffset(7) NOT NULL);
EXEC(N'CREATE OR ALTER PROCEDURE [identity].[begin_authentication_attempt]
 @realm nvarchar(128), @identifier nvarchar(254), @source_key nvarchar(256), @expires_at datetimeoffset(7)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit = CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 DECLARE @now datetimeoffset(7)=SYSUTCDATETIME(), @attempt_id uniqueidentifier=NEWID(), @allowed bit=0;
 DECLARE @window int,@account_limit int,@source_limit int,@attempt_seconds int;
 SELECT @window=throttle_seconds,@account_limit=account_limit,@source_limit=source_limit,@attempt_seconds=attempt_seconds
 FROM [identity].login_policy WHERE policy_id=1;
 IF @realm IS NULL OR LEN(LTRIM(RTRIM(@realm)))=0 OR @identifier IS NULL OR LEN(LTRIM(RTRIM(@identifier)))=0
 OR @source_key IS NULL OR LEN(@source_key)=0 OR @expires_at IS NULL OR @expires_at<=@now OR @window IS NULL
 THROW 51000,''IDENTITY_INPUT_INVALID'',1;
 SET @identifier=LOWER(LTRIM(RTRIM(@identifier)));
 IF @expires_at>DATEADD(second,@attempt_seconds,@now) SET @expires_at=DATEADD(second,@attempt_seconds,@now);
 -- Account key normalization matches the case-insensitive unique realm/identifier index.
 DECLARE @known_principal uniqueidentifier;
 SELECT @known_principal=principal_id FROM [identity].principal
 WHERE realm=@realm AND normalized_identifier=@identifier;
 DECLARE @account binary(32)=HASHBYTES(''SHA2_256'',CASE WHEN @known_principal IS NOT NULL
 THEN CONVERT(nvarchar(36),@known_principal)
 ELSE CONCAT(LEN(RTRIM(@realm)),N'':'',LOWER(RTRIM(@realm)),N'':'',@identifier) END);
 DECLARE @source binary(32)=HASHBYTES(''SHA2_256'',@source_key),@lock_result int;
 -- Stable account-then-source lock order; transaction-owned locks cover absent-row inserts.
 DECLARE @account_lock nvarchar(255)=N''identity-account-''+CONVERT(varchar(64),@account,2),
 @source_lock nvarchar(255)=N''identity-source-''+CONVERT(varchar(64),@source,2);
 EXEC @lock_result=sys.sp_getapplock @Resource=@account_lock,@LockMode=''Exclusive'',@LockOwner=''Transaction'',@LockTimeout=5000 WITH RESULT SETS NONE;
 IF @lock_result<0 THROW 51000,''IDENTITY_BUSY'',1;
 EXEC @lock_result=sys.sp_getapplock @Resource=@source_lock,@LockMode=''Exclusive'',@LockOwner=''Transaction'',@LockTimeout=5000 WITH RESULT SETS NONE;
 IF @lock_result<0 THROW 51000,''IDENTITY_BUSY'',1;
 IF NOT EXISTS(SELECT 1 FROM [identity].authentication_throttle WHERE scope=1 AND key_hash=@account)
 INSERT [identity].authentication_throttle VALUES(1,@account,@now,0);
 IF NOT EXISTS(SELECT 1 FROM [identity].authentication_throttle WHERE scope=2 AND key_hash=@source)
 INSERT [identity].authentication_throttle VALUES(2,@source,@now,0);
 UPDATE [identity].authentication_throttle SET window_start=@now,attempt_count=0
 WHERE ((scope=1 AND key_hash=@account) OR (scope=2 AND key_hash=@source)) AND window_start<=DATEADD(second,-@window,@now);
 IF EXISTS(SELECT 1 FROM [identity].authentication_throttle WHERE scope=1 AND key_hash=@account AND attempt_count<@account_limit)
 AND EXISTS(SELECT 1 FROM [identity].authentication_throttle WHERE scope=2 AND key_hash=@source AND attempt_count<@source_limit)
 BEGIN
  SET @allowed=1;
  UPDATE [identity].authentication_throttle SET attempt_count=attempt_count+1 WHERE (scope=1 AND key_hash=@account) OR (scope=2 AND key_hash=@source);
  INSERT [identity].authentication_attempt(attempt_id,realm,normalized_identifier,state,created_at,expires_at)
  VALUES(@attempt_id,@realm,@identifier,0,@now,@expires_at);
 END
 ELSE INSERT [identity].authentication_audit(attempt_id,principal_id,event_kind,occurred_at) VALUES(NULL,NULL,''throttled'',@now);
 SELECT @attempt_id AS attempt_id,@expires_at AS expires_at,@allowed AS allowed;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END;');

EXEC(N'CREATE OR ALTER PROCEDURE [identity].[resolve_login_principal]
 @attempt_id uniqueidentifier,@realm nvarchar(128),@identifier nvarchar(254)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit = CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 DECLARE @principal_id uniqueidentifier,@active bit,@security_version bigint,@credential_version bigint;
 IF EXISTS(SELECT 1 FROM [identity].authentication_attempt WITH(UPDLOCK,HOLDLOCK)
 WHERE attempt_id=@attempt_id AND state=0 AND expires_at>SYSUTCDATETIME()
 AND realm=@realm AND normalized_identifier=LOWER(LTRIM(RTRIM(@identifier))))
 BEGIN
  SELECT @principal_id=p.principal_id,@active=p.active,@security_version=p.security_version,@credential_version=ISNULL(c.credential_version,0)
  FROM [identity].principal p LEFT JOIN [identity].password_credential c ON c.principal_id=p.principal_id
  WHERE p.realm=@realm AND p.normalized_identifier=LOWER(LTRIM(RTRIM(@identifier)));
  UPDATE [identity].authentication_attempt SET state=1,principal_id=@principal_id,security_version=@security_version,credential_version=@credential_version
  WHERE attempt_id=@attempt_id;
 END
 SELECT @principal_id AS principal_id,@active AS active,@security_version AS security_version,@credential_version AS credential_version
 WHERE @principal_id IS NOT NULL;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END;');

EXEC(N'CREATE OR ALTER PROCEDURE [identity].[read_password_verifier]
 @attempt_id uniqueidentifier,@principal_id uniqueidentifier,@credential_version bigint
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit = CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 SELECT c.verifier FROM [identity].authentication_attempt a
 JOIN [identity].principal p ON p.principal_id=a.principal_id AND p.security_version=a.security_version
 JOIN [identity].password_credential c ON c.principal_id=p.principal_id AND c.credential_version=a.credential_version
 WHERE a.attempt_id=@attempt_id AND a.principal_id=@principal_id AND c.credential_version=@credential_version
 AND a.state=1 AND a.expires_at>SYSUTCDATETIME();
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END;');

EXEC(N'CREATE OR ALTER PROCEDURE [identity].[complete_credential_verification]
 @attempt_id uniqueidentifier,@principal_id uniqueidentifier=NULL,@security_version bigint=NULL,@credential_version bigint=NULL,@matched bit=0
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit = CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 DECLARE @accepted bit=0,@actual_principal uniqueidentifier;
 IF EXISTS(SELECT 1 FROM [identity].authentication_attempt WITH(UPDLOCK,HOLDLOCK) WHERE attempt_id=@attempt_id AND state=1)
 BEGIN
  SELECT @actual_principal=principal_id FROM [identity].authentication_attempt WHERE attempt_id=@attempt_id;
  IF @matched=1 AND EXISTS(
   SELECT 1 FROM [identity].authentication_attempt a
   JOIN [identity].principal p ON p.principal_id=a.principal_id AND p.security_version=a.security_version
   JOIN [identity].password_credential c ON c.principal_id=p.principal_id AND c.credential_version=a.credential_version
   WHERE a.attempt_id=@attempt_id AND p.principal_id=@principal_id AND p.active=1
   AND p.security_version=@security_version AND c.credential_version=@credential_version AND a.expires_at>SYSUTCDATETIME())
  SET @accepted=1;
  UPDATE [identity].authentication_attempt SET state=CASE WHEN @accepted=1 THEN 2 ELSE 3 END WHERE attempt_id=@attempt_id;
  INSERT [identity].authentication_audit(attempt_id,principal_id,event_kind,occurred_at)
  VALUES(@attempt_id,@actual_principal,CASE WHEN @accepted=1 THEN ''credential_accepted'' ELSE ''credential_rejected'' END,SYSUTCDATETIME());
 END
 SELECT @accepted AS accepted;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END;');

EXEC(N'CREATE OR ALTER PROCEDURE [identity].[establish_session]
 @attempt_id uniqueidentifier,@principal_id uniqueidentifier,@security_version bigint,@credential_version bigint,@verifier_hash varbinary(32),@expires_at datetimeoffset(7)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit = CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 DECLARE @now datetimeoffset(7)=SYSUTCDATETIME(),@session_id uniqueidentifier=NULL,@established bit=0,@lifetime int;
 SELECT @lifetime=session_seconds FROM [identity].login_policy WHERE policy_id=1;
 IF @verifier_hash IS NULL OR DATALENGTH(@verifier_hash)<>32 OR @expires_at IS NULL OR @expires_at<=@now OR @lifetime IS NULL
 THROW 51000,''IDENTITY_INPUT_INVALID'',1;
 IF @expires_at>DATEADD(second,@lifetime,@now) SET @expires_at=DATEADD(second,@lifetime,@now);
 IF EXISTS(SELECT 1 FROM [identity].authentication_attempt WITH(UPDLOCK,HOLDLOCK) WHERE attempt_id=@attempt_id AND state=2 AND expires_at>@now)
 AND EXISTS(SELECT 1 FROM [identity].authentication_attempt a
 JOIN [identity].principal p WITH(UPDLOCK,HOLDLOCK) ON p.principal_id=a.principal_id AND p.security_version=a.security_version
 JOIN [identity].password_credential c WITH(UPDLOCK,HOLDLOCK) ON c.principal_id=p.principal_id AND c.credential_version=a.credential_version
 WHERE a.attempt_id=@attempt_id AND p.principal_id=@principal_id AND p.active=1
 AND p.security_version=@security_version AND c.credential_version=@credential_version)
 BEGIN
  SET @session_id=NEWID();
  INSERT [identity].session(session_id,principal_id,attempt_id,security_version,credential_version,verifier_hash,created_at,expires_at,last_seen_at)
  VALUES(@session_id,@principal_id,@attempt_id,@security_version,@credential_version,@verifier_hash,@now,@expires_at,@now);
  UPDATE [identity].authentication_attempt SET state=4 WHERE attempt_id=@attempt_id;
  INSERT [identity].authentication_audit(attempt_id,principal_id,event_kind,occurred_at) VALUES(@attempt_id,@principal_id,''session_established'',@now);
  SET @established=1;
 END
 SELECT @established AS established,@session_id AS session_id,
 CASE WHEN @established=1 THEN @principal_id END AS principal_id,
 CASE WHEN @established=1 THEN @expires_at END AS expires_at;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END;');

EXEC(N'CREATE OR ALTER PROCEDURE [identity].[validate_session]
 @verifier_hash varbinary(32)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit = CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 DECLARE @now datetimeoffset(7)=SYSUTCDATETIME(),@idle int;
 SELECT @idle=idle_seconds FROM [identity].login_policy WHERE policy_id=1;
 DECLARE @validated TABLE(session_id uniqueidentifier,principal_id uniqueidentifier,expires_at datetimeoffset(7));
 UPDATE s WITH(UPDLOCK) SET last_seen_at=@now
 OUTPUT inserted.session_id,inserted.principal_id,inserted.expires_at INTO @validated
 FROM [identity].session s
 JOIN [identity].principal p WITH(HOLDLOCK) ON p.principal_id=s.principal_id AND p.security_version=s.security_version
 JOIN [identity].password_credential c WITH(HOLDLOCK) ON c.principal_id=s.principal_id AND c.credential_version=s.credential_version
 WHERE DATALENGTH(@verifier_hash)=32 AND s.verifier_hash=@verifier_hash AND p.active=1 AND s.revoked_at IS NULL
 AND s.expires_at>@now AND s.last_seen_at>DATEADD(second,-@idle,@now);
 SELECT session_id,principal_id,expires_at FROM @validated;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END;');

EXEC(N'CREATE OR ALTER PROCEDURE [identity].[revoke_session]
 @verifier_hash varbinary(32)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit = CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 DECLARE @now datetimeoffset(7)=SYSUTCDATETIME();
 DECLARE @revoked TABLE(attempt_id uniqueidentifier,principal_id uniqueidentifier);
 UPDATE [identity].session SET revoked_at=@now
 OUTPUT inserted.attempt_id,inserted.principal_id INTO @revoked
 WHERE DATALENGTH(@verifier_hash)=32 AND verifier_hash=@verifier_hash AND revoked_at IS NULL;
 INSERT [identity].authentication_audit(attempt_id,principal_id,event_kind,occurred_at)
 SELECT attempt_id,principal_id,''session_revoked'',@now FROM @revoked;
 SELECT CONVERT(bit,1) AS revoked;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END;');

EXEC(N'CREATE OR ALTER PROCEDURE [identity].[provision_principal_credential]
 @realm nvarchar(128),@identifier nvarchar(254),@verifier nvarchar(256)
AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 DECLARE @owns_transaction bit = CASE WHEN @@TRANCOUNT=0 THEN 1 ELSE 0 END;
 IF @owns_transaction=1 BEGIN TRANSACTION;
 BEGIN TRY

 IF @realm IS NULL OR LEN(LTRIM(RTRIM(@realm)))=0 OR @identifier IS NULL OR LEN(LTRIM(RTRIM(@identifier)))=0
 OR @verifier IS NULL OR @verifier NOT LIKE N''$argon2id$v=19$m=19456,t=2,p=1$%$%'' OR LEN(@verifier)<80
 THROW 51000,''IDENTITY_INPUT_INVALID'',1;
 DECLARE @now datetimeoffset(7)=SYSUTCDATETIME(),@principal_id uniqueidentifier=NEWID();
 -- Enrollment creates only; changing credentials requires a separately reviewed rotation operation.
 INSERT [identity].principal(principal_id,realm,identifier,active,security_version,created_at) VALUES(@principal_id,@realm,@identifier,1,1,@now);
 INSERT [identity].password_credential(principal_id,verifier,credential_version,updated_at) VALUES(@principal_id,@verifier,1,@now);
 INSERT [identity].authentication_audit(attempt_id,principal_id,event_kind,occurred_at) VALUES(NULL,@principal_id,''credential_provisioned'',@now);
 SELECT @principal_id AS principal_id,CONVERT(bigint,1) AS credential_version;
 IF @owns_transaction=1 COMMIT TRANSACTION;
 END TRY
 BEGIN CATCH
  IF @owns_transaction=1 AND XACT_STATE()<>0 ROLLBACK TRANSACTION;
  THROW;
 END CATCH
END;');

IF DATABASE_PRINCIPAL_ID(N'sfx_identity_runtime') IS NULL CREATE ROLE sfx_identity_runtime AUTHORIZATION dbo;
IF DATABASE_PRINCIPAL_ID(N'sfx_identity_enrollment') IS NULL CREATE ROLE sfx_identity_enrollment AUTHORIZATION dbo;
DENY SELECT,INSERT,UPDATE,DELETE ON SCHEMA::[identity] TO sfx_identity_runtime;
DENY SELECT,INSERT,UPDATE,DELETE ON SCHEMA::[identity] TO sfx_identity_enrollment;
DENY EXECUTE ON OBJECT::[identity].provision_principal_credential TO sfx_identity_runtime;
GRANT EXECUTE ON OBJECT::[identity].provision_principal_credential TO sfx_identity_enrollment;
GRANT EXECUTE ON OBJECT::[identity].begin_authentication_attempt TO sfx_identity_runtime;
GRANT EXECUTE ON OBJECT::[identity].resolve_login_principal TO sfx_identity_runtime;
GRANT EXECUTE ON OBJECT::[identity].read_password_verifier TO sfx_identity_runtime;
GRANT EXECUTE ON OBJECT::[identity].complete_credential_verification TO sfx_identity_runtime;
GRANT EXECUTE ON OBJECT::[identity].establish_session TO sfx_identity_runtime;
GRANT EXECUTE ON OBJECT::[identity].validate_session TO sfx_identity_runtime;
GRANT EXECUTE ON OBJECT::[identity].revoke_session TO sfx_identity_runtime;
IF (SELECT COUNT(*) FROM sys.tables WHERE schema_id=SCHEMA_ID(N'identity'))<>7 THROW 51000,'IDENTITY_TABLE_COUNT_MISMATCH',1;
IF (SELECT COUNT(*) FROM sys.procedures WHERE schema_id=SCHEMA_ID(N'identity'))<>8 THROW 51000,'IDENTITY_PROCEDURE_COUNT_MISMATCH',1;
IF EXISTS(SELECT 1 FROM sys.foreign_keys WHERE schema_id=SCHEMA_ID(N'identity') AND (is_disabled=1 OR is_not_trusted=1)) THROW 51000,'IDENTITY_FOREIGN_KEY_INVALID',1;
SELECT DB_NAME() AS database_name,
 (SELECT COUNT(*) FROM sys.tables WHERE schema_id=SCHEMA_ID(N'identity')) AS table_count,
 (SELECT COUNT(*) FROM sys.procedures WHERE schema_id=SCHEMA_ID(N'identity')) AS procedure_count;

COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;

