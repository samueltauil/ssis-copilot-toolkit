# SSIS Copilot Toolkit

GitHub Copilot customizations (agents, skills, prompts, and PowerShell primitives) that let you author SQL Server Integration Services (SSIS) packages agentically from chat. The toolkit works in both **Visual Studio 2026 (18.4+)** and **VS Code** with GitHub Copilot Chat, and packages round-trip cleanly to the native SSIS designer that ships with Visual Studio.

The custom agent **ssis-author** writes structured metadata JSON, then calls a thin PowerShell layer that drives the same managed object model the SSIS designer uses internally (`Microsoft.SqlServer.Dts.Runtime`) to emit valid `.dtsx`. The agent never hand-edits the XML.

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
2. Copies the **overlay** into your tree. The manifest's `Overlay` list: `tools/`, `.github/agents/`, `.github/skills/`, `.github/prompts/`, `.github/instructions/`, `.github/copilot-instructions.md`, `.vscode/`, and `install/` itself. See [What ships in the overlay](#what-ships-in-the-overlay) below for the complete list.
3. **Skips** any file that already exists in your repo (default `-Mode Skip`). Pass `-Mode Overwrite` to force-update every overlay file.
4. Appends a **managed block** to your `AGENTS.md` and `.gitignore`. A managed block is a region fenced by `<!-- BEGIN: ssis-copilot-toolkit ... -->` / `<!-- END: ssis-copilot-toolkit -->` markers in `AGENTS.md` and the same comments with `#` in `.gitignore`. On re-run the script finds those markers and replaces only what's between them, leaving the rest of the file untouched. If your repo has no `AGENTS.md` or `.gitignore` yet, the script creates one with the block in it. These two files are managed this way regardless of `-Mode`.
5. **Does not copy** the demo content (the manifest's `Demo` list): `templates/sql/`, `templates/metadata/`, `templates/ssis-project/`, `install/Install-Toolkit.ps1`, the demo script, this `README.md`, or the `template-cleanup.yml` workflow. Those are for the AdventureWorks2025 walkthrough that ships with the template, not for your repo.

Re-running the one-liner is safe and idempotent: copied files stay (or get refreshed under `-Mode Overwrite`), managed blocks get replaced in place, and your own files are left alone.

After either path:

```powershell
# 1. Build the managed-OM helper (one-time, requires .NET 8 + SQL Server 2022/2025 client tools)
.\tools\lib\SsisOmHost\Build-SsisOmHost.ps1

# 2. Open the repo in Visual Studio 2026 (18.4+) or VS Code, then in Copilot Chat:
# Select ssis-author from the agent picker, then run:
/generate-staging-package
/generate-dim-type2-package
```

## Using the toolkit from Copilot Chat

Everything is driven through two custom agents and a set of slash prompts you invoke in the Chat input. Skills load automatically based on context; you do not call them by name.

### Custom agents

| Agent | What it does | When to call it |
|---|---|---|
| **ssis-author** | The only sanctioned entry point for SSIS work. Identifies which of the four supported patterns applies, writes metadata JSON, calls `tools/New-SsisPackage.ps1`, and spawns **ssis-validator** at the end. Refuses to hand-edit `.dtsx`, to author packages outside the four patterns, or to skip the gate. | Any time you want to create, modify, deploy, or execute an SSIS package. Select this agent from the agent picker before running prompts. |
| **ssis-validator** | Read-only delivery-gate runner. Takes a `.dtsx` plus its `.dtproj`, runs `Test-SsisPackage.ps1` and `Test-SsisDesignerLoad.ps1` in order, and returns a structured `VERDICT: PASS\|FAIL` block with per-step exit codes and the first failing step's diagnosis. Cannot edit, deploy, or execute. | Usually invoked automatically by **ssis-author**. Call it directly if you want to re-validate a package on its own. Select this agent from the agent picker first. |

Direct example (select **ssis-validator** from the agent picker first):

```text
validate templates/ssis-project/StageCustomer.dtsx in templates/ssis-project/DemoProject.dtproj
```

### Slash prompts (select **ssis-author** from the agent picker first)

| Prompt | What it does |
|---|---|
| `/scaffold-new-ssis-project` | One-time setup. Creates `.dtproj`, `Project.params`, and the `Source` / `Warehouse` connection managers via `tools/New-SsisProject.ps1`. |
| `/generate-staging-package` | Source table to `stg.*` via OLE DB Source plus OLE DB Destination. |
| `/generate-dim-type1-package` | `stg.*` to `dim.*` with overwrite-on-key-match (Type-1 SCD). |
| `/generate-dim-type2-package` | `stg.*` to `dim.*` with `IsCurrent`, `EffectiveFrom`, `EffectiveTo` (Type-2 SCD). |
| `/generate-fact-package` | `stg.*` to `fact.*` with surrogate-key lookups against one or more `dim.*` tables. |
| `/generate-validation-sql` | Emits T-SQL queries that prove a package loaded the right row counts into the right tables with the right shape. |
| `/generate-package-docs` | Generates human-readable Markdown documentation for a `.dtsx` (control flow, data flow, parameters, connections, runbook). |
| `/deploy-and-execute` | Builds the `.ispac`, deploys to SSISDB, then executes one or more packages and reports status. (Refuses today; depends on roadmap primitives.) |

Example session in Copilot Chat (select **ssis-author** from the agent picker first):

```text
/generate-staging-package
> Load AdventureWorks2025 Sales.Customer into stg.Customer.

/generate-dim-type2-package
> Build dim.Customer from stg.Customer keyed on CustomerID.

/generate-validation-sql
> Validate the staging and dim packages we just built.
```

### PowerShell primitives (callable directly or via Ctrl+Shift+B)

You normally never call these yourself; the **ssis-author** agent does. They are surfaced in `.vscode/tasks.json` for ad-hoc use.

| Primitive | Purpose |
|---|---|
| `tools/lib/SsisOmHost/Build-SsisOmHost.ps1` | Build the .NET 8 managed-OM host. Run once per machine. |
| `tools/New-SsisPackage.ps1 -Metadata <file.json>` | Generate a `.dtsx` from metadata JSON. |
| `tools/Test-SsisPackage.ps1 -Package <file.dtsx>` | Validate via `dtexec /Validate /WarnAsError`. |
| `tools/Test-SsisDesignerLoad.ps1 -Package <file.dtsx>` | Round-trip via `Microsoft.SqlServer.Dts.Runtime.Application.LoadPackage` to prove the designer can re-open it. |
| `tools/New-SsisProject.ps1` | Generate `.dtproj`, connection managers (`.conmgr`), and `Project.params` for the demo project. |

### Skills (auto-loaded by Copilot)

You do not invoke skills directly; Copilot loads them based on the active file or the agent's needs. The eight that ship: `ssis-delivery-gate`, `ssis-package-patterns`, `dtexec-validation-triage`, `dtsx-xml-anatomy`, `ssis-clone-roundtrip`, `git-roundtrip-for-ssis`, `ssisdb-deployment`, `adventureworks-mapping`.

## What ships in the overlay

| Path | What |
|---|---|
| `.github/agents/` | **ssis-author** (authoring), **ssis-validator** (delivery gate) |
| `.github/skills/` | 8 skills: `ssis-delivery-gate`, `ssis-package-patterns`, `dtexec-validation-triage`, `dtsx-xml-anatomy`, `ssis-clone-roundtrip`, `git-roundtrip-for-ssis`, `ssisdb-deployment`, `adventureworks-mapping` |
| `.github/prompts/` | 8 `/`-invokable workflows: scaffold, generate-{staging,dim-type1,dim-type2,fact}, deploy-and-execute, generate-{validation-sql,package-docs} |
| `.github/instructions/` | Per-file-pattern guidance (`.dtsx`, `.gitattributes`, metadata JSON, T-SQL, SSISDB) |
| `tools/New-SsisPackage.ps1` | Generate a `.dtsx` from metadata JSON |
| `tools/Test-SsisPackage.ps1` | Validate via `dtexec /Validate /WarnAsError` |
| `tools/Test-SsisDesignerLoad.ps1` | Round-trip via `Application.LoadPackage` |
| `tools/lib/SsisOm.psm1` + `tools/lib/patterns/` | PowerShell dispatchers that pick a pattern module per metadata JSON |
| `tools/lib/SsisOmHost/` | .NET 8 console host that wraps `Microsoft.SqlServer.Dts.Runtime` (`Program.cs`, `PackageBuilder.cs`, `MetadataHelpers.cs`, per-pattern builders under `Patterns/`). Built once via `Build-SsisOmHost.ps1` |
| `.vscode/tasks.json` | Surfaces the primitives as `Ctrl+Shift+B` build tasks |

Roadmap (referenced by **ssis-author**'s `deploy-and-execute` prompt, not yet shipped): `Build-SsisIspac.ps1`, `Publish-SsisIspac.ps1`, `Start-SsisExecution.ps1`, `Verify-ClonedProject.ps1`. The matching prompt refuses on invocation today.

## The four supported package patterns

The **ssis-author** agent only emits packages that match one of these four shapes. Anything else: the agent refuses and asks which pattern fits. The pattern recipes (the managed-OM call sequences) live in the [`ssis-package-patterns`](.github/skills/ssis-package-patterns/SKILL.md) skill; each pattern is implemented by a builder module under `tools\lib\patterns\`.

| Pattern | When | Module |
|---|---|---|
| Staging load | Source → `stg.*` | `StagingLoad` |
| Type-1 dimension | `stg.*` → `dim.*` (overwrite on key match) | `Type1Dimension` |
| Type-2 dimension (SCD-2) | `stg.*` → `dim.*` with current-flag + effective dates | `Type2Dimension` |
| Fact load | `stg.*` → `fact.*` with surrogate-key lookups | `FactLoad` |

### Why these four

The toolkit follows the **Kimball dimensional modeling methodology** — the approach most SQL Server data warehouses have used since the 1990s. Kimball's core idea is simple: structure your warehouse as a star schema (central fact tables surrounded by dimension tables), stage raw extracts before transforming them, and version dimension rows with surrogate keys so facts remain historically accurate.

**Core Kimball principles** implemented by this toolkit:

- **Star schema design**: Facts at the center (measures + foreign keys), dimensions at the edges (descriptive attributes). No normalization across dimensions.
- **Conformed dimensions**: Shared dimensions (Customer, Product, Date) with consistent keys across fact tables enable drill-across queries.
- **Surrogate keys**: Integer keys assigned by the warehouse, decoupled from source-system natural keys. Protects facts from source-key changes and enables dimension versioning.
- **Slowly Changing Dimensions (SCD)**: Type 1 (overwrite, no history), Type 2 (versioned rows with effective dates and current flag), Type 3 (limited history in separate columns — not implemented).
- **Staging layer**: Land raw extracts in a `stg.*` schema before transformation. Makes ETL restartable, isolates source drift, and enables incremental loads.
- **Bus architecture**: Enterprise data warehouse as a collection of conformed dimensions and incrementally-built fact tables, not a single monolithic schema.

Ralph Kimball's *The Data Warehouse Toolkit* (Wiley, 3rd edition, 2013) is the canonical reference; Microsoft's own Fabric and Power BI documentation cites it directly (see [Kimball dimensional modeling methodology](#kimball-dimensional-modeling-methodology) in References below). The Kimball Group's [Dimensional Modeling Techniques](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/) article consolidates the full pattern catalog.

These are the load patterns of a Kimball-style dimensional warehouse, expressed in the smallest set that covers the lifecycle of a row from source system to fact table. Each one solves a different problem; together they cover the everyday ELT cases without overlap. The four pattern modules are direct implementations of patterns Microsoft documents on Learn (staging, SCD Type 1, SCD Type 2, surrogate-key fact loads), not toolkit-invented shapes. See [Dimensional modeling and load patterns](#dimensional-modeling-and-load-patterns) below for the per-topic links; each pattern subsection cites the most specific reference inline.

#### Staging load: `Source → stg.*`

Staging decouples extraction from transformation. Source systems are often slow, transient, behind firewalls, or owned by another team. Landing rows in a `stg.*` table inside your warehouse gives you a replayable snapshot you control: downstream dim and fact loads can re-run without re-querying the source, source-schema drift is isolated to one place, and incremental-load watermarks live next to the data. Staging is also the only place where raw column projection and minimal type casting happen. No business logic, no surrogate-key assignment, no history tracking.

Data flow: OLE DB Source then OLE DB Destination, with an optional truncate-before-load Execute SQL Task. The source `SELECT` may flatten joins (the demo's `Sales.Customer` to `stg.Customer` joins `Person.Person` and `Person.EmailAddress`), but it does not enrich.

Reference: Microsoft Learn, [Load tables in a dimensional model, *Stage data*](https://learn.microsoft.com/en-us/fabric/data-warehouse/dimensional-modeling-load-tables#stage-data). Recommends a dedicated `staging` schema to minimize source-system impact and to make the ETL restartable.

#### Type-1 dimension: `stg.* → dim.*`, overwrite on key match

Some attributes do not need history. When a customer's preferred email or phone number changes, overwriting the row is fine; nobody runs analytics that asks "what was this customer's email on March 15th?" Type-1 fits master and reference data, and any slowly-changing attribute that does not drive analytical queries. It is cheaper than Type-2 in storage (no row versioning), simpler in queries (no `IsCurrent` filter, no effective-date range join), and faster to load.

Data flow: Lookup against `dim` by business key, then Conditional Split (matched routes to update, unmatched routes to insert), then OLE DB Command for updates plus OLE DB Destination for inserts.

References: Microsoft Learn, [Dimension tables, *SCD Type 1*](https://learn.microsoft.com/en-us/fabric/data-warehouse/dimensional-modeling-dimension-tables#scd-type-1) for the overwrite-in-place definition, and [Slowly Changing Dimension transformation](https://learn.microsoft.com/en-us/sql/integration-services/data-flow/transformations/slowly-changing-dimension-transformation) for the native SSIS SCD Wizard's *changing attribute* path. That wizard output is the same shape this module emits.

#### Type-2 dimension (SCD-2): `stg.* → dim.*` with `IsCurrent`, `EffectiveFrom`, `EffectiveTo`

Use Type-2 when you need to answer "what did this dimension look like at the time the fact happened?" A sales order from last March must join the customer dim row that was current last March, not today's row, even if the customer's territory, segment, or address has changed since. Type-2 is required for accurate point-in-time reporting, for regulatory reporting where history cannot be rewritten, and for any attribute drift that drives analytical slicing (territory reassignments, segment migrations, status transitions).

Data flow: Lookup against `dim` by business key, then Conditional Split (new business key, tracked attribute changed, or no change). For changed rows, expire the old row (`IsCurrent = 0`, `EffectiveTo = now`) and insert a new row (`IsCurrent = 1`, `EffectiveFrom = now`, `EffectiveTo = 9999-12-31`). The metadata JSON pins which attributes are *tracked* (trigger a new version) versus *Type-1 overwritten in place*.

References: Microsoft Learn, [Dimension tables, *SCD Type 2*](https://learn.microsoft.com/en-us/fabric/data-warehouse/dimensional-modeling-dimension-tables#scd-type-2) for surrogate key plus validity columns plus current flag, [Slowly Changing Dimension transformation](https://learn.microsoft.com/en-us/sql/integration-services/data-flow/transformations/slowly-changing-dimension-transformation) for the SSIS SCD Wizard's *historical attribute* path, and [Power BI guidance, *Star schema, Type 2 SCD*](https://learn.microsoft.com/en-us/power-bi/guidance/star-schema#type-2-scd).

#### Fact load: `stg.* → fact.*` with surrogate-key lookups

Facts store the measurements; dimensions hold the descriptive context. A fact row holds surrogate keys (small INTs sourced from the dim tables), not natural or business keys, for three reasons: (a) surrogate keys are stable across SCD-2 versions, so a fact row pins itself to a specific dim version forever; (b) joins are narrower and faster than joining on composite natural keys; (c) source-system key changes do not ripple into the warehouse. The fact loader's job is mechanical: take staged business keys, look up the right surrogate keys (current row for Type-1 dims, point-in-time row for Type-2 dims), write the fact.

Data flow: OLE DB Source on `stg`, then one Lookup per foreign key (to each `dim`), then Conditional Split for lookup-miss handling (route to error table or insert an inferred-member row), then OLE DB Destination into `fact`.

References: Microsoft Learn, [Fact tables in a dimensional model](https://learn.microsoft.com/en-us/fabric/data-warehouse/dimensional-modeling-fact-tables) for dimension-key columns as surrogate FKs plus measure columns, [Load tables, *Process fact tables*](https://learn.microsoft.com/en-us/fabric/data-warehouse/dimensional-modeling-load-tables#process-fact-tables) for the per-dimension surrogate-key lookup pattern (point-in-time for SCD-2), and [Dimension tables, *Surrogate key*](https://learn.microsoft.com/en-us/fabric/data-warehouse/dimensional-modeling-dimension-tables#surrogate-key) for why facts join on surrogate keys, not natural keys.

### What is deliberately not a pattern

- **Source → fact direct.** Skips staging, couples extraction to transformation, leaves no replay path. The agent refuses and asks for a staging step first.
- **Truncate-and-reload dim or fact.** Destroys history, breaks the SCD-2 contract, and invalidates any saved fact-to-dim joins. The agent refuses.
- **SCD-3 / SCD-6.** Rare in practice; the column-explosion of SCD-3 and the hybrid complexity of SCD-6 are usually better served by a second Type-2 dim or a snapshot fact. Raise an issue if you have a real case.
- **Aggregated / snapshot facts.** A specialization of the fact load. Build them on top of the `FactLoad` module rather than as a separate pattern.

## Read next

- [GUIDE.md](GUIDE.md): hands-on walkthrough driven entirely from GitHub Copilot Chat. Generate, modify, validate, and document all four package patterns by typing prompts; no PowerShell required after the one-time prep.
- [AGENTS.md](AGENTS.md): repo-wide agent contract.
- [install/overlay.manifest.psd1](install/overlay.manifest.psd1): single source of truth for the brownfield installer and template-cleanup workflow.

## References

The toolkit's design decisions trace back to these Microsoft Learn topics. Use them when reading the agent and skill files, when extending a pattern module, or when triaging a validation failure.

**SSIS managed object model and CLIs**

- [`Microsoft.SqlServer.Dts.Runtime` namespace](https://learn.microsoft.com/en-us/dotnet/api/microsoft.sqlserver.dts.runtime): the .NET API the toolkit's host wraps.
- [Building packages programmatically](https://learn.microsoft.com/en-us/sql/integration-services/building-packages-programmatically/building-packages-programmatically): landing page for the OM authoring model.
- [Loading and saving packages programmatically](https://learn.microsoft.com/en-us/sql/integration-services/building-packages-programmatically/loading-and-saving-packages): `Application.LoadPackage` and `Package.SaveToXml`, used by the generator and by `Test-SsisDesignerLoad.ps1`.
- [`dtexec` utility](https://learn.microsoft.com/en-us/sql/integration-services/packages/dtexec-utility): called by `Test-SsisPackage.ps1` with `/Validate /WarnAsError`.
- [`dtutil` utility](https://learn.microsoft.com/en-us/sql/integration-services/dtutil-utility): `/IDRegenerate`, the last-resort fix for lineage-ID corruption.
- [SSIS DevOps standalone build tools (`SSISBuild.exe`)](https://learn.microsoft.com/en-us/sql/integration-services/devops/ssis-devops-standalone): the headless project builder referenced by the roadmap `Build-SsisIspac.ps1` primitive.
- [`[MS-DTSX]` package XML format](https://learn.microsoft.com/openspecs/sql_data_portability/ms-dtsx/235600e9-0c13-4b5b-a388-aa3c65aec1dd) and [`[MS-DTSX2]`](https://learn.microsoft.com/openspecs/sql_data_portability/ms-dtsx2/fb216aa4-62ab-41c8-a6d5-5b1002739d21): the open spec for the `.dtsx` file. Read-only reference; the toolkit never hand-writes this.

**Project deployment, catalog, and security**

- [Deploy Integration Services projects and packages](https://learn.microsoft.com/en-us/sql/integration-services/packages/deploy-integration-services-ssis-projects-and-packages): Project Deployment Model, `.ispac`, SSISDB. The only execution path the toolkit supports.
- [Deploy an SSIS project with PowerShell](https://learn.microsoft.com/en-us/sql/integration-services/ssis-quickstart-deploy-powershell): pattern for the roadmap `Publish-SsisIspac.ps1` primitive.
- [`catalog.deploy_project`](https://learn.microsoft.com/en-us/sql/integration-services/system-stored-procedures/catalog-deploy-project-ssisdb-database): server-side project deployment.
- [`catalog.validate_package`](https://learn.microsoft.com/en-us/sql/integration-services/system-stored-procedures/catalog-validate-package-ssisdb-database): server-side pre-execution validation (catches env-ref and project-parameter issues `dtexec /Validate` cannot).
- [`catalog.create_execution`](https://learn.microsoft.com/en-us/sql/integration-services/system-stored-procedures/catalog-create-execution-ssisdb-database) + [`catalog.start_execution`](https://learn.microsoft.com/en-us/sql/integration-services/system-stored-procedures/catalog-start-execution-ssisdb-database): the canonical execution sequence for the roadmap `Start-SsisExecution.ps1` primitive.
- [Access control for sensitive data in packages](https://learn.microsoft.com/en-us/sql/integration-services/security/access-control-for-sensitive-data-in-packages): `ProtectionLevel`. The toolkit pins every package and project to `DontSaveSensitive`.
- [SSIS on Linux](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-migrate-ssis): the constraint that makes the toolkit Windows-only (no SSISDB on Linux; Project Deployment Model unsupported).

**Kimball dimensional modeling methodology**

The foundational methodology for enterprise data warehousing that this toolkit implements. The four patterns (staging, Type-1 dimension, Type-2 dimension, fact load) directly map to Kimball's ETL subsystems.

- [The Kimball Group: Dimensional Modeling Techniques](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dimensional-modeling-techniques/): comprehensive catalog of dimensional modeling patterns, including star schema, surrogate keys, conformed dimensions, SCD types, factless facts, and degenerate dimensions. The authoritative source from Ralph Kimball's consulting practice.
- [The Kimball Group: Kimball DW/BI Lifecycle Methodology](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/kimball-techniques/dw-bi-lifecycle-method/): the full program planning and delivery framework that contextualizes dimensional modeling within business requirements definition, ETL design, and BI application deployment.
- Ralph Kimball and Margy Ross, *The Data Warehouse Toolkit: The Definitive Guide to Dimensional Modeling*, 3rd Edition (Wiley, 2013). The canonical textbook. Chapters 1–3 establish star schema, SCD types, and surrogate keys; Chapter 19 covers ETL subsystems (the conceptual basis for the four pattern modules).
- [Kimball Design Tips archive](https://www.kimballgroup.com/category/design-tip/): 20+ years of monthly design-tip articles covering edge cases (many-to-many bridge tables, multi-valued dimensions, handling late-arriving facts, snapshot fact tables, handling source key reuse).

**Dimensional modeling and load patterns**

The four pattern modules under `tools\lib\patterns\` (`StagingLoad`, `Type1Dimension`, `Type2Dimension`, `FactLoad`) implement these Microsoft-documented shapes. Following them gives you portable warehouse loads that any SSIS, Fabric, Synapse, or Power BI practitioner will recognize, not toolkit-specific conventions.

- [Understand star schema and the importance for Power BI](https://learn.microsoft.com/en-us/power-bi/guidance/star-schema): fact-vs-dimension split, SCD Type 1 and Type 2 definitions, surrogate keys. Cites *The Data Warehouse Toolkit* (Ralph Kimball) as the canonical reference.
- [Dimensional modeling in Microsoft Fabric data warehouse, overview](https://learn.microsoft.com/en-us/fabric/data-warehouse/dimensional-modeling-overview): star schema, fact and dimension table roles, periodic ETL loading. Also cites the Kimball Toolkit.
- [Dimensional modeling, dimension tables](https://learn.microsoft.com/en-us/fabric/data-warehouse/dimensional-modeling-dimension-tables): surrogate keys, natural / business keys, SCD Type 1, SCD Type 2, managing historical change. The conceptual basis for the `Type1Dimension` and `Type2Dimension` modules.
- [Dimensional modeling, fact tables](https://learn.microsoft.com/en-us/fabric/data-warehouse/dimensional-modeling-fact-tables): fact structure (dimension keys as surrogate FKs plus measures plus audit columns), transaction / periodic snapshot / accumulating snapshot fact types. The conceptual basis for the `FactLoad` module.
- [Dimensional modeling, load tables](https://learn.microsoft.com/en-us/fabric/data-warehouse/dimensional-modeling-load-tables): end-to-end ETL flow: stage, then process dimensions (per SCD type), then process facts (with surrogate-key lookups and inferred dimension members). The conceptual basis for the `StagingLoad` module and for the lookup behavior in `FactLoad`.
- [Slowly Changing Dimension transformation (SSIS)](https://learn.microsoft.com/en-us/sql/integration-services/data-flow/transformations/slowly-changing-dimension-transformation): the SSIS-native SCD Wizard, with the same Type 1 (*changing attribute*) and Type 2 (*historical attribute*) outputs the `Type1Dimension` and `Type2Dimension` modules emit. The wizard does not support Type 3, which is why this toolkit does not either.

**Copilot customization**

- [VS Code Copilot customization overview](https://code.visualstudio.com/docs/copilot/customization/overview): agents, skills, prompts, and instructions. The portable schema both Visual Studio 2026 and VS Code honor.
- [`AGENTS.md` cross-tool convention](https://agents.md/): the format used for the repo-wide agent contract.

## Requirements

- **Windows.** The SSIS managed OM and `dtexec` are Windows-only.
- **PowerShell 7+** (`pwsh`) preferred; Windows PowerShell 5.1 is supported.
- **.NET 8 SDK**, required by the managed-OM helper exe.
- **SQL Server 2022 or 2025 client tools**, which provide `Microsoft.SqlServer.ManagedDTS.dll` and `dtexec.exe`.
- **GitHub Copilot Chat** in Visual Studio 2026 (18.4+) or VS Code (Stable or Insiders).
