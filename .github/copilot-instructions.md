# Copilot instructions

The repo-wide always-on guidance for this workspace lives in [../AGENTS.md](../AGENTS.md). Read it once per session.

In short:
- This repo authors SSIS via a managed object model from PowerShell. Never hand-edit `.dtsx`.
- The custom agent **ssis-author** (see [agents/ssis-author.agent.md](agents/ssis-author.agent.md)) is the only sanctioned entry point for SSIS work.
- Eight `/`-invokable prompts live in [prompts/](prompts/); eight skills auto-discover under [skills/](skills/).
- Every SSIS change must pass the delivery gate, encoded in the [`ssis-delivery-gate`](skills/ssis-delivery-gate/SKILL.md) skill and run by the **ssis-validator** agent. The two shipped gate steps are `Test-SsisPackage.ps1` (`dtexec /Validate`) and `Test-SsisDesignerLoad.ps1` (designer round-trip); `Build-SsisIspac.ps1` and `Verify-ClonedProject.ps1` are roadmap and report SKIPPED today.
- Repo layout, connections, and warehouse schema names come from `.ssis-toolkit.json` at the repo root. Never hard-code a path, server, or database. Pointing the toolkit at your own databases: [docs/bring-your-own-databases.md](../docs/bring-your-own-databases.md).

For SSIS API questions, use the `microsoft-docs/*` tools (Microsoft Learn MCP) and cite the URL.
