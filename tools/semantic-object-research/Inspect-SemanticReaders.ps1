# Research only: fixed reader corpus; no installation, regeneration or writer calls.
# The receipt contains schemas, counts and bounded state vocabulary, not row payloads.
[CmdletBinding()]
param(
    [ValidateSet('Machine', 'User', 'Process')]
    [string]$EnvironmentTarget = 'Machine',
    [string]$ReceiptPath = 'verification/2026-10-09-semantic-readers.json'
)

$ErrorActionPreference = 'Stop'
$connection = $null
$transaction = $null
$reader = $null
function Get-TextDigest([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function New-ResearchCommand([string]$Sql) {
    $command = $connection.CreateCommand()
    $command.Transaction = $transaction
    $command.CommandTimeout = 90
    $command.CommandText = $Sql
    return $command
}

try {
    $setting = [Environment]::GetEnvironmentVariable('sidefx-connection-string', $EnvironmentTarget)
    if ([string]::IsNullOrWhiteSpace($setting)) { throw 'Required connection setting is absent.' }
    $connection = [System.Data.SqlClient.SqlConnection]::new($setting)
    $connection.Open()
    $command = New-ResearchCommand "SELECT DB_NAME(),snapshot_isolation_state_desc,is_read_committed_snapshot_on FROM sys.databases WHERE name=DB_NAME()"
    $reader = $command.ExecuteReader()
    if (-not $reader.Read() -or $reader.GetString(0) -ne 'sidefx') { throw 'Unexpected database.' }
    $snapshotState = $reader.GetString(1)
    $rcsi = $reader.GetBoolean(2)
    $reader.Close()
    $reader = $null
    $command.Dispose()
    if ($snapshotState -ne 'ON') { throw 'Snapshot isolation must already be enabled.' }
    $transaction = $connection.BeginTransaction([System.Data.IsolationLevel]::Snapshot)
    $command = New-ResearchCommand 'SELECT estate_model_pk FROM source.current_model WHERE singleton_id=1'
    $estate = [long]$command.ExecuteScalar()
    $command.Dispose()
    $receipt = [ordered]@{
        schemaVersion = 'sfx-semantic-reader-research.v1'
        capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        database = 'sidefx'
        environmentTarget = $EnvironmentTarget
        estateModelPk = $estate.ToString([Globalization.CultureInfo]::InvariantCulture)
        isolation = 'SNAPSHOT'
        snapshotIsolationState = $snapshotState
        readCommittedSnapshot = $rcsi
        scope = 'One snapshot transaction; fixed read procedures; rolled back. Metadata and counts only. No generated-DAL, HTTP, admission or cross-language acceptance claim.'
        procedures = @()
        observations = @()
    }
    $names = @('analysis.read_capability_details', 'analysis.read_provider_details', 'analysis.read_kernel_canonical_graph',
        'analysis.fv_extract_execution_authority', 'model.assert_execution_authority_conformance', 'model.assert_capability_topology_conformance',
        'model.patch_capability_envelope')
    foreach ($name in $names) {
        $command = New-ResearchCommand 'SELECT OBJECT_DEFINITION(OBJECT_ID(@name))'
        [void]$command.Parameters.Add('@name', [System.Data.SqlDbType]::NVarChar, 256)
        $command.Parameters['@name'].Value = $name
        $definition = $command.ExecuteScalar()
        if ($definition -isnot [string]) { throw 'Reader definition unavailable.' }
        $receipt.procedures += [ordered]@{ name = $name; definitionUtf8Sha256 = Get-TextDigest $definition; definitionCharacters = $definition.Length }
        $command.Dispose()
    }
    $corpus = @(
        @{ procedure = 'analysis.read_capability_details'; parameter = 'capability_id'; id = 'ui-page-landing'; emit = $true },
        @{ procedure = 'analysis.read_capability_details'; parameter = 'capability_id'; id = 'ui-page-landing'; emit = $false },
        @{ procedure = 'analysis.read_capability_details'; parameter = 'capability_id'; id = 'ui-page-landing'; emit = $null },
        @{ procedure = 'analysis.read_provider_details'; parameter = 'provider_id'; id = 'sfx-ui-explorer-region-header' },
        @{ procedure = 'analysis.read_provider_details'; parameter = 'provider_id'; id = 'sfx-ui-explorer-region-left-sidebar' },
        @{ procedure = 'analysis.read_provider_details'; parameter = 'provider_id'; id = 'sfx-ui-explorer-region-right-sidebar' },
        @{ procedure = 'analysis.read_provider_details'; parameter = 'provider_id'; id = 'sfx-ui-explorer-region-sidebar' },
        @{ procedure = 'analysis.read_kernel_canonical_graph'; parameter = 'capability_id'; id = 'authenticate-ide-user' }
    )
    foreach ($item in $corpus) {
        $command = New-ResearchCommand $item.procedure
        $command.CommandType = [System.Data.CommandType]::StoredProcedure
        $p = $command.Parameters.Add('@' + $item.parameter, [System.Data.SqlDbType]::NVarChar, 400)
        $p.Value = $item.id
        $p = $command.Parameters.Add('@estate_model_pk', [System.Data.SqlDbType]::BigInt)
        $p.Value = $estate
        if ($item.ContainsKey('emit')) {
            $p = $command.Parameters.Add('@emit', [System.Data.SqlDbType]::Bit)
            $p.Value = if ($null -eq $item.emit) { [DBNull]::Value } else { $item.emit }
            $p = $command.Parameters.Add('@result', [System.Data.SqlDbType]::NVarChar, -1)
            $p.Direction = [System.Data.ParameterDirection]::Output
        }
        $observation = [ordered]@{ procedure = $item.procedure; identity = $item.id; resultSets = @() }
        if ($item.ContainsKey('emit')) { $observation.emit = $item.emit }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $reader = $command.ExecuteReader()
        do {
            if ($reader.FieldCount -eq 0) { continue }
            $schema = $reader.GetSchemaTable()
            $columns = @()
            $nullCounts = [ordered]@{}
            $stateCounts = [ordered]@{}
            $labels = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $columnName = $reader.GetName($i)
                $metadata = $schema.Rows[$i]
                $columns += [ordered]@{
                    ordinal = $i; name = $columnName; sqlType = $reader.GetDataTypeName($i)
                    clrType = $reader.GetFieldType($i).FullName
                    allowsDbNull = [bool]$metadata.AllowDBNull
                    size = [int]$metadata.ColumnSize
                    precision = if ($metadata.NumericPrecision -is [DBNull]) { $null } else { [int]$metadata.NumericPrecision }
                    scale = if ($metadata.NumericScale -is [DBNull]) { $null } else { [int]$metadata.NumericScale }
                }
                $nullCounts[$columnName] = 0
                if ($columnName -in @('row_state', 'row_kind', 'provider_state', 'binding_state', 'state', 'gate_state', 'gate_status', 'parity_status', 'subject_contract_state', 'reconstruction_state', 'unprojected_content_state')) {
                    $stateCounts[$columnName] = [ordered]@{}
                }
            }
            $rows = 0
            while ($reader.Read()) {
                $rows++
                if ($rows -gt 100000) { throw 'Research row budget exceeded.' }
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $columnName = $reader.GetName($i)
                    if ($reader.IsDBNull($i)) { $nullCounts[$columnName]++; continue }
                    if ($columnName -eq 'result_set') { [void]$labels.Add([string]$reader.GetValue($i)) }
                    if ($stateCounts.Contains($columnName)) {
                        $value = [string]$reader.GetValue($i)
                        if ($value.Length -le 80 -and $value -cmatch '^[A-Z][A-Z0-9_ -]*$') {
                            $counts = $stateCounts[$columnName]
                            if (-not $counts.Contains($value)) { $counts[$value] = 0 }
                            $counts[$value]++
                        }
                    }
                }
            }
            $observation.resultSets += [ordered]@{
                ordinal = $observation.resultSets.Count + 1
                labels = @($labels | Sort-Object)
                rowCount = $rows; columns = $columns; observedNullCounts = $nullCounts; stateCounts = $stateCounts
            }
        } while ($reader.NextResult())
        $reader.Close()
        $reader = $null
        if ($item.ContainsKey('emit')) {
            $outputValue = $command.Parameters['@result'].Value
            $observation.resultOutputIsNull = $null -eq $outputValue -or $outputValue -is [DBNull]
        }
        if ($item.ContainsKey('emit') -and $item.emit -eq $false) {
            $document = [string]$command.Parameters['@result'].Value
            $parsed = $document | ConvertFrom-Json
            $observation.document = [ordered]@{
                utf8Sha256 = Get-TextDigest $document
                utf8Bytes = [Text.Encoding]::UTF8.GetByteCount($document)
                sets = @($parsed.PSObject.Properties | ForEach-Object {
                    [ordered]@{ name = $_.Name; rowCount = @($_.Value).Count; firstRowProperties = @(if (@($_.Value).Count -gt 0) { $_.Value[0].PSObject.Properties.Name }) }
                })
            }
        }
        $watch.Stop()
        $observation.elapsedMilliseconds = $watch.ElapsedMilliseconds
        $receipt.observations += $observation
        Write-Output ($item.procedure + ' / ' + $item.id + ': ' + $observation.resultSets.Count + ' result sets in ' + $watch.ElapsedMilliseconds + ' ms')
        $command.Dispose()
    }
    $rowMode = $receipt.observations | Where-Object { $_.procedure -eq 'analysis.read_capability_details' -and $_.emit -eq $true }
    $documentMode = $receipt.observations | Where-Object { $_.procedure -eq 'analysis.read_capability_details' -and $_.emit -eq $false }
    $mismatches = @()
    foreach ($set in $rowMode.resultSets) {
        $match = @($documentMode.document.sets | Where-Object { $_.name -eq $set.labels[0] })
        if ($match.Count -ne 1 -or $match[0].rowCount -ne $set.rowCount -or
            @(Compare-Object @($set.columns.name) @($match[0].firstRowProperties)).Count -gt 0) {
            $mismatches += $set.ordinal
        }
    }
    $receipt.emitDocumentComparison = [ordered]@{
        scope = 'Section names, row counts and first-row property names; no value equality or canonical-digest parity claim.'
        rowModeSets = $rowMode.resultSets.Count
        documentModeSets = $documentMode.document.sets.Count
        mismatchedOrdinals = $mismatches
    }
    $transaction.Rollback()
    $transaction.Dispose()
    $transaction = $null
    $receipt.transactionOutcome = 'ROLLED_BACK'
    $target = [IO.Path]::GetFullPath($ReceiptPath)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::WriteAllText($target, ($receipt | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    Write-Output ('Receipt saved: ' + $target)
} catch {
    # Provider exception messages may contain connection details or data; do not print them.
    Write-Error ('Research failed at script line ' + $_.InvocationInfo.ScriptLineNumber + ' (' + $_.Exception.GetType().Name + '). No completed receipt written.') -ErrorAction Continue
    exit 1
} finally {
    if ($reader) { $reader.Dispose() }
    if ($transaction) { try { $transaction.Rollback() } catch {}; $transaction.Dispose() }
    if ($connection) { $connection.Dispose() }
}
