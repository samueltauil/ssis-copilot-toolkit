# AGENTS.md — SSIS Copilot Toolkit

This file is the repo-wide contract every coding agent must follow (Copilot, Claude, Codex, Cursor, Gemini). Read once per session.

> **Note**: this is the toolkit's own engineering AGENTS.md (for contributors building the toolkit). In repos that consume the toolkit — whether created from the template or via the brownfield installer — `AGENTS.md` is the much smaller managed block defined in [install/overlay.manifest.psd1](install/overlay.manifest.psd1)'s `AgentsMdBlock`.

## What this repo is

A toolkit for authoring SQL Server Integration Services (SSIS) packages from chat via GitHub Copilot, in either **Visual Studio 2026 (18.4+)** or **VS Code**. Two custom agents (`@ssis-author`, `@ssis-validator`), a set of agent **skills** that encode the procedures, and a thin layer of **PowerShell primitives** that call the **managed object model** (`Microsoft.SqlServer.Dts.Runtime`) — the same code path the native SSIS designer uses internally. The agent never writes XML; PowerShell only does what skills can't (.NET interop, external `.exe` invocation, SSISDB stored procs).

Distributed two ways from a single source tree, both driven by the manifest:
- **Template repo** — "Use this template" on GitHub. First push triggers [.github/workflows/template-cleanup.yml](.github/workflows/template-cleanup.yml), which reads the manifest, strips the `Demo` list, and regenerates `AGENTS.md` + `README.md` for the new repo.
- **Brownfield installer** — `iex (irm .../install/Add-CopilotSsisToolkit.ps1)`. Drops the manifest's `Overlay` list into an existing SSIS repo, idempotent on re-runs.

Demo script: [context/github-copilot-ssis-demo-plan.md](context/github-copilot-ssis-demo-plan.md). Microsoft Learn references for the SSIS foundations (managed OM, `dtexec`, SSISDB, ProtectionLevel) live in the [README References section](README.md#references).

## Hard rules

1. **Never hand-edit `.dtsx`, `.dtproj`, `.conmgr`, or `.params` files.** Regenerate from metadata JSON via `tools/New-SsisPackage.ps1`. Editing these files corrupts refIds, lineage IDs, or designer-load state.
2. **`@ssis-author` is the only sanctioned entry point for SSIS work.** The default Copilot agent may answer general questions (e.g. "what does this PowerShell line do?") but must not author SSIS artifacts.
3. **The validation gate is non-bypassable.** It is encoded in the [`ssis-delivery-gate`](.github/skills/ssis-delivery-gate/SKILL.md) skill and run by `@ssis-validator`. `@ssis-author` must spawn `@ssis-validator` after every SSIS-affecting change and surface its verdict verbatim. No verdict, no "done".
4. **`ProtectionLevel = DontSaveSensitive` on project and every package.** Sensitive values resolve at runtime via SSISDB environment variables — never commit credentials.
5. **Cite Microsoft Learn for SSIS technical decisions.** When introducing or changing a design rule, add the supporting `learn.microsoft.com` URL to the [README References section](README.md#references).

## Architecture in two layers

**Layer A — PowerShell primitives** (`tools/`, single responsibility, no orchestration). Each does one thing because skills cannot: .NET interop, run an `.exe`, or call a stored proc.

*Shipped in the overlay (manifest's `Overlay` list):*

| Goal | Primitive |
|---|---|
| Build the managed-OM host (one-time) | `.\tools\lib\SsisOmHost\Build-SsisOmHost.ps1` |
| Generate a package from metadata JSON | `.\tools\New-SsisPackage.ps1 -Metadata <file.json>` |
| Validate (`dtexec /Validate /WarnAsError`) | `.\tools\Test-SsisPackage.ps1 -Package <file.dtsx>` |
| Designer-load round-trip (`Application.LoadPackage`) | `.\tools\Test-SsisDesignerLoad.ps1 -Package <file.dtsx>` |

*Demo-only (manifest's `Demo` list — template repos and contributors, not brownfield repos):*

| Goal | Primitive |
|---|---|
| Provision SQL DBs + SSISDB for the AdventureWorks2025 walkthrough | `.\install\Install-Toolkit.ps1` |

*Roadmap (not yet implemented; referenced by `@ssis-author`'s deploy-and-execute prompt):*

| Goal | Primitive |
|---|---|
| Build `.ispac` (`SSISBuild.exe`) | `tools\Build-SsisIspac.ps1 -Project <file.dtproj>` |
| Deploy `.ispac` (`catalog.deploy_project`) | `tools\Publish-SsisIspac.ps1 -Ispac <file.ispac> -Folder <name>` |
| Execute package (`create_execution` → `start_execution`) | `tools\Start-SsisExecution.ps1 -Folder ... -Project ... -Package ...` |
| Clean-clone round-trip gate | `tools\Verify-ClonedProject.ps1` |

**Layer B — Skills + agents** (knowledge, orchestration, triage). Skills live under `.github/skills/`; agents under `.github/agents/`.

| Concern | Where it lives |
|---|---|
| The non-bypassable validation gate procedure | skill: [`ssis-delivery-gate`](.github/skills/ssis-delivery-gate/SKILL.md) |
| Reading `dtexec /Validate` output and proposing fixes | skill: [`dtexec-validation-triage`](.github/skills/dtexec-validation-triage/SKILL.md) |
| Clean-clone round-trip procedure | skill: [`ssis-clone-roundtrip`](.github/skills/ssis-clone-roundtrip/SKILL.md) |
| The four pattern recipes (managed-OM call sequences) | skill: [`ssis-package-patterns`](.github/skills/ssis-package-patterns/SKILL.md) |
| SSISDB catalog conventions | skill: [`ssisdb-deployment`](.github/skills/ssisdb-deployment/SKILL.md) |
| Authoring orchestration | agent: [`ssis-author`](.github/agents/ssis-author.agent.md) |
| Delivery-gate enforcement (read-only) | agent: [`ssis-validator`](.github/agents/ssis-validator.agent.md) |

Primitives surface as VS Code tasks (`.vscode/tasks.json` — Ctrl+Shift+B). Skills and agents are auto-discovered by Copilot Chat.

## The four supported package patterns

`@ssis-author` only emits packages that match one of these. Anything else: refuse and ask the user which pattern fits. Recipes (managed-OM call sequences) live in the [`ssis-package-patterns`](.github/skills/ssis-package-patterns/SKILL.md) skill; the matching builder module under `tools/lib/patterns/` implements that recipe.

| Pattern | When | Builder module |
|---|---|---|
| Staging load | Source → `stg.*` via OLE DB Source + OLE DB Destination | `tools/lib/patterns/StagingLoad.psm1` |
| Type-1 dimension | `stg.*` → `dim.*` (overwrite on key match) | `tools/lib/patterns/Type1Dimension.psm1` |
| Type-2 dimension (SCD-2) | `stg.*` → `dim.*` with current-flag + effective dates | `tools/lib/patterns/Type2Dimension.psm1` |
| Fact load | `stg.*` → `fact.*` with surrogate-key lookups | `tools/lib/patterns/FactLoad.psm1` |

## What NOT to invent

- Don't invent AdventureWorks2025 column names. The `.github/skills/adventureworks-mapping/SKILL.md` skill pins them — load that skill before referencing AW tables.
- Don't invent demo schema (`stg`/`dim`/`fact`/`etl`) shapes. They live in `templates/sql/`.
- Don't invent new SSIS execution paths (e.g. msdb storage, legacy package deployment). Project Deployment Model + `.ispac` + SSISDB only.

## Environment assumptions

- **SQL Server**: `.\SQL2025` (SQL Server 2025 Developer Edition) with AdventureWorks2025 attached.
- **IDE**: either **Visual Studio 2026 (18.4+)** (native SSIS designer; native Copilot Chat with agent-customization parity) or **VS Code** Stable/Insiders with GitHub Copilot Chat. Customization files under `.github/` use only VS Code's documented portable schema (capability aliases — `read`, `edit`, `search`, `execute`, `todo` — in agent frontmatter) so both IDEs honor them.
- **PowerShell**: 7+ (`pwsh`) preferred; Windows PowerShell 5.1 acceptable for `Microsoft.SqlServer.ManagedDTS.dll` interop.
- **.NET 8 SDK**: required by [tools/lib/SsisOmHost/Build-SsisOmHost.ps1](tools/lib/SsisOmHost/Build-SsisOmHost.ps1).
- **Recommended VS Code extensions**: [.vscode/extensions.json](.vscode/extensions.json).
- **Containers**: SSIS execution is Windows-only — the managed OM (`Microsoft.SqlServer.Dts.Runtime`), `dtexec`, and `dtutil` ship with the SQL Server client tools and have no Linux equivalent. All workflow runners use `windows-latest`.
