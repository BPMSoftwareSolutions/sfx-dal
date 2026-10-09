# SFX.DAL

The [Semantic Object Projection implementation strategy](docs/semantic-object-projection-strategy.md)
describes a proposed typed semantic layer above this generated DAL, grounded in
the [October 9 live reader research](verification/2026-10-09-semantic-readers.json).
Its first read slice, a CodeLightly-generated immutable capability snapshot, lives in
[semantic/](semantic/README.md) and is excluded from the root project.

The separately generated [SFX.Identity.DAL](identity/README.md) lives in `identity/`
and targets `sfx-identity` using `SFX_IDENTITY_CONNECTION_STRING`. It has its own
schema migrations, CodeLightly config, assembly and verification receipts. The
root project remains the estate DAL described below.

This workspace is **auto-generated** by [CodeLightly](https://github.com/BPMSoftwareSolutions/Codelightly) from the `sidefx` database schema.

The estate models, repositories, helpers and `SFX.DAL.csproj` are produced from the live database. Generated files are overwritten on every regeneration - do not edit them directly. Configuration, documentation, verification tools and SQL are maintained source.

```
Models/        Interfaces/        Repositories/        Helpers/     <- tables (and shared helpers)
Views/
  Models/      Interfaces/        Repositories/                     <- views (read-only repositories)
Functions/
  Models/      Interfaces/        Repositories/                     <- row-returning functions (IF/TF)
```

## Regenerating

1. Ensure the connection string environment variable configured in `SFX.DAL.Config.json` (`sidefx-connection-string`, Machine target) points at the database.
2. From the CodeLightly repository:

   ```powershell
   cd platform\apps\console\DALComparisonTestApp
   dotnet run -c Release -- "C:\lab\repos\sfx-dal\SFX.DAL.Config.json" "C:\lab\repos\sfx-dal"
   ```

3. Build the generated output:

   ```powershell
   dotnet build C:\lab\repos\sfx-dal\SFX.DAL.csproj
   ```

Stored procedures are explicitly selected in `SFX.DAL.Config.json` under
`Procedures`. Add newly installed procedures there before regenerating. A changed
signature also requires regeneration and rebuilding consumers such as
`sfx-providers/providers/procedure-extract`; an already published API keeps its
previous DAL until it is rebuilt and deployed. Generating a writer does not admit
it to the hosted API's reader allowlist.

The [2026-10-02 regeneration receipt](verification/2026-10-02-regeneration.json)
records the live catalog, generator revision, generated manifest and DLL hashes,
checks and SQL review findings. This generation covers 90 procedures (eight new
authoring writers), excluding the three existing `r1_txn_*` test helpers. It also
adds `expectedDigest` to `ModelUpdateDefinitionValueRepository`. Both DAL and
procedure-extract Release builds passed with zero warnings/errors; all eight
provider-reader result sets matched through the consumer, and 13 named SQL
refusals passed. These checks establish wrapper/transport behavior, not full
authoring correctness: the receipt records the outstanding SQL findings.

## Customizing generated code

Place customizations in the matching `.Custom.cs` companion files; those are created once and never overwritten (same folder as the generated file):

- `Models/<Table>.Custom.cs` / `Views/Models/<View>.Custom.cs` / `Functions/Models/<Function>.Custom.cs`
- `Interfaces/I<Object>Repository.Custom.cs`
- `Repositories/<Object>Repository.Custom.cs`

Generation settings (project name, output directory, connection string env var, tables, views, functions, custom queries) live in `SFX.DAL.Config.json`.

## What gets generated

- Base tables from the `analysis`, `media`, `model`, `runtime`, and `source` schemas.
- One model per table, plus a repository/interface per table that has a primary key. Tables without a primary key (for example `model.r1_txn_probe4` and `model.r1_txn_probe5`) receive models only.
- Views listed under `Views` in the config get read-only repositories (`GetById`/`GetAll`/`GetAny`, no writes); `KeyColumns` enable typed lookups.
- Row-returning functions (IF/TF) listed under `Functions` get typed `Execute`/`ExecuteAsync(param...)` plus `GetAny`/`GetAnyAsync(QueryDetail<T>, param...)`; scalar functions are skipped.
- Composite primary keys are supported via typed `GetById` / `GetByIdAsync` overloads using every key column.
- Computed columns and `timestamp`/rowversion columns are read-only in the generated repositories (excluded from inserts and updates).
