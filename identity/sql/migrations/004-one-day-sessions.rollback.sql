-- One-day absolute and idle sessions. Existing sessions keep their issued expiry.
-- Policy data only: no schema/procedure change or generated DAL change.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME() <> N'sfx-identity' THROW 51000,'IDENTITY_DATABASE_MISMATCH',1;
BEGIN TRY
BEGIN TRANSACTION;
IF (SELECT COUNT(*) FROM [identity].login_policy WHERE policy_id=1)<>1
 THROW 51000,'IDENTITY_LOGIN_POLICY_REQUIRED',1;
UPDATE [identity].login_policy SET session_seconds=86400,idle_seconds=86400
WHERE policy_id=1 AND (session_seconds<>86400 OR idle_seconds<>86400);
DECLARE @changed int=@@ROWCOUNT;
IF NOT EXISTS(SELECT 1 FROM [identity].login_policy WHERE policy_id=1 AND session_seconds=86400 AND idle_seconds=86400)
 THROW 51000,'IDENTITY_ONE_DAY_POLICY_NOT_APPLIED',1;
SELECT N'one-day-session-policy' AS check_name,@changed AS changed_rows,
 session_seconds,idle_seconds,attempt_seconds,throttle_seconds,account_limit,source_limit
FROM [identity].login_policy WHERE policy_id=1;
ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
