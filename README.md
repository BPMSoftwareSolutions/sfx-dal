# SFX.DAL

This workspace is **auto-generated** by [CodeLightly](https://github.com/BPMSoftwareSolutions/Codelightly) from the `sidefx` database schema.

Everything in this workspace (and the `SFX.DAL.csproj` project file) is produced from the live database. Generated files are overwritten on every regeneration - do not edit them directly.

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
