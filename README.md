# SSIS Copilot Toolkit

GitHub Copilot customizations (agents, skills, prompts, and PowerShell primitives) that let you author SQL Server Integration Services (SSIS) packages agentically from chat. The toolkit works in both **Visual Studio 2026 (18.4+)** and **VS Code** with GitHub Copilot Chat, and packages round-trip cleanly to the native SSIS designer that ships with Visual Studio.

The custom agent `@ssis-author` writes structured metadata JSON, then calls a thin PowerShell layer that drives the same managed object model the SSIS designer uses internally (`Microsoft.SqlServer.Dts.Runtime`) to emit valid `.dtsx`. The agent never hand-edits the XML.

## Two ways to onboard

### 1. New repo (use this as a template)

Click **"Use this template" → "Create a new repository"** on the GitHub page. On the first push to `main`, a one-shot workflow ([template-cleanup.yml](.github/workflows/template-cleanup.yml)) strips the demo content (AdventureWorks2025 walkthrough, engineering plan, this README) and leaves you with a clean overlay: `tools/`, `.github/`, `.vscode/`, the brownfield installer, and a fresh README that points at your new repo.

### 2. Existing SSIS repo (drop in the overlay)

Use this when you already have an SSIS repository (with your own `.dtproj`, packages, SQL, and folder layout) and just want to add the Copilot toolkit on top of it, without re-cloning or restructuring anything.

```powershell
# From the root of your existing SSIS repository, in PowerShell on Windows:
iex (irm https://raw.githubusercontent.com/samueltauil/ssis-copilot-toolkit/main/install/Add-CopilotSsisToolkit.ps1)
```

What it does:

1. Downloads [overlay.manifest.psd1](install/overlay.manifest.psd1) (the single source of truth for what ships) and [Add-CopilotSsisToolkit.ps1](install/Add-CopilotSsisToolkit.ps1).
2. Copies the **overlay** into your tree — the manifest's `Overlay` list: `tools/`, `.github/agents/`, `.github/skills/`, `.github/prompts/`, `.github/instructions/`, `.github/copilot-instructions.md`, `.vscode/`, and `install/` itself. See [What ships in the overlay](#what-ships-in-the-overlay) below for the complete list.
3. **Skips** any file that already exists in your repo (default `-Mode Skip`). Pass `-Mode Overwrite` to force-update every overlay file.
4. Appends a **managed block** to your `AGENTS.md` and `.gitignore`. A managed block is a region fenced by `<!-- BEGIN: ssis-copilot-toolkit ... -->` / `<!-- END: ssis-copilot-toolkit -->` markers in `AGENTS.md` and the same comments with `#` in `.gitignore`. On re-run the script finds those markers and replaces only what's between them, leaving the rest of the file untouched. If your repo has no `AGENTS.md` or `.gitignore` yet, the script creates one with the block in it. These two files are managed this way regardless of `-Mode`.
5. **Does not copy** the demo content (the manifest's `Demo` list): `templates/sql/`, `templates/metadata/`, `templates/ssis-project/`, `install/Install-Toolkit.ps1`, the demo script, this `README.md`, or the `template-cleanup.yml` workflow. Those are for the AdventureWorks2025 walkthrough that ships with the template, not for your repo.

Re-running the one-liner is safe and idempotent: copied files stay (or get refreshed under `-Mode Overwrite`), managed blocks get replaced in place, and your own files are left alone.

After either path:

```powershell
# 1. Build the managed-OM helper (one-time, requires .NET 8 + SQL Server 2022/2025 client tools)
.\tools\lib\SsisOmHost\Build-SsisOmHost.ps1

# 2. Open the repo in Visual Studio 2026 (18.4+) or VS Code, then in Copilot Chat:
@ssis-author /generate-staging-package
@ssis-author /generate-dim-type2-package
```

## Using the toolkit from Copilot Chat

Everything is driven through two custom agents and a set of slash prompts you invoke in the Chat input. Skills load automatically based on context; you do not call them by name.

### Custom agents

| Agent | What it does | When to call it |
|---|---|---|
| `@ssis-author` | The only sanctioned entry point for SSIS work. Identifies which of the four supported patterns applies, writes metadata JSON, calls `tools/New-SsisPackage.ps1`, and spawns `@ssis-validator` at the end. Refuses to hand-edit `.dtsx`, to author packages outside the four patterns, or to skip the gate. | Any time you want to create, modify, deploy, or execute an SSIS package. |
| `@ssis-validator` | Read-only delivery-gate runner. Takes a `.dtsx` plus its `.dtproj`, runs `Test-SsisPackage.ps1` and `Test-SsisDesignerLoad.ps1` in order, and returns a structured `VERDICT: PASS\|FAIL` block with per-step exit codes and the first failing step's diagnosis. Cannot edit, deploy, or execute. | Usually invoked automatically by `@ssis-author`. Call it directly if you want to re-validate a package on its own. |

Direct example:

```text
@ssis-validator validate templates/ssis-project/StageCustomer.dtsx in templates/ssis-project/DemoProject.dtproj
```

### Slash prompts (invoke after `@ssis-author`)

| Prompt | What it does |
|---|---|
| `/scaffold-new-ssis-project` | One-time setup. Creates `.dtproj`, `Project.params`, and the `Source` / `Warehouse` connection managers via the managed OM. (Refuses today; depends on a roadmap primitive.) |
| `/generate-staging-package` | Source table to `stg.*` via OLE DB Source plus OLE DB Destination. |
| `/generate-dim-type1-package` | `stg.*` to `dim.*` with overwrite-on-key-match (Type-1 SCD). |
| `/generate-dim-type2-package` | `stg.*` to `dim.*` with `IsCurrent`, `EffectiveFrom`, `EffectiveTo` (Type-2 SCD). |
| `/generate-fact-package` | `stg.*` to `fact.*` with surrogate-key lookups against one or more `dim.*` tables. |
| `/generate-validation-sql` | Emits T-SQL queries that prove a package loaded the right row counts into the right tables with the right shape. |
| `/generate-package-docs` | Generates human-readable Markdown documentation for a `.dtsx` (control flow, data flow, parameters, connections, runbook). |
| `/deploy-and-execute` | Builds the `.ispac`, deploys to SSISDB, then executes one or more packages and reports status. (Refuses today; depends on roadmap primitives.) |

Example session in Copilot Chat:

```text
@ssis-author /generate-staging-package
> Load AdventureWorks2025 Sales.Customer into stg.Customer.

@ssis-author /generate-dim-type2-package
> Build dim.Customer from stg.Customer keyed on CustomerID.

@ssis-author /generate-validation-sql
> Validate the staging and dim packages we just built.
```

### PowerShell primitives (callable directly or via Ctrl+Shift+B)

You normally never call these yourself; `@ssis-author` does. They are surfaced in `.vscode/tasks.json` for ad-hoc use.

| Primitive | Purpose |
|---|---|
| `tools/lib/SsisOmHost/Build-SsisOmHost.ps1` | Build the .NET 8 managed-OM host. Run once per machine. |
| `tools/New-SsisPackage.ps1 -Metadata <file.json>` | Generate a `.dtsx` from metadata JSON. |
| `tools/Test-SsisPackage.ps1 -Package <file.dtsx>` | Validate via `dtexec /Validate /WarnAsError`. |
| `tools/Test-SsisDesignerLoad.ps1 -Package <file.dtsx>` | Round-trip via `Microsoft.SqlServer.Dts.Runtime.Application.LoadPackage` to prove the designer can re-open it. |

### Skills (auto-loaded by Copilot)

You do not invoke skills directly; Copilot loads them based on the active file or the agent's needs. The eight that ship: `ssis-delivery-gate`, `ssis-package-patterns`, `dtexec-validation-triage`, `dtsx-xml-anatomy`, `ssis-clone-roundtrip`, `git-roundtrip-for-ssis`, `ssisdb-deployment`, `adventureworks-mapping`.

## What ships in the overlay

| Path | What |
|---|---|
| `.github/agents/` | `@ssis-author` (authoring), `@ssis-validator` (delivery gate) |
| `.github/skills/` | 8 skills: `ssis-delivery-gate`, `ssis-package-patterns`, `dtexec-validation-triage`, `dtsx-xml-anatomy`, `ssis-clone-roundtrip`, `git-roundtrip-for-ssis`, `ssisdb-deployment`, `adventureworks-mapping` |
| `.github/prompts/` | 8 `/`-invokable workflows: scaffold, generate-{staging,dim-type1,dim-type2,fact}, deploy-and-execute, generate-{validation-sql,package-docs} |
| `.github/instructions/` | Per-file-pattern guidance (`.dtsx`, `.gitattributes`, metadata JSON, T-SQL, SSISDB) |
| `tools/New-SsisPackage.ps1` | Generate a `.dtsx` from metadata JSON |
| `tools/Test-SsisPackage.ps1` | Validate via `dtexec /Validate /WarnAsError` |
| `tools/Test-SsisDesignerLoad.ps1` | Round-trip via `Application.LoadPackage` |
| `tools/lib/SsisOm.psm1` + `tools/lib/patterns/` | PowerShell dispatchers that pick a pattern module per metadata JSON |
| `tools/lib/SsisOmHost/` | .NET 8 console host that wraps `Microsoft.SqlServer.Dts.Runtime` (`Program.cs`, `PackageBuilder.cs`, `MetadataHelpers.cs`, per-pattern builders under `Patterns/`). Built once via `Build-SsisOmHost.ps1` |
| `.vscode/tasks.json` | Surfaces the primitives as `Ctrl+Shift+B` build tasks |

Roadmap (referenced by `@ssis-author`'s `deploy-and-execute` and `scaffold-new-ssis-project` prompts, not yet shipped): `Build-SsisIspac.ps1`, `Publish-SsisIspac.ps1`, `Start-SsisExecution.ps1`, `Verify-ClonedProject.ps1`. The matching prompts refuse on invocation today.

## The four supported package patterns

`@ssis-author` only emits packages that match one of these four shapes. Anything else: the agent refuses and asks which pattern fits. The pattern recipes (the managed-OM call sequences) live in the [`ssis-package-patterns`](.github/skills/ssis-package-patterns/SKILL.md) skill; each pattern is implemented by a builder module under `tools\lib\patterns\`.

| Pattern | When | Module |
|---|---|---|
| Staging load | Source → `stg.*` | `StagingLoad` |
| Type-1 dimension | `stg.*` → `dim.*` (overwrite on key match) | `Type1Dimension` |
| Type-2 dimension (SCD-2) | `stg.*` → `dim.*` with current-flag + effective dates | `Type2Dimension` |
| Fact load | `stg.*` → `fact.*` with surrogate-key lookups | `FactLoad` |

### Why these four

These are the load patterns of a Kimball-style dimensional warehouse, expressed in the smallest set that covers the lifecycle of a row from source system to fact table. Each one solves a different problem; together they cover the everyday ELT cases without overlap.

#### Staging load — `Source → stg.*`

**Why it exists.** It decouples extraction from transformation. Source systems are often slow, transient, behind firewalls, or owned by another team. Landing rows in a `stg.*` table inside your warehouse gives you a replayable snapshot you control: downstream dim and fact loads can re-run without re-querying the source, source-schema drift is isolated to one place, and incremental-load watermarks live next to the data. Staging is also the only place where raw column projection and minimal type casting happen — **no business logic, no surrogate-key assignment, no history tracking**.

**Shape.** OLE DB Source → OLE DB Destination. Optional truncate-before-load via an Execute SQL Task. The source `SELECT` may flatten joins (the demo's `Sales.Customer` → `stg.Customer` joins `Person.Person` and `Person.EmailAddress`), but it does not enrich.

#### Type-1 dimension — `stg.* → dim.*`, overwrite on key match

**Why it exists.** Some attributes do not need history. A customer's preferred email or phone number changes? Just overwrite the row — nobody runs analytics that asks "what was this customer's email on March 15th?" Type-1 is the right fit for **master and reference data, and for slowly-changing attributes that do not drive analytical queries**. It is cheaper than Type-2 in storage (no row versioning), simpler in queries (no `IsCurrent` filter, no effective-date range join), and faster to load.

**Shape.** Lookup against `dim` by business key → Conditional Split (matched → update, unmatched → insert) → OLE DB Command for updates plus OLE DB Destination for inserts.

#### Type-2 dimension (SCD-2) — `stg.* → dim.*` with `IsCurrent`, `EffectiveFrom`, `EffectiveTo`

**Why it exists.** When you need to answer **"what did this dimension look like at the time the fact happened?"** A sales order from last March must join the customer dim row that was current last March, not today's row — even if the customer's territory, segment, or address has changed since. Type-2 is required for accurate point-in-time reporting, regulatory reporting where history cannot be rewritten, and any attribute drift that drives analytical slicing (territory reassignments, segment migrations, status transitions).

**Shape.** Lookup against `dim` by business key → Conditional Split (new business key / tracked attribute changed / no change) → for changed rows: expire the old row (`IsCurrent = 0`, `EffectiveTo = now`) and insert a new row (`IsCurrent = 1`, `EffectiveFrom = now`, `EffectiveTo = 9999-12-31`). The metadata JSON pins which attributes are *tracked* (trigger a new version) versus *Type-1 overwritten in place*.

#### Fact load — `stg.* → fact.*` with surrogate-key lookups

**Why it exists.** Facts store the measurements; dimensions hold the descriptive context. A fact row holds **surrogate keys** (small INTs sourced from the dim tables), not natural / business keys, for three reasons: (a) surrogate keys are stable across SCD-2 versions, so a fact row pins itself to a specific dim version forever; (b) joins are narrower and faster than joining on composite natural keys; (c) source-system key changes do not ripple into the warehouse. The fact loader's job is mechanical: take staged business keys, look up the right surrogate keys (current row for Type-1 dims, point-in-time row for Type-2 dims), write the fact.

**Shape.** OLE DB Source on `stg` → one Lookup per foreign key (to each `dim`) → Conditional Split for lookup-miss handling (route to error table or insert an inferred-member row) → OLE DB Destination into `fact`.

### What is deliberately not a pattern

- **Source → fact direct.** Skips staging, couples extraction to transformation, no replay. Refuse.
- **Truncate-and-reload dim or fact.** Destroys history; breaks SCD-2 contract; invalidates any saved fact-to-dim joins. Refuse.
- **SCD-3 / SCD-6.** Rare in practice; the column-explosion of SCD-3 and the hybrid complexity of SCD-6 are usually better served by a second Type-2 dim or a snapshot fact. Not a pattern today; raise an issue if you have a real case.
- **Aggregated / snapshot facts.** A specialization of the fact load. Build them on top of the `FactLoad` module rather than as a separate pattern.

## Read next

- [GUIDE.md](GUIDE.md): hands-on walkthrough driven entirely from GitHub Copilot Chat — generate, modify, validate, and document all four package patterns by typing prompts, no PowerShell required after the one-time prep.
- [AGENTS.md](AGENTS.md): repo-wide agent contract.
- [install/overlay.manifest.psd1](install/overlay.manifest.psd1): single source of truth for the brownfield installer and template-cleanup workflow.

## References

The toolkit's design decisions trace back to these Microsoft Learn topics. Use them when reading the agent and skill files, when extending a pattern module, or when triaging a validation failure.

**SSIS managed object model and CLIs**

- [`Microsoft.SqlServer.Dts.Runtime` namespace](https://learn.microsoft.com/en-us/dotnet/api/microsoft.sqlserver.dts.runtime) — the .NET API the toolkit's host wraps.
- [Building packages programmatically](https://learn.microsoft.com/en-us/sql/integration-services/building-packages-programmatically/building-packages-programmatically) — landing page for the OM authoring model.
- [Loading and saving packages programmatically](https://learn.microsoft.com/en-us/sql/integration-services/building-packages-programmatically/loading-and-saving-packages) — `Application.LoadPackage` and `Package.SaveToXml`, used by the generator and by `Test-SsisDesignerLoad.ps1`.
- [`dtexec` utility](https://learn.microsoft.com/en-us/sql/integration-services/packages/dtexec-utility) — called by `Test-SsisPackage.ps1` with `/Validate /WarnAsError`.
- [`dtutil` utility](https://learn.microsoft.com/en-us/sql/integration-services/dtutil-utility) — `/IDRegenerate`, the last-resort fix for lineage-ID corruption.
- [SSIS DevOps standalone build tools (`SSISBuild.exe`)](https://learn.microsoft.com/en-us/sql/integration-services/devops/ssis-devops-standalone) — the headless project builder referenced by the roadmap `Build-SsisIspac.ps1` primitive.
- [`[MS-DTSX]` package XML format](https://learn.microsoft.com/openspecs/sql_data_portability/ms-dtsx/235600e9-0c13-4b5b-a388-aa3c65aec1dd) and [`[MS-DTSX2]`](https://learn.microsoft.com/openspecs/sql_data_portability/ms-dtsx2/fb216aa4-62ab-41c8-a6d5-5b1002739d21) — the open spec for the `.dtsx` file. Read-only reference; the toolkit never hand-writes this.

**Project deployment, catalog, and security**

- [Deploy Integration Services projects and packages](https://learn.microsoft.com/en-us/sql/integration-services/packages/deploy-integration-services-ssis-projects-and-packages) — Project Deployment Model, `.ispac`, SSISDB. The only execution path the toolkit supports.
- [Deploy an SSIS project with PowerShell](https://learn.microsoft.com/en-us/sql/integration-services/ssis-quickstart-deploy-powershell) — pattern for the roadmap `Publish-SsisIspac.ps1` primitive.
- [`catalog.deploy_project`](https://learn.microsoft.com/en-us/sql/integration-services/system-stored-procedures/catalog-deploy-project-ssisdb-database) — server-side project deployment.
- [`catalog.validate_package`](https://learn.microsoft.com/en-us/sql/integration-services/system-stored-procedures/catalog-validate-package-ssisdb-database) — server-side pre-execution validation (catches env-ref and project-parameter issues `dtexec /Validate` cannot).
- [`catalog.create_execution`](https://learn.microsoft.com/en-us/sql/integration-services/system-stored-procedures/catalog-create-execution-ssisdb-database) + [`catalog.start_execution`](https://learn.microsoft.com/en-us/sql/integration-services/system-stored-procedures/catalog-start-execution-ssisdb-database) — the canonical execution sequence for the roadmap `Start-SsisExecution.ps1` primitive.
- [Access control for sensitive data in packages](https://learn.microsoft.com/en-us/sql/integration-services/security/access-control-for-sensitive-data-in-packages) — `ProtectionLevel`. The toolkit pins every package and project to `DontSaveSensitive`.
- [SSIS on Linux](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-migrate-ssis) — the constraint that makes the toolkit Windows-only (no SSISDB on Linux; Project Deployment Model unsupported).

**Copilot customization**

- [VS Code Copilot customization overview](https://code.visualstudio.com/docs/copilot/customization/overview) — agents, skills, prompts, and instructions. The portable schema both Visual Studio 2026 and VS Code honor.
- [`AGENTS.md` cross-tool convention](https://agents.md/) — the format used for the repo-wide agent contract.

## Requirements

- **Windows.** The SSIS managed OM and `dtexec` are Windows-only.
- **PowerShell 7+** (`pwsh`) preferred; Windows PowerShell 5.1 is supported.
- **.NET 8 SDK**, required by the managed-OM helper exe.
- **SQL Server 2022 or 2025 client tools**, which provide `Microsoft.SqlServer.ManagedDTS.dll` and `dtexec.exe`.
- **GitHub Copilot Chat** in Visual Studio 2026 (18.4+) or VS Code (Stable or Insiders).
