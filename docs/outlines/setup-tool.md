# Outline: InstallMedia setup tool v1

## Goal
A PowerShell tool that (1) audits a new Windows 11 machine against what was paid for and saves a report, (2) applies a per-machine profile of tweaks through an engine that records every previous value so `-Revert` restores it exactly, and (3) is reusable for the owner's own machines. First run: an ASUS Zenbook S 16 UM5606G, driven by the helper over Quick Assist from an elevated PowerShell window, before the keyboard is engraved.

## Non-goals
- App installs (winget) — later stage, owner's own machines only.
- Any runtime download (no PowerShell Gallery, no web requests). Windows itself fetching language features is acceptable.
- GUI. Console only.
- MyASUS settings (Pixel Refresh, Pixel Shift, OLED taskbar transparency): no supported API; they go in `CHECKLIST.md`.

## Anti-goals (failure even if it works)
- A change that is not in the journal, or a revert that leaves a value different from the original (including "value did not exist" → must be deleted again).
- Touching vendor driver/utility apps (MyASUS, ASUS System Control Interface, Armoury Crate services, Realtek/Cirrus audio, touchpad, AMD chipset/graphics).
- Removing anything without a per-item confirmation.
- Writing HKCU of the wrong user (elevated as a different admin than the signed-in user).
- Requiring PowerShell 7, or non-ASCII source files that Windows PowerShell 5.1 misreads.
- Testing that changes the dev machine's real settings.

## Approaches considered
1. **Own small PowerShell tool (chosen — user)**: engine + modules + PSD1 profiles; exact revert, audit, confirm flows; no dependencies.
2. WinGet Configuration / DSC: no recorded-previous-value revert, no audit, resources often downloaded. Possible later layer for app installs (user).
3. Existing debloat tools (Sophia Script, Win11Debloat): too broad and opinionated to audit for someone else's laptop; used only as a key reference.

## Settled decisions
| Decision | By |
|---|---|
| Remote channel: Quick Assist only; helper runs the tool in one elevated PowerShell window the owner approved | user |
| Reusable tool now; Zenbook profile is the first profile | user |
| Private GitHub repo (never public) | user |
| Delivery to a machine: `tools/Build-Bundle.ps1` produces one self-contained `dist/InstallMedia-<profile>-<version>.ps1`; the helper shares it via their own cloud link and runs it with `powershell -ExecutionPolicy Bypass -File <path>` | agent call (follows from private repo) |
| Search debloat is the shared base tweak set (owner's own tweak list = search debloat) | user |
| OLED/power settings in the Zenbook profile; dark mode and taskbar auto-hide are opt-in at run time | agent call, owner decides on the call |
| Keyboard: ensure plain US (`0409:00000409`) + Russian ЙЦУКЕН (`0419:00000419`); remove US-International (`0409:00020409`) if present; display language and regional formats untouched | agent call (proposed, not objected) |
| Optional light stress test (default 10 min) using built-in PowerShell only | user ("potentially"), agent proposed; opt-in |
| Tests use plain PowerShell assert scripts (dev machine has Pester 3.4 only) | agent call |

## Layout
```
Setup.ps1                     entry point
lib/Engine.psm1               journal, tracked changes, revert, logging, elevation/user checks, sandbox redirection
modules/Audit.ps1             read-only report
modules/Search.ps1            search debloat (registry)
modules/Keyboard.ps1          input layouts
modules/Display.ps1           power timeouts, optional dark mode / taskbar auto-hide
modules/Bloat.ps1             list candidates, confirm per item, remove
modules/Stress.ps1            optional CPU load test
profiles/base.psd1            shared defaults (search tweaks, bloat candidates)
profiles/zenbook-s16-um5606g.psd1   machine profile; Inherits = 'base'
tools/Build-Bundle.ps1        single-file bundle -> dist/ (gitignored)
tests/Run-Tests.ps1           engine + sandbox end-to-end tests
docs/worker-log.md
```
All `.ps1/.psm1/.psd1` files ASCII-only. Where Cyrillic is needed in output, build it from code points.

## Setup.ps1 interface
```
Setup.ps1 [-Profile <name|path>] [-Only <module[]>] [-Skip <module[]>]
          [-AuditOnly] [-Revert] [-Enable <option[]>] [-StressMinutes <int>]
          [-Sandbox] [-NoElevate] [-Force] [-WhatIf]
```
- Modules run in order: Audit, Search, Keyboard, Display, Bloat, Stress. Stress runs only when `-StressMinutes` > 0 or `-Only Stress` (then default 10).
- `-Profile` default: if exactly one non-base profile exists (bundle case) use it; else required.
- `-Enable` values: `DarkMode`, `AutoHideTaskbar` (validated against the profile's `Optional` keys).
- `-AuditOnly`: Audit only, no restore point, no journal.
- `-Revert [-Only <module[]>]`: undo journal entries (all, or those tagged with the modules) in reverse order.
- `-Sandbox`: test mode, see Engine. Implies no elevation needed, no restore point, journal in `%TEMP%\InstallMedia-Sandbox\`.
- `-NoElevate`: do not self-elevate (testing; Audit marks admin-only fields "needs admin").
- `-WhatIf`: `SupportsShouldProcess` throughout; nothing changes, planned changes are printed.
- Elevation: if not admin and not `-Sandbox/-NoElevate`, relaunch `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file>` with the same bound parameters, then exit. Requires running from a file (document; refuse with a clear message under `iex`).
- Before the first changing module (not AuditOnly/Revert/Sandbox/WhatIf): ensure System Protection on the system drive (`Enable-ComputerRestore`), set `SystemRestorePointCreationFrequency` = 0 via the engine (tracked) so `Checkpoint-Computer` is not skipped by the 24 h limit, create restore point "InstallMedia before <profile>". If restore point creation fails, stop unless `-Force`.
- User check: if elevated, compare the process user with the owner of the interactive `explorer.exe`; if different, stop unless `-Force` (HKCU would be the wrong user).
- Output folder: `<Desktop>\InstallMedia\<COMPUTERNAME>-<yyyyMMdd-HHmmss>\` via `[Environment]::GetFolderPath('Desktop')` (handles OneDrive-redirected Desktop). Holds transcript, report, battery report, stress CSV, journal copy.
- End: print a summary (per module: changed / unchanged / skipped / failed), whether Explorer restart or sign-out is needed, and the revert command.

## Engine (lib/Engine.psm1)
Public functions:
- `Initialize-Engine -Sandbox:$bool -WhatIf:$bool -OutputDir <path>` — sets journal path (`$env:ProgramData\InstallMedia\journal.json`, or sandbox temp path), loads existing journal.
- `Set-TrackedRegistryValue -Module <s> -Path <'HKCU:\...'|'HKLM:\...'> -Name <s> -Value <obj> -Type <DWord|QWord|String|ExpandString|Binary|MultiString>` — reads current state; if equal, records nothing and returns 'Unchanged'; otherwise records an entry once per (path,name) — if an entry already exists from an earlier run, keep its original `Old*` and update `New*` — then writes (creating keys as needed). Returns 'Changed'.
- `Remove-TrackedRegistryValue` — same journaling, for values that should not exist.
- `Invoke-TrackedAction -Module <s> -Kind <power|language|appx|win32> -Description <s> -Capture {sb} -Apply {sb} -Restore {sb param($old)}` — generic tracked non-registry change; `Capture` result stored as `Old`. `appx`/`win32` entries are `Revertible = $false`.
- `Invoke-Revert [-Module <s[]>] [-Force]` — reverse order; for registry: if the current value no longer equals `New*` (changed since), warn and skip unless `-Force`; restore `Old*` or delete when `ExistedBefore = $false`; remove empty keys the engine created. Non-revertible entries are listed with how to restore (Microsoft Store / restore point). Reverted entries are removed from the journal; journal saved after each entry.
- `Write-Log` — console + transcript, levels Info/Ok/Warn/Fail.
- Journal entry shape (JSON array):
  `{ Id, Time, Module, Kind: 'registry'|'power'|'language'|'appx'|'win32', Path, Name, ExistedBefore, OldValue, OldType, NewValue, NewType, Old, Description, Revertible }`
  Binary values stored as base64; MultiString as arrays.
- **Sandbox**: every registry path is redirected to `HKCU:\Software\InstallMedia-Test\<HKCU|HKLM>\<rest of path>`; `Invoke-TrackedAction` runs `Capture` for real (read-only) but replaces `Apply`/`Restore` with logging. This is the only way tests may exercise writes on the dev machine.

## Profiles (PSD1)
Loaded with `Import-PowerShellDataFile`; `Inherits` merges base first, then machine keys override (hashtables merge recursively; arrays replace).

`base.psd1` keys:
- `SearchTweaks` — array of `@{ Path; Name; Type; Value; Note; Verified = '<build, date>' | 'ineffective on 24H2+' }`. Builder verifies each candidate against current Win11 (24H2/25H2) documentation and keeps only effective or harmless-and-documented ones, recording findings in `Note`. Candidates:
  - `HKCU\Software\Policies\Microsoft\Windows\Explorer` `DisableSearchBoxSuggestions`=1
  - `HKCU\Software\Microsoft\Windows\CurrentVersion\Search` `BingSearchEnabled`=0, `CortanaConsent`=0
  - `HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings` `IsDynamicSearchBoxEnabled`=0, `IsMSACloudSearchEnabled`=0, `IsAADCloudSearchEnabled`=0
  - `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search` `EnableDynamicContentInWSB`=0, `ConnectedSearchUseWeb`=0, `DisableWebSearch`=1, `AllowCloudSearch`=0
  - Local search history and the taskbar search box mode are NOT changed.
- `Bloat` — `@{ Appx = @(<package name wildcards>); Win32 = @(<DisplayName wildcards>); Protect = @(<wildcards never offered>) }`. Conservative Appx list: Clipchamp, BingNews, Solitaire, Xbox apps (`Microsoft.GamingApp`, `Microsoft.XboxApp`, `Microsoft.Xbox.TCUI`? only if not a dependency), `Microsoft.MicrosoftOfficeHub` NOT included (owner uses Office). Win32: `McAfee*`, `Norton*`, `ExpressVPN*`, `WildTangent*`, `Booking.com*`, `Dropbox*promotion*`. Protect: `*ASUS*`, `*MyASUS*`, `*Armoury*`, `*Realtek*`, `*AMD*`, `*Cirrus*`, `*Dolby*`, `*Synaptics*`, `*ELAN*`, `Microsoft.WindowsStore`, `Microsoft.DesktopAppInstaller`, `*Office*` (except explicit Appx list entries).
- `Keyboard` — `@{ Ensure = @('0409:00000409','0419:00000419'); Remove = @('0409:00020409'); LanguageOrder = @('en-US','ru-RU') }`.

`zenbook-s16-um5606g.psd1` keys:
- `Inherits = 'base'`, `Name`, `Description`
- `Expected = @{ Manufacturer = 'ASUS*'; Model = '*UM5606*'; Cpu = '*Ryzen AI 9 465*'; RamGB = 32; DiskGB = 1000 (±5%); Edition = '*Pro*'; BatteryDesignWh = 83 (±5%); DisplayResolution = '2880x1800'; Touch = $true }` — mismatch → WARN (FAIL for CPU/RAM/disk size/edition).
- `Power = @{ MonitorAcMin = 10; MonitorDcMin = 5; SleepAcMin = 30; SleepDcMin = 15 }`
- `Optional = @{ DarkMode = 'Windows + apps dark theme'; AutoHideTaskbar = 'Taskbar hides until the pointer reaches the bottom edge' }`

## Modules
Each module file defines `Invoke-<Name>Module -Profile <hashtable> -Context <hashtable>` and returns a result object `{ Module, Changed, Unchanged, Skipped, Failed, Notes[] }`. `Context` holds OutputDir, Enable list, StressMinutes, flags.

- **Audit** (read-only; also runs first in a full run): system (manufacturer, model, serial, BIOS version/date), Windows edition/version/build, activation (`SoftwareLicensingProduct` with PartialProductKey, LicenseStatus=1), CPU (name, cores/threads), RAM (total, speed, configured speed), disks (model, size, bus, health, `Get-StorageReliabilityCounter`: wear, temperature, power-on hours, read/write errors — admin), battery (`powercfg /batteryreport` HTML to output folder + `/xml` parsed: design vs full-charge capacity → health %, cycle count; high cycle count on a new unit → WARN), display (current resolution, refresh rate, `WmiMonitorID` panel name), GPU + driver version/date, Wi-Fi adapter, camera/mic/audio endpoints present, touch present, Secure Boot, TPM, BitLocker/device encryption status (WARN to back up the recovery key if on), PnP devices with problems (`Get-PnpDevice -PresentOnly` Status Error/Degraded/Unknown), events in the last 14 days: WHEA-Logger, Kernel-Power 41, BugCheck 1001. Compares with `Expected` → PASS/WARN/FAIL. Writes `report.md` and `report.json`; prints a compact summary. Every probe in try/catch; a failed probe is "unavailable", never aborts.
- **Search**: applies `SearchTweaks` via engine; sets `Context.NeedsExplorerRestart`.
- **Keyboard**: tracked action Kind `language`: Capture = serialized `Get-WinUserLanguageList` (tag + InputMethodTips per language, order); Apply = build new list (keep every existing language and its tips, add missing `Ensure` tips under the right language tag, remove `Remove` tips, but never leave a language with zero tips — drop that language entry only if it has no other tips and is not the first/display language); `Set-WinUserLanguageList -Force`; Restore = rebuild captured list. Prints the result and "switch with Win+Space".
- **Display**: power timeouts via tracked action Kind `power` (Capture current AC/DC values of active scheme for VIDEOIDLE and STANDBYIDLE via `powercfg /q`, Apply `powercfg /change`, Restore `powercfg /setacvalueindex|setdcvalueindex` + `/setactive`). Optional only when in `-Enable`: DarkMode (`HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` `AppsUseLightTheme`=0, `SystemUsesLightTheme`=0); AutoHideTaskbar (`HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3` `Settings` binary, byte 8 set to 0x03 from 0x02, written as a tracked Binary value; sets NeedsExplorerRestart).
- **Bloat**: find installed Appx (current user, `Get-AppxPackage`) and Win32 (uninstall keys HKLM 64/32 + HKCU) matching `Bloat` lists and not matching `Protect`; print numbered list with name, publisher, size if known; prompt for item numbers (`1,3,5`, `all`, or empty = none). Appx: `Remove-AppxPackage` for the current user only (no deprovisioning), journal Kind `appx`, `Revertible=$false`. Win32: start its `QuietUninstallString` if present else `UninstallString`, wait, re-check; journal Kind `win32`. Never runs under `-WhatIf` beyond listing; `-Force` does not skip the prompt.
- **Stress**: warn if on battery (ask to plug in, continue on confirm). Start one runspace per logical processor running a tight hashing loop; sample every 5 s: `\Processor Information(_Total)\% Processor Utility`, `% Processor Performance`, `Processor Frequency`, battery/AC state; attempt `MSAcpi_ThermalZoneTemperature` (ignore if unsupported). Ctrl+C or end → stop and dispose runspaces in `finally`. Afterwards check events since start (WHEA, Kernel-Power, BugCheck). Write `stress.csv`; summary: duration completed, mean effective clock first vs last minute (ratio < 0.6 → WARN "heavy throttling"), any errors → FAIL. Reminds the helper to ask the owner about fan noise and keyboard-deck heat.

## Bundle (tools/Build-Bundle.ps1)
`Build-Bundle.ps1 -Profile <name>` → `dist/InstallMedia-<profile>-<version>.ps1`: one file containing the engine (as a dynamic module via `New-Module -ScriptBlock`), all modules, base + chosen profile embedded as data, and `Setup.ps1`'s parameter block and main logic. Behaves exactly like `Setup.ps1 -Profile <name>` and supports all switches, including self-elevation (relaunching itself by path). `$InstallMediaVersion` lives in `Setup.ps1` (start `1.0.0`). `dist/` is gitignored. Prints the SHA256 of the output so the helper can confirm the downloaded copy.

## Acceptance checks
1. `tests/Run-Tests.ps1` passes on the dev machine (Windows PowerShell 5.1, non-elevated), covering: set new value → revert deletes it; set existing value → revert restores original value and type; double set keeps the original; revert skips a value changed since (and `-Force` overrides); Binary and MultiString round-trip; empty created keys removed; profile inheritance merge; keyboard list builder (pure function) for: already-US, US-International only, Russian already present.
2. `Setup.ps1 -Profile zenbook-s16-um5606g -Sandbox -Enable DarkMode,AutoHideTaskbar` completes (Bloat lists and accepts an empty answer; Stress skipped), all registry writes land under `HKCU:\Software\InstallMedia-Test`, then `-Sandbox -Revert` leaves that key empty/removed. No real setting changed (spot-check the real Search, Personalize and StuckRects3 values before/after).
3. `Setup.ps1 -Profile zenbook-s16-um5606g -AuditOnly -NoElevate` produces `report.md`, `report.json` and a battery report on the dev machine without errors; Expected mismatches show as WARN/FAIL (the dev machine is not a Zenbook), admin-only fields show "needs admin".
4. `Setup.ps1 -Only Stress -StressMinutes 1 -NoElevate -Sandbox` runs and stops cleanly, CSV written, CPU returns to idle (no leftover runspaces).
5. `tools/Build-Bundle.ps1 -Profile zenbook-s16-um5606g` produces a single file; running it with `-Sandbox -AuditOnly -NoElevate` and with `-Sandbox` behaves as checks 2–3.
6. `-WhatIf` full run with `-Sandbox` writes nothing (sandbox key absent afterwards).
7. All source files ASCII; parse cleanly under 5.1 (`[System.Management.Automation.Language.Parser]::ParseFile` with zero errors).

## Verification script (no browser)
Run checks 1–7 in order from a non-elevated Windows PowerShell 5.1 on the dev machine; passing means every check reports success, no unhandled exceptions in transcripts, and the real registry values spot-checked in check 2 are identical before and after. The real run (elevated, real changes) happens only on the Zenbook over Quick Assist.

## Clarifications (gap check; these override earlier sections where they differ — all agent calls)
1. **User identity.** On Quick Assist the owner approves the UAC prompt, so the elevated process runs as the owner (same admin account). The explorer-owner check is a hard stop. `-Force` does not override it for HKCU work: it only allows HKLM-only work to continue. Log the user name and SID at start.
2. **Journal user scope.** Each entry carries `UserSid`. Revert skips HKCU and language entries whose SID differs from the current user's, with a warning.
3. **Registry revert details.** Each entry records `KeyExistedBefore`. Revert deletes a key only if it is empty and was created by the engine. An entry skipped as "changed since" stays in the journal and is reported. Values are compared by type and content (element-wise for byte[] and string[]).
4. **Keyboard.** Capture stores tags and tips in order. Restore removes only languages absent at capture and restores the captured tip sets and order. After Apply and after Restore, re-read the list and fail loudly on a mismatch. A layout tip that would need a download is skipped and reported.
5. **Search tweak verification.** The builder verifies each entry from its own knowledge and any web documentation it can reach. It records the source and confidence in `Note`, marks uncertain entries `Verified = 'unverified'`, and applies only those that are effective or harmless. Policies that are no-ops on Home are skipped on Home (edition check).
6. **AutoHideTaskbar.** Byte index 8, zero-based. If the value is absent, shorter than 9 bytes, or byte 8 is not 0x02/0x03, skip with a warning. Write the full blob back as one tracked Binary value.
7. **Power.** Use `powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE` (and `SUB_SLEEP STANDBYIDLE`). Parse the two hex index lines by regex on the trailing `0x...` (locale-independent: take the last two hex values in order AC, DC). Store seconds and the active scheme GUID. Apply and restore with `/setacvalueindex` and `/setdcvalueindex` on that GUID, then `/setactive <guid>`.
8. **Restore point.** The frequency value is journaled under module `Engine` and reverted only by a full `-Revert`. `Enable-ComputerRestore` is journaled as non-revertible. Order: enable protection, write frequency, create restore point, then modules. If restore points are disabled by policy, report it and stop unless `-Force`.
9. **Bloat matching.** Protect always wins, except that an exact (non-wildcard) name in the Appx list beats a Protect wildcard. Replace the `*Office*` Protect entry with `Microsoft.Office.*` and `*Microsoft 365*`. Drop `Microsoft.Xbox.TCUI` from candidates. Under `-WhatIf` and `-Sandbox`, Bloat only lists.
10. **Bundle.** Profiles are embedded as here-strings and parsed with a restricted-language data parse (for example `[scriptblock]::Create($text)` after `CheckRestrictedLanguage`), since `Import-PowerShellDataFile` needs a file. Relaunch serializes bound parameters (switches as flags, arrays comma-joined and quoted). The SHA256 is printed at build time only.
11. **Expected values.** Disk in decimal GB (bytes/1e9), 1000 ± 5%. RAM: total ≥ 31 GB. The Model match is checked first. FAIL = CPU, RAM, disk size, edition or model mismatch; anything else is WARN. The exact unit has a Ryzen AI 9 465 (from the box label).
12. **Acceptance wording.** "No errors" means exit code 0 and no unhandled exception. "Writes nothing" refers to the registry and the journal; the output folder is allowed. Check 4 runs real CPU load (not a setting change); `-Sandbox` is irrelevant there. Read-only capture (`powercfg /q`, `Get-AppxPackage`) runs under `-WhatIf`.
