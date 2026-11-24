# Bloat: list candidates, ask which to remove, remove only the chosen items.
# Matching and answer parsing are pure functions so they can be unit tested.

function Test-IMWildcard { param([string]$Pattern) return ($Pattern -match '[\*\?\[]') }

function Test-IMMatchAny {
    param([string[]]$Values, [string[]]$Patterns)
    foreach ($p in @($Patterns)) {
        if (-not $p) { continue }
        foreach ($v in @($Values)) { if ($v -and $v -like $p) { return $true } }
    }
    return $false
}

function Get-BloatCandidates {
    # Appx: listed by Name; Protect (Name or Publisher) wins, except that an exact (non-wildcard)
    # Appx list entry equal to the package name beats a Protect wildcard.
    # Win32: listed by DisplayName; Protect (DisplayName or Publisher) always wins.
    param([hashtable]$Bloat, [object[]]$Appx = @(), [object[]]$Win32 = @())
    $out = New-Object System.Collections.ArrayList
    $appxPatterns = @($Bloat.Appx | Where-Object { $_ })
    $win32Patterns = @($Bloat.Win32 | Where-Object { $_ })
    $protect = @($Bloat.Protect | Where-Object { $_ })
    foreach ($a in @($Appx)) {
        if (-not $a) { continue }
        if (-not (Test-IMMatchAny @($a.Name) $appxPatterns)) { continue }
        $exact = @($appxPatterns | Where-Object { -not (Test-IMWildcard $_) -and $_ -eq $a.Name }).Count -gt 0
        if (-not $exact -and (Test-IMMatchAny @($a.Name, $a.Publisher) $protect)) { continue }
        [void]$out.Add([pscustomobject]@{
                Kind = 'appx'; Name = [string]$a.Name; Publisher = [string]$a.Publisher; Size = ''
                Id = [string]$a.PackageFullName; Version = [string]$a.Version; Uninstall = $null; QuietUninstall = $null; RegistryKey = $null
            })
    }
    foreach ($w in @($Win32)) {
        if (-not $w) { continue }
        if (-not (Test-IMMatchAny @($w.DisplayName) $win32Patterns)) { continue }
        if (Test-IMMatchAny @($w.DisplayName, $w.Publisher) $protect) { continue }
        $size = if ($w.EstimatedSize) { '{0:N0} MB' -f ([double]$w.EstimatedSize / 1024) } else { '' }
        [void]$out.Add([pscustomobject]@{
                Kind = 'win32'; Name = [string]$w.DisplayName; Publisher = [string]$w.Publisher; Size = $size
                Id = [string]$w.RegistryKey; Version = [string]$w.DisplayVersion
                Uninstall = [string]$w.UninstallString; QuietUninstall = [string]$w.QuietUninstallString; RegistryKey = [string]$w.RegistryKey
            })
    }
    , @($out)
}

function ConvertFrom-BloatSelection {
    # '' -> none; 'all' -> every item; '1,3 5' -> those items. Throws on anything else.
    param([AllowEmptyString()][string]$Answer, [int]$Count)
    $a = "$Answer".Trim()
    if (-not $a) { return , @() }
    if ($a -ieq 'all') { return , @(1..$Count) }
    $nums = New-Object System.Collections.ArrayList
    foreach ($part in ($a -split '[,\s]+' | Where-Object { $_ })) {
        if ($part -notmatch '^\d+$') { throw "Not a number: '$part'" }
        $n = [int]$part
        if ($n -lt 1 -or $n -gt $Count) { throw "Out of range: $n (1-$Count)" }
        if (-not $nums.Contains($n)) { [void]$nums.Add($n) }
    }
    , @($nums)
}

function Get-IMInstalledWin32 {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $list = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or -not $p.DisplayName) { continue }
            if ($p.SystemComponent -eq 1) { continue }
            [void]$list.Add([pscustomobject]@{
                    DisplayName = [string]$p.DisplayName; Publisher = [string]$p.Publisher; DisplayVersion = [string]$p.DisplayVersion
                    EstimatedSize = $p.EstimatedSize; UninstallString = [string]$p.UninstallString
                    QuietUninstallString = [string]$p.QuietUninstallString; RegistryKey = [string]$k.PSPath
                })
        }
    }
    , @($list)
}

function Remove-IMBloatItem {
    param($Item)
    if ($Item.Kind -eq 'appx') {
        $full = $Item.Id
        $status = Invoke-TrackedAction -Module 'Bloat' -Kind 'appx' -Key $full -Description "remove Appx $($Item.Name) ($full) for the current user" `
            -RestoreHint 'reinstall from Microsoft Store, or use the restore point' `
            -Capture { [pscustomobject]@{ Name = $Item.Name; PackageFullName = $full; Version = $Item.Version; Publisher = $Item.Publisher } } `
            -Apply { param($old) Remove-AppxPackage -Package $full -ErrorAction Stop }
        if ($status -eq 'Changed' -and @(Get-AppxPackage -Name $Item.Name -ErrorAction SilentlyContinue).Count -gt 0) {
            Write-Log "$($Item.Name) is still installed after removal" Warn
            return 'Failed'
        }
        return $status
    }
    $cmd = if ($Item.QuietUninstall) { $Item.QuietUninstall } else { $Item.Uninstall }
    if (-not $cmd) { Write-Log "No uninstall command for $($Item.Name)" Warn; return 'Skipped' }
    $status = Invoke-TrackedAction -Module 'Bloat' -Kind 'win32' -Key $Item.RegistryKey -Description "uninstall $($Item.Name) $($Item.Version)" `
        -RestoreHint 'reinstall from the vendor, or use the restore point' `
        -Capture { [pscustomobject]@{ Name = $Item.Name; Version = $Item.Version; Publisher = $Item.Publisher; RegistryKey = $Item.RegistryKey; Command = $cmd } } `
        -Apply {
        param($old)
        Write-Log "Running: $cmd"
        $p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList ('/d /s /c "' + $cmd + '"') -Wait -PassThru
        Write-Log "Uninstaller exit code $($p.ExitCode)"
    }
    if ($status -eq 'Changed' -and (Test-Path -LiteralPath $Item.RegistryKey)) {
        Write-Log "$($Item.Name) is still listed as installed (its uninstaller may still be running or need a restart)" Warn
        return 'Failed'
    }
    return $status
}

function Invoke-BloatModule {
    param([hashtable]$Profile, [hashtable]$Context)
    $res = New-ModuleResult 'Bloat'
    if (-not $Profile.Bloat) { Add-ModuleResultStatus $res 'Skipped' 'no Bloat section in profile'; return $res }
    # Appx removal is per user: never act for a process user other than the signed-in one.
    $appx = if ($Context.HkcuAllowed) { @(Get-AppxPackage -ErrorAction SilentlyContinue) } else { @() }
    if (-not $Context.HkcuAllowed) { Write-Log 'Store apps are not listed: per-user changes are blocked for this process.' Warn }
    $win32 = Get-IMInstalledWin32
    $cands = Get-BloatCandidates -Bloat $Profile.Bloat -Appx $appx -Win32 $win32
    if ($cands.Count -eq 0) {
        Write-Log 'No removal candidates found.' Ok
        Add-ModuleResultStatus $res 'Unchanged'
        return $res
    }
    Write-Log "Removal candidates ($($cands.Count)):"
    $i = 0
    foreach ($c in $cands) {
        $i++
        $extra = @($c.Publisher, $c.Size) | Where-Object { $_ }
        Write-Log ('  {0,2}. [{1}] {2}  {3}' -f $i, $c.Kind, $c.Name, ($extra -join ', '))
    }
    if ($Context.WhatIf -or $Context.Sandbox) {
        Write-Log 'Listing only (WhatIf/Sandbox): nothing is removed.'
        $res.Skipped += $cands.Count
        return $res
    }
    $sel = $null
    for ($try = 1; $try -le 3 -and $null -eq $sel; $try++) {
        $ans = Read-Host 'Numbers to remove (e.g. 1,3,5), "all", or Enter for none'
        try { $sel = ConvertFrom-BloatSelection -Answer $ans -Count $cands.Count }
        catch { Write-Log $_.Exception.Message Warn }
    }
    if ($null -eq $sel -or $sel.Count -eq 0) {
        Write-Log 'Nothing selected; nothing removed.'
        $res.Skipped += $cands.Count
        return $res
    }
    $chosen = @($sel | ForEach-Object { $cands[$_ - 1] })
    Write-Log 'Selected for removal:'
    foreach ($c in $chosen) { Write-Log "  - [$($c.Kind)] $($c.Name)" }
    $ok = Read-Host "Remove these $($chosen.Count) item(s)? Type y to confirm"
    if ($ok -notmatch '^(y|yes)$') {
        Write-Log 'Not confirmed; nothing removed.'
        $res.Skipped += $cands.Count
        return $res
    }
    $res.Skipped += ($cands.Count - $chosen.Count)
    foreach ($c in $chosen) {
        try { $st = Remove-IMBloatItem $c }
        catch { Write-Log "Removing $($c.Name) failed: $($_.Exception.Message)" Fail; $st = 'Failed' }
        Add-ModuleResultStatus $res $st
    }
    return $res
}
