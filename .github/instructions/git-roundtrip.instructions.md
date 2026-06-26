---
description: "Use when editing .gitattributes, .gitignore, or the round-trip verification scripts (Verify-*.ps1). Enforces the clone → build → open-in-Visual-Studio gate."
applyTo: ".gitattributes, .gitignore, tools/Verify-*.ps1, tools/Build-SsisIspac.ps1"
---
# Git round-trip rules

The toolkit guarantees: a fresh `git clone` on a clean Windows machine with **Visual Studio 2026 (18.4+)** (or VS Code with the build helper installed) can open the `.dtproj`, build via `SSISBuild.exe`, and execute the resulting `.ispac` with **zero manual repair steps**.

## `.gitattributes` invariants

- `*.dtsx`, `*.dtproj`, `*.conmgr`, `*.params` → `text eol=crlf`. SSIS files are Windows XML; LF normalization corrupts designer-load.
- `*.ispac` → `binary`. Don't normalize.
- `*.ps1`, `*.psm1`, `*.psd1`, `*.md`, `*.json`, `*.yml`, `*.sql` → `text eol=lf`.

## `.gitignore` invariants

- Exclude `bin/`, `obj/`, `out/`, `*.suo`, `*.user`, `*.dtproj.user`, `.vs/`, `*.ispac`.
- Exclude `.env*` (except `.env.example`).
- Never exclude `.vscode/` itself — only per-user files (`.vscode/*.local.json`).

## The round-trip gate

`tools/Verify-ClonedProject.ps1` runs four checks in order; any failure blocks the PR:

1. `git clone --depth=1` into a temp dir.
2. `SSISBuild.exe -p:<.dtproj> -ss` → exit code must be 0; `-ss` strips sensitive data for VCS safety.
3. `Microsoft.SqlServer.Dts.Runtime.Application.LoadPackage` against every `.dtsx` → must not throw.
4. `dtexec /Project <.ispac> /Package <name> /Validate /WarnAsError` against every package → must succeed.

## What can break round-trip (and how to fix)

| Symptom | Cause | Fix |
|---|---|---|
| `SSISBuild` exit 1, "ProtectionLevel mismatch" | Project and packages have different `ProtectionLevel` | Regenerate via `New-SsisPackage.ps1` — generator enforces `DontSaveSensitive` uniformly. |
| `LoadPackage` throws `System.Xml.XmlException` | EOL normalization corrupted the XML | Verify `.gitattributes` has `*.dtsx text eol=crlf`; reclone. |
| Visual Studio opens project, prompts for password | Sensitive data baked in with user-key encryption | Confirm `ProtectionLevel=DontSaveSensitive` and that no DPAPI-encrypted blobs leaked into commits. |
| Designer shows "Could not load package" | refIds drifted (manual edit) | Regenerate from metadata JSON; never edit the XML. |

## Don't do

- Don't add `*.user` files to `.gitattributes` with `text` — they're per-user and shouldn't be tracked at all.
- Don't `git add` `.ispac` outputs — they're build artifacts.
- Don't `git add` files from a Visual Studio "Convert" prompt unless you understand what it did to the project.
