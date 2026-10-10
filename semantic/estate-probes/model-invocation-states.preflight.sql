-- model-invocation-states.preflight.sql
--
-- ============================== PREFLIGHT - NOT AN INSTALL ==============================
-- A verification probe with no commit twin. It ends in ROLLBACK; nothing is written.
-- (SQL Server does not roll back IDENTITY increments, so probe runs leave gaps in pk sequences.)
--
-- WHAT THIS PROVES: analysis.read_capability_model_invocations reports explicit states when the
-- declaration it interprets is wrong. Inside one transaction it puts a deliberately broken
-- generation of request-capability-from-objective-v3/model-invocations.v1 (derived from the
-- installed one with JSON_MODIFY), reads it back, and prints the states:
--   invocation 1  operationId names no operation               -> operation MISSING, sequence UNRESOLVED
--   invocation 2  constructor digest is not the installed body -> SYSTEM_CONSTRUCTOR body STALE
--                 composition names a non-compose operation    -> composition MISMATCH, sequence OUT_OF_ORDER
--   invocation 3  first model path does not exist              -> value PATH_MISSING
--                 first static segment is not in the body      -> NOT_FOUND_IN_BODY
--                 a segment names an undeclared input          -> SEGMENT_INPUT_UNDECLARED
--   templates     the active transformation is listed inactive -> CONFLICTS_WITH_ACTIVE
--
-- Run from sfx-embody with the lifecycle runner:
--   node ../scenario-driven-architecture/languages/typescript/src/kernel/bootstrap/run-migration.mjs ../sfx-dal/semantic/estate-probes/model-invocation-states.preflight.sql
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF @@TRANCOUNT=0 BEGIN TRANSACTION;
DECLARE @lock int;
EXEC @lock=sys.sp_getapplock @Resource=N'sidefx:model-write',@LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=300000;
IF @lock<0 THROW 51000,N'MODEL_INVOCATION_PROBE_LOCK_FAILED',1;
DECLARE @scope nvarchar(400)=N'sidefx:capability:request-capability-from-objective-v3';
DECLARE @estate bigint=(SELECT estate_model_pk FROM source.current_model WHERE singleton_id=1);
DECLARE @installed nvarchar(max)=(SELECT JSON_QUERY(CONVERT(nvarchar(max),CONVERT(varchar(max),co.content_bytes) COLLATE Latin1_General_100_BIN2_UTF8),'$.semantics')
  FROM model.identity_namespace n
  JOIN model.semantic_object so ON so.namespace_pk=n.namespace_pk AND so.object_kind='AUTHORITY' AND so.declared_id=N'model-invocations.v1'
  JOIN model.semantic_object_definition d ON d.semantic_object_pk=so.semantic_object_pk
  JOIN source.content_object co ON co.content_object_pk=d.canonical_content_pk
  WHERE n.namespace_id=@scope
   AND d.semantic_object_definition_pk=(SELECT MAX(d2.semantic_object_definition_pk) FROM model.semantic_object_definition d2
     JOIN model.estate_definition ed ON ed.semantic_object_definition_pk=d2.semantic_object_definition_pk AND ed.estate_model_pk=@estate
     WHERE d2.semantic_object_pk=so.semantic_object_pk));
IF @installed IS NULL THROW 51000,N'MODEL_INVOCATION_PROBE_NO_DECLARATION',1;
DECLARE @s nvarchar(max)=@installed;
SET @s=JSON_MODIFY(@s,'$.invocations[0].operationId',N'request-capability-from-objective-v3.no-such-step');
SET @s=JSON_MODIFY(@s,'$.invocations[1].instruction.constructor.procedure.bodySha256Utf16le',N'0000000000000000000000000000000000000000000000000000000000000000');
SET @s=JSON_MODIFY(@s,'$.invocations[1].model.compositionOperationId',N'request-capability-from-objective-v3.select');
SET @s=JSON_MODIFY(@s,'$.invocations[2].model.values[0].path',N'$.semantics.expression.no.such.path');
SET @s=JSON_MODIFY(@s,'$.invocations[2].instruction.system.segments[0].text',N'This sentence is not in the constructor body.');
SET @s=JSON_MODIFY(@s,'append $.invocations[2].instruction.system.segments',JSON_QUERY(N'{"kind":"input","input":"undeclaredInput"}'));
SET @s=JSON_MODIFY(@s,'append $.inactiveTemplates',JSON_QUERY(N'{"namespace":"sidefx:capability:request-capability-from-objective-v3","kind":"TRANSFORMATION","id":"compose-governed-model-invocation.v1","reason":"probe"}'));
DECLARE @obj bigint,@def bigint,@digest binary(32),@r nvarchar(max);
EXEC model.put_semantic_definition 'AUTHORITY',@scope,N'model-invocations.v1',@s,@obj OUTPUT,@def OUTPUT,@digest OUTPUT;
EXEC analysis.read_capability_model_invocations @capability_id=N'request-capability-from-objective-v3',@estate_model_pk=@estate,@result=@r OUTPUT;
SELECT 'probe_declaration' AS result_set,@def AS probe_definition_pk,JSON_VALUE(@r,'$.model_invocation_summary[0].declaration_definition_pk') AS read_definition_pk,
  JSON_VALUE(@r,'$.model_invocation_summary[0].declaration_state') AS declaration_state,JSON_VALUE(@r,'$.model_invocation_summary[0].resolved_invocations') AS resolved_invocations,
  JSON_VALUE(@r,'$.model_invocation_summary[0].findings') AS findings,JSON_VALUE(@r,'$.model_invocation_summary[0].refusing_findings') AS refusing_findings;
SELECT 'probe_invocations' AS result_set,JSON_VALUE(v.value,'$.invocation_id') AS invocation_id,JSON_VALUE(v.value,'$.operation_state') AS operation_state,
  JSON_VALUE(v.value,'$.composition_link_state') AS composition_link_state,JSON_VALUE(v.value,'$.sequence_state') AS sequence_state
FROM OPENJSON(@r,'$.model_invocations') v ORDER BY CONVERT(int,JSON_VALUE(v.value,'$.invocation_ordinal'));
SELECT 'probe_constructors' AS result_set,JSON_VALUE(v.value,'$.invocation_id') AS invocation_id,JSON_VALUE(v.value,'$.role') AS role,JSON_VALUE(v.value,'$.body_state') AS body_state
FROM OPENJSON(@r,'$.instruction_constructors') v WHERE JSON_VALUE(v.value,'$.body_state')<>N'CURRENT';
SELECT 'probe_segments' AS result_set,JSON_VALUE(v.value,'$.invocation_id') AS invocation_id,JSON_VALUE(v.value,'$.segment_ordinal') AS segment_ordinal,
  JSON_VALUE(v.value,'$.segment_kind') AS segment_kind,JSON_VALUE(v.value,'$.input_name') AS input_name,JSON_VALUE(v.value,'$.corroboration') AS corroboration
FROM OPENJSON(@r,'$.instruction_segments') v WHERE JSON_VALUE(v.value,'$.invocation_id')=N'summarize';
SELECT 'probe_configuration' AS result_set,JSON_VALUE(v.value,'$.invocation_id') AS invocation_id,JSON_VALUE(v.value,'$.value_name') AS value_name,JSON_VALUE(v.value,'$.value_state') AS value_state
FROM OPENJSON(@r,'$.model_configuration') v WHERE JSON_VALUE(v.value,'$.value_state')<>N'RESOLVED';
SELECT 'probe_templates' AS result_set,JSON_VALUE(v.value,'$.declared_id') AS declared_id,JSON_VALUE(v.value,'$.template_state') AS template_state,JSON_VALUE(v.value,'$.active_reference_state') AS active_reference_state
FROM OPENJSON(@r,'$.inactive_templates') v;
SELECT 'probe_findings' AS result_set,JSON_VALUE(v.value,'$.code') AS code,JSON_VALUE(v.value,'$.severity') AS severity,JSON_VALUE(v.value,'$.subject') AS subject
FROM OPENJSON(@r,'$.model_invocation_findings') v ORDER BY CONVERT(int,JSON_VALUE(v.value,'$.finding_ordinal'));
ROLLBACK TRANSACTION;
