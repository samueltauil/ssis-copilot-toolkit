---
description: "Generate human-readable Markdown documentation for an SSIS package — control flow, data flow components, parameters, connections, and runbook for execution."
agent: ssis-author
argument-hint: "Package name or .dtsx path"
---
Document an SSIS package so a new team member can understand what it does, how to run it, and what to check after.

Inputs:
- Package name OR `.dtsx` file path.

Steps:
1. Load the package via `Application.LoadPackage` (read-only) and walk the control flow and data flow.
2. Read the matching `templates/metadata/<PackageName>.metadata.json` for the intent (pattern, source, target, key strategy).
3. Write `templates/docs/<PackageName>.md` with these sections:
   - **Purpose** (one paragraph from the metadata `description`).
   - **Pattern** (staging / type1-dim / type2-dim / fact) and what that pattern guarantees.
   - **Control flow** — each task, in order, one line each.
   - **Data flow** — source → transformations → destination, with column-level mapping table.
   - **Connection managers** — name, type, and what each points at.
   - **Parameters** — name, scope (project vs package), default, sensitive Y/N.
   - **Runbook** — exact PowerShell command to execute, expected runtime, what success looks like, what failure looks like.
   - **Validation queries** — link to the matching `templates/sql/validate-<PackageName>.sql` if present.
4. Refresh `templates/docs/README.md` (the index) to include the new doc.

Do not modify the `.dtsx`. Do not modify the metadata JSON.
