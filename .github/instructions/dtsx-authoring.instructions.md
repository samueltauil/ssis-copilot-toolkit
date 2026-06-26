---
description: "Use when editing, opening, or generating SSIS package files (.dtsx, .dtproj, .conmgr, .params) — enforces the never-hand-edit-XML rule and routes work through the managed object model pattern modules."
applyTo: "**/*.dtsx, **/*.dtproj, **/*.conmgr, **/*.params, templates/ssis-project/**"
---
# DTSX authoring rules

## Hard rule: never hand-edit `.dtsx`, `.dtproj`, `.conmgr`, or `.params`

These files contain internal refIds, lineage IDs, designer-only DesignTimeProperties, and validation state. The managed object model (`Microsoft.SqlServer.Dts.Runtime`) owns those identifiers. A text edit corrupts them and the package fails one of:

- XML well-formedness (`Test-SsisPackage.ps1` step 1)
- Runtime validation (`dtexec /Validate` step 2)
- Designer load (`Application.LoadPackage` step 3)
- Round-trip to Visual Studio (`Verify-ClonedProject.ps1` step 4 — *roadmap*)

## How to author or change a package

1. Edit the **metadata JSON** under `templates/metadata/` (or generate a new one).
2. Run `.\tools\New-SsisPackage.ps1 -Metadata <file.json>` — it dispatches to the pattern module under `tools/lib/patterns/` and emits the `.dtsx` via `Package.SaveToXml`.
3. Run the delivery gate (skill: [`ssis-delivery-gate`](../skills/ssis-delivery-gate/SKILL.md)): `Test-SsisPackage.ps1` → `Test-SsisDesignerLoad.ps1`. `Build-SsisIspac.ps1` and `Verify-ClonedProject.ps1` are roadmap and skipped today.

## If the existing patterns don't fit

Refuse the change and ask the user to extend the pattern modules at the OM level. Don't generate a custom `.dtsx` outside the pattern dispatcher.

## Refid / lineageId / GUID rules

- Never write `refId="…"` or `lineageId="…"` values directly.
- Never copy these IDs from one package to another.
- If a regenerated package needs a new GUID, use `dtutil /IDRegenerate` from inside the generator, not by editing the XML.
