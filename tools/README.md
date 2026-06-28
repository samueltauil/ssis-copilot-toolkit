# `tools/` — PowerShell primitives

This folder holds **single-purpose** PowerShell scripts. Each one does exactly one thing because skills (which encode procedures) cannot do those things: load `Microsoft.SqlServer.ManagedDTS.dll`, invoke an external `.exe`, or call an SSISDB stored procedure.

Anything that orchestrates multiple primitives (validate → designer-load → build → round-trip) belongs in a **skill** under [`.github/skills/`](../.github/skills/), not here.

## Shipped primitives

| Script | What it does | Wraps |
|---|---|---|
| `lib/SsisOmHost/Build-SsisOmHost.ps1` | One-time build of the .NET 8 console host that fronts the managed OM | `dotnet publish` against `lib/SsisOmHost/*.cs` |
| `New-SsisPackage.ps1` | Reads a metadata JSON, dispatches to a `lib/patterns/*.psm1` module, calls the host to write `.dtsx` | `Microsoft.SqlServer.Dts.Runtime.Package.SaveToXml` (via the host) |
| `New-SsisProject.ps1` | Generates `.dtproj`, `.conmgr`, and `.params` files for Visual Studio Designer | Well-formed XML generation |
| `Test-SsisPackage.ps1` | Runtime validation | `dtexec.exe /Validate /WarnAsError` |
| `Test-SsisDesignerLoad.ps1` | Round-trip via the managed OM | `Microsoft.SqlServer.Dts.Runtime.Application.LoadPackage` |
| `Remove-DemoAssets.ps1` | Cleanup script — drops warehouse DB, SSISDB Demo folder, generated artifacts | `SqlServer` module + file system operations |

## Roadmap primitives

Referenced by `@ssis-author`'s `deploy-and-execute` and `scaffold-new-ssis-project` prompts and by Steps 3 and 4 of the delivery gate. Not yet on disk; both prompts refuse on invocation, and the delivery gate reports SKIPPED for the matching steps.

| Script | Will do | Will wrap |
|---|---|---|
| `Build-SsisIspac.ps1` | Build `.ispac` from `.dtproj` | `SSISBuild.exe` |
| `Publish-SsisIspac.ps1` | Deploy `.ispac` to SSISDB | `catalog.deploy_project` |
| `Start-SsisExecution.ps1` | Execute a deployed package | `catalog.create_execution` → `catalog.set_execution_parameter_value` → `catalog.start_execution` |
| `Verify-ClonedProject.ps1` | Clean-clone round-trip gate driven by [`ssis-clone-roundtrip`](../.github/skills/ssis-clone-roundtrip/SKILL.md) | `git clone --no-local` + Steps 1–3 against the clone |

## Shared layout under `lib/`

| Path | Purpose |
|---|---|
| `lib/SsisOm.psm1` | PowerShell helpers that locate and invoke the .NET 8 host |
| `lib/patterns/StagingLoad.psm1` | Dispatcher for the staging pattern |
| `lib/patterns/Type1Dimension.psm1` | Dispatcher for the Type-1 dimension pattern |
| `lib/patterns/Type2Dimension.psm1` | Dispatcher for the Type-2 (SCD-2) dimension pattern |
| `lib/patterns/FactLoad.psm1` | Dispatcher for the fact-load pattern |
| `lib/SsisOmHost/Program.cs` | Entry point of the .NET 8 console host |
| `lib/SsisOmHost/PackageBuilder.cs` | Core OM glue (`Package`, `ConnectionManager`, control flow, data flow) |
| `lib/SsisOmHost/MetadataHelpers.cs` | Metadata JSON deserialization + validation |
| `lib/SsisOmHost/Patterns/` | Per-pattern C# builders called by the host |

## What you will NOT find here

- No `Validate-SsisPackage.ps1` orchestrator. The [`ssis-delivery-gate`](../.github/skills/ssis-delivery-gate/SKILL.md) skill composes the `Test-Ssis*` primitives instead.
- No script that calls more than one primitive. Composition lives in a skill, not in PowerShell.
