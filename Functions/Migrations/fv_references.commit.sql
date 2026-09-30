-- draft emitted by Codelightly; promote through the deployment lifecycle
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF @@TRANCOUNT=0 BEGIN TRANSACTION;
DECLARE @lock int;
EXEC @lock=sys.sp_getapplock @Resource=N'sidefx:model-write',@LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=60000;
IF @lock<0 THROW 51000,N'fv_references_LOCK_FAILED',1;
GO
CREATE OR ALTER FUNCTION [analysis].[fv_references](@estate_model_pk bigint, @namespace_id nvarchar(400) = NULL, @object_kind varchar(64), @declared_id nvarchar(400), @site_class varchar(16) = NULL, @offset int = 0, @fetch int = 200, @size_bound_bytes int = 65536) RETURNS TABLE AS RETURN
WITH targets AS (
  SELECT so.semantic_object_pk, so.object_kind, so.declared_id, n.namespace_id
  FROM model.semantic_object so
  JOIN model.identity_namespace n ON n.namespace_pk = so.namespace_pk
  WHERE so.object_kind = @object_kind
    AND so.declared_id = @declared_id COLLATE Latin1_General_100_BIN2
    AND (@namespace_id IS NULL OR n.namespace_id = @namespace_id COLLATE Latin1_General_100_BIN2)),
scan_kinds AS (
  SELECT object_kind FROM (VALUES
    ('PORT'), ('PROVIDER'), ('TRANSFORMATION'), ('FIXTURE'), ('AUTHORITY'), ('SCENARIO'),
    ('CONTRACT'), ('CAPABILITY'), ('EXECUTION_AUTHORITY'), ('BLUEPRINT'), ('FEATURE'),
    ('MECHANIC'), ('TOOL'), ('OBSERVABLE_CONDITION')) k(object_kind)),
sites AS (
  SELECT CONVERT(bigint, sve.semantic_object_definition_pk) AS referencing_definition_pk,
    CAST('TYPED' AS varchar(16)) AS site_class, CAST('model.operation_port_invocation' AS varchar(128)) AS site_table,
    CAST('port_version_pk' AS varchar(128)) AS site_column, CAST(NULL AS nvarchar(400)) AS site_json_path,
    CONVERT(nvarchar(400), opi.port_version_pk) AS matched_value, CAST('EXACT' AS varchar(8)) AS match_quality,
    CAST('MATCH' AS varchar(16)) AS scan_state
  FROM targets t
  JOIN model.port p ON p.semantic_object_pk = t.semantic_object_pk
  JOIN model.port_version pv ON pv.port_pk = p.port_pk
  JOIN model.operation_port_invocation opi ON opi.port_version_pk = pv.port_version_pk
  JOIN model.execution_operation eo ON eo.execution_operation_pk = opi.execution_operation_pk
  JOIN model.scenario_event se ON se.execution_authority_version_pk = eo.execution_authority_version_pk
  JOIN model.scenario_version sve ON sve.scenario_version_pk = se.scenario_version_pk
  UNION ALL
  SELECT CONVERT(bigint, bv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.slot_port_requirement' AS varchar(128)), CAST('port_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), spr.port_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.port p ON p.semantic_object_pk = t.semantic_object_pk
  JOIN model.port_version pv ON pv.port_pk = p.port_pk
  JOIN model.slot_port_requirement spr ON spr.port_version_pk = pv.port_version_pk
  JOIN model.provider_slot ps ON ps.provider_slot_pk = spr.provider_slot_pk
  JOIN model.blueprint_version bv ON bv.blueprint_version_pk = ps.blueprint_version_pk
  UNION ALL
  SELECT CONVERT(bigint, bv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.binding_port_implementation' AS varchar(128)), CAST('port_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), bpi.port_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.port p ON p.semantic_object_pk = t.semantic_object_pk
  JOIN model.port_version pv ON pv.port_pk = p.port_pk
  JOIN model.binding_port_implementation bpi ON bpi.port_version_pk = pv.port_version_pk
  JOIN model.provider_slot ps ON ps.provider_slot_pk = bpi.provider_slot_pk
  JOIN model.blueprint_version bv ON bv.blueprint_version_pk = ps.blueprint_version_pk
  UNION ALL
  SELECT CONVERT(bigint, pd.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.provider_port_implementation' AS varchar(128)), CAST('port_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), ppi.port_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.port p ON p.semantic_object_pk = t.semantic_object_pk
  JOIN model.port_version pv ON pv.port_pk = p.port_pk
  JOIN model.provider_port_implementation ppi ON ppi.port_version_pk = pv.port_version_pk
  JOIN model.provider_definition pd ON pd.provider_definition_pk = ppi.provider_definition_pk
  UNION ALL
  SELECT CONVERT(bigint, fi.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.fixture_port_outcome' AS varchar(128)), CAST('port_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), fpo.port_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.port p ON p.semantic_object_pk = t.semantic_object_pk
  JOIN model.port_version pv ON pv.port_pk = p.port_pk
  JOIN model.fixture_port_outcome fpo ON fpo.port_version_pk = pv.port_version_pk
  JOIN model.fixture_case fc ON fc.fixture_case_pk = fpo.fixture_case_pk
  JOIN model.fixture fi ON fi.fixture_pk = fc.fixture_pk
  UNION ALL
  SELECT CONVERT(bigint, ctv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.port_contract' AS varchar(128)), CAST('port_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), pc.port_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.port p ON p.semantic_object_pk = t.semantic_object_pk
  JOIN model.port_version pv ON pv.port_pk = p.port_pk
  JOIN model.port_contract pc ON pc.port_version_pk = pv.port_version_pk
  JOIN model.contract_version ctv ON ctv.contract_version_pk = pc.contract_version_pk
  UNION ALL
  SELECT CONVERT(bigint, tv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.transformation_expression_node' AS varchar(128)), CAST('reference_name' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), ten.reference_name), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.transformation tr ON tr.semantic_object_pk = t.semantic_object_pk
  JOIN model.transformation_version tv ON tv.transformation_pk = tr.transformation_pk
  JOIN model.transformation_expression_node ten ON ten.transformation_version_pk = tv.transformation_version_pk
    AND ten.reference_name = t.declared_id COLLATE Latin1_General_100_BIN2
  UNION ALL
  SELECT CONVERT(bigint, tv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.expression_semantic_reference' AS varchar(128)), CAST('semantic_object_definition_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), esr.semantic_object_definition_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.semantic_object_definition td ON td.semantic_object_pk = t.semantic_object_pk
  JOIN model.expression_semantic_reference esr ON esr.semantic_object_definition_pk = td.semantic_object_definition_pk
  JOIN model.transformation_expression_node ten ON ten.expression_node_pk = esr.expression_node_pk
  JOIN model.transformation_version tv ON tv.transformation_version_pk = ten.transformation_version_pk
  UNION ALL
  SELECT CONVERT(bigint, sve.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.operation_state_projection' AS varchar(128)), CAST('transformation_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), osp.transformation_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.transformation tr ON tr.semantic_object_pk = t.semantic_object_pk
  JOIN model.transformation_version tv ON tv.transformation_pk = tr.transformation_pk
  JOIN model.operation_state_projection osp ON osp.transformation_version_pk = tv.transformation_version_pk
  JOIN model.execution_operation eo ON eo.execution_operation_pk = osp.execution_operation_pk
  JOIN model.scenario_event se ON se.execution_authority_version_pk = eo.execution_authority_version_pk
  JOIN model.scenario_version sve ON sve.scenario_version_pk = se.scenario_version_pk
  UNION ALL
  SELECT CONVERT(bigint, sve.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.operation_transformation' AS varchar(128)), CAST('transformation_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), ot.transformation_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.transformation tr ON tr.semantic_object_pk = t.semantic_object_pk
  JOIN model.transformation_version tv ON tv.transformation_pk = tr.transformation_pk
  JOIN model.operation_transformation ot ON ot.transformation_version_pk = tv.transformation_version_pk
  JOIN model.execution_operation eo ON eo.execution_operation_pk = ot.execution_operation_pk
  JOIN model.scenario_event se ON se.execution_authority_version_pk = eo.execution_authority_version_pk
  JOIN model.scenario_version sve ON sve.scenario_version_pk = se.scenario_version_pk
  UNION ALL
  SELECT CONVERT(bigint, sve.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.scenario_input' AS varchar(128)), CAST('input_contract_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), si.input_contract_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.contract ct ON ct.semantic_object_pk = t.semantic_object_pk
  JOIN model.contract_version cv ON cv.contract_pk = ct.contract_pk
  JOIN model.scenario_input si ON si.input_contract_version_pk = cv.contract_version_pk
  JOIN model.scenario_version sve ON sve.scenario_version_pk = si.scenario_version_pk
  UNION ALL
  SELECT CONVERT(bigint, sve.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.scenario_outcome_contract' AS varchar(128)), CAST('contract_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), soc.contract_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.contract ct ON ct.semantic_object_pk = t.semantic_object_pk
  JOIN model.contract_version cv ON cv.contract_pk = ct.contract_pk
  JOIN model.scenario_outcome_contract soc ON soc.contract_version_pk = cv.contract_version_pk
  JOIN model.scenario_version sve ON sve.scenario_version_pk = soc.scenario_version_pk
  UNION ALL
  SELECT CONVERT(bigint, pd.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.product_definition' AS varchar(128)), CAST('contract_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), pd.contract_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.contract ct ON ct.semantic_object_pk = t.semantic_object_pk
  JOIN model.contract_version cv ON cv.contract_pk = ct.contract_pk
  JOIN model.product_definition pd ON pd.contract_version_pk = cv.contract_version_pk
  UNION ALL
  SELECT CONVERT(bigint, pv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.port_contract' AS varchar(128)), CAST('contract_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), pc.contract_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.contract ct ON ct.semantic_object_pk = t.semantic_object_pk
  JOIN model.contract_version cv ON cv.contract_pk = ct.contract_pk
  JOIN model.port_contract pc ON pc.contract_version_pk = cv.contract_version_pk
  JOIN model.port_version pv ON pv.port_version_pk = pc.port_version_pk
  UNION ALL
  SELECT CONVERT(bigint, cv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.capability_scenario' AS varchar(128)), CAST('scenario_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), cs.scenario_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.scenario s ON s.semantic_object_pk = t.semantic_object_pk
  JOIN model.capability_scenario cs ON cs.scenario_pk = s.scenario_pk
  JOIN model.capability_version cv ON cv.capability_version_pk = cs.capability_version_pk
  UNION ALL
  SELECT CONVERT(bigint, fv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.feature_scenario' AS varchar(128)), CAST('scenario_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), fs.scenario_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.scenario s ON s.semantic_object_pk = t.semantic_object_pk
  JOIN model.feature_scenario fs ON fs.scenario_pk = s.scenario_pk
  JOIN model.feature_version fv ON fv.feature_version_pk = fs.feature_version_pk
  UNION ALL
  SELECT CONVERT(bigint, bv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.blueprint_node_scenario' AS varchar(128)), CAST('scenario_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), bns.scenario_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.scenario s ON s.semantic_object_pk = t.semantic_object_pk
  JOIN model.scenario_version ts ON ts.scenario_pk = s.scenario_pk
  JOIN model.blueprint_node_scenario bns ON bns.scenario_version_pk = ts.scenario_version_pk
  JOIN model.blueprint_version bv ON bv.blueprint_version_pk = bns.blueprint_version_pk
  UNION ALL
  SELECT CONVERT(bigint, fi.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.fixture_scenario_step' AS varchar(128)), CAST('scenario_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), fss.scenario_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.scenario s ON s.semantic_object_pk = t.semantic_object_pk
  JOIN model.scenario_version ts ON ts.scenario_pk = s.scenario_pk
  JOIN model.fixture_scenario_step fss ON fss.scenario_version_pk = ts.scenario_version_pk
  JOIN model.fixture_case fc ON fc.fixture_case_pk = fss.fixture_case_pk
  JOIN model.fixture fi ON fi.fixture_pk = fc.fixture_pk
  UNION ALL
  SELECT CONVERT(bigint, sve.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.operation_scenario_invocation' AS varchar(128)), CAST('target_scenario_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), osi.target_scenario_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.scenario s ON s.semantic_object_pk = t.semantic_object_pk
  JOIN model.scenario_version ts ON ts.scenario_pk = s.scenario_pk
  JOIN model.operation_scenario_invocation osi ON osi.target_scenario_version_pk = ts.scenario_version_pk
  JOIN model.execution_operation eo ON eo.execution_operation_pk = osi.execution_operation_pk
  JOIN model.scenario_event se ON se.execution_authority_version_pk = eo.execution_authority_version_pk
  JOIN model.scenario_version sve ON sve.scenario_version_pk = se.scenario_version_pk
  UNION ALL
  SELECT CONVERT(bigint, pd.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.provider_capability_implementation' AS varchar(128)), CAST('capability_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), pci.capability_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.capability c ON c.semantic_object_pk = t.semantic_object_pk
  JOIN model.capability_version cv ON cv.capability_pk = c.capability_pk
  JOIN model.provider_capability_implementation pci ON pci.capability_version_pk = cv.capability_version_pk
  JOIN model.provider_definition pd ON pd.provider_definition_pk = pci.provider_definition_pk
  UNION ALL
  SELECT CONVERT(bigint, pv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.provider_port_implementation' AS varchar(128)), CAST('provider_definition_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), ppi.provider_definition_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.provider pr ON pr.semantic_object_pk = t.semantic_object_pk
  JOIN model.provider_definition pd ON pd.provider_pk = pr.provider_pk
  JOIN model.provider_port_implementation ppi ON ppi.provider_definition_pk = pd.provider_definition_pk
  JOIN model.port_version pv ON pv.port_version_pk = ppi.port_version_pk
  UNION ALL
  SELECT CONVERT(bigint, bv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.binding_port_implementation' AS varchar(128)), CAST('provider_definition_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), bpi.provider_definition_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.provider pr ON pr.semantic_object_pk = t.semantic_object_pk
  JOIN model.provider_definition pd ON pd.provider_pk = pr.provider_pk
  JOIN model.binding_port_implementation bpi ON bpi.provider_definition_pk = pd.provider_definition_pk
  JOIN model.provider_slot ps ON ps.provider_slot_pk = bpi.provider_slot_pk
  JOIN model.blueprint_version bv ON bv.blueprint_version_pk = ps.blueprint_version_pk
  UNION ALL
  SELECT CONVERT(bigint, cv.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.provider_capability_implementation' AS varchar(128)), CAST('provider_definition_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), pci.provider_definition_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.provider pr ON pr.semantic_object_pk = t.semantic_object_pk
  JOIN model.provider_definition pd ON pd.provider_pk = pr.provider_pk
  JOIN model.provider_capability_implementation pci ON pci.provider_definition_pk = pd.provider_definition_pk
  JOIN model.capability_version cv ON cv.capability_version_pk = pci.capability_version_pk
  UNION ALL
  SELECT CONVERT(bigint, sve.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.scenario_event' AS varchar(128)), CAST('execution_authority_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), se.execution_authority_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.execution_authority ea ON ea.semantic_object_pk = t.semantic_object_pk
  JOIN model.execution_authority_version eav ON eav.execution_authority_pk = ea.execution_authority_pk
  JOIN model.scenario_event se ON se.execution_authority_version_pk = eav.execution_authority_version_pk
  JOIN model.scenario_version sve ON sve.scenario_version_pk = se.scenario_version_pk
  UNION ALL
  SELECT CONVERT(bigint, pd.semantic_object_definition_pk), CAST('TYPED' AS varchar(16)),
    CAST('model.provider_port_implementation' AS varchar(128)), CAST('provider_profile_version_pk' AS varchar(128)),
    CAST(NULL AS nvarchar(400)), CONVERT(nvarchar(400), ppi.provider_profile_version_pk), CAST('EXACT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM targets t
  JOIN model.provider_profile_version ppv ON ppv.semantic_object_pk = t.semantic_object_pk
  JOIN model.provider_port_implementation ppi ON ppi.provider_profile_version_pk = ppv.provider_profile_version_pk
  JOIN model.provider_definition pd ON pd.provider_definition_pk = ppi.provider_definition_pk),
docs AS (
  SELECT sod.semantic_object_definition_pk, so.semantic_object_pk, so.object_kind, so.declared_id, n.namespace_id,
    co.byte_length, co.content_bytes
  FROM model.semantic_object_definition sod
  JOIN source.content_object co ON co.content_object_pk = sod.canonical_content_pk
  JOIN model.semantic_object so ON so.semantic_object_pk = sod.semantic_object_pk
  JOIN model.identity_namespace n ON n.namespace_pk = so.namespace_pk
  WHERE so.object_kind IN (SELECT k.object_kind FROM scan_kinds k)
    AND NOT EXISTS (SELECT 1 FROM targets t WHERE t.semantic_object_pk = so.semantic_object_pk)
    AND EXISTS (
      SELECT 1 FROM model.estate_definition ed
      WHERE ed.estate_model_pk = @estate_model_pk AND ed.semantic_object_definition_pk = sod.semantic_object_definition_pk
      UNION ALL
      SELECT 1 FROM model.estate_capability ec
      JOIN model.capability_version cv2 ON cv2.capability_version_pk = ec.capability_version_pk
      WHERE ec.estate_model_pk = @estate_model_pk AND cv2.semantic_object_definition_pk = sod.semantic_object_definition_pk)
    AND CHARINDEX(CONVERT(varbinary(800), CONVERT(varchar(800), @declared_id)), co.content_bytes) > 0),
scan_docs AS (
  SELECT d.semantic_object_definition_pk, d.semantic_object_pk, d.object_kind, d.declared_id, d.namespace_id, d.byte_length,
    CONVERT(nvarchar(max), CONVERT(varchar(max), d.content_bytes) COLLATE Latin1_General_100_BIN2_UTF8) COLLATE DATABASE_DEFAULT AS body
  FROM docs d
  WHERE d.byte_length <= @size_bound_bytes),
walk AS (
  SELECT d.semantic_object_definition_pk, d.semantic_object_pk, d.object_kind, d.declared_id, d.namespace_id, d.byte_length,
    CAST((N'$.' + j.[key]) COLLATE DATABASE_DEFAULT AS nvarchar(400)) AS site_json_path, j.[key], j.[value], j.[type]
  FROM scan_docs d
  CROSS APPLY OPENJSON(CAST(CASE WHEN ISJSON(d.body) = 1 THEN d.body ELSE N'{}' END AS nvarchar(max))) j
  UNION ALL
  SELECT w.semantic_object_definition_pk, w.semantic_object_pk, w.object_kind, w.declared_id, w.namespace_id, w.byte_length,
    CAST((w.site_json_path + CASE WHEN w.[type] = 4 THEN N'[' + j.[key] + N']' ELSE N'.' + j.[key] END) COLLATE DATABASE_DEFAULT AS nvarchar(400)),
    j.[key], j.[value], j.[type]
  FROM walk w
  CROSS APPLY OPENJSON(CAST(CASE WHEN w.[type] IN (4, 5) THEN w.[value] ELSE N'{}' END AS nvarchar(max))) j
  WHERE w.[type] IN (4, 5)),
hits AS (
  SELECT w.semantic_object_definition_pk AS referencing_definition_pk,
    CAST('MEMBER' AS varchar(16)) AS site_class, CAST('source.content_object' AS varchar(128)) AS site_table,
    CAST('content_bytes' AS varchar(128)) AS site_column, w.site_json_path,
    CONVERT(nvarchar(400), w.[value]) AS matched_value, CAST('EXACT' AS varchar(8)) AS match_quality,
    CAST('MATCH' AS varchar(16)) AS scan_state
  FROM walk w
  WHERE w.[type] = 1 AND w.[value] = @declared_id COLLATE Latin1_General_100_BIN2
  UNION ALL
  SELECT w.semantic_object_definition_pk, CAST('STATEMENT' AS varchar(16)), CAST('source.content_object' AS varchar(128)),
    CAST('content_bytes' AS varchar(128)), w.site_json_path, CONVERT(nvarchar(400), w.[value]),
    CAST('TEXT' AS varchar(8)), CAST('MATCH' AS varchar(16))
  FROM walk w
  WHERE w.[type] = 1 AND w.[value] <> @declared_id COLLATE Latin1_General_100_BIN2
    AND (w.site_json_path LIKE N'%.statement' OR w.site_json_path LIKE N'%.requestPath')
    AND CHARINDEX(@declared_id COLLATE Latin1_General_100_BIN2, w.[value]) > 0
  UNION ALL
  SELECT d.semantic_object_definition_pk, CAST('MEMBER' AS varchar(16)), CAST('source.content_object' AS varchar(128)),
    CAST('content_bytes' AS varchar(128)), CAST(NULL AS nvarchar(400)), CAST(NULL AS nvarchar(400)),
    CAST(NULL AS varchar(8)), CAST('SIZE_BOUND' AS varchar(16))
  FROM docs d
  WHERE d.byte_length > @size_bound_bytes),
source_hits AS (
  SELECT CONVERT(bigint, sl.semantic_object_definition_pk) AS referencing_definition_pk,
    CAST('SOURCE' AS varchar(16)) AS site_class, CAST('source.relationship_observation' AS varchar(128)) AS site_table,
    CAST(CASE WHEN ro.target_reference = @declared_id COLLATE Latin1_General_100_BIN2 THEN 'target_reference' ELSE 'source_reference' END AS varchar(128)) AS site_column,
    CAST(NULL AS nvarchar(400)) AS site_json_path,
    CONVERT(nvarchar(400), CASE WHEN ro.target_reference = @declared_id COLLATE Latin1_General_100_BIN2 THEN ro.target_reference ELSE ro.source_reference END) AS matched_value,
    CAST('EXACT' AS varchar(8)) AS match_quality, CAST('MATCH' AS varchar(16)) AS scan_state
  FROM source.relationship_observation ro
  OUTER APPLY (SELECT TOP (1) x.semantic_object_definition_pk
    FROM source.source_lineage x
    WHERE x.source_observation_pk = ro.source_observation_pk
    ORDER BY x.source_lineage_pk) sl
  WHERE ro.source_reference = @declared_id COLLATE Latin1_General_100_BIN2
    OR ro.target_reference = @declared_id COLLATE Latin1_General_100_BIN2)
SELECT so.object_kind AS referencing_object_kind, n.namespace_id AS referencing_namespace_id,
  so.declared_id AS referencing_declared_id, a.referencing_definition_pk,
  sod.definition_digest AS referencing_digest, a.site_class, a.site_table, a.site_column,
  a.site_json_path, a.matched_value, a.match_quality, CAST('SELECTED' AS varchar(16)) AS scope, a.scan_state
FROM (
  SELECT referencing_definition_pk, site_class, site_table, site_column, site_json_path, matched_value, match_quality, scan_state FROM sites
  UNION ALL
  SELECT referencing_definition_pk, site_class, site_table, site_column, site_json_path, matched_value, match_quality, scan_state FROM hits
  UNION ALL
  SELECT referencing_definition_pk, site_class, site_table, site_column, site_json_path, matched_value, match_quality, scan_state FROM source_hits
) a
LEFT JOIN model.semantic_object_definition sod ON sod.semantic_object_definition_pk = a.referencing_definition_pk
LEFT JOIN model.semantic_object so ON so.semantic_object_pk = sod.semantic_object_pk
LEFT JOIN model.identity_namespace n ON n.namespace_pk = so.namespace_pk
WHERE @site_class IS NULL OR a.site_class = @site_class
ORDER BY so.object_kind, n.namespace_id, so.declared_id, a.site_class, a.site_table, a.site_json_path, a.matched_value
OFFSET @offset ROWS FETCH NEXT @fetch ROWS ONLY
GO
SELECT 'function_installed' AS result_set,
  CONVERT(int, CASE WHEN OBJECT_ID(N'[analysis].[fv_references]', N'IF') IS NOT NULL THEN 1 ELSE 0 END) AS installed;
GO
COMMIT TRANSACTION;
