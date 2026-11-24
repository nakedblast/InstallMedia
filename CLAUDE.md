# InstallMedia: reusable Windows machine setup tool

PowerShell tool that audits a Windows 11 machine, applies data-driven tweaks with exact revert, and runs a per-machine profile. First use: a relative's new ASUS Zenbook S 16 (UM5606G), set up over Quick Assist before its keyboard is laser-engraved (return window closes then). Later use: the owner's own machines.

- Plan: `docs/PLAN.md`. Design: `docs/outlines/`. Original brief: `HANDOFF.md` (provenance; the outline supersedes it where they differ).
- Target: Windows 11 Home and Pro, x64 and ARM64, Windows PowerShell 5.1 (must not require PowerShell 7). No downloads at runtime; native cmdlets.
- Every registry or system change goes through the engine so its previous state is recorded and `-Revert` restores it exactly. Audit is read-only.
- Never remove vendor driver/utility apps (MyASUS, ASUS System Control Interface, Armoury Crate services, audio/touchpad drivers). Bloat removal lists first and removes only after confirmation.
- Test on this dev machine only with `-WhatIf`/audit-only runs unless a change is explicitly approved; never apply tweaks to the dev machine as a side effect of testing.
