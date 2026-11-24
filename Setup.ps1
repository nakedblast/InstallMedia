<#
.SYNOPSIS
    InstallMedia: audit a Windows 11 machine, apply a per-machine profile of tracked tweaks, revert exactly.

.DESCRIPTION
    Run from a file in Windows PowerShell 5.1:
        powershell -ExecutionPolicy Bypass -File .\Setup.ps1 -Profile zenbook-s16-um5606g
    Modules run in order: Audit, Search, Keyboard, Display, Bloat, Stress.
    Every change is journaled (%ProgramData%\InstallMedia\journal.json); -Revert undoes them.
    Not supported under Invoke-Expression: the script must be able to relaunch itself elevated.

.PARAMETER Profile
    Profile name (profiles\<name>.psd1) or path. Default: the only non-base profile, if there is exactly one.
.PARAMETER Only
    Run only these modules (with -Revert: revert only entries tagged with these modules).
.PARAMETER Skip
    Skip these modules.
.PARAMETER AuditOnly
    Read-only report; no restore point, no journal.
.PARAMETER Revert
    Undo journal entries in reverse order.
.PARAMETER Enable
    Opt-in options from the profile's Optional section: DarkMode, AutoHideTaskbar.
.PARAMETER StressMinutes
    Run the CPU load test for this many minutes (with -Only Stress the default is 10).
.PARAMETER Sandbox
    Test mode: registry writes go to HKCU:\Software\InstallMedia-Test, other changes are only logged.
.PARAMETER NoElevate
    Do not relaunch elevated (testing; admin-only audit fields show "needs admin").
.PARAMETER Force
    Continue when the restore point fails; revert values changed since; with a user mismatch, do HKLM-only work.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Profile,
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$AuditOnly,
    [switch]$Revert,
    [string[]]$Enable,
    [int]$StressMinutes = 0,
    [switch]$Sandbox,
    [switch]$NoElevate,
    [switch]$Force
)

$InstallMediaVersion = '1.0.0'
$ErrorActionPreference = 'Stop'

if (-not $PSCommandPath) {
    Write-Host 'InstallMedia must be run from a file: powershell -ExecutionPolicy Bypass -File <path to script>' -ForegroundColor Red
    return
}

#region IM-LOADER
$script:IMEmbeddedProfiles = $null
$script:IMProfileDir = Join-Path $PSScriptRoot 'profiles'
Import-Module (Join-Path $PSScriptRoot 'lib\Engine.psm1') -Force -DisableNameChecking
foreach ($m in 'Audit', 'Search', 'Keyboard', 'Display', 'Bloat', 'Stress') { . (Join-Path $PSScriptRoot "modules\$m.ps1") }
#endregion IM-LOADER

#region IM-MAIN
$script:IMModules = @('Audit', 'Search', 'Keyboard', 'Display', 'Bloat', 'Stress')
$script:IMChangingModules = @('Search', 'Keyboard', 'Display', 'Bloat')

function Split-IMList {
    # Accepts arrays and comma-joined strings (powershell -File passes "a,b" as one string).
    param([string[]]$Value)
    , @($Value | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Resolve-IMNames {
    param([string[]]$Names, [string[]]$Allowed, [string]$What)
    $out = @()
    foreach ($n in $Names) {
        $hit = $Allowed | Where-Object { $_ -ieq $n } | Select-Object -First 1
        if (-not $hit) { throw "Unknown $What '$n' (allowed: $($Allowed -join ', '))" }
        $out += $hit
    }
    , $out
}

function Get-IMProfileNames {
    if ($script:IMEmbeddedProfiles) { return , @($script:IMEmbeddedProfiles.Keys) }
    , @(Get-ChildItem -LiteralPath $script:IMProfileDir -Filter '*.psd1' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
}

function Read-IMProfileData {
    param([string]$Name, [string]$Dir)
    if ($script:IMEmbeddedProfiles -and -not $Dir) {
        if (-not $script:IMEmbeddedProfiles.ContainsKey($Name)) { throw "Profile '$Name' is not in this bundle (contains: $(@($script:IMEmbeddedProfiles.Keys) -join ', '))" }
        return (ConvertFrom-IMDataText -Text $script:IMEmbeddedProfiles[$Name] -SourceName "profile $Name")
    }
    if (-not $Dir) { $Dir = $script:IMProfileDir }
    $path = Join-Path $Dir "$Name.psd1"
    if (-not (Test-Path -LiteralPath $path)) { throw "Profile not found: $path" }
    return (Import-PowerShellDataFile -LiteralPath $path)
}

function Resolve-IMProfile {
    param([string]$Requested)
    $dir = $null
    if ($Requested -and ($Requested -match '[\\/]' -or $Requested -like '*.psd1')) {
        $full = (Resolve-Path -LiteralPath $Requested).Path
        $dir = Split-Path -Parent $full
        $name = [System.IO.Path]::GetFileNameWithoutExtension($full)
    } elseif ($Requested) {
        $name = $Requested
    } else {
        $all = Get-IMProfileNames
        $names = @($all | Where-Object { $_ -ne 'base' })
        if ($names.Count -ne 1) { throw "Specify -Profile (available: $($names -join ', '))" }
        $name = $names[0]
    }
    $chain = New-Object System.Collections.ArrayList
    $data = Read-IMProfileData -Name $name -Dir $dir
    [void]$chain.Add($data)
    $seen = @($name)
    while ($data.Inherits) {
        $parent = [string]$data.Inherits
        if ($seen -contains $parent) { throw "Profile inheritance loop at '$parent'" }
        $seen += $parent
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir "$parent.psd1"))) { $data = Read-IMProfileData -Name $parent -Dir $dir }
        else { $data = Read-IMProfileData -Name $parent }
        [void]$chain.Insert(0, $data)
    }
    $merged = @{}
    foreach ($d in $chain) { $merged = Merge-IMHashtable $merged $d }
    $merged.Remove('Inherits')
    [pscustomobject]@{ Name = $name; Data = $merged }
}

function Get-IMRelaunchArgumentLine {
    param([System.Collections.IDictionary]$Bound, [string]$ScriptPath)
    $parts = New-Object System.Collections.ArrayList
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { [void]$parts.Add("-$k") }; continue }
        if ($v -is [bool]) { if ($v) { [void]$parts.Add("-$k") }; continue }
        if ($v -is [array]) { $s = (@($v) | ForEach-Object { "$_" }) -join ',' } else { $s = "$v" }
        if ($s.EndsWith('\')) { $s = $s + '\' }
        [void]$parts.Add("-$k")
        [void]$parts.Add('"' + $s + '"')
    }
    ('-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" {1}' -f $ScriptPath, ($parts -join ' ')).Trim()
}

function Test-IMSystemProtectionOn {
    try {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients'
        $v = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).'{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}'
        if (-not $v) { return $false }
        $tag = '(' + ($env:SystemDrive -replace ':', '%3A') + ')'
        foreach ($line in @($v)) { if ("$line".Contains($tag)) { return $true } }
        return $false
    } catch { return $null }
}

function Invoke-IMRestorePoint {
    # Order: enable protection, write the frequency value, create the restore point. $true = continue.
    param([string]$ProfileName, [bool]$Force)
    $pol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -ErrorAction SilentlyContinue
    if ($pol -and ($pol.DisableSR -eq 1 -or $pol.DisableConfig -eq 1)) {
        Write-Log 'System Restore is disabled by policy; no restore point can be created.' Fail
        return $Force
    }
    $drive = "$env:SystemDrive\"
    $wasOn = Test-IMSystemProtectionOn
    if ($wasOn -ne $true) {
        $st = Invoke-TrackedAction -Module 'Engine' -Kind 'system' -Key 'system-protection' -Description "enable System Protection on $drive" `
            -RestoreHint 'turn System Protection off in System Properties > System Protection if wanted' `
            -Capture { [pscustomobject]@{ Drive = $drive; WasOn = $wasOn } } `
            -Apply { param($old) Enable-ComputerRestore -Drive $drive -ErrorAction Stop }
        if ($st -eq 'Failed') { return $Force }
    }
    $st = Set-TrackedRegistryValue -Module 'Engine' -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' `
        -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord -Description 'allow a restore point without the 24 h limit'
    if ($st -eq 'Failed' -or $st -eq 'Skipped') { return $Force }
    $desc = "InstallMedia before $ProfileName"
    try {
        $before = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | ForEach-Object { $_.SequenceNumber } | Measure-Object -Maximum).Maximum
        Write-Log "Creating restore point '$desc' (can take a few minutes)..."
        Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
        $rp = Get-ComputerRestorePoint -ErrorAction Stop | Where-Object { $_.Description -eq $desc -and (-not $before -or $_.SequenceNumber -gt $before) } | Select-Object -Last 1
        if (-not $rp) { throw 'restore point not found after creation' }
        Write-Log "Restore point created (#$($rp.SequenceNumber))." Ok
        return $true
    } catch {
        Write-Log "Restore point failed: $($_.Exception.Message)" Fail
        return $Force
    }
}

function Write-IMSummary {
    param([object[]]$Results, [hashtable]$Context, [string]$RevertCommand)
    $head = if ($Context.WhatIf) { 'would change' } else { 'changed' }
    Write-Log ''
    Write-Log "Summary ($head / unchanged / skipped / failed):"
    foreach ($r in $Results) {
        $lvl = if ($r.Failed -gt 0) { 'Fail' } else { 'Ok' }
        $notes = if ($r.Notes.Count) { '  ' + (@($r.Notes) -join '; ') } else { '' }
        Write-Log ('  {0,-9} {1,3} / {2,3} / {3,3} / {4,3}{5}' -f $r.Module, $r.Changed, $r.Unchanged, $r.Skipped, $r.Failed, $notes) $lvl
    }
    if ($Context.WhatIf) { }
    elseif ($Context.NeedsSignOut) { Write-Log 'Sign out and back in (or restart) so dark mode applies everywhere.' Warn }
    elseif ($Context.NeedsExplorerRestart) { Write-Log 'Restart Explorer (or sign out) to apply: Stop-Process -Name explorer' Warn }
    if ($RevertCommand) { Write-Log "To revert: $RevertCommand" }
}

function Invoke-IMMain {
    $only = Split-IMList $Only
    $skip = Split-IMList $Skip
    $enable = Split-IMList $Enable
    $revertModules = $script:IMModules + 'Engine'
    if ($Revert) { $only = Resolve-IMNames $only $revertModules 'module' } else { $only = Resolve-IMNames $only $script:IMModules 'module' }
    $skip = Resolve-IMNames $skip $script:IMModules 'module'
    if ($Revert -and $AuditOnly) { throw '-Revert and -AuditOnly cannot be combined.' }

    $isAdmin = Test-IMIsAdmin
    $whatIf = [bool]$WhatIfPreference
    $user = Get-IMCurrentUser
    Write-Log "InstallMedia $InstallMediaVersion on $env:COMPUTERNAME; user $($user.Name) (SID $($user.Sid)); admin: $isAdmin; sandbox: $([bool]$Sandbox); WhatIf: $whatIf"

    # The elevated process must be the signed-in user, otherwise HKCU would be the wrong user's.
    $hkcuAllowed = $true
    $ia = Get-IMInteractiveUser
    $mismatch = $null
    if ($null -eq $ia) {
        if ($isAdmin) { $mismatch = 'cannot determine the signed-in desktop user' }
        else { Write-Log 'Could not determine the signed-in desktop user (not elevated: assuming it is this user).' Warn }
    } elseif ($ia.Sid -ne $user.Sid) {
        $mismatch = "signed-in desktop user is $($ia.Name) ($($ia.Sid))"
    } else {
        Write-Log "Signed-in desktop user matches: $($ia.Name)"
    }
    if ($mismatch) {
        if ($AuditOnly) { Write-Log "User check: $mismatch (audit is read-only, continuing)" Warn }
        elseif (-not $Force) {
            Write-Log "User check failed: $mismatch, but this process runs as $($user.Name). Per-user settings would go to the wrong account. Stopping." Fail
            return 2
        } else {
            Write-Log "User check failed: $mismatch. -Force: continuing with machine-wide (HKLM) work only." Warn
            $hkcuAllowed = $false
        }
    }

    $edition = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
    $ctx = @{
        OutputDir = $script:IMOutputDir; Enable = $enable; StressMinutes = $StressMinutes
        Sandbox = [bool]$Sandbox; WhatIf = $whatIf; Force = [bool]$Force; IsAdmin = $isAdmin; HkcuAllowed = $hkcuAllowed
        Edition = $edition; IsHome = ($edition -like 'Core*'); ProfileName = $null
        NeedsExplorerRestart = $false; NeedsSignOut = $false; AuditFailCount = 0
    }

    Initialize-Engine -Sandbox ([bool]$Sandbox) -WhatIf $whatIf -OutputDir $script:IMOutputDir -IsAdmin $isAdmin -HkcuAllowed $hkcuAllowed
    $scriptRef = '"' + $PSCommandPath + '"'
    $revertCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptRef -Revert" + $(if ($Sandbox) { ' -Sandbox' } else { '' })

    if ($Revert) {
        Write-Log ("Reverting " + $(if ($only.Count) { "modules: $($only -join ', ')" } else { 'all journal entries' }) + $(if ($Force) { ' (-Force)' } else { '' }))
        $sum = Invoke-Revert -Module $only -Force:$Force
        Write-Log ''
        Write-Log ("Revert summary: reverted {0}, skipped {1}, failed {2}, not revertible {3}{4}" -f $sum.Reverted, $sum.Skipped, $sum.Failed, $sum.NotRevertible, $(if ($whatIf) { ", would revert $($sum.Planned)" } else { '' })) $(if ($sum.Failed) { 'Fail' } else { 'Ok' })
        if ($sum.Modules.ContainsKey('Search') -or $sum.Modules.ContainsKey('Display')) { Write-Log 'Restart Explorer or sign out so the restored settings apply.' Warn }
        if (-not $whatIf) { [void](Copy-EngineJournal -Destination (Join-Path $script:IMOutputDir 'journal.json')) }
        if ($sum.Failed) { return 1 }
        return 0
    }

    $p = Resolve-IMProfile $Profile
    $prof = $p.Data
    $ctx.ProfileName = $p.Name
    Write-Log "Profile: $($p.Name) - $($prof.Description)"
    $optional = @()
    if ($prof.Optional) { $optional = @($prof.Optional.Keys) }
    $ctx.Enable = Resolve-IMNames $enable $optional 'option'
    foreach ($e in $ctx.Enable) { Write-Log "Enabled option: $e - $($prof.Optional[$e])" }

    if ($AuditOnly) { $mods = @('Audit') }
    else {
        $mods = @($script:IMModules | Where-Object { $skip -notcontains $_ })
        if ($only.Count) { $mods = @($mods | Where-Object { $only -contains $_ }) }
        $wantStress = ($StressMinutes -gt 0) -or ($only -contains 'Stress')
        if (-not $wantStress) { $mods = @($mods | Where-Object { $_ -ne 'Stress' }) }
    }
    Write-Log "Modules: $($mods -join ', ')"

    $results = New-Object System.Collections.ArrayList
    $restoreDone = $false
    foreach ($m in $mods) {
        if (-not $restoreDone -and ($script:IMChangingModules -contains $m) -and -not $Sandbox -and -not $whatIf) {
            $restoreDone = $true
            if (-not (Invoke-IMRestorePoint -ProfileName $p.Name -Force ([bool]$Force))) {
                Write-Log 'Stopping before any change because no restore point exists (use -Force to continue without one).' Fail
                Write-IMSummary -Results $results -Context $ctx -RevertCommand $revertCmd
                [void](Copy-EngineJournal -Destination (Join-Path $script:IMOutputDir 'journal.json'))
                return 1
            }
        }
        Write-Log ''
        Write-Log "=== $m ==="
        try {
            $r = & "Invoke-${m}Module" -Profile $prof -Context $ctx
        } catch {
            Write-Log "$m module failed: $($_.Exception.Message)" Fail
            Write-Log ($_.ScriptStackTrace -replace "`r?`n", ' | ')
            $r = New-ModuleResult $m
            Add-ModuleResultStatus $r 'Failed' $_.Exception.Message
        }
        [void]$results.Add($r)
    }

    $ranChanging = @($mods | Where-Object { $script:IMChangingModules -contains $_ }).Count -gt 0
    $journalChanged = $ranChanging -and -not $whatIf
    Write-IMSummary -Results $results -Context $ctx -RevertCommand $(if ($journalChanged) { $revertCmd } else { $null })
    if ($journalChanged) { [void](Copy-EngineJournal -Destination (Join-Path $script:IMOutputDir 'journal.json')) }
    Write-Log "Output folder: $script:IMOutputDir"
    if (@($results | Where-Object { $_.Failed -gt 0 }).Count) { return 1 }
    return 0
}

# ---------------------------------------------------------------- entry
if (-not (Test-IMIsAdmin) -and -not $Sandbox -and -not $NoElevate) {
    $argLine = Get-IMRelaunchArgumentLine -Bound $PSBoundParameters -ScriptPath $PSCommandPath
    Write-Host 'Not elevated: relaunching as administrator (approve the UAC prompt)...'
    try {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argLine -Verb RunAs
        exit 0
    } catch {
        Write-Host "Elevation failed or was cancelled: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
$script:IMOutputDir = Join-Path $desktop ('InstallMedia\{0}-{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
[void][System.IO.Directory]::CreateDirectory($script:IMOutputDir)
$transcribing = $false
try { Start-Transcript -LiteralPath (Join-Path $script:IMOutputDir 'transcript.txt') -WhatIf:$false | Out-Null; $transcribing = $true } catch { Write-Host "Transcript not started: $($_.Exception.Message)" }
$code = 1
try {
    $code = Invoke-IMMain | Select-Object -Last 1
} catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" Fail
    Write-Log ($_.ScriptStackTrace -replace "`r?`n", ' | ')
    $code = 1
} finally {
    if ($transcribing) { try { Stop-Transcript | Out-Null } catch { } }
}
exit $code
#endregion IM-MAIN
