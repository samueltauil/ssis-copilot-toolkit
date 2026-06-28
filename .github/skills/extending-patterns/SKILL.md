# Skill: Extending Patterns

Use when adding a new SSIS package pattern to the toolkit (beyond the four shipped: staging, Type-1 dim, Type-2 dim, fact). This skill is a checklist — follow it top to bottom.

## Prerequisites

- The new pattern must represent a repeatable data-flow shape (not a one-off package).
- You must be able to describe the control-flow and data-flow structure in one sentence (e.g. "merge-join two sorted staging tables into a bridge table").

## Checklist

### 1. Define the metadata schema extension

Create a sample `templates/metadata/<PatternName>.metadata.json` with:
- `"pattern": "<patternKey>"` — a new lowercase key (e.g. `"bridge"`, `"aggregate"`, `"delete-detection"`).
- All fields the builder will need (source/destination tables, columns, keys, any pattern-specific options).
- Follow the rules in `.github/instructions/metadata-schema.instructions.md`.

### 2. Write the C# builder class

Create `tools/lib/SsisOmHost/Patterns/<PatternName>.cs`:
- Implement the same interface as the existing builders (see `StagingLoad.cs` for the minimal contract).
- Use the managed object model (`Microsoft.SqlServer.Dts.Runtime`, `Microsoft.SqlServer.Dts.Pipeline.Wrapper`) — never emit raw XML.
- The class receives deserialized metadata and an `Application` + `Package` object; it adds tasks, data-flow components, and connections.

### 3. Register in Program.cs

Edit `tools/lib/SsisOmHost/Program.cs`:
- Add a `case "<patternKey>":` branch that instantiates your new builder class.
- The pattern key must match the `"pattern"` value in metadata JSON exactly.

### 4. Write the PowerShell dispatch module

Create `tools/lib/patterns/<PatternName>.psm1`:
- Export a single function that the dispatcher (`SsisOm.psm1`) calls.
- It should validate metadata fields specific to this pattern, then invoke `SsisOmHost.exe` with the JSON path.
- Follow the same structure as `StagingLoad.psm1`.

### 5. Update SsisOm.psm1 dispatcher

Add your new pattern key to the `switch` statement in `tools/lib/SsisOm.psm1` so that `New-SsisPackage.ps1` routes to your module.

### 6. Add DDL for target tables (demo only)

If you are extending the demo walkthrough, add a SQL script under `templates/sql/` for the target schema/table. Follow `.github/instructions/sql-conventions.instructions.md`.

### 7. Run the delivery gate

After generating a test package with your new pattern:
1. `.\tools\Test-SsisPackage.ps1 -Package <generated.dtsx>` — must exit 0.
2. `.\tools\Test-SsisDesignerLoad.ps1 -Package <generated.dtsx>` — must exit 0.
3. Open in Visual Studio's SSIS designer — verify no red-X or missing-component errors.

### 8. Document

- Add the pattern to the table in `AGENTS.md` (§ "The four supported package patterns" — now N+1).
- Add to `README.md` § "The four supported package patterns" with a "Why" paragraph.
- Add to `.github/skills/ssis-package-patterns/SKILL.md` with the managed-OM call sequence.
- If the pattern is demo-only, add a sample `.metadata.json` under `templates/metadata/`.

## Anti-patterns

- Do NOT create a pattern for something achievable by parameterizing an existing pattern (e.g. adding a WHERE clause to staging is not a new pattern).
- Do NOT skip the delivery gate; a pattern that cannot pass validation is not shippable.
- Do NOT hand-edit `.dtsx` to "test quickly" — always go through the builder.
