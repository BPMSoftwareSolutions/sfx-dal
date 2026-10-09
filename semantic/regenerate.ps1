# Offline semantic projection regeneration: contracts in, C# out. Opens no database
# connection, applies no views and installs nothing. Proves byte-for-byte reproducibility
# by generating twice into scratch directories before replacing SFX.Semantics/Generated.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CodeLightlyRoot,
    [string]$ReceiptPath
)
$ErrorActionPreference = 'Stop'
$semanticRoot = $PSScriptRoot
$dalRoot = Split-Path $semanticRoot -Parent
$configuration = Join-Path $semanticRoot 'semantic-projection.config.json'
$generatorProject = Join-Path $CodeLightlyRoot 'platform/apps/console/SemanticProjectionGenerator/SemanticProjectionGenerator.csproj'
if (-not (Test-Path -LiteralPath $generatorProject)) { throw 'The CodeLightly semantic projection generator was not found.' }

$revision = (git -C $CodeLightlyRoot rev-parse HEAD)
if ($LASTEXITCODE -ne 0) { throw 'Cannot identify the generator revision.' }
$uncommitted = @(git -C $CodeLightlyRoot status --porcelain -- platform/codelightly/src platform/apps/console/SemanticProjectionGenerator).Count -gt 0
$env:CODELIGHTLY_SOURCE_SHA = if ($uncommitted) { $revision + '+uncommitted' } else { $revision }

dotnet build $generatorProject -c Release -nologo -v:q
if ($LASTEXITCODE -ne 0) { throw 'Generator build failed.' }

function Invoke-Generator([string[]]$Arguments) {
    dotnet run --no-build --project $generatorProject -c Release -- @Arguments
    if ($LASTEXITCODE -ne 0) { throw ('Generator failed: ' + ($Arguments -join ' ')) }
}

function Get-Tree([string]$Directory) {
    $map = [ordered]@{}
    Get-ChildItem -LiteralPath $Directory -File | Sort-Object Name | ForEach-Object {
        $map[$_.Name] = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
    }
    return $map
}

# Two independent generations from the same inputs must be byte-identical.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('sfx-semantic-regen-' + [Guid]::NewGuid().ToString('N'))
try {
    Invoke-Generator @('generate', $configuration, '--output', (Join-Path $scratch 'a'))
    Invoke-Generator @('generate', $configuration, '--output', (Join-Path $scratch 'b'))
    $first = Get-Tree (Join-Path $scratch 'a')
    $second = Get-Tree (Join-Path $scratch 'b')
    $differences = @($first.Keys | Where-Object { $second[$_] -ne $first[$_] }) + @($second.Keys | Where-Object { -not $first.Contains($_) })
    if ($differences.Count -gt 0) { throw ('Generation is not deterministic: ' + ($differences -join ', ')) }
} finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}

Invoke-Generator @('generate', $configuration)
Invoke-Generator @('check', $configuration)

$generated = Join-Path $semanticRoot 'SFX.Semantics/Generated'
$installed = Get-Tree $generated
foreach ($name in $first.Keys) {
    if ($installed[$name] -ne $first[$name]) { throw "Installed output differs from the scratch generation: $name" }
}

dotnet build (Join-Path $semanticRoot 'SFX.Semantics.Cli/SFX.Semantics.Cli.csproj') -c Release -nologo -v:q
if ($LASTEXITCODE -ne 0) { throw 'Semantic projection build failed (warnings are errors).' }
dotnet build (Join-Path $dalRoot 'SFX.DAL.csproj') -c Release -nologo -v:q
if ($LASTEXITCODE -ne 0) { throw 'The estate DAL no longer builds independently of semantic/.' }

$manifest = Get-Content -LiteralPath (Join-Path $generated 'semantic-projection-manifest.v1.json') -Raw | ConvertFrom-Json
foreach ($artifact in $manifest.artifacts) {
    if ($installed[$artifact.path] -ne $artifact.sha256) { throw "Manifest hash mismatch: $($artifact.path)" }
}

if ($ReceiptPath) {
    $receipt = [ordered]@{
        schemaVersion = 'sfx-semantic-generation.v1'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        scope = 'Offline generation from maintained contracts. No database connection, view application, installation or writer. Builds prove compilation (warnings as errors for semantic/) and that the root estate DAL still builds without semantic/.'
        generator = [ordered]@{
            repository = 'Codelightly'
            revision = $revision
            uncommittedGeneratorSource = $uncommitted
            emitter = $manifest.generator.emitter
            version = $manifest.generator.version
        }
        configuration = $manifest.configuration
        contracts = $manifest.contracts
        determinism = [ordered]@{
            independentGenerations = 2
            identical = $true
            files = $first.Count
            installedMatchesScratch = $true
            driftCheck = 'no drift'
        }
        artifacts = $manifest.artifacts
        builds = @('semantic/SFX.Semantics.Cli (includes SFX.Semantics)', 'SFX.DAL.csproj')
    }
    $target = [IO.Path]::GetFullPath((Join-Path (Get-Location) $ReceiptPath))
    [IO.File]::WriteAllText($target, (($receipt | ConvertTo-Json -Depth 10) -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Write-Output ('Receipt saved: ' + $target)
}
Write-Output ('Regenerated ' + $first.Count + ' file(s) deterministically from ' + @($manifest.contracts).Count + ' contract(s).')
