-- conformance read for repair objective-invoke-outcome
WITH estate AS (
  SELECT estate_model_pk FROM source.current_model WHERE singleton_id=1
),
live AS (
  SELECT c.capability_id, s.scenario_id, cs.scenario_version_pk, se.execution_authority_version_pk
  FROM model.capability c
  JOIN model.identity_namespace n ON n.namespace_pk=c.namespace_pk
  JOIN model.estate_capability ec ON ec.capability_pk=c.capability_pk AND ec.estate_model_pk=(SELECT estate_model_pk FROM estate)
  JOIN model.capability_scenario cs ON cs.capability_version_pk=ec.capability_version_pk
  JOIN model.scenario s ON s.scenario_pk=cs.scenario_pk
  JOIN model.scenario_event se ON se.scenario_version_pk=cs.scenario_version_pk
  WHERE n.namespace_id=N'sidefx:capabilities'
    AND c.capability_id=N'request-capability-from-objective' COLLATE Latin1_General_100_BIN2
    AND s.scenario_id=N'request-capability-from-objective' COLLATE Latin1_General_100_BIN2
),
ops AS (
  SELECT l.capability_id, l.scenario_id, l.scenario_version_pk, l.execution_authority_version_pk,
    eo.ordinal, eo.operation_id, eo.operation_kind, p.port_id, opi.port_version_pk
  FROM live l
  JOIN model.execution_operation eo ON eo.execution_authority_version_pk=l.execution_authority_version_pk
  LEFT JOIN model.operation_port_invocation opi ON opi.execution_operation_pk=eo.execution_operation_pk
  LEFT JOIN model.port_version pv ON pv.port_version_pk=opi.port_version_pk
  LEFT JOIN model.port p ON p.port_pk=pv.port_pk
),
shaping AS (
  SELECT g.newest_selected_sod, g.definition_digest_hex, g.typed_version_pk
  FROM analysis.fv_selected_definition((SELECT estate_model_pk FROM estate), 'TRANSFORMATION', N'shape-objective-invocation-result', N'sidefx:capability:request-capability-from-objective') g
)
SELECT o.capability_id, o.scenario_id, o.scenario_version_pk, o.execution_authority_version_pk AS authority_version_pk,
  COUNT(*) AS operation_count,
  COUNT(o.port_version_pk) AS link_count,
  SUM(CASE WHEN o.ordinal < 7 THEN 1 ELSE 0 END) AS preserved_link_count,
  MAX(CASE WHEN o.operation_id=N'request-capability-from-objective.shape' THEN o.ordinal END) AS shape_ordinal,
  MAX(CASE WHEN o.ordinal=7 THEN o.operation_id END) AS shape_operation_id,
  MAX(CASE WHEN o.ordinal=7 THEN o.port_id END) AS shape_port_id,
  MAX(CASE WHEN o.ordinal=7 THEN o.port_version_pk END) AS shape_port_version_pk,
  LOWER(CONVERT(varchar(64),HASHBYTES('SHA2_256',CONVERT(varbinary(max),
    STRING_AGG(CONVERT(nvarchar(max),CONVERT(nvarchar(20),o.ordinal)+N'|'+ISNULL(o.operation_id,N'')
      +N'|'+o.operation_kind+N'|'+ISNULL(o.port_id,N'')+N'|'+ISNULL(CONVERT(nvarchar(20),o.port_version_pk),N'')),N';')
    WITHIN GROUP (ORDER BY o.ordinal))),2)) AS operation_set_digest,
  s.newest_selected_sod AS shaping_sod, s.definition_digest_hex AS shaping_digest_hex, s.typed_version_pk,
  CONVERT(bit,CASE WHEN s.typed_version_pk IS NULL THEN 0 ELSE 1 END) AS typed_row_present,
  CONVERT(bit,CASE WHEN tv.definition_digest=sd.definition_digest THEN 1 ELSE 0 END) AS typed_digest_matches,
  (SELECT COUNT(*) FROM model.transformation_root r WHERE r.transformation_version_pk=s.typed_version_pk) AS expression_root_count,
  (SELECT COUNT(*) FROM model.transformation_expression_node nd WHERE nd.transformation_version_pk=s.typed_version_pk) AS expression_node_count,
  (SELECT COUNT(*) FROM model.outcome_variant ov WHERE ov.scenario_version_pk=o.scenario_version_pk
    AND (ov.variant_id=N'ADMITTED' AND ov.classification=N'success'
      OR ov.variant_id=N'REFUSED' AND ov.classification=N'failure'
      OR ov.variant_id=N'PROVIDER_UNAVAILABLE' AND ov.classification=N'failure')) AS declared_variants_matched,
  (SELECT LOWER(CONVERT(varchar(64),HASHBYTES('SHA2_256',CONVERT(varbinary(max),g.graph_source)),2))
    FROM analysis.capability_graph_source(N'request-capability-from-objective',CONVERT(bit,0),NULL) g) AS graph_digest
FROM ops o
CROSS JOIN shaping s
LEFT JOIN model.semantic_object_definition sd ON sd.semantic_object_definition_pk=s.newest_selected_sod
LEFT JOIN model.transformation_version tv ON tv.transformation_version_pk=s.typed_version_pk
GROUP BY o.capability_id, o.scenario_id, o.scenario_version_pk, o.execution_authority_version_pk,
  s.newest_selected_sod, s.definition_digest_hex, s.typed_version_pk, sd.definition_digest, tv.definition_digest;
