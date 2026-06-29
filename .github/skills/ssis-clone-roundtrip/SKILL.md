---
name: ssis-clone-roundtrip
description: Use as Step 4 of the ssis-delivery-gate. Performs a clean `git clone` of the current HEAD into a temp directory and re-runs Test-SsisPackage + Test-SsisDesignerLoad + Build-SsisIspac against the cloned copy, proving the artifact survives the round-trip a downstream developer would experience. Catches line-ending corruption, missing tracked files, and accidental dependence on uncommitted state.
---

# SSIS clean-clone round-trip

This skill is the final step of the delivery gate. It guarantees the property AGENTS.md promises: **a developer can clone this repo and open the `.dtproj` in Visual Studio (or build with `SSISBuild.exe`) without errors.**

Run it by invoking the **ssis-validator** agent after Steps 1–3 of [`ssis-delivery-gate`](../ssis-delivery-gate/SKILL.md) pass.

## Procedure

### 1. Prepare a temp clone directory

```powershell
$tempRoot = Join-Path $env:TEMP "ssis-roundtrip-$(Get-Random)"
New-Item -ItemType Directory -Path $tempRoot | Out-Null
```

### 2. Clone HEAD (not the working tree)

```powershell
$repoRoot = (git -C $PSScriptRoot rev-parse --show-toplevel).Trim()
git clone --quiet --no-local $repoRoot $tempRoot
```

`--no-local` forces git to use its transport rather than hardlinks, so file modes and line endings go through the same normalization a fresh clone would.

### 3. Re-run validate / designer-load / build inside the clone

```powershell
Push-Location $tempRoot
try {
  & .\tools\Test-SsisPackage.ps1      -Package $Package    # path relative to clone
  & .\tools\Test-SsisDesignerLoad.ps1 -Package $Package
  & .\tools\Build-SsisIspac.ps1       -Project $Project
} finally {
  Pop-Location
}
```

If any step fails in the clone but passed in the working tree, the most likely causes are:

- **Line-ending corruption** — `.gitattributes` is not enforcing `eol=lf` on `.dtsx`. Fix in [`.gitattributes`](../../../.gitattributes); see the [`git-roundtrip-for-ssis`](../git-roundtrip-for-ssis/SKILL.md) skill.
- **Untracked dependency** — the pattern module reads a file that's in `.gitignore` or was never `git add`-ed. Run `git status` in the working tree and confirm the file is tracked.
- **Uncommitted change** — the working tree has edits that aren't yet committed. The agent should commit (or stash) and re-run the gate.

### 4. Tear down

```powershell
Remove-Item -Recurse -Force $tempRoot
```

## Why this is a skill, not a script

The procedure is short, deterministic, and rarely changes — perfect for a single `.ps1`. But making it a skill has one critical advantage: when it **fails**, the agent already has the full context (which step failed in the clone, what passed in the working tree, what the diff between the two was) and can triage on the spot. A script would emit an exit code and lose that context.

## What goes in the verdict

```
4. ssis-clone-roundtrip      : <PASS|FAIL>
```

If FAIL, include in `FIRST_FAILURE`:

- which sub-step (validate / designer-load / build) broke in the clone,
- a one-line diagnosis from one of: this skill, [`git-roundtrip-for-ssis`](../git-roundtrip-for-ssis/SKILL.md), or [`dtexec-validation-triage`](../dtexec-validation-triage/SKILL.md).
