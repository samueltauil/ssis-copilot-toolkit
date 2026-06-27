# SSIS Copilot Toolkit — Hands-on Guide

This guide walks through the toolkit by **running it**. Every step uses files that ship in this repository and commands that work today. By the end you will have provisioned a demo warehouse, generated all four supported package patterns from metadata JSON, validated them with the same gate `@ssis-validator` runs, and opened a generated `.dtsx` in Copilot Chat.

If you only want to read the architecture, start at [AGENTS.md](AGENTS.md). If you want to see the toolkit do work, stay here.

## What you need

- **Windows** with PowerShell 7+ (`pwsh`) — Windows PowerShell 5.1 also works.
- **.NET 8 SDK** — the managed-OM helper builds against this.
- **SQL Server 2022 or 2025 client tools** — for `Microsoft.SqlServer.ManagedDTS.dll` and `dtexec.exe`.
- **SQL Server 2025 Developer Edition** on the default instance `.\SQL2025` with **AdventureWorks2025** attached. The demo metadata JSON assumes this; change `source.server` / `target.server` in the JSON if your instance name differs.
- **GitHub Copilot Chat** in Visual Studio 2026 (18.4+) or VS Code (Stable or Insiders) — needed for Step 7.

Everything else is in the repo.

---

## Step 0 — Clone the repo

```powershell
git clone https://github.com/samueltauil/ssis-copilot-toolkit.git
cd ssis-copilot-toolkit
```

Or click **"Use this template"** on GitHub; the first push to `main` will strip the demo content and leave you with a clean overlay. This guide assumes you cloned the full repo (demo content intact).

## Step 1 — Build the managed-OM host (one-time, ~10s)

The toolkit never hand-edits `.dtsx`. Instead, a small .NET 8 console host wraps `Microsoft.SqlServer.Dts.Runtime` (the same managed object model the SSIS designer uses internally). PowerShell calls that host.

```powershell
.\tools\lib\SsisOmHost\Build-SsisOmHost.ps1
```

You should see a `dotnet publish` succeed and `tools\lib\SsisOmHost\SsisOmHost.exe` appear. Run this once per machine, or after pulling a change under `tools\lib\SsisOmHost\`.

## Step 2 — Bootstrap the demo databases

This is **demo-only**; it ships in the template repo but is excluded from the brownfield overlay. It creates two SQL databases for the AdventureWorks2025 walkthrough and applies the schema scripts under [templates/sql/](templates/sql/).

```powershell
.\install\Install-Toolkit.ps1
```

What it does (idempotent — safe to re-run):

1. Verifies the `SqlServer` PowerShell module is available.
2. Checks connectivity to `.\SQL2025` and that **SSISDB** exists (warns if not — create it in SSMS via _Integration Services Catalogs_).
3. Creates `CopilotSSIS_Source` and `CopilotSSIS_Warehouse` if missing (pass `-Force` to drop and recreate).
4. Applies [templates/sql/01-create-databases.sql](templates/sql/) through `06-fact-load.sql` in order: schemas (`stg`, `dim`, `fact`, `etl`), tables, and seed rows.
5. Confirms `AdventureWorks2025` is attached.

If you are on a different instance, pass `-Server`:

```powershell
.\install\Install-Toolkit.ps1 -Server 'YOUR\INSTANCE'
```

## Step 3 — Validate a shipped package (proves the gate works)

The repo ships four pre-built demo packages under [templates/ssis-project/Packages/](templates/ssis-project/Packages/). Validate one with the same primitive `@ssis-validator` calls:

```powershell
.\tools\Test-SsisPackage.ps1 -Package .\templates\ssis-project\Packages\Stg_Customer.dtsx
```

Expected last line:

```text
dtexec /Validate exit=0 (PASS)
```

That is `dtexec.exe /File ... /Validate /WarnAsError` — the canonical pre-deployment validation. Exit code 0 = the package is structurally valid, all connection managers resolve, and all data-flow column metadata matches.

Now confirm the SSIS designer can re-open it (round-trip via `Application.LoadPackage`):

```powershell
.\tools\Test-SsisDesignerLoad.ps1 -Package .\templates\ssis-project\Packages\Stg_Customer.dtsx
```

Expected:

```text
Application.LoadPackage round-trip: PASS
```

Together those two checks are the non-bypassable delivery gate. Every package `@ssis-author` produces gets put through them by `@ssis-validator` before the agent reports "done".

## Step 4 — Regenerate the staging package from metadata

This is the loop the agent uses on every authoring turn: metadata JSON in, `.dtsx` out.

Open [templates/metadata/Stg_Customer.metadata.json](templates/metadata/Stg_Customer.metadata.json) — that is the **only** authored artifact for this package. The JSON pins `pattern: "staging"`, source/target connections, the `SELECT` that drives the OLE DB Source, the column mapping, and `protectionLevel: "DontSaveSensitive"`.

Regenerate the package:

```powershell
.\tools\New-SsisPackage.ps1 -Metadata .\templates\metadata\Stg_Customer.metadata.json
```

The script:

1. Loads the JSON, validates required fields per the `metadata-schema` instructions.
2. Dispatches to the matching pattern module under `tools\lib\patterns\` (here, `StagingLoad.psm1`).
3. Invokes `SsisOmHost.exe` to construct the package via the managed OM and call `Application.SaveToXml`.
4. Writes the result to `templates\ssis-project\Packages\Stg_Customer.dtsx` (overwriting the previous one).

Re-run Step 3 against the regenerated `.dtsx` — same PASS. The output is deterministic for a given input.

## Step 5 — Generate the other three patterns

The four supported patterns each ship with a metadata example. Generate them the same way:

```powershell
# Type-1 dimension (overwrite on key match)
.\tools\New-SsisPackage.ps1 -Metadata .\templates\metadata\Dim_Customer_Type1.metadata.json

# Type-2 dimension (IsCurrent, EffectiveFrom, EffectiveTo)
.\tools\New-SsisPackage.ps1 -Metadata .\templates\metadata\Dim_CustomerHistory_Type2.metadata.json

# Fact load with surrogate-key lookups
.\tools\New-SsisPackage.ps1 -Metadata .\templates\metadata\Fact_SalesOrder.metadata.json
```

Validate all four at once:

```powershell
Get-ChildItem .\templates\ssis-project\Packages\*.dtsx | ForEach-Object {
    .\tools\Test-SsisPackage.ps1 -Package $_.FullName
}
```

Each should print `dtexec /Validate exit=0 (PASS)`.

## Step 6 — Edit metadata, regenerate, re-validate

This is the round trip that shows the toolkit's value. Open [templates/metadata/Stg_Customer.metadata.json](templates/metadata/Stg_Customer.metadata.json) and flip `truncateBeforeLoad` from `true` to `false`. Regenerate:

```powershell
.\tools\New-SsisPackage.ps1 -Metadata .\templates\metadata\Stg_Customer.metadata.json
.\tools\Test-SsisPackage.ps1 -Package .\templates\ssis-project\Packages\Stg_Customer.dtsx
```

The `.dtsx` will differ — the `Execute SQL Task` that issues `TRUNCATE TABLE` is gone — and the gate still passes. You never opened the XML. Revert the JSON and regenerate to undo.

## Step 7 — Drive it from Copilot Chat

Open the repo in Visual Studio 2026 (18.4+) or VS Code with GitHub Copilot Chat enabled. In the Chat input:

```text
@ssis-author /generate-staging-package
> Load AdventureWorks2025 Person.Address into stg.Address.
```

`@ssis-author` will:

1. Resolve `Person.Address` columns via the `adventureworks-mapping` skill — it never invents column names.
2. Write `templates/metadata/Stg_Address.metadata.json`.
3. Call `New-SsisPackage.ps1` to emit `templates/ssis-project/Packages/Stg_Address.dtsx`.
4. Spawn `@ssis-validator`, which runs `Test-SsisPackage.ps1` and `Test-SsisDesignerLoad.ps1` and returns a structured `VERDICT: PASS|FAIL` block.
5. Report the verdict back to you verbatim.

If the verdict is `FAIL`, the agent loads the `dtexec-validation-triage` skill to map the error to the metadata field most likely at fault — and patches the JSON, never the XML.

Other useful prompts:

```text
@ssis-author /generate-dim-type2-package
> Build dim.Customer from stg.Customer keyed on CustomerID, tracking changes to FirstName, LastName, EmailAddress.

@ssis-author /generate-validation-sql
> Validation queries for the staging and Type-2 dimension packages we just built.

@ssis-author /generate-package-docs
> Document templates/ssis-project/Packages/Stg_Customer.dtsx.
```

All eight `/`-prompts live in [.github/prompts/](.github/prompts/).

## Step 8 — Open the generated package in the SSIS designer

In Visual Studio 2026 (18.4+) with the SQL Server Data Tools workload installed, open `templates/ssis-project/` as a folder and inspect any `.dtsx`. The control flow and data flow render cleanly — this is the round-trip `Test-SsisDesignerLoad.ps1` proves on every gate run.

> Note: a full `.dtproj` for the demo is roadmap; the `.dtsx` files are valid standalone for design-time inspection and `dtexec /Validate`.

---

## What's next

- **Brownfield install.** Drop the overlay into your existing SSIS repo with the one-liner in the [README brownfield section](README.md#2-existing-ssis-repo-drop-in-the-overlay). The `Demo` list above (the SQL scripts, metadata JSON, demo packages, this guide) is **not** copied — your repo keeps its own data model.
- **Deploy and execute.** `Build-SsisIspac.ps1`, `Publish-SsisIspac.ps1`, and `Start-SsisExecution.ps1` are roadmap. The `/deploy-and-execute` prompt refuses today. When they ship, the flow will be: build `.ispac` via `SSISBuild.exe`, deploy via `catalog.deploy_project`, execute via `catalog.create_execution` → `catalog.start_execution`. See the [`ssisdb-deployment`](.github/skills/ssisdb-deployment/SKILL.md) skill for the contract those primitives will satisfy.
- **Add a pattern.** The four shipped patterns cover the common ELT cases. To add a fifth, write a new module under `tools\lib\patterns\`, extend the dispatcher in `tools\lib\SsisOm.psm1`, document the metadata fields in [`.github/instructions/metadata-schema.instructions.md`](.github/instructions/metadata-schema.instructions.md), and add a slash prompt under [`.github/prompts/`](.github/prompts/).
- **Read the contract.** [AGENTS.md](AGENTS.md) covers the hard rules, the two-layer architecture, and what NOT to invent.
