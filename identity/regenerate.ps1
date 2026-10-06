[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$CodeLightlyRoot,
    [string]$ReceiptPath
)
$ErrorActionPreference = 'Stop'
$identityRoot = $PSScriptRoot
$dalRoot = Split-Path $identityRoot -Parent
$generator = Join-Path $CodeLightlyRoot 'platform/apps/console/DALComparisonTestApp/DALComparisonTestApp.csproj'
if (-not (Test-Path -LiteralPath $generator)) { throw 'CodeLightly generator project was not found.' }
if ([string]::IsNullOrWhiteSpace($env:SFX_IDENTITY_CONNECTION_STRING)) { throw 'Set SFX_IDENTITY_CONNECTION_STRING in this process first.' }
$configPath = Join-Path $identityRoot 'SFX.Identity.DAL.Config.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($config.SchemaReaderConfig.ConnectionString -or $config.ConnectionStringEnvVar -ne 'SFX_IDENTITY_CONNECTION_STRING') {
    throw 'Identity generation requires the dedicated environment setting, not an embedded connection string.'
}
$adminProject = Join-Path $dalRoot 'tools/identity-database/IdentityDatabase.csproj'
$catalogPath = Join-Path $identityRoot 'verification/latest-schema.json'
dotnet run --project $adminProject -c Release -- inspect $identityRoot $catalogPath
if ($LASTEXITCODE -ne 0) { throw 'Identity schema inspection failed.' }
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
$summary = $catalog.resultSets[0][0]
if ($summary.database_name -ne 'sfx-identity' -or $summary.has_view_definition -ne 1 -or $summary.table_count -lt 7) {
    throw 'Identity schema is missing or cannot be fully inspected. Run the migration preflight/install separately.'
}
# Gate regeneration on the database/source lineage, not merely a successful build.
# SQL Server stores CREATE OR ALTER using the observed CREATE header below;
# every subsequent UTF-16 byte must match the authored procedure definition.
$migrationFiles = @(Get-ChildItem -LiteralPath (Join-Path $identityRoot 'sql/migrations') -Filter '*.commit.sql' | Sort-Object Name)
$definitionsByName = @{}
foreach ($migrationFile in $migrationFiles) {
    $migration = Get-Content -LiteralPath $migrationFile.FullName -Raw
    foreach ($definition in [regex]::Matches($migration, "EXEC\(N'(CREATE OR ALTER PROCEDURE (?:''|[^'])*)'\);")) {
        $body = $definition.Groups[1].Value.Replace("''", "'")
        $identityMatch = [regex]::Match($body, 'CREATE OR ALTER PROCEDURE \[([^\]]+)\]\.\[([^\]]+)\]')
        if (-not $identityMatch.Success) { throw 'Procedure declaration must include schema and name.' }
        $definitionsByName[$identityMatch.Groups[1].Value + '.' + $identityMatch.Groups[2].Value] = $body
    }
}
$matchedProcedureBodies = 0
foreach ($procedure in $config.Procedures) {
    $name = $procedure.Name; $schemaName = $procedure.Schema
    $body = $definitionsByName[$schemaName + '.' + $name]
    if (-not $body) { throw "No migration accounts for $schemaName.$name." }
    $storedForm = [regex]::Replace($body, '^CREATE OR ALTER PROCEDURE', 'CREATE   PROCEDURE')
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::Unicode.GetBytes($storedForm))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $row = @($catalog.resultSets[6] | Where-Object { $_.procedure_name -eq $name -and $_.schema_name -eq $schemaName })
    if ($row.Count -ne 1 -or $row[0].definition_sha256 -ne $hash) {
        throw "Installed procedure differs from migration: $name. Reconcile the database declaration before regenerating."
    }
    $matchedProcedureBodies++
}
if ($matchedProcedureBodies -ne $config.Procedures.Count) {
    throw 'The migration must account for every configured identity procedure.'
}
dotnet run --project $generator -c Release -- $configPath $identityRoot
if ($LASTEXITCODE -ne 0) { throw 'Identity generation failed.' }
foreach ($procedure in $config.Procedures) {
    $schemaClass = (($procedure.Schema -split '_' | ForEach-Object { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) }) -join '')
    $class = $schemaClass + (($procedure.Name -split '_' | ForEach-Object {
        $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1)
    }) -join '')
    if (-not (Test-Path -LiteralPath (Join-Path $identityRoot "Procedures/Models/$class.cs"))) {
        throw "Missing generated typed result model for $($procedure.Name)."
    }
}
dotnet build (Join-Path $identityRoot 'SFX.Identity.DAL.csproj') -c Release
if ($LASTEXITCODE -ne 0) { throw 'Generated identity DAL build failed.' }
$manifest = Get-Content (Join-Path $identityRoot 'catalog-manifest.v1.json') -Raw | ConvertFrom-Json
foreach ($artifact in $manifest.artifacts) {
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $identityRoot $artifact.path)).Hash.ToLowerInvariant()
    if ($actual -ne $artifact.sha256) { throw "Generated manifest hash mismatch: $($artifact.path)" }
}
if ($ReceiptPath) {
    $revision = git -C $CodeLightlyRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the generator revision.' }
    $dirty = @(git -C $CodeLightlyRoot status --porcelain)
    [ordered]@{
        capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
        database = 'sfx-identity'
        generatorCommit = $revision
        generatorDirty = ($dirty.Count -gt 0)
        configSha256 = (Get-FileHash $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
        catalogDigest = $manifest.catalogDigest
        manifestArtifacts = $manifest.artifacts.Count
        manifestHashMismatches = 0
        configuredProcedures = $config.Procedures.Count
        liveTables = $summary.table_count
        liveProcedures = $summary.procedure_count
        installedProcedureBodyHashMatches = $matchedProcedureBodies
        sqlHeaderNormalization = 'SQL Server persists CREATE OR ALTER PROCEDURE as CREATE   PROCEDURE; remaining UTF-16 bytes match exactly.'
        migrations = @($migrationFiles | ForEach-Object { [ordered]@{ path = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } })
        identityDalSha256 = (Get-FileHash (Join-Path $identityRoot 'bin/Release/net8.0/SFX.Identity.DAL.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
        build = 'Release passed'
        scope = 'Schema generation and artifact integrity; live provider acceptance is recorded separately.'
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReceiptPath -Encoding utf8
}
Write-Output "Identity DAL regenerated: $($summary.table_count) tables, $($config.Procedures.Count) typed procedures; manifest hashes verified."

