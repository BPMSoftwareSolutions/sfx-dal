-- Compile assertions after the migration adds graphs_json.
EXEC(N'-- Disposable fixtures inside the migration''s rollback transaction only.
DECLARE @p uniqueidentifier=NEWID(),@s uniqueidentifier=NEWID(),@a uniqueidentifier=NEWID(),@r varchar(128)=CONVERT(varchar(36),NEWID());
DECLARE @now datetimeoffset(7)=SYSUTCDATETIME(),@expires datetimeoffset(7)=DATEADD(minute,10,SYSUTCDATETIME());
INSERT [identity].principal VALUES(@p,N''run-evidence-preflight'',CONVERT(nvarchar(36),@p),1,1,@now);
INSERT [identity].authentication_attempt VALUES(@a,N''run-evidence-preflight'',CONVERT(nvarchar(36),@p),@p,1,1,2,@now,@expires);
INSERT [identity].session VALUES(@s,@p,@a,1,1,CRYPT_GEN_RANDOM(32),@now,@expires,@now,NULL);
EXEC evidence.register_run @r,@p,@s,N''fixture-capability'',N''fixture'', ''circuit-host'';
EXEC evidence.register_run @r,@p,@s,N''fixture-capability'',N''fixture'', ''circuit-host'';
IF (SELECT COUNT(*) FROM evidence.run WHERE run_id=@r)<>1 THROW 51000,''EVIDENCE_REGISTRATION_IDEMPOTENCE'',1;
DECLARE @bytes varbinary(max)=0x01020304,@hash varbinary(32)=HASHBYTES(''SHA2_256'',0x01020304);
EXEC evidence.append_trace_chunk @r,''circuit-host'',1,3,3,@hash,@bytes;
EXEC evidence.append_trace_chunk @r,''circuit-host'',1,3,3,@hash,@bytes;
IF (SELECT COUNT(*) FROM evidence.run_trace_chunk WHERE run_id=@r)<>1 THROW 51000,''EVIDENCE_CHUNK_IDEMPOTENCE'',1;
DECLARE @run_json nvarchar(max)=N''{"runId":"''+@r+N''","state":"completed","partial":false}'';
EXEC evidence.complete_run @r,''circuit-host'',@run_json,NULL,N''{"fixture":true}'',3;
EXEC evidence.complete_run @r,''circuit-host'',@run_json,NULL,N''{"fixture":true}'',3;
IF (SELECT COUNT(*) FROM evidence.run_completion WHERE run_id=@r AND trace_complete=1)<>1 THROW 51000,''EVIDENCE_COMPLETE_IDEMPOTENCE'',1;
EXEC evidence.read_run @p,@r;
EXEC evidence.read_trace_chunks @p,@r,0;
DECLARE @unowned TABLE(first_cursor bigint,last_cursor bigint,record_count int,content_digest binary(32),content varbinary(max));
DECLARE @other uniqueidentifier=NEWID();
INSERT @unowned EXEC evidence.read_trace_chunks @other,@r,0;
IF EXISTS(SELECT 1 FROM @unowned) THROW 51000,''EVIDENCE_CROSS_PRINCIPAL_DISCLOSURE'',1;
IF (SELECT COUNT(*) FROM sys.database_permissions WHERE grantee_principal_id=DATABASE_PRINCIPAL_ID(''sfx_evidence_runtime'')
 AND class=3 AND major_id=SCHEMA_ID(''evidence'') AND state=''D'' AND permission_name IN(''SELECT'',''INSERT'',''UPDATE'',''DELETE''))<>4
 THROW 51000,''EVIDENCE_DIRECT_ACCESS_NOT_DENIED'',1;
SELECT N''run-evidence-contract-preflight'' AS check_name,CONVERT(bit,1) AS passed,CONVERT(int,6) AS assertion_count;

-- The original caller shape still stores a parent without a graph collection.
IF EXISTS(SELECT 1 FROM evidence.run_completion WHERE run_id=@r AND graphs_json IS NOT NULL)
 THROW 51000,''EVIDENCE_LEGACY_GRAPHS_CHANGED'',1;
DECLARE @legacy_digest binary(32)=HASHBYTES(''SHA2_256'',CONCAT(LEN(@run_json),'':'',@run_json,'':'',-1,'':'',N'''','':'',LEN(N''{"fixture":true}''),'':'',N''{"fixture":true}'','':'',3));
IF NOT EXISTS(SELECT 1 FROM evidence.run_completion WHERE run_id=@r AND material_digest=@legacy_digest)
 THROW 51000,''EVIDENCE_LEGACY_DIGEST_CHANGED'',1;
DECLARE @root_run varchar(128)=CONVERT(varchar(36),NEWID());
DECLARE @graphs nvarchar(max)=N''[{"rootExecutionId":"root-a","graphId":"graph:shared","canonicalGraphDigest":"digest-a","projection":{"rootExecutionId":"root-a","graphId":"graph:shared","cells":[{"cellId":"a"}]}},{"rootExecutionId":"root-b","graphId":"graph:shared","canonicalGraphDigest":"digest-b","projection":{"rootExecutionId":"root-b","graphId":"graph:shared","cells":[{"cellId":"b"}]}}]'';
DECLARE @parent nvarchar(max)=N''{"rootExecutionId":"parent","graphId":"graph:parent"}'';
DECLARE @root_json nvarchar(max)=N''{"runId":"''+@root_run+N''","state":"completed","partial":false}'';
EXEC evidence.register_run @root_run,@p,@s,N''fixture-capability'',N''fixture'',''circuit-host'';
EXEC evidence.append_trace_chunk @root_run,''circuit-host'',1,3,3,@hash,@bytes;
EXEC evidence.complete_run @root_run,''circuit-host'',@root_json,@parent,NULL,3,@graphs;
EXEC evidence.complete_run @root_run,''circuit-host'',@root_json,@parent,NULL,3,@graphs;
IF NOT EXISTS(SELECT 1 FROM evidence.run_completion WHERE run_id=@root_run AND graphs_json=@graphs AND graph_json=@parent AND trace_complete=1)
 THROW 51000,''EVIDENCE_ROOT_GRAPHS_NOT_RETAINED'',1;
IF (SELECT COUNT(*) FROM evidence.run_completion c CROSS APPLY OPENJSON(c.graphs_json) g WHERE c.run_id=@root_run AND JSON_VALUE(g.value,''$.graphId'')=N''graph:shared'')<>2
 THROW 51000,''EVIDENCE_SHARED_GRAPH_ROOTS_COLLAPSED'',1;
EXEC evidence.read_run @p,@root_run;
SELECT N''per-root-run-graphs-preflight'' AS check_name,CONVERT(bit,1) AS passed,CONVERT(int,4) AS assertion_count;
');
