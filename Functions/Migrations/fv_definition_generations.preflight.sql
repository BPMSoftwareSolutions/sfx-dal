-- draft emitted by Codelightly; promote through the deployment lifecycle
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF @@TRANCOUNT=0 BEGIN TRANSACTION;
DECLARE @lock int;
EXEC @lock=sys.sp_getapplock @Resource=N'sidefx:model-write',@LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=60000;
IF @lock<0 THROW 51000,N'fv_definition_generations_LOCK_FAILED',1;
GO
CREATE OR ALTER FUNCTION [analysis].[fv_definition_generations](@estate_model_pk bigint, @namespace_id nvarchar(400) = NULL, @object_kind varchar(64), @declared_id nvarchar(400)) RETURNS TABLE AS RETURN
WITH base AS (
  SELECT g.semantic_object_pk, g.namespace_id, g.declared_id, g.selection_source,
         g.newest_selected_sod, g.selected_generation_count, g.total_generation_count,
         g.typed_version_pk AS newest_typed_version_pk, g.typed_row_present, g.newest_sod_with_typed
  FROM analysis.fv_selected_definition(@estate_model_pk, @object_kind, @declared_id, @namespace_id) g
  WHERE @namespace_id IS NULL OR g.namespace_id = @namespace_id COLLATE Latin1_General_100_BIN2),
typed AS (
  SELECT CAST('TRANSFORMATION' AS varchar(64)) AS object_kind, semantic_object_pk, semantic_object_definition_pk AS sod, transformation_version_pk AS version_pk FROM model.transformation_version
  UNION ALL SELECT 'PORT',       semantic_object_pk, semantic_object_definition_pk, port_version_pk        FROM model.port_version
  UNION ALL SELECT 'SCENARIO',   semantic_object_pk, semantic_object_definition_pk, scenario_version_pk    FROM model.scenario_version
  UNION ALL SELECT 'CAPABILITY', semantic_object_pk, semantic_object_definition_pk, capability_version_pk  FROM model.capability_version
  UNION ALL SELECT 'PROVIDER',   semantic_object_pk, semantic_object_definition_pk, provider_definition_pk FROM model.provider_definition
  UNION ALL SELECT 'CONTRACT',   semantic_object_pk, semantic_object_definition_pk, contract_version_pk    FROM model.contract_version),
gens AS (
  SELECT b.semantic_object_pk, b.namespace_id, b.declared_id, b.selection_source,
         b.newest_selected_sod, b.selected_generation_count, b.total_generation_count,
         b.newest_typed_version_pk, b.typed_row_present, b.newest_sod_with_typed,
         d.semantic_object_definition_pk, d.definition_digest, d.canonical_content_pk,
         ROW_NUMBER() OVER (PARTITION BY b.semantic_object_pk ORDER BY d.semantic_object_definition_pk) AS generation_ordinal,
         CONVERT(bit, CASE WHEN d.semantic_object_definition_pk = b.newest_selected_sod THEN 1 ELSE 0 END) AS selected_is_newest,
         CONVERT(bit, CASE WHEN @object_kind = 'CAPABILITY'
             THEN CASE WHEN d.semantic_object_definition_pk = b.newest_selected_sod THEN 1 ELSE 0 END
             WHEN EXISTS (SELECT 1 FROM model.estate_definition ed
                    WHERE ed.estate_model_pk = @estate_model_pk
                      AND ed.semantic_object_definition_pk = d.semantic_object_definition_pk) THEN 1
             ELSE 0 END) AS selected
  FROM base b
  JOIN model.semantic_object_definition d ON d.semantic_object_pk = b.semantic_object_pk)
SELECT TOP (2147483647) g.semantic_object_definition_pk, g.semantic_object_pk, g.namespace_id,
  @object_kind AS object_kind, g.declared_id, g.generation_ordinal, g.selected, g.selected_is_newest,
  g.definition_digest, LOWER(CONVERT(varchar(64), g.definition_digest, 2)) AS definition_digest_hex,
  g.canonical_content_pk, t.version_pk AS typed_version_pk,
  CONVERT(bit, CASE WHEN t.version_pk IS NULL THEN 0 ELSE 1 END) AS has_typed_row,
  g.newest_typed_version_pk, g.typed_row_present, g.newest_sod_with_typed,
  g.selection_source, g.selected_generation_count, g.total_generation_count
FROM gens g
LEFT JOIN typed t ON t.object_kind = @object_kind
  AND t.semantic_object_pk = g.semantic_object_pk
  AND t.sod = g.semantic_object_definition_pk
ORDER BY g.semantic_object_pk, g.semantic_object_definition_pk
GO
SELECT 'function_installed' AS result_set,
  CONVERT(int, CASE WHEN OBJECT_ID(N'[analysis].[fv_definition_generations]', N'IF') IS NOT NULL THEN 1 ELSE 0 END) AS installed;
GO
ROLLBACK TRANSACTION;
