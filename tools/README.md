# `tools/` — PowerShell primitives

This folder holds **single-purpose** PowerShell scripts. Each one does exactly one thing because skills (which encode procedures) cannot do those things: load `Microsoft.SqlServer.ManagedDTS.dll`, invoke an external `.exe`, or call an SSISDB stored procedure.

Anything that orchestrates multiple primitives (validate → designer-load → build → round-trip) belongs in a **skill** under [`.github/skills/`](../.github/skills/), not here.

## Shipped primitives

| Script | What it does | Wraps |
|---|---|---|
| `lib/SsisOmHost/Build-SsisOmHost.ps1` | One-time build of the console host that fronts the managed OM | `csc.exe` against `lib/SsisOmHost/*.cs` |
| `New-SsisPackage.ps1` | Reads a metadata JSON and calls the host to write the `.dtsx` | `Microsoft.SqlServer.Dts.Runtime.Package.SaveToXml` (via the host) |
| `New-SsisProject.ps1` | Generates `.dtproj`, `.conmgr`, and `.params` files for Visual Studio Designer | Well-formed XML generation |
| `Test-SsisPackage.ps1` | Runtime validation | `dtexec.exe /Validate /WarnAsError` |
| `Test-SsisDesignerLoad.ps1` | Round-trip via the managed OM | `Microsoft.SqlServer.Dts.Runtime.Application.LoadPackage` |

Every path and connection these scripts use comes from `.ssis-toolkit.json` at the repo root. None of them hard-code a folder, server, or database.

## Roadmap primitives

Referenced by the **ssis-author** agent's `deploy-and-execute` prompt and by Steps 3 and 4 of the delivery gate. Not yet on disk; that prompt refuses on invocation, and the delivery gate reports SKIPPED for the matching steps.

| Script | Will do | Will wrap |
|---|---|---|
| `Build-SsisIspac.ps1` | Build `.ispac` from `.dtproj` | `SSISBuild.exe` |
| `Publish-SsisIspac.ps1` | Deploy `.ispac` to SSISDB | `catalog.deploy_project` |
| `Start-SsisExecution.ps1` | Execute a deployed package | `catalog.create_execution` → `catalog.set_execution_parameter_value` → `catalog.start_execution` |
| `Verify-ClonedProject.ps1` | Clean-clone round-trip gate driven by [`ssis-clone-roundtrip`](../.github/skills/ssis-clone-roundtrip/SKILL.md) | `git clone --no-local` + Steps 1–3 against the clone |

## Shared layout under `lib/`

| Path | Purpose |
|---|---|
| `lib/ToolkitConfig.psm1` | Locates and reads `.ssis-toolkit.json`; resolves repo-relative paths |
| `lib/SsisOmHost/Program.cs` | Entry point of the console host; dispatches on `pattern` |
| `lib/SsisOmHost/PackageBuilder.cs` | Core OM glue (`Package`, `ConnectionManager`, control flow, data flow) |
| `lib/SsisOmHost/MetadataHelpers.cs` | Metadata JSON accessors, connection resolution, schema checks |
| `lib/SsisOmHost/Patterns/` | Per-pattern C# builders called by the host |
| `lib/SsisOm.psm1`, `lib/patterns/*.psm1` | Superseded by the C# host, which owns all OM work. Retained for reference only — `New-SsisPackage.ps1` does not load them. |

## What you will NOT find here

- No `Validate-SsisPackage.ps1` orchestrator. The [`ssis-delivery-gate`](../.github/skills/ssis-delivery-gate/SKILL.md) skill composes the `Test-Ssis*` primitives instead.
- No script that calls more than one primitive. Composition lives in a skill, not in PowerShell.
