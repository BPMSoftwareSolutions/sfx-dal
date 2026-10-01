-- expected-before-digest: f23d61daa878b292ea652ebe3fe0be52a8a05cb61aaf0cb0516a0a8260ec0109
-- shape-objective-invocation-result.commit.sql
--
-- Draft emitted by Codelightly. Promote through the deployment lifecycle before applying.
-- Entry id: shape-objective-invocation-result
-- Declared object kind: TRANSFORMATION; namespace: sidefx:capability:request-capability-from-objective; declared id: shape-objective-invocation-result
-- Before-digest guard: the declared verification read must return a definition_digest column.
-- A NULL before-digest means the document is not installed yet, so the mint is allowed.
-- Declared typed row: this draft carries a declared write statement emitted between the mint and the optional normalize.
--
-- Commit drafts end in COMMIT and are the install once promoted through the deployment lifecycle.
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
DECLARE @lock int;
EXEC @lock=sp_getapplock @Resource=N'sidefx:model-write',@LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=60000;
IF @lock<0 THROW 51000,N'DOCUMENT_MINT_LOCK_FAILED',1;
GO
-- Mint the declared document through the configured mint procedure, then run the
-- declared typed row and the configured verification read; the read must return at
-- least semantic_object_definition_pk and definition_digest.
SET NOCOUNT ON;
DECLARE @object bigint,@definition bigint,@digest binary(32);
-- Expected before-digest guard: the configured verification read must return a definition_digest column.
DECLARE @before_digest_hex nvarchar(64) = (SELECT LOWER(CONVERT(varchar(64), v.definition_digest, 2)) FROM (SELECT g.newest_selected_sod AS semantic_object_definition_pk, g.definition_digest AS definition_digest, g.definition_digest_hex AS definition_digest_hex, CONVERT(nvarchar(max),CONVERT(varchar(max),co.content_bytes) COLLATE Latin1_General_100_BIN2_UTF8) AS definition_json, CONVERT(bit,CASE WHEN g.typed_version_pk IS NULL THEN 0 ELSE 1 END) AS typed_row_present, g.selected_generation_count FROM analysis.fv_selected_definition((SELECT estate_model_pk FROM source.current_model WHERE singleton_id=1), 'TRANSFORMATION', N'shape-objective-invocation-result', N'sidefx:capability:request-capability-from-objective') g JOIN source.content_object co ON co.content_object_pk=g.canonical_content_pk) v);
IF @before_digest_hex IS NOT NULL AND @before_digest_hex <> N'f23d61daa878b292ea652ebe3fe0be52a8a05cb61aaf0cb0516a0a8260ec0109' THROW 51000, N'SHAPE_OBJECTIVE_INVOCATION_RESULT_DOCUMENT_EXPECTED_DIGEST_MISMATCH', 1;
EXEC model.put_semantic_definition 'TRANSFORMATION',N'sidefx:capability:request-capability-from-objective',N'shape-objective-invocation-result',N'{"id":"shape-objective-invocation-result","expression":{"op":"let","bindings":{"result":{"op":"path","from":"input","path":"result"},"nestedContract":{"op":"path","from":"input","path":"result.contractId"},"refusalModelDisposition":{"op":"path","from":"input","path":"result.model.disposition"},"disposition":{"op":"if","when":{"op":"path","from":"result","path":""},"then":{"op":"if","when":{"op":"equals","left":{"op":"path","from":"nestedContract","path":""},"right":{"op":"literal","value":"agent-refusal-evidence.v1"}},"then":{"op":"if","when":{"op":"equals","left":{"op":"path","from":"refusalModelDisposition","path":""},"right":{"op":"literal","value":"PROVIDER_UNAVAILABLE"}},"then":{"op":"literal","value":"PROVIDER_UNAVAILABLE"},"else":{"op":"literal","value":"REFUSED"}},"else":{"op":"literal","value":"ADMITTED"}},"else":{"op":"path","from":"input","path":"disposition"}}},"value":{"op":"if","when":{"op":"equals","left":{"op":"path","from":"disposition","path":""},"right":{"op":"literal","value":"ADMITTED"}},"then":{"op":"object","fields":{"contractId":{"op":"literal","value":"invoke-database-capability-result.v1"},"disposition":{"op":"path","from":"disposition","path":""},"result":{"op":"path","from":"result","path":""},"invocationDisposition":{"op":"path","from":"input","path":"disposition"}}},"else":{"op":"object","fields":{"contractId":{"op":"literal","value":"invoke-database-capability-result.v1"},"disposition":{"op":"path","from":"disposition","path":""},"result":{"op":"path","from":"result","path":""}}}}}}',@object OUTPUT,@definition OUTPUT,@digest OUTPUT;
-- Declared typed row: executed as a declared write statement between the mint and
-- the optional normalize.
-- A5 typed row (declare-objective-invoke-outcome-shaping.commit.sql:131-153; fix-objective-shaping-expression.commit.sql:77-89).
IF (SELECT MAX(d.semantic_object_definition_pk)
    FROM model.estate_definition ed
    JOIN model.semantic_object_definition d ON d.semantic_object_definition_pk=ed.semantic_object_definition_pk
    WHERE ed.estate_model_pk=(SELECT estate_model_pk FROM source.current_model WHERE singleton_id=1)
      AND d.semantic_object_pk=@object) <>@definition
 THROW 51000,N'OBJECTIVE_SHAPING_TRANSFORMATION_CONTENT_RETAINED',1;
DECLARE @t_transformation_pk bigint,@t_version_pk bigint;
SET @t_transformation_pk=(SELECT transformation_pk FROM model.transformation WHERE semantic_object_pk=@object);
IF @t_transformation_pk IS NULL
BEGIN
 INSERT model.transformation(namespace_pk,transformation_id,semantic_object_pk,object_kind)
 SELECT namespace_pk,N'shape-objective-invocation-result',@object,'TRANSFORMATION'
 FROM model.semantic_object WHERE semantic_object_pk=@object;
 SET @t_transformation_pk=SCOPE_IDENTITY();
END
SET @t_version_pk=(SELECT transformation_version_pk FROM model.transformation_version WHERE semantic_object_definition_pk=@definition);
IF @t_version_pk IS NULL
BEGIN
 INSERT model.transformation_version(transformation_pk,semantic_object_pk,semantic_object_definition_pk,definition_digest,
  expression_profile,object_kind,_owner_definition_pk,_canonical_pointer)
 VALUES(@t_transformation_pk,@object,@definition,@digest,'json-expression-tree.v1','TRANSFORMATION',@definition,N'');
 SET @t_version_pk=SCOPE_IDENTITY();
END
IF NOT EXISTS (SELECT 1 FROM model.transformation_version WHERE transformation_version_pk=@t_version_pk AND semantic_object_definition_pk=@definition)
 THROW 51000,N'OBJECTIVE_SHAPING_TYPED_ROW_MISSING',1;
SET @definition=@t_version_pk;
EXEC model.normalize_transformation_expression @definition;
-- Verification read: the configured read must return at least
-- semantic_object_definition_pk and definition_digest for the minted definition.
SELECT g.newest_selected_sod AS semantic_object_definition_pk, g.definition_digest AS definition_digest, g.definition_digest_hex AS definition_digest_hex, CONVERT(nvarchar(max),CONVERT(varchar(max),co.content_bytes) COLLATE Latin1_General_100_BIN2_UTF8) AS definition_json, CONVERT(bit,CASE WHEN g.typed_version_pk IS NULL THEN 0 ELSE 1 END) AS typed_row_present, g.selected_generation_count FROM analysis.fv_selected_definition((SELECT estate_model_pk FROM source.current_model WHERE singleton_id=1), 'TRANSFORMATION', N'shape-objective-invocation-result', N'sidefx:capability:request-capability-from-objective') g JOIN source.content_object co ON co.content_object_pk=g.canonical_content_pk

COMMIT;
