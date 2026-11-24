# Display: power timeouts (tracked 'power' action), optional dark mode and taskbar auto-hide (tracked registry).

function ConvertFrom-IMPowercfgQuery {
    # Locale-independent: the last two lines ending in a hex value are the AC and DC indexes.
    param([string[]]$Lines)
    $hex = @(foreach ($line in @($Lines)) { if ("$line" -match '(0x[0-9a-fA-F]+)\s*$') { $Matches[1] } })
    if ($hex.Count -lt 2) { throw 'powercfg output has no AC/DC index lines' }
    [pscustomobject]@{ Ac = [Convert]::ToInt64($hex[$hex.Count - 2], 16); Dc = [Convert]::ToInt64($hex[$hex.Count - 1], 16) }
}

function Get-IMActiveSchemeGuid {
    $r = Invoke-IMNative 'powercfg.exe' @('/getactivescheme')
    $text = $r.Output -join ' '
    if ($text -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1].ToLowerInvariant() }
    throw "Cannot read the active power scheme (exit $($r.ExitCode)): $text"
}

function Get-IMPowerTimeouts {
    $guid = Get-IMActiveSchemeGuid
    $v = Invoke-IMNative 'powercfg.exe' @('/q', $guid, 'SUB_VIDEO', 'VIDEOIDLE')
    if ($v.ExitCode -ne 0) { throw "powercfg /q SUB_VIDEO VIDEOIDLE failed (exit $($v.ExitCode))" }
    $s = Invoke-IMNative 'powercfg.exe' @('/q', $guid, 'SUB_SLEEP', 'STANDBYIDLE')
    if ($s.ExitCode -ne 0) { throw "powercfg /q SUB_SLEEP STANDBYIDLE failed (exit $($s.ExitCode))" }
    $vi = ConvertFrom-IMPowercfgQuery $v.Output
    $si = ConvertFrom-IMPowercfgQuery $s.Output
    [pscustomobject]@{ Scheme = $guid; VideoAc = $vi.Ac; VideoDc = $vi.Dc; SleepAc = $si.Ac; SleepDc = $si.Dc }
}

function Set-IMPowerTimeouts {
    # Seconds; applied to the recorded scheme GUID, then that scheme is re-activated.
    param([Parameter(Mandatory = $true)]$State)
    $g = [string]$State.Scheme
    $cmds = @(
        @('/setacvalueindex', $g, 'SUB_VIDEO', 'VIDEOIDLE', [string][int64]$State.VideoAc),
        @('/setdcvalueindex', $g, 'SUB_VIDEO', 'VIDEOIDLE', [string][int64]$State.VideoDc),
        @('/setacvalueindex', $g, 'SUB_SLEEP', 'STANDBYIDLE', [string][int64]$State.SleepAc),
        @('/setdcvalueindex', $g, 'SUB_SLEEP', 'STANDBYIDLE', [string][int64]$State.SleepDc),
        @('/setactive', $g)
    )
    foreach ($c in $cmds) {
        $r = Invoke-IMNative 'powercfg.exe' $c
        if ($r.ExitCode -ne 0) { throw "powercfg $($c -join ' ') failed (exit $($r.ExitCode)): $($r.Output -join ' ')" }
    }
}

Register-TrackedActionHandler -Kind 'power' -Capture { Get-IMPowerTimeouts } -Restore { param($old) Set-IMPowerTimeouts -State $old }

function Get-IMAutoHideBlob {
    # StuckRects3\Settings: byte index 8 (zero-based) is 0x02 (always show) or 0x03 (auto-hide).
    param([byte[]]$Blob)
    if ($null -eq $Blob -or $Blob.Length -lt 9) { return [pscustomobject]@{ Status = 'Invalid'; Blob = $null; Reason = 'value absent or shorter than 9 bytes' } }
    if ($Blob[8] -eq 0x03) { return [pscustomobject]@{ Status = 'Already'; Blob = $Blob; Reason = 'auto-hide already on' } }
    if ($Blob[8] -ne 0x02) { return [pscustomobject]@{ Status = 'Invalid'; Blob = $null; Reason = ('byte 8 is 0x{0:x2}, expected 0x02 or 0x03' -f $Blob[8]) } }
    $copy = New-Object byte[] $Blob.Length
    [Array]::Copy($Blob, $copy, $Blob.Length)
    $copy[8] = 0x03
    return [pscustomobject]@{ Status = 'Ok'; Blob = $copy; Reason = '' }
}

function Invoke-DisplayModule {
    param([hashtable]$Profile, [hashtable]$Context)
    $res = New-ModuleResult 'Display'
    $enable = @($Context.Enable)

    # Power timeouts
    $pw = $Profile.Power
    if ($pw) {
        $want = [pscustomobject]@{
            VideoAc = [int64]$pw.MonitorAcMin * 60; VideoDc = [int64]$pw.MonitorDcMin * 60
            SleepAc = [int64]$pw.SleepAcMin * 60; SleepDc = [int64]$pw.SleepDcMin * 60
        }
        try {
            $cur = Get-IMPowerTimeouts
            Write-Log ('Power (seconds) now: display AC {0} / DC {1}, sleep AC {2} / DC {3} (scheme {4})' -f $cur.VideoAc, $cur.VideoDc, $cur.SleepAc, $cur.SleepDc, $cur.Scheme)
            $status = Invoke-TrackedAction -Module 'Display' -Kind 'power' -Key 'power-timeouts' `
                -Description ('set power timeouts: display AC {0} / DC {1} min, sleep AC {2} / DC {3} min' -f $pw.MonitorAcMin, $pw.MonitorDcMin, $pw.SleepAcMin, $pw.SleepDcMin) `
                -Capture { Get-IMPowerTimeouts } `
                -Test { param($old) $old.VideoAc -eq $want.VideoAc -and $old.VideoDc -eq $want.VideoDc -and $old.SleepAc -eq $want.SleepAc -and $old.SleepDc -eq $want.SleepDc } `
                -Apply { param($old) Set-IMPowerTimeouts -State ([pscustomobject]@{ Scheme = $old.Scheme; VideoAc = $want.VideoAc; VideoDc = $want.VideoDc; SleepAc = $want.SleepAc; SleepDc = $want.SleepDc }) } `
                -Restore { param($old) Set-IMPowerTimeouts -State $old }
            Add-ModuleResultStatus $res $status
        } catch {
            Write-Log "Power timeouts skipped: $($_.Exception.Message)" Warn
            Add-ModuleResultStatus $res 'Skipped' "power timeouts: $($_.Exception.Message)"
        }
    } else {
        Add-ModuleResultStatus $res 'Skipped' 'no Power section in profile'
    }

    # Optional: dark mode
    if ($enable -contains 'DarkMode') {
        $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        foreach ($n in 'AppsUseLightTheme', 'SystemUsesLightTheme') {
            $st = Set-TrackedRegistryValue -Module 'Display' -Path $p -Name $n -Value 0 -Type DWord -Description 'Dark mode (opt-in)'
            Add-ModuleResultStatus $res $st
            if ($st -eq 'Changed') { $Context.NeedsSignOut = $true }
        }
    }

    # Optional: taskbar auto-hide
    if ($enable -contains 'AutoHideTaskbar') {
        $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
        $st = Read-IMRegistryValue -Path $p -Name 'Settings' -FallbackToReal
        $blob = $null
        if ($st.ValueExists -and $st.Type -eq 'Binary') { $blob = [byte[]]$st.Value }
        $ah = Get-IMAutoHideBlob $blob
        if ($ah.Status -eq 'Invalid') {
            Write-Log "Taskbar auto-hide skipped: $($ah.Reason)" Warn
            Add-ModuleResultStatus $res 'Skipped' "auto-hide: $($ah.Reason)"
        } else {
            # 'Already' also goes through the engine: it reports Unchanged, or writes the sandbox copy.
            $s2 = Set-TrackedRegistryValue -Module 'Display' -Path $p -Name 'Settings' -Value $ah.Blob -Type Binary -Description 'Taskbar auto-hide (opt-in)'
            Add-ModuleResultStatus $res $s2
            if ($s2 -eq 'Changed') { $Context.NeedsExplorerRestart = $true }
        }
    }
    return $res
}
