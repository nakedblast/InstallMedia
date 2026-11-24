# Plan

## State
Tool v1 on `main`: `Setup.ps1` + engine with journal/exact revert, modules Audit, Search, Keyboard, Display, Bloat, Stress; profiles `base` and `zenbook-s16-um5606g`; single-file bundle via `tools/Build-Bundle.ps1`. Design: `docs/outlines/setup-tool.md`. Call script: `CHECKLIST.md`. Target laptop: ASUS Zenbook S 16 UM5606G (Ryzen AI 9 465, 32 GB, 1 TB, OLED touch, Win11 Pro). Remote channel: Quick Assist. GitHub repo nakedblast/InstallMedia, temporarily PUBLIC for easy install (history rewritten to noreply email, HANDOFF.md kept local only); switch back to private after the laptop setup.

## Next
- Run the call (install from the public repo zip) per `CHECKLIST.md` (inside the return window)
  - Verify on the laptop what the dev machine could not: restore point, HKLM/policy writes, language list apply/restore, powercfg apply/restore, Appx/Win32 removal, admin audit fields
- Send for engraving after all checks pass

- Switch the repo back to private after the call: `gh repo edit nakedblast/InstallMedia --visibility private --accept-visibility-change-consequences`

## Blocked

## Deferred
- winget app-install layer and a profile for the owner's own machines

## 2026-11-24 · Design outline
Outline written, gap-checked by a fresh reader (12 points resolved as agent calls), committed.

## 2026-11-24 · Build tool v1
Built by an Opus subagent. Evidence: `tests/Run-Tests.ps1` 92/92 pass (rerun by overseer after adding `*McAfee*` to Appx candidates); `tests/Test-Source.ps1` 13 files, 0 parse errors, 0 non-ASCII; sandbox run + revert left no sandbox key and real values unchanged; audit-only report produced; 1-minute stress clean; bundle builds and behaves the same. Unresolved UX points settled as agent calls: keep `-NoExit` on elevated relaunch, keep the final "y" confirm in Bloat, keep `CortanaConsent` and `ConnectedSearchUseWeb` (harmless), accept that `DisableSearchBoxSuggestions` also hides File Explorer search suggestions.
