-- draft emitted by Codelightly; promote through the deployment lifecycle
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF @@TRANCOUNT=0 BEGIN TRANSACTION;
DECLARE @lock int;
EXEC @lock=sys.sp_getapplock @Resource=N'sidefx:model-write',@LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=60000;
IF @lock<0 THROW 51000,N'fv_scenario_port_bindings_LOCK_FAILED',1;
GO
CREATE OR ALTER FUNCTION [analysis].[fv_scenario_port_bindings](@estate_model_pk bigint, @capability_id nvarchar(400), @scenario_id nvarchar(400) = NULL) RETURNS TABLE AS RETURN
WITH newest AS (
  SELECT d.semantic_object_pk, MAX(d.semantic_object_definition_pk) AS newest_sod
  FROM model.estate_definition ed
  JOIN model.semantic_object_definition d ON d.semantic_object_definition_pk = ed.semantic_object_definition_pk
  WHERE ed.estate_model_pk = @estate_model_pk
  GROUP BY d.semantic_object_pk)
SELECT c.capability_id, s.scenario_id, cs.scenario_version_pk,
  eo.ordinal, eo.operation_id, eo.operation_kind,
  p.port_id, p.port_pk, opi.port_version_pk AS linked_port_version_pk,
  pv.semantic_object_definition_pk AS linked_sod, nw.newest_sod AS newest_selected_sod,
  CONVERT(bit, CASE WHEN pv.semantic_object_definition_pk = nw.newest_sod THEN 1 ELSE 0 END) AS linked_is_newest,
  CONVERT(bit, CASE WHEN ed2.semantic_object_definition_pk IS NULL THEN 0 ELSE 1 END) AS linked_selected,
  JSON_VALUE(env.body, '$.semantics.platformCapabilityId') AS platform_capability_id,
  JSON_VALUE(env.body, '$.semantics.configuration.providerId') AS provider_id,
  analysis.fv_definition_label(N'sidefx:providers', JSON_VALUE(env.body, '$.semantics.configuration.providerId')) AS provider_label,
  CONVERT(bit, CASE WHEN JSON_QUERY(env.body, '$.semantics.configuration') IS NOT NULL THEN 1 ELSE 0 END) AS has_configuration,
  JSON_QUERY(env.body, '$.semantics.configuration') AS configuration_json
FROM model.estate_capability ec
JOIN model.capability c ON c.capability_pk = ec.capability_pk
JOIN model.capability_scenario cs ON cs.capability_version_pk = ec.capability_version_pk
JOIN model.scenario s ON s.scenario_pk = cs.scenario_pk
JOIN model.scenario_event se ON se.scenario_version_pk = cs.scenario_version_pk
JOIN model.execution_operation eo ON eo.execution_authority_version_pk = se.execution_authority_version_pk
JOIN model.operation_port_invocation opi ON opi.execution_operation_pk = eo.execution_operation_pk
JOIN model.port_version pv ON pv.port_version_pk = opi.port_version_pk
JOIN model.port p ON p.port_pk = pv.port_pk
JOIN model.semantic_object_definition d ON d.semantic_object_definition_pk = pv.semantic_object_definition_pk
JOIN source.content_object co ON co.content_object_pk = d.canonical_content_pk
LEFT JOIN model.estate_definition ed2 ON ed2.estate_model_pk = @estate_model_pk
  AND ed2.semantic_object_definition_pk = pv.semantic_object_definition_pk
LEFT JOIN newest nw ON nw.semantic_object_pk = p.semantic_object_pk
CROSS APPLY (SELECT CONVERT(nvarchar(max), CONVERT(varchar(max), co.content_bytes)
  COLLATE Latin1_General_100_BIN2_UTF8) AS body) env
WHERE ec.estate_model_pk = @estate_model_pk
  AND c.capability_id = @capability_id
  AND (@scenario_id IS NULL OR s.scenario_id = @scenario_id)
GO
SELECT 'function_installed' AS result_set,
  CONVERT(int, CASE WHEN OBJECT_ID(N'[analysis].[fv_scenario_port_bindings]', N'IF') IS NOT NULL THEN 1 ELSE 0 END) AS installed;
GO
COMMIT TRANSACTION;
