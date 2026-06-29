# SSIS Copilot Toolkit: Hands-on Guide

Everything below happens **in GitHub Copilot Chat**. You will not write PowerShell, you will not open `.dtsx` XML, you will not click through wizards. You select the **ssis-author** agent from the agent picker and type natural-language prompts into the Chat input; the agent writes the metadata, calls the toolkit, and spawns **ssis-validator** to prove the result. This guide shows you the prompts.

If you only want to read the architecture, start at [AGENTS.md](AGENTS.md).

## What you need

- **Windows** with PowerShell 7+, **.NET 8 SDK**, and **SQL Server 2022 or 2025 client tools** (for `dtexec.exe` and the managed OM).
- **SQL Server 2025 Developer Edition** on `.\SQL2025` with **AdventureWorks2025** attached. (Different instance? Tell the agent in chat and it will adjust the metadata.)
- **GitHub Copilot Chat** in Visual Studio 2026 (18.4+) or VS Code (Stable or Insiders).

Clone the repo (or click **"Use this template"**) and open the folder in your IDE:

```powershell
git clone https://github.com/samueltauil/ssis-copilot-toolkit.git
```

Open the Copilot Chat panel. You are ready.

---

## Step 1. One-time prep (ask Copilot to do it)

Two things have to happen once per machine before the agent can author packages: build the .NET 8 host that wraps the SSIS managed object model, and create the demo databases the example metadata points at.

In Copilot Chat, ask:

> Run `.\tools\lib\SsisOmHost\Build-SsisOmHost.ps1` to build the managed-OM host, then run `.\install\Install-Toolkit.ps1` to provision the demo databases.

Copilot will surface both commands for your approval, run them in the integrated terminal, and report back. You should see `SsisOmHost.exe` produced and the databases `CopilotSSIS_Source` and `CopilotSSIS_Warehouse` created with the `stg` / `dim` / `fact` / `etl` schemas applied.

(Prefer to run them yourself? Both are documented in the [README primitives table](README.md#powershell-primitives-callable-directly-or-via-ctrlshiftb).)

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
> Build fact.SalesOrder from stg.SalesOrderHeader. Look up CustomerKey from dim.Customer on CustomerID and DateKey from dim.Date on OrderDate.
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
- **Drop the toolkit into your existing SSIS repo.** One-liner in the [README brownfield section](README.md#2-existing-ssis-repo-drop-in-the-overlay). The demo content used in this guide is **not** copied; your repo keeps its own data model. After installing, the same chat-first workflow above works against your tables.
- **Add a fifth pattern.** Write a module under `tools\lib\patterns\`, extend the dispatcher in `tools\lib\SsisOm.psm1`, document the metadata fields in [.github/instructions/metadata-schema.instructions.md](.github/instructions/metadata-schema.instructions.md), and add a slash prompt under [.github/prompts/](.github/prompts/). The **ssis-author** agent picks it up automatically.
- **Read the contract.** [AGENTS.md](AGENTS.md) covers the hard rules, the two-layer architecture (PowerShell primitives + skills/agents), and what NOT to invent.
