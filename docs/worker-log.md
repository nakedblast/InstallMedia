# Worker log

## 2026-11-24 · Setup tool v1 build

**Task:** build v1 per `docs/outlines/setup-tool.md` (Clarifications override).

**Files:** `Setup.ps1`, `lib/Engine.psm1`, `modules/{Audit,Search,Keyboard,Display,Bloat,Stress}.ps1`, `profiles/base.psd1`, `profiles/zenbook-s16-um5606g.psd1`, `tools/Build-Bundle.ps1`, `tests/Run-Tests.ps1`, `tests/Test-Source.ps1` (check 7 helper). Bundle built to `dist/InstallMedia-zenbook-s16-um5606g-1.0.0.ps1` (gitignored).

**Validation (dev machine, Windows PowerShell 5.1.26100, non-elevated, Win11 Home 25H2):**
- Check 1: `tests/Run-Tests.ps1`: 92 passed, 0 failed, exit 0.
- Check 2: sandbox run with `-Enable DarkMode,AutoHideTaskbar`: exit 0, 9 values plus 1 logged power action under `HKCU:\Software\InstallMedia-Test`; `-Sandbox -Revert`: reverted 10, sandbox key removed. A snapshot of the real values (Search, SearchSettings, Explorer policies, Personalize, StuckRects3, Windows Search policies, SystemRestore, language list, power indexes) was identical before and after.
- Check 3: `-AuditOnly -NoElevate`: exit 0; report.md, report.json, battery-report.html/.xml written; 4 FAIL and 3 WARN rows (not a Zenbook); "needs admin" for TPM and disk reliability counters; no ProgramData journal.
- Check 4: `-Only Stress -StressMinutes 1 -NoElevate -Sandbox`: exit 0; 12 CSV samples; 0 leftover runspaces; CPU about 6% afterwards.
- Check 5: bundle built (SHA256 printed); run from a separate folder with `-Sandbox -AuditOnly -NoElevate` and with `-Sandbox -Enable ...`, then reverted: same results as checks 2 and 3.
- Check 6: `-WhatIf -Sandbox` full run: exit 0; sandbox key absent; sandbox journal byte-identical.
- Check 7: `tests/Test-Source.ps1 -Extra <bundle>`: 14 files, 0 parse errors, 0 non-ASCII bytes.
- Test output folders on the Desktop and `%TEMP%\InstallMedia-Sandbox` deleted afterwards.

**Not verifiable here (needs the elevated real run):** restore point creation, `Enable-ComputerRestore`, live HKLM writes, real `Set-WinUserLanguageList` apply/verify/restore, real powercfg apply/restore, Appx/Win32 removal, self-elevation relaunch, admin-only audit fields (TPM, BitLocker, disk reliability), battery parsing on a real battery.

**Open issues:** see the build report (search-key confidence, Pro-only policy effectiveness, -NoExit on relaunch, final y/N confirmation in Bloat).
