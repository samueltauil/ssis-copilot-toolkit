---
name: ssis-delivery-gate
description: Use to run the non-bypassable delivery gate after any SSIS-affecting change. Encodes the canonical sequence of primitive invocations (Test-SsisPackage → Test-SsisDesignerLoad → Build-SsisIspac → ssis-clone-roundtrip) and the triage hand-off on failure. Always invoked by @ssis-validator, optionally by @ssis-author during exploration.
---

# SSIS delivery gate

This skill encodes the **non-bypassable validation procedure** referenced by AGENTS.md hard rule #3. It is the single source of truth for what "validated" means for an SSIS artifact in this repo.

The gate is a sequence of single-purpose PowerShell primitives. Each primitive does one thing because skills cannot do those things (.NET interop, external `.exe` invocation). Orchestration — running the steps in order, stopping on the first failure, triaging the result — happens **here in the skill**, executed by the agent that loaded it.

## Inputs

- `Package` — absolute path to a `.dtsx` file under `templates/ssis-project/Packages/`
- `Project` — absolute path to the parent `.dtproj`

Both must exist on disk. If either is missing, return `INVALID_INPUT` and stop.

## Steps (run in order, stop on first failure)

### Step 1 — `Test-SsisPackage` (runtime validation)

Invokes `dtexec /Validate /WarnAsError` against the package. This proves runtime correctness — bindings resolve, expressions parse, data flow paths type-check.

```powershell
.\tools\Test-SsisPackage.ps1 -Package $Package
```

- **PASS** = exit 0
- **FAIL** = non-zero exit. Hand off to the [`dtexec-validation-triage`](../dtexec-validation-triage/SKILL.md) skill for a one-line diagnosis. Capture last 40 lines of output as evidence.

> Source: `dtexec /Validate` — https://learn.microsoft.com/sql/integration-services/packages/dtexec-utility?view=sql-server-ver17#parameters

### Step 2 — `Test-SsisDesignerLoad` (round-trip)

Loads the package via `Microsoft.SqlServer.Dts.Runtime.Application.LoadPackage`, re-saves it to a temp location, and verifies the round-trip. This proves designer-load correctness — the managed OM (same code path SSDT uses) can deserialize the XML without losing or corrupting state.

```powershell
.\tools\Test-SsisDesignerLoad.ps1 -Package $Package
```

- **PASS** = round-trip succeeds, structural hash matches.
- **FAIL** = OM raises an exception, or the re-saved package differs structurally. Hand off to the [`dtsx-xml-anatomy`](../dtsx-xml-anatomy/SKILL.md) skill for diagnosis. Capture the .NET exception as evidence.

> Source: `Application.LoadPackage` — https://learn.microsoft.com/sql/integration-services/building-packages-programmatically/loading-and-saving-packages?view=sql-server-ver17

### Step 3 — `Build-SsisIspac` (SSISBuild.exe) — ROADMAP

> **Not yet shipped.** Report `SKIPPED (roadmap)` and continue. Do **not** report `MISSING_PRIMITIVE`; that status is reserved for Steps 1 and 2 whose primitives ship today.

When shipped, this step will build the `.dtproj` via the Microsoft-published standalone `SSISBuild.exe`, the same engine SSDT uses, producing the `.ispac`.

```powershell
.\tools\Build-SsisIspac.ps1 -Project $Project
```

- **PASS** = `.ispac` produced under `templates/ssis-project/bin/Development/`.
- **FAIL** = SSISBuild.exe exits non-zero. The error usually indicates a project-level issue (ProtectionLevel mismatch, missing connection manager, parameter binding error). Capture SSISBuild stderr as evidence.
- **SKIPPED (roadmap)** = primitive does not exist on disk yet.

> Source: `SSISBuild.exe`, https://learn.microsoft.com/sql/integration-services/devops/ssis-devops-standalone?view=sql-server-ver17#ssisbuildexe

### Step 4 — `ssis-clone-roundtrip` skill — ROADMAP

> **Not yet shipped.** The [`ssis-clone-roundtrip`](../ssis-clone-roundtrip/SKILL.md) skill depends on Step 3's `.ispac` artifact, so Step 4 reports `SKIPPED (roadmap)` whenever Step 3 is SKIPPED. Do **not** report `MISSING_PRIMITIVE`.

When shipped, this step will be a **skill, not a primitive**: it performs a clean `git clone` of HEAD into a temp dir and re-runs Steps 1 through 3 against the cloned copy. This is the gate that guarantees a developer can clone the repo and open it in Visual Studio without errors.

Follow the [`ssis-clone-roundtrip`](../ssis-clone-roundtrip/SKILL.md) skill.

- **PASS** = all three steps pass in the cloned copy.
- **FAIL** = any step fails. The most common failure mode is line-ending corruption; see the [`git-roundtrip-for-ssis`](../git-roundtrip-for-ssis/SKILL.md) skill.
- **SKIPPED (roadmap)** = Step 3 was SKIPPED, or the clone primitive does not exist on disk.

## Verdict assembly

Compose the verdict block per the format pinned in [`ssis-validator.agent.md`](../../agents/ssis-validator.agent.md). Never collapse multiple steps into one line. Never claim a step PASS without an exit code.

## Why this is a skill and not a script

Three reasons:

1. **Triage requires reasoning.** A `dtexec /Validate` failure can mean a missing column, a type mismatch, a connection-manager binding error, or a stale expression — the diagnosis depends on the package and the metadata. A script returns an exit code; an agent + skill returns a diagnosis.
2. **The gate composes with the user's intent.** If only docs changed, the gate may not need to run. If only the metadata changed, only the affected package needs Steps 1–3 (not every package). A script either runs the whole gate or none of it.
3. **The gate is auditable.** A 60-line skill in plain English is easier for a future contributor to read, change, and verify than a 200-line orchestrating PowerShell script that bakes the same logic into try/catch + Write-Error.
