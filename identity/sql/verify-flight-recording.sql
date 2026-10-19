-- Compile assertions after 006 adds the flight plan/recording tables.
DECLARE @p uniqueidentifier=NEWID(),@s uniqueidentifier=NEWID(),@a uniqueidentifier=NEWID(),@r varchar(128)=CONVERT(varchar(36),NEWID());
DECLARE @rec uniqueidentifier=NEWID();
DECLARE @now datetimeoffset(7)=SYSUTCDATETIME(),@expires datetimeoffset(7)=DATEADD(minute,10,SYSUTCDATETIME());
INSERT [identity].principal VALUES(@p,N'flight-preflight',CONVERT(nvarchar(36),@p),1,1,@now);
INSERT [identity].authentication_attempt VALUES(@a,N'flight-preflight',CONVERT(nvarchar(36),@p),@p,1,1,2,@now,@expires);
INSERT [identity].session VALUES(@s,@p,@a,1,1,CRYPT_GEN_RANDOM(32),@now,@expires,@now,NULL);
DECLARE @steps nvarchar(max)=N'[{"capabilityId":"read-topology-conformance","purpose":"Inspect"},{"capabilityId":"repair-capability-topology","purpose":"Repair"},{"capabilityId":"read-topology-conformance","purpose":"Verify"}]';
EXEC evidence.upsert_flight_plan @p,N'frontier-alpha',N'Repair the readiness topology',@steps;
IF (SELECT plan_revision FROM evidence.flight_plan WHERE principal_id=@p AND agent_id=N'frontier-alpha')<>1 THROW 51000,'FLIGHT_PLAN_REVISION_ONE',1;
DECLARE @d1 binary(32)=(SELECT plan_digest FROM evidence.flight_plan WHERE principal_id=@p AND agent_id=N'frontier-alpha');
EXEC evidence.upsert_flight_plan @p,N'frontier-alpha',N'Repair the readiness topology',@steps;
IF (SELECT plan_revision FROM evidence.flight_plan WHERE principal_id=@p AND agent_id=N'frontier-alpha')<>1
 OR (SELECT plan_digest FROM evidence.flight_plan WHERE principal_id=@p AND agent_id=N'frontier-alpha')<>@d1 THROW 51000,'FLIGHT_PLAN_REPLAY',1;
EXEC evidence.begin_flight_recording @p,N'frontier-alpha',@rec;
IF NOT EXISTS(SELECT 1 FROM evidence.flight_recording WHERE flight_recording_id=@rec AND principal_id=@p AND plan_revision=1 AND plan_digest=@d1)
 THROW 51000,'FLIGHT_RECORDING_SNAPSHOT',1;
EXEC evidence.register_run @r,@p,@s,N'fixture-capability',N'fixture','flight-host';
EXEC evidence.attach_run_to_recording @p,@r,@rec;
IF NOT EXISTS(SELECT 1 FROM evidence.run WHERE run_id=@r AND principal_id=@p AND flight_recording_id=@rec)
 THROW 51000,'FLIGHT_RECORDING_ATTACH',1;
EXEC evidence.upsert_flight_plan @p,N'frontier-alpha',N'Repair the readiness topology',N'[{"capabilityId":"read-topology-conformance","purpose":"Inspect"}]';
IF (SELECT plan_revision FROM evidence.flight_plan WHERE principal_id=@p AND agent_id=N'frontier-alpha')<>2 THROW 51000,'FLIGHT_PLAN_REVISION_TWO',1;
IF NOT EXISTS(SELECT 1 FROM evidence.flight_recording WHERE flight_recording_id=@rec AND plan_revision=1 AND steps_snapshot=@steps)
 THROW 51000,'FLIGHT_RECORDING_SNAPSHOT_CHANGED',1;
EXEC evidence.complete_flight_recording @p,@rec,N'Repaired the topology and verified it.';
IF NOT EXISTS(SELECT 1 FROM evidence.flight_recording WHERE flight_recording_id=@rec AND principal_id=@p
 AND frontier_response=N'Repaired the topology and verified it.' AND completed_at IS NOT NULL)
 THROW 51000,'FLIGHT_RECORDING_COMPLETION',1;
DECLARE @read TABLE(value nvarchar(max));
INSERT @read EXEC evidence.read_flight_recording @p,@rec;
DECLARE @value nvarchar(max)=(SELECT TOP(1) value FROM @read);
IF ISJSON(@value)<>1 OR JSON_VALUE(@value,'$.plan_revision')<>'1'
 OR JSON_VALUE(@value,'$.frontier_response')<>N'Repaired the topology and verified it.'
 OR JSON_QUERY(@value,'$.runs') IS NULL
 OR (SELECT COUNT(*) FROM OPENJSON(@value,'$.runs'))<>1
 THROW 51000,'FLIGHT_RECORDING_READ',1;
DECLARE @p2 uniqueidentifier=NEWID(),@s2 uniqueidentifier=NEWID(),@a2 uniqueidentifier=NEWID();
INSERT [identity].principal VALUES(@p2,N'flight-preflight',CONVERT(nvarchar(36),@p2),1,1,@now);
INSERT [identity].authentication_attempt VALUES(@a2,N'flight-preflight',CONVERT(nvarchar(36),@p2),@p2,1,1,2,@now,@expires);
INSERT [identity].session VALUES(@s2,@p2,@a2,1,1,CRYPT_GEN_RANDOM(32),@now,@expires,@now,NULL);
DECLARE @other TABLE(value nvarchar(max));
INSERT @other EXEC evidence.read_flight_recording @p2,@rec;
IF EXISTS(SELECT 1 FROM @other WHERE value IS NOT NULL) THROW 51000,'FLIGHT_RECORDING_CROSS_PRINCIPAL_READ',1;
IF (SELECT COUNT(*) FROM sys.database_permissions WHERE grantee_principal_id=DATABASE_PRINCIPAL_ID('sfx_evidence_runtime')
 AND class=3 AND major_id=SCHEMA_ID('evidence') AND state='D')<>4
 THROW 51000,'EVIDENCE_DIRECT_ACCESS_NOT_DENIED',1;
IF (SELECT COUNT(*) FROM sys.database_permissions p JOIN sys.objects o ON o.object_id=p.major_id
 WHERE p.grantee_principal_id=DATABASE_PRINCIPAL_ID('sfx_evidence_runtime') AND p.state='G'
 AND o.schema_id=SCHEMA_ID('evidence') AND o.name IN ('upsert_flight_plan','begin_flight_recording','attach_run_to_recording','complete_flight_recording','read_flight_recording'))<>5
 THROW 51000,'FLIGHT_RECORDING_GRANTS_MISSING',1;
SELECT N'flight-recording-contract-preflight' AS check_name,CONVERT(bit,1) AS passed,CONVERT(int,9) AS assertion_count;