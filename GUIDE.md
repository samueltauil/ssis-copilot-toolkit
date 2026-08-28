# SSIS Copilot Toolkit: Hands-on Guide

Everything below happens **in GitHub Copilot Chat**. You will not write PowerShell, you will not open `.dtsx` XML, you will not click through wizards. You select the **ssis-author** agent from the agent picker and type natural-language prompts into the Chat input; the agent writes the metadata, calls the toolkit, and spawns **ssis-validator** to prove the result. This guide shows you the prompts.

If you only want to read the architecture, start at [AGENTS.md](AGENTS.md).

## Prerequisites

This guide runs the **demo** against AdventureWorks2025. Full details are in the [README Prerequisites section](README.md#prerequisites); the short version:

**Toolchain (needed for any scenario)**

- **Windows** (64-bit) with **PowerShell 5.1** (ships with Windows). **PowerShell 7** is recommended — the VS Code tasks call `pwsh`. [Install](https://github.com/PowerShell/PowerShell/releases/latest)
- **Git for Windows** — to clone the repo. [Install](https://git-scm.com/download/win)
- **.NET Framework 4.6.2+** — its `csc.exe` compiles the managed-OM host. No .NET SDK required. Already on Windows 10 1903+ and Windows 11.
- **SQL Server 2025 Integration Services (shared components)** — provides `Microsoft.SqlServer.ManagedDTS.dll` and `dtexec.exe`. The database engine alone is not enough; tick **Integration Services** under **Shared Features** in the installer. SQL Server 2022 does not satisfy this. [Download Developer edition](https://www.microsoft.com/sql-server/sql-server-downloads)
- **GitHub Copilot Chat** in Visual Studio 2026 (18.4+) or VS Code. Needs a GitHub account with a Copilot subscription — see [README → Set up GitHub Copilot Chat](README.md#set-up-github-copilot-chat).

**Demo-only, on top of the above**

- A **SQL Server instance**. This repo's `.ssis-toolkit.json` assumes `.\SQL2025` — using something else? Edit that file and the `source` / `target` blocks in `templates/metadata/*.json`, or just tell the agent in chat and it will adjust them.
- The **`SqlServer` PowerShell module**: `Install-Module SqlServer -Scope CurrentUser -Force`.
- **AdventureWorks2025** restored on that instance ([download and restore instructions](https://learn.microsoft.com/sql/samples/adventureworks-install-configure)). The installer verifies it is present but will not restore it for you.
- **SSISDB** only if you intend to deploy. Create it via SSMS → **Integration Services Catalogs** → **Create Catalog**. The validation gate in this guide does not need it.

Clone the repo, **change into the folder**, and let the toolkit tell you what is missing:

```powershell
git clone https://github.com/samueltauil/ssis-copilot-toolkit.git
cd ssis-copilot-toolkit
powershell -NoProfile -ExecutionPolicy Bypass -File .\install\Test-Prerequisites.ps1
```

If `git` is not recognized, install it first and open a **new** terminal — `winget install --id Git.Git --exact --source winget` — or download the repo as a ZIP from the green **Code** button on [GitHub](https://github.com/samueltauil/ssis-copilot-toolkit).

Every command in this guide is relative to the repository root, so the `cd` is not optional: run `.\tools\...` from anywhere else and PowerShell answers `The term '.\tools\...' is not recognized`.

The checker prints `[ OK ]` / `[WARN]` / `[FAIL]` per requirement with the exact fix command, and exits non-zero while anything required is missing. Add `-Install` and it will install PowerShell 7 and the `SqlServer` module for you, then re-verify. **Do not continue until it reports `RESULT: PASS`.**

Never used GitHub Copilot before? You need a GitHub account with a Copilot subscription, an IDE (VS Code or Visual Studio 2026), the Copilot Chat extension, and to be signed in. Step-by-step: [README → Set up GitHub Copilot Chat](README.md#set-up-github-copilot-chat).

Now open the folder in your IDE and open the Copilot Chat panel. You are ready.

> Not running the demo? Starting a new repo or adding the toolkit to an existing one are covered in the README's [Greenfield](README.md#greenfield-new-repo-from-the-template) and [Brownfield](README.md#brownfield-existing-ssis-repo) sections, then [Bring your own databases](docs/bring-your-own-databases.md).

---

## Step 1. One-time prep (ask Copilot to do it)

Two things have to happen once per machine before the agent can author packages: compile the host that wraps the SSIS managed object model, and create the demo databases the example metadata points at.

In Copilot Chat, ask:

> Run `.\install\Test-Prerequisites.ps1` to confirm the machine is ready, then `.\tools\lib\SsisOmHost\Build-SsisOmHost.ps1` to build the managed-OM host, then `.\install\Install-Toolkit.ps1` to provision the demo databases.

Copilot will surface each command for your approval, run it in the integrated terminal, and report back. You should see `RESULT: PASS` from the checker, `OK: ...\SsisOmHost.exe` from the build, and the databases `CopilotSSIS_Source` and `CopilotSSIS_Warehouse` created with the `stg` / `dim` / `fact` / `etl` schemas applied.

> If a command fails with *"is not recognized as the name of a cmdlet"*, the terminal is not in the repository root. Run `cd ssis-copilot-toolkit` (or the full path to your clone) and retry.

(Prefer to run them yourself? Both are documented in the [README primitives table](README.md#powershell-primitives-callable-directly-or-via-ctrlshiftb).)

This repo already ships a `.ssis-toolkit.json` pinned to the demo layout, so you can skip `/scaffold-new-ssis-project` here. In your own repo that prompt is the first thing you run — see [Bring your own databases](docs/bring-your-own-databases.md).

## Step 2. Generate your first package, from chat

Select **ssis-author** from the agent picker, then type:

```text
/generate-staging-package
> Load AdventureWorks2025 Sales.Customer into stg.Customer in CopilotSSIS_Warehouse.
```

What the agent does, in order:

1. Loads the `adventureworks-mapping` skill and resolves the real column list for `Sales.Customer` (joining `Person.Person` and `Person.EmailAddress` to get `FirstName`, `LastName`, `EmailAddress`). It never invents column names.
2. Writes `templates/metadata/Stg_Customer.metadata.json` with `pattern: "staging"`, the column mapping, `protectionLevel: "DontSaveSensitive"`, and `truncateBeforeLoad: true`.
3. Calls `tools\New-SsisPackage.ps1` (which dispatches to the `StagingLoad` pattern module and the .NET host) to emit `templates/ssis-project/Packages/Stg_Customer.dtsx`.
4. Spawns the **ssis-validator** agent, which runs `Test-SsisPackage.ps1` (`dtexec /Validate /WarnAsError`) and `Test-SsisDesignerLoad.ps1` (`Application.LoadPackage` round-trip).
5. Returns a `VERDICT: PASS|FAIL` block with per-step exit codes.

You see all of it in the chat transcript. The agent never edits the `.dtsx` directly; it only touches the metadata JSON. If the verdict is `FAIL`, the agent loads the `dtexec-validation-triage` skill, identifies which metadata field is wrong, patches the JSON, and re-runs the gate.

## Step 3. Cover the other three patterns

The toolkit supports four patterns: staging, Type-1 dimension, Type-2 dimension, and fact. Each one solves a different problem in a Kimball-style warehouse. See [README §The four supported package patterns](README.md#the-four-supported-package-patterns) for why each exists and what shape it takes. 

Select **ssis-author** from the agent picker, then type each of these:

```text
/generate-staging-package
> Load AdventureWorks2025 Sales.SalesOrderHeader into stg.SalesOrderHeader in CopilotSSIS_Warehouse.
```

```text
/generate-dim-type1-package
> Build dim.Customer from stg.Customer keyed on CustomerID, overwrite on key match.
```

```text
/generate-dim-type2-package
> Build dim.CustomerHistory from stg.Customer keyed on CustomerID, with EffectiveFrom, EffectiveTo, and IsCurrent.
```

```text
/generate-fact-package
> Build fact.SalesOrder from stg.SalesOrderHeader. Look up CustomerKey from dim.Customer on CustomerID.
```

**Package dependency note:** The fact.SalesOrder package reads from `stg.SalesOrderHeader`, which is populated by the Stg_SalesOrderHeader staging package above. Execute packages in this order: Stg_Customer → Stg_SalesOrderHeader → Dim_Customer_Type1 → Fact_SalesOrder.

Each prompt walks the same loop: gather metadata → write JSON → generate `.dtsx` → run the gate → report. Each ends with a `VERDICT: PASS` block before the agent says "done".

Anything that does not fit the four patterns? The **ssis-author** agent refuses and asks which pattern fits. That refusal is enforced by [.github/agents/ssis-author.agent.md](.github/agents/ssis-author.agent.md).

## Step 4. Modify a package without touching XML or PowerShell

Select **ssis-author** from the agent picker, then describe the change:

> change `Stg_Customer` so it does not truncate before load.

The agent will:

1. Read `templates/metadata/Stg_Customer.metadata.json`.
2. Flip `truncateBeforeLoad` from `true` to `false`.
3. Regenerate the `.dtsx`.
4. Re-run the gate.
5. Report the new verdict.

Same loop for "add the `ModifiedDate` column to the staging mapping", "switch the source query to filter customers with `StoreID IS NOT NULL`", or "track `Phone` in the Type-2 dimension too". You stay in chat; the agent owns the JSON-and-regenerate dance.

## Step 5. Re-validate any package on demand

If you want to confirm a package is still healthy (after a SQL schema change, after pulling someone else's branch, before a deployment), select **ssis-validator** from the agent picker and type:

```text
validate templates/ssis-project/Packages/Stg_Customer.dtsx
```

The **ssis-validator** agent is read-only. It cannot author, deploy, or execute. It only runs the gate and returns the verdict. The full procedure it follows lives in the [`ssis-delivery-gate`](.github/skills/ssis-delivery-gate/SKILL.md) skill.

## Step 6. Generate validation SQL

After the agent loads a staging or dimension package, you usually want to prove the rows landed in the right shape.

The **ssis-author** agent emits T-SQL under `templates/sql/validation/`: row counts, key uniqueness checks, SCD-2 invariants (exactly one current row per business key, no overlapping effective dates), and source-to-target reconciliations. Run them in SSMS or with the `mssql` extension.

## Step 7. Generate human-readable docs for a package

Select **ssis-author** from the agent picker, then type:

```text
/generate-package-docs
> Document templates/ssis-project/Packages/Stg_Customer.dtsx.
```

The agent reads the package via the managed OM and writes a Markdown file under `templates/docs/` covering control flow, data flow, parameters, connections, and a runbook. Useful for PR reviews where the reviewer does not want to open the `.dtsx` in the designer.

## Step 8. Open a generated package in the SSIS designer

First, generate the Visual Studio project file and connection managers.

Select **ssis-author** from the agent picker, then type:

```text
Run .\tools\New-SsisProject.ps1 to generate the .dtproj, connection managers, and project parameters.
```

Or run it directly:

```powershell
.\tools\New-SsisProject.ps1
```

This creates:
- `templates/ssis-project/CopilotSsisDemos.dtproj` — the VS project file
- `templates/ssis-project/ConnectionManagers/*.conmgr` — OLE DB connections for AdventureWorks2025 and CopilotSSIS_Warehouse
- `templates/ssis-project/Project.params` — project parameters (SourceServer, TargetServer)

Then open `CopilotSsisDemos.dtproj` in Visual Studio 2026 (18.4+) with the SQL Server Data Tools workload. Control flow and data flow render cleanly. Right-click any package → **Execute Package** to run it.

> These generated files are gitignored (regenerable on demand). If connection strings need updating, re-run with `-SourceServer` and `-TargetServer` parameters.

---

## Two prompts that refuse today

These exist for completeness but depend on roadmap primitives. The agent will refuse on invocation and tell you exactly which primitive is missing:

- `/deploy-and-execute`: needs `Build-SsisIspac.ps1` + `Publish-SsisIspac.ps1` + `Start-SsisExecution.ps1`.

> `/scaffold-new-ssis-project` is now functional via `tools\New-SsisProject.ps1`.

When those land, the chat experience is the same shape: a single prompt, the agent owns the work end-to-end, and **ssis-validator** (or the SSISDB equivalent) reports the verdict.

## What's next

- **Clean up and start fresh.** Run `.\tools\Remove-DemoAssets.ps1` to remove all generated packages, project files, SSISDB content, and built artifacts. Add `-DropWarehouse` to also drop the demo database. Idempotent and safe to repeat.
- **Drop the toolkit into your existing SSIS repo.** One-liner in the [README brownfield section](README.md#brownfield-existing-ssis-repo). The demo content used in this guide is **not** copied; your repo keeps its own data model. Run `/scaffold-new-ssis-project` once to write `.ssis-toolkit.json`, then the same chat-first workflow above works against your tables. Full walkthrough: [Bring your own databases](docs/bring-your-own-databases.md).
- **Add a fifth pattern.** Write a module under `tools\lib\patterns\`, extend the dispatcher in `tools\lib\SsisOm.psm1`, document the metadata fields in [.github/instructions/metadata-schema.instructions.md](.github/instructions/metadata-schema.instructions.md), and add a slash prompt under [.github/prompts/](.github/prompts/). The **ssis-author** agent picks it up automatically.
- **Read the contract.** [AGENTS.md](AGENTS.md) covers the hard rules, the two-layer architecture (PowerShell primitives + skills/agents), and what NOT to invent.
