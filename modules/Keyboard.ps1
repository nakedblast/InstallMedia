# Keyboard: ensure input layouts through a tracked 'language' action.
# The plan builder (Get-KeyboardLanguagePlan) is a pure function so it can be unit tested.

function Get-IMLangIdForTag {
    # 'en-US' -> '0409', 'ru' -> '0419' (neutral tags resolve to their specific culture).
    param([string]$Tag)
    try {
        $c = [Globalization.CultureInfo]::GetCultureInfo($Tag)
        if ($c.IsNeutralCulture) { $c = [Globalization.CultureInfo]::CreateSpecificCulture($Tag) }
        if ($c.LCID -eq 4096 -or $c.LCID -eq 127) { return $null }
        return ('{0:X4}' -f $c.LCID)
    } catch { return $null }
}

function Test-IMLanguageListEqual {
    param([object[]]$A, [object[]]$B)
    $A = @($A); $B = @($B)
    if ($A.Count -ne $B.Count) { return $false }
    for ($i = 0; $i -lt $A.Count; $i++) {
        if ([string]$A[$i].Tag -ne [string]$B[$i].Tag) { return $false }
        $ta = @($A[$i].Tips); $tb = @($B[$i].Tips)
        if ($ta.Count -ne $tb.Count) { return $false }
        for ($j = 0; $j -lt $ta.Count; $j++) { if ([string]$ta[$j] -ne [string]$tb[$j]) { return $false } }
    }
    return $true
}

function Format-IMLanguageList {
    param([object[]]$List)
    (@($List) | ForEach-Object { '{0} [{1}]' -f $_.Tag, (@($_.Tips) -join ', ') }) -join '; '
}

function Get-KeyboardLanguagePlan {
    # Pure: builds the new language list from the current one.
    #  - keeps every existing language and its tips, in order (the first/display language never moves)
    #  - adds missing Ensure tips under the language whose LANGID matches (adds the language if absent)
    #  - removes Remove tips, but never leaves a language with zero tips: such a language is dropped,
    #    unless it is the first (display) language, in which case the tip is kept
    param(
        [object[]]$Current,
        [string[]]$Ensure = @(),
        [string[]]$Remove = @(),
        [string[]]$LanguageOrder = @(),
        [scriptblock]$IsTipAvailable
    )
    $notes = New-Object System.Collections.ArrayList
    $plan = New-Object System.Collections.ArrayList
    foreach ($l in @($Current)) {
        $tips = New-Object System.Collections.ArrayList
        foreach ($t in @($l.Tips)) { if ($t) { [void]$tips.Add([string]$t) } }
        [void]$plan.Add([pscustomobject]@{ Tag = [string]$l.Tag; Tips = $tips })
    }
    foreach ($tip in @($Ensure)) {
        $present = $false
        foreach ($p in $plan) { if ($p.Tips -contains $tip) { $present = $true; break } }
        if ($present) { continue }
        if ($IsTipAvailable -and -not (& $IsTipAvailable $tip)) {
            [void]$notes.Add("skipped $tip : layout not installed (would need a download)")
            continue
        }
        $langId = ($tip -split ':')[0].ToUpperInvariant()
        $target = $null
        foreach ($p in $plan) { if ((Get-IMLangIdForTag $p.Tag) -eq $langId) { $target = $p; break } }
        if (-not $target) {
            $tag = $null
            foreach ($t in @($LanguageOrder)) { if ((Get-IMLangIdForTag $t) -eq $langId) { $tag = $t; break } }
            if (-not $tag) { [void]$notes.Add("skipped $tip : no language in LanguageOrder matches LANGID $langId"); continue }
            $target = [pscustomobject]@{ Tag = $tag; Tips = (New-Object System.Collections.ArrayList) }
            [void]$plan.Add($target)
            [void]$notes.Add("add language $tag")
        }
        [void]$target.Tips.Add($tip)
        [void]$notes.Add("add layout $tip to $($target.Tag)")
    }
    $drop = New-Object System.Collections.ArrayList
    foreach ($tip in @($Remove)) {
        for ($i = 0; $i -lt $plan.Count; $i++) {
            $p = $plan[$i]
            if (-not ($p.Tips -contains $tip)) { continue }
            $rest = @($p.Tips | Where-Object { $_ -ne $tip })
            if ($rest.Count -eq 0) {
                if ($i -eq 0) { [void]$notes.Add("kept $tip : it is the only layout of the first (display) language $($p.Tag)"); continue }
                [void]$drop.Add($p)
                [void]$notes.Add("remove language $($p.Tag) (its only layout $tip is removed)")
                continue
            }
            $p.Tips.Clear()
            foreach ($t in $rest) { [void]$p.Tips.Add($t) }
            [void]$notes.Add("remove layout $tip from $($p.Tag)")
        }
    }
    foreach ($d in $drop) { $plan.Remove($d) }
    $result = @($plan | ForEach-Object { [pscustomobject]@{ Tag = $_.Tag; Tips = [string[]]@($_.Tips) } })
    $currentNorm = @(@($Current) | ForEach-Object { [pscustomobject]@{ Tag = [string]$_.Tag; Tips = [string[]]@($_.Tips | Where-Object { $_ }) } })
    [pscustomobject]@{
        Plan    = $result
        Notes   = @($notes)
        Changed = -not (Test-IMLanguageListEqual $currentNorm $result)
    }
}

function Test-IMKeyboardTipAvailable {
    # Built-in keyboard layout DLL present for 'LANGID:KLID' tips; other tip kinds count as unavailable.
    param([string]$Tip)
    if ($Tip -notmatch '^[0-9A-Fa-f]{4}:([0-9A-Fa-f]{8})$') { return $false }
    $klid = $Matches[1]
    try {
        $p = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\$klid" -ErrorAction Stop
        $file = $p.'Layout File'
        if (-not $file) { return $false }
        return (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$file"))
    } catch { return $false }
}

function Get-IMLanguageState {
    # The cmdlet writes the whole list as one pipeline object: enumerate it explicitly.
    $list = Get-WinUserLanguageList
    $langs = @(foreach ($l in $list) { [pscustomobject]@{ Tag = [string]$l.LanguageTag; Tips = [string[]]@($l.InputMethodTips) } })
    [pscustomobject]@{ Languages = $langs }
}

function Set-IMLanguagePlan {
    # Applies a list of @{Tag; Tips} in order, reusing existing language objects (keeps their other
    # settings), then re-reads the list and throws on any mismatch.
    param([object[]]$Plan)
    $Plan = @($Plan)
    if ($Plan.Count -eq 0) { throw 'Refusing to set an empty language list.' }
    $current = Get-WinUserLanguageList
    $byTag = @{}
    foreach ($l in $current) { $byTag[$l.LanguageTag.ToLowerInvariant()] = $l }
    $target = Get-WinUserLanguageList
    $target.Clear()
    foreach ($p in $Plan) {
        $k = ([string]$p.Tag).ToLowerInvariant()
        if ($byTag.ContainsKey($k)) { $lang = $byTag[$k] }
        else { $lang = (New-WinUserLanguageList -Language ([string]$p.Tag))[0] }
        $lang.InputMethodTips.Clear()
        foreach ($t in @($p.Tips)) { $lang.InputMethodTips.Add([string]$t) }
        $target.Add($lang)
    }
    $expected = @($target | ForEach-Object { [pscustomobject]@{ Tag = [string]$_.LanguageTag; Tips = [string[]]@($_.InputMethodTips) } })
    Set-WinUserLanguageList -LanguageList $target -Force
    $actual = (Get-IMLanguageState).Languages
    if (-not (Test-IMLanguageListEqual $expected $actual)) {
        throw ("Language list mismatch after change. Expected: {0}. Actual: {1}" -f (Format-IMLanguageList $expected), (Format-IMLanguageList $actual))
    }
}

Register-TrackedActionHandler -Kind 'language' -Capture { Get-IMLanguageState } -Restore {
    param($old)
    # Restores the captured languages, tip sets and order; languages absent at capture are removed.
    Set-IMLanguagePlan -Plan @($old.Languages)
}

function Invoke-KeyboardModule {
    param([hashtable]$Profile, [hashtable]$Context)
    $res = New-ModuleResult 'Keyboard'
    $kb = $Profile.Keyboard
    if (-not $kb) { Add-ModuleResultStatus $res 'Skipped' 'no Keyboard section in profile'; return $res }
    if (-not $Context.HkcuAllowed) { Write-Log 'Keyboard skipped: per-user changes are blocked for this process' Warn; Add-ModuleResultStatus $res 'Skipped'; return $res }
    $state = Get-IMLanguageState
    Write-Log "Current input languages: $(Format-IMLanguageList $state.Languages)"
    $avail = { param($t) Test-IMKeyboardTipAvailable $t }
    $p = Get-KeyboardLanguagePlan -Current $state.Languages -Ensure @($kb.Ensure) -Remove @($kb.Remove) -LanguageOrder @($kb.LanguageOrder) -IsTipAvailable $avail
    foreach ($n in $p.Notes) {
        $lvl = if ($n -like 'skipped*' -or $n -like 'kept*') { 'Warn' } else { 'Info' }
        Write-Log "Keyboard plan: $n" $lvl
        if ($lvl -eq 'Warn') { [void]$res.Notes.Add($n) }
    }
    if (-not $p.Changed) {
        Write-Log 'Keyboard layouts already as required.' Ok
        Add-ModuleResultStatus $res 'Unchanged'
        return $res
    }
    $plan = $p.Plan
    $status = Invoke-TrackedAction -Module 'Keyboard' -Kind 'language' -Key 'user-language-list' `
        -Description ("set input languages to: " + (Format-IMLanguageList $plan)) `
        -Capture { Get-IMLanguageState } `
        -Apply { param($old) Set-IMLanguagePlan -Plan $plan } `
        -Restore { param($old) Set-IMLanguagePlan -Plan @($old.Languages) }
    Add-ModuleResultStatus $res $status
    if ($status -eq 'Changed' -and -not $Context.Sandbox) {
        Write-Log "Input languages now: $(Format-IMLanguageList (Get-IMLanguageState).Languages)" Ok
    }
    Write-Log 'Switch layouts with Win+Space.'
    return $res
}
