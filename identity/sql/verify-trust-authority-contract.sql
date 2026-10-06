-- Runs inside the rollback migration. No principal, run or claim is created.
DECLARE @copy TABLE(policy_digest binary(32),policy_content varbinary(max),evaluator_digest binary(32),evaluator_content varbinary(max));
INSERT @copy EXEC ledger.read_evaluation_authority @pd,@ed;
IF (SELECT COUNT(*) FROM @copy)<>1 OR EXISTS(SELECT 1 FROM @copy WHERE policy_content<>@pb OR evaluator_content<>@eb)
 THROW 51000,'LEDGER_AUTHORITY_READBACK',1;
DELETE @copy;
DECLARE @unknown binary(32)=HASHBYTES('SHA2_256',N'uninstalled fixture authority');
INSERT @copy EXEC ledger.read_evaluation_authority @unknown,@ed;
IF EXISTS(SELECT 1 FROM @copy) THROW 51000,'LEDGER_UNKNOWN_AUTHORITY_ACCEPTED',1;
IF (SELECT COUNT(*) FROM ledger.trust_state WHERE policy_digest=@pd)<>9
 OR (SELECT COUNT(*) FROM ledger.evidence_class WHERE policy_digest=@pd)<>8
 OR (SELECT COUNT(*) FROM ledger.claim_kind WHERE policy_digest=@pd)<>2
 OR (SELECT COUNT(*) FROM ledger.evaluation_rule WHERE policy_digest=@pd)<>2 THROW 51000,'LEDGER_VOCABULARY_COUNTS',1;
IF EXISTS(SELECT 1 FROM ledger.evaluation_rule WHERE policy_digest=@pd AND claim_kind='C2' AND available=1)
 OR EXISTS(SELECT 1 FROM ledger.evaluation_rule WHERE policy_digest=@pd AND target_state<>'OBSERVED') THROW 51000,'LEDGER_UNDECLARED_RELIANCE',1;
IF (SELECT COUNT(*) FROM sys.database_permissions WHERE grantee_principal_id=DATABASE_PRINCIPAL_ID('sfx_ledger_runtime')
 AND class=3 AND major_id=SCHEMA_ID('ledger') AND state='D' AND permission_name IN('SELECT','INSERT','UPDATE','DELETE'))<>4
 THROW 51000,'LEDGER_DIRECT_ACCESS_NOT_DENIED',1;
SELECT N'trust-authority-contract-preflight' AS check_name,CONVERT(bit,1) AS passed,5 AS assertion_groups;
