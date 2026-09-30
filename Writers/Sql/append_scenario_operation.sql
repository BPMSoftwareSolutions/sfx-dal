-- draft emitted by Codelightly; promote through the deployment lifecycle

CREATE OR ALTER PROCEDURE [model].[append_scenario_operation](@capability_id nvarchar(400), @authority_id nvarchar(400), @operation_id nvarchar(400), @operation_kind varchar(64), @port_id nvarchar(400), @port_version_pk bigint, @expected_authority_version_pk bigint, @authority_version_pk bigint OUTPUT) AS BEGIN
SET NOCOUNT ON;
DECLARE @lock int;
EXEC @lock=sys.sp_getapplock @Resource=N'sidefx:model-write',@LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=300000;
IF @lock<0 THROW 51000,N'APPEND_SCENARIO_OPERATION_LOCK_FAILED',1;
DECLARE @estate bigint=(SELECT estate_model_pk FROM source.current_model WHERE singleton_id=1);
IF @estate IS NULL THROW 51000,N'APPEND_SCENARIO_OPERATION_MODEL_NOT_FOUND',1;
DECLARE @capability_pk bigint=(SELECT c.capability_pk FROM model.capability c JOIN model.identity_namespace n ON n.namespace_pk=c.namespace_pk WHERE n.namespace_id=N'sidefx:capabilities' AND c.capability_id=@capability_id COLLATE Latin1_General_100_BIN2);
IF @capability_pk IS NULL THROW 51000,N'APPEND_SCENARIO_OPERATION_CAPABILITY_NOT_FOUND',1;
DECLARE @capability_version_pk bigint=(SELECT capability_version_pk FROM model.estate_capability WHERE estate_model_pk=@estate AND capability_pk=@capability_pk);
IF @capability_version_pk IS NULL THROW 51000,N'APPEND_SCENARIO_OPERATION_CAPABILITY_NOT_SELECTED',1;
DECLARE @scenario_version_pk bigint=(SELECT cs.scenario_version_pk FROM model.capability_scenario cs JOIN model.scenario s ON s.scenario_pk=cs.scenario_pk WHERE cs.capability_version_pk=@capability_version_pk AND s.scenario_id=@capability_id COLLATE Latin1_General_100_BIN2);
IF @scenario_version_pk IS NULL THROW 51000,N'APPEND_SCENARIO_OPERATION_SCENARIO_NOT_LINKED',1;
DECLARE @linked_authority_version_pk bigint=(SELECT execution_authority_version_pk FROM model.scenario_event WHERE scenario_version_pk=@scenario_version_pk);
IF @linked_authority_version_pk IS NULL THROW 51000,N'APPEND_SCENARIO_OPERATION_AUTHORITY_NOT_FOUND',1;
IF @expected_authority_version_pk>0 AND @expected_authority_version_pk<>@linked_authority_version_pk THROW 51000,N'APPEND_SCENARIO_OPERATION_STALE_EXPECTATION',1;
DECLARE @namespace_id nvarchar(400)=(SELECT n.namespace_id FROM model.execution_authority_version eav JOIN model.semantic_object so ON so.semantic_object_pk=eav.semantic_object_pk JOIN model.identity_namespace n ON n.namespace_pk=so.namespace_pk WHERE eav.execution_authority_version_pk=@linked_authority_version_pk);
IF @namespace_id IS NULL THROW 51000,N'APPEND_SCENARIO_OPERATION_AUTHORITY_NAMESPACE_NOT_FOUND',1;
IF NOT EXISTS (SELECT 1 FROM model.port_version pv JOIN model.port p ON p.port_pk=pv.port_pk WHERE pv.port_version_pk=@port_version_pk AND p.port_id=@port_id COLLATE Latin1_General_100_BIN2) THROW 51000,N'APPEND_SCENARIO_OPERATION_PORT_VERSION_NOT_FOUND',1;
IF EXISTS (SELECT 1 FROM model.execution_operation eo WHERE eo.execution_authority_version_pk=@linked_authority_version_pk AND eo.operation_id=@operation_id COLLATE Latin1_General_100_BIN2) THROW 51000,N'APPEND_SCENARIO_OPERATION_OPERATION_ID_ALREADY_DECLARED',1;
DECLARE @links_before TABLE(ordinal int PRIMARY KEY,port_id nvarchar(400) COLLATE Latin1_General_100_BIN2,operation_kind varchar(64) COLLATE Latin1_General_100_BIN2,port_version_pk bigint);
INSERT @links_before(ordinal,port_id,operation_kind,port_version_pk) SELECT eo.ordinal,p.port_id COLLATE Latin1_General_100_BIN2,opi.operation_kind,opi.port_version_pk FROM model.execution_operation eo JOIN model.operation_port_invocation opi ON opi.execution_operation_pk=eo.execution_operation_pk JOIN model.port_version pv ON pv.port_version_pk=opi.port_version_pk JOIN model.port p ON p.port_pk=pv.port_pk WHERE eo.execution_authority_version_pk=@linked_authority_version_pk;
DECLARE @operation_count_before int=(SELECT COUNT(*) FROM model.execution_operation WHERE execution_authority_version_pk=@linked_authority_version_pk);
DECLARE @link_count_before int=(SELECT COUNT(*) FROM @links_before);
IF EXISTS (SELECT 1 FROM model.execution_operation eo WHERE eo.execution_authority_version_pk=@linked_authority_version_pk AND (eo.ordinal<0 OR eo.ordinal>=@operation_count_before)) THROW 51000,N'APPEND_SCENARIO_OPERATION_AUTHORITY_ORDINALS_NOT_CONTIGUOUS',1;
DECLARE @auth_sod bigint=(SELECT newest_selected_sod FROM analysis.fv_selected_definition(@estate,N'EXECUTION_AUTHORITY',@authority_id,@namespace_id));
IF @auth_sod IS NULL THROW 51000,N'APPEND_SCENARIO_OPERATION_AUTHORITY_DEFINITION_NOT_FOUND',1;
DECLARE @auth_object bigint,@auth_semantics nvarchar(max);
SELECT @auth_object=d.semantic_object_pk,@auth_semantics=JSON_QUERY(j.js,N'$.semantics') FROM model.semantic_object_definition d JOIN source.content_object co ON co.content_object_pk=d.canonical_content_pk CROSS APPLY (SELECT CONVERT(nvarchar(max),CONVERT(varchar(max),co.content_bytes) COLLATE Latin1_General_100_BIN2_UTF8) AS js) j WHERE d.semantic_object_definition_pk=@auth_sod;
IF @auth_semantics IS NULL OR ISJSON(@auth_semantics)<>1 THROW 51000,N'APPEND_SCENARIO_OPERATION_AUTHORITY_NOT_JSON',1;
DECLARE @ops_old nvarchar(max)=JSON_QUERY(@auth_semantics,N'$.authority.operations');
IF @ops_old IS NULL THROW 51000,N'APPEND_SCENARIO_OPERATION_AUTHORITY_OPERATIONS_MISSING',1;
IF (SELECT COUNT(*) FROM OPENJSON(@ops_old))<>@operation_count_before THROW 51000,N'APPEND_SCENARIO_OPERATION_AUTHORITY_OPERATION_SET_MISMATCH',1;
DECLARE @op_new nvarchar(max)=N'{"operationId":"'+STRING_ESCAPE(@operation_id,'json')+'","kind":"'+STRING_ESCAPE(@operation_kind,'json')+'","portId":"'+STRING_ESCAPE(@port_id,'json')+'"}';
DECLARE @ops_new nvarchar(max)=JSON_MODIFY(@ops_old,N'append $',JSON_QUERY(@op_new));
IF (SELECT COUNT(*) FROM OPENJSON(@ops_new))<>@operation_count_before+1 THROW 51000,N'APPEND_SCENARIO_OPERATION_AUTHORITY_OPERATIONS_NOT_APPENDED',1;
SET @auth_semantics=JSON_MODIFY(@auth_semantics,N'strict $.authority.operations',JSON_QUERY(@ops_new));
DECLARE @auth_definition bigint,@auth_digest binary(32);
EXEC model.put_semantic_definition 'EXECUTION_AUTHORITY',@namespace_id,@authority_id,@auth_semantics,@auth_object OUTPUT,@auth_definition OUTPUT,@auth_digest OUTPUT;
IF (SELECT MAX(d.semantic_object_definition_pk) FROM model.estate_definition ed JOIN model.semantic_object_definition d ON d.semantic_object_definition_pk=ed.semantic_object_definition_pk WHERE ed.estate_model_pk=@estate AND d.semantic_object_pk=@auth_object)<>@auth_definition THROW 51000,N'APPEND_SCENARIO_OPERATION_AUTHORITY_CONTENT_RETAINED',1;
DECLARE @auth_pk bigint=(SELECT execution_authority_pk FROM model.execution_authority WHERE semantic_object_pk=@auth_object);
IF @auth_pk IS NULL THROW 51000,N'APPEND_SCENARIO_OPERATION_AUTHORITY_ROW_MISSING',1;
DECLARE @auth_version_new bigint=(SELECT execution_authority_version_pk FROM model.execution_authority_version WHERE semantic_object_definition_pk=@auth_definition);
IF @auth_version_new IS NULL
BEGIN
 INSERT model.execution_authority_version(execution_authority_pk,semantic_object_pk,semantic_object_definition_pk,definition_digest,authority_profile,object_kind,_owner_definition_pk,_canonical_pointer) VALUES(@auth_pk,@auth_object,@auth_definition,@auth_digest,'execution-authorities.v1','EXECUTION_AUTHORITY',@auth_definition,N'');
 SET @auth_version_new=SCOPE_IDENTITY();
END
IF @auth_version_new=@linked_authority_version_pk THROW 51000,N'APPEND_SCENARIO_OPERATION_AUTHORITY_VERSION_NOT_ADVANCED',1;
INSERT model.execution_operation(execution_authority_version_pk,operation_id,ordinal,operation_kind,_owner_definition_pk,_canonical_pointer) SELECT @auth_version_new,JSON_VALUE(value,'$.operationId'),CONVERT(int,[key]),JSON_VALUE(value,'$.kind'),@auth_definition,N'/semantics/authority/operations/'+[key] FROM OPENJSON(@ops_new);
INSERT model.operation_port_invocation(execution_operation_pk,port_version_pk,operation_kind,_owner_definition_pk,_canonical_pointer) SELECT eo.execution_operation_pk,b.port_version_pk,b.operation_kind,@auth_definition,eo._canonical_pointer FROM model.execution_operation eo JOIN @links_before b ON b.ordinal=eo.ordinal WHERE eo.execution_authority_version_pk=@auth_version_new;
INSERT model.operation_port_invocation(execution_operation_pk,port_version_pk,operation_kind,_owner_definition_pk,_canonical_pointer) SELECT eo.execution_operation_pk,@port_version_pk,@operation_kind,@auth_definition,eo._canonical_pointer FROM model.execution_operation eo WHERE eo.execution_authority_version_pk=@auth_version_new AND eo.ordinal=@operation_count_before;
IF EXISTS (SELECT 1 FROM model.execution_operation eo WHERE eo.execution_authority_version_pk=@auth_version_new AND eo.operation_kind='invoke-port' AND NOT EXISTS (SELECT 1 FROM model.operation_port_invocation ip WHERE ip.execution_operation_pk=eo.execution_operation_pk)) THROW 51000,N'APPEND_SCENARIO_OPERATION_OPERATION_BINDING_NOT_DECLARED',1;
UPDATE model.scenario_event SET execution_authority_version_pk=@auth_version_new WHERE scenario_version_pk=@scenario_version_pk AND execution_authority_version_pk=@linked_authority_version_pk;
IF @@ROWCOUNT<>1 THROW 51000,N'APPEND_SCENARIO_OPERATION_SCENARIO_EVENT_NOT_RELINKED',1;
IF (SELECT COUNT(*) FROM model.execution_operation WHERE execution_authority_version_pk=@auth_version_new)<>@operation_count_before+1 THROW 51000,N'APPEND_SCENARIO_OPERATION_OPERATION_SET_NOT_APPENDED',1;
IF NOT EXISTS (SELECT 1 FROM model.execution_operation eo JOIN model.operation_port_invocation opi ON opi.execution_operation_pk=eo.execution_operation_pk WHERE eo.execution_authority_version_pk=@auth_version_new AND eo.ordinal=@operation_count_before AND eo.operation_id=@operation_id COLLATE Latin1_General_100_BIN2 AND opi.port_version_pk=@port_version_pk) THROW 51000,N'APPEND_SCENARIO_OPERATION_OPERATION_NOT_LINKED',1;
IF EXISTS (SELECT 1 FROM @links_before b JOIN model.execution_operation eo ON eo.execution_authority_version_pk=@auth_version_new AND eo.ordinal=b.ordinal JOIN model.operation_port_invocation opi ON opi.execution_operation_pk=eo.execution_operation_pk WHERE opi.port_version_pk<>b.port_version_pk) THROW 51000,N'APPEND_SCENARIO_OPERATION_EXISTING_LINK_MOVED',1;
IF (SELECT COUNT(*) FROM model.execution_operation eo JOIN model.operation_port_invocation opi ON opi.execution_operation_pk=eo.execution_operation_pk WHERE eo.execution_authority_version_pk=@auth_version_new)<>@link_count_before+1 THROW 51000,N'APPEND_SCENARIO_OPERATION_LINK_COUNT_NOT_PRESERVED',1;
IF (SELECT COUNT(*) FROM model.execution_operation WHERE execution_authority_version_pk=@linked_authority_version_pk)<>@operation_count_before THROW 51000,N'APPEND_SCENARIO_OPERATION_HISTORY_REWRITTEN',1;
SET @authority_version_pk=@auth_version_new;
SELECT N'append_scenario_operation' AS result_set,@capability_id AS capability_id,@authority_id AS authority_id,@linked_authority_version_pk AS authority_before,@auth_version_new AS authority_after,@operation_count_before AS operations_before,@link_count_before AS links_before,@operation_id AS operation_id,@port_id AS port_id,@port_version_pk AS port_version_pk;
-- refusal APPEND_SCENARIO_OPERATION_LOCK_FAILED: Could not acquire the exclusive sidefx:model-write application lock.
-- refusal APPEND_SCENARIO_OPERATION_MODEL_NOT_FOUND: The current model pin (source.current_model singleton_id=1) was not found.
-- refusal APPEND_SCENARIO_OPERATION_CAPABILITY_NOT_FOUND: The capability id was not found in the sidefx:capabilities namespace.
-- refusal APPEND_SCENARIO_OPERATION_CAPABILITY_NOT_SELECTED: The capability is not selected in the current estate model.
-- refusal APPEND_SCENARIO_OPERATION_SCENARIO_NOT_LINKED: The capability version has no scenario version for the capability id.
-- refusal APPEND_SCENARIO_OPERATION_AUTHORITY_NOT_FOUND: The scenario event has no linked execution authority version.
-- refusal APPEND_SCENARIO_OPERATION_STALE_EXPECTATION: The expected authority version does not match the linked authority version; pass 0 to skip the expectation.
-- refusal APPEND_SCENARIO_OPERATION_AUTHORITY_NAMESPACE_NOT_FOUND: The linked authority version does not resolve to an identity namespace.
-- refusal APPEND_SCENARIO_OPERATION_PORT_VERSION_NOT_FOUND: The declared port_version_pk does not belong to the named port_id.
-- refusal APPEND_SCENARIO_OPERATION_OPERATION_ID_ALREADY_DECLARED: The linked authority version already declares this operation id; a replay is refused.
-- refusal APPEND_SCENARIO_OPERATION_AUTHORITY_ORDINALS_NOT_CONTIGUOUS: The linked authority version ordinals are not contiguous from zero.
-- refusal APPEND_SCENARIO_OPERATION_AUTHORITY_DEFINITION_NOT_FOUND: No selected execution authority definition was found for the authority id and namespace.
-- refusal APPEND_SCENARIO_OPERATION_AUTHORITY_NOT_JSON: The selected authority definition semantics are missing or not JSON.
-- refusal APPEND_SCENARIO_OPERATION_AUTHORITY_OPERATIONS_MISSING: The selected authority semantics have no authority.operations array.
-- refusal APPEND_SCENARIO_OPERATION_AUTHORITY_OPERATION_SET_MISMATCH: The authority operations array does not match the linked authority version operation rows.
-- refusal APPEND_SCENARIO_OPERATION_AUTHORITY_OPERATIONS_NOT_APPENDED: Appending the operation did not grow the operations array by exactly one.
-- refusal APPEND_SCENARIO_OPERATION_AUTHORITY_CONTENT_RETAINED: The minted authority definition is not the newest selected definition.
-- refusal APPEND_SCENARIO_OPERATION_AUTHORITY_ROW_MISSING: The authority semantic object has no execution_authority row.
-- refusal APPEND_SCENARIO_OPERATION_AUTHORITY_VERSION_NOT_ADVANCED: The authority version did not advance; the append is a no-op.
-- refusal APPEND_SCENARIO_OPERATION_OPERATION_BINDING_NOT_DECLARED: An invoke-port operation on the new authority version has no port invocation link.
-- refusal APPEND_SCENARIO_OPERATION_SCENARIO_EVENT_NOT_RELINKED: The scenario event was not relinked to the new authority version.
-- refusal APPEND_SCENARIO_OPERATION_OPERATION_SET_NOT_APPENDED: The new authority version does not contain exactly one more operation than the old one.
-- refusal APPEND_SCENARIO_OPERATION_OPERATION_NOT_LINKED: The appended operation is not linked to the declared port version.
-- refusal APPEND_SCENARIO_OPERATION_EXISTING_LINK_MOVED: A preserved operation link no longer points at its original port version.
-- refusal APPEND_SCENARIO_OPERATION_LINK_COUNT_NOT_PRESERVED: The new authority version link count is not the preserved link count plus one.
-- refusal APPEND_SCENARIO_OPERATION_HISTORY_REWRITTEN: The old authority version operation rows changed.
END
GO
