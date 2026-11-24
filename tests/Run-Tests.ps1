<#
.SYNOPSIS
    Engine and pure-function tests. Writes only under HKCU:\Software\InstallMedia-Test (sandbox)
    and %TEMP%; removes both at the end. Run non-elevated in Windows PowerShell 5.1:
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Engine.psm1') -Force -DisableNameChecking
foreach ($m in 'Keyboard', 'Display', 'Bloat') { . (Join-Path $root "modules\$m.ps1") }

$script:Passed = 0
$script:Failed = 0
$script:Current = ''
function Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:Passed++; Write-Host "  pass  $Message" -ForegroundColor Green }
    else { $script:Failed++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ''
    Write-Host "== $Name" -ForegroundColor Cyan
    try { & $Body } catch {
        $script:Failed++
        Write-Host "  FAIL  unhandled: $($_.Exception.Message) $($_.ScriptStackTrace)" -ForegroundColor Red
    }
}

$SandboxKey = 'HKCU:\Software\InstallMedia-Test'
$Raw = 'HKCU:\Software\InstallMedia-Test\HKCU\Software\IMTest'
$TmpDir = Join-Path $env:TEMP "InstallMedia-Tests-$PID"
$JournalPath = Join-Path $TmpDir 'journal.json'

function Reset-Sandbox {
    if (Test-Path -LiteralPath $SandboxKey) { Remove-Item -LiteralPath $SandboxKey -Recurse -Force }
    if (Test-Path -LiteralPath $JournalPath) { Remove-Item -LiteralPath $JournalPath -Force }
}
function Start-TestEngine {
    param([bool]$WhatIf = $false, [bool]$HkcuAllowed = $true)
    Initialize-Engine -Sandbox $true -WhatIf $WhatIf -OutputDir $TmpDir -JournalPath $JournalPath -IsAdmin $false -HkcuAllowed $HkcuAllowed 6>$null
}
function Get-RawValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $k = Get-Item -LiteralPath $Path
    if (-not (@($k.GetValueNames()) -contains $Name)) { return $null }
    [pscustomobject]@{ Kind = $k.GetValueKind($Name).ToString(); Value = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') }
}
function Set-RawValue {
    param([string]$Path, [string]$Name, $Value, [string]$Kind)
    if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -Path $Path -Force) }
    [void](New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force)
}
function Get-Journal { $j = Get-EngineJournal; , $j }
function Test-SameArray($a, $b) {
    $a = @($a); $b = @($b)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) { if ("$($a[$i])" -cne "$($b[$i])") { return $false } }
    return $true
}

# Real-registry guard: the tests must never touch these.
$guard = @(
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Search', 'BingSearchEnabled'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize', 'AppsUseLightTheme'),
    @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3', 'Settings')
)
function Get-GuardSnapshot { ($guard | ForEach-Object { $v = Get-RawValue $_[0] $_[1]; if ($v) { "$($v.Kind):" + (@($v.Value) -join ',') } else { '<absent>' } }) -join '|' }
$guardBefore = Get-GuardSnapshot

[void][System.IO.Directory]::CreateDirectory($TmpDir)
Reset-Sandbox

Test-Case 'New value: revert deletes it and the keys it created' {
    Reset-Sandbox; Start-TestEngine
    $s = Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\New\Deep' -Name 'V' -Value 5 -Type DWord 6>$null
    Assert ($s -eq 'Changed') "set returns Changed ($s)"
    $v = Get-RawValue "$Raw\New\Deep" 'V'
    Assert ($v -and $v.Kind -eq 'DWord' -and $v.Value -eq 5) 'value written under the sandbox'
    $e = (Get-Journal)[0]
    Assert ($e.ExistedBefore -eq $false -and $e.KeyExistedBefore -eq $false) 'journal: ExistedBefore/KeyExistedBefore false'
    Assert (@($e.CreatedKeys) -contains 'HKCU:\Software\IMTest\New\Deep') 'journal lists created keys'
    Assert ($e.UserSid -eq (Get-IMCurrentUser).Sid) 'journal entry carries the user SID'
    $s2 = Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\New\Deep' -Name 'V' -Value 5 -Type DWord 6>$null
    Assert ($s2 -eq 'Unchanged') 'setting the same value again returns Unchanged'
    $r = Invoke-Revert 6>$null
    Assert ($r.Reverted -eq 1) 'one entry reverted'
    Assert (-not (Test-Path -LiteralPath "$Raw")) 'created keys removed'
    Assert (-not (Test-Path -LiteralPath $SandboxKey)) 'sandbox root removed when empty'
    Assert ((Get-Journal).Count -eq 0) 'journal empty after revert'
}

Test-Case 'Partial revert hands created keys to the remaining entries' {
    Reset-Sandbox; Start-TestEngine
    [void](Set-TrackedRegistryValue -Module X -Path 'HKCU:\Software\IMTest\P' -Name 'a' -Value 1 -Type DWord 6>$null)
    [void](Set-TrackedRegistryValue -Module Y -Path 'HKCU:\Software\IMTest\P\Q' -Name 'b' -Value 1 -Type DWord 6>$null)
    $r = Invoke-Revert -Module X 6>$null
    Assert ($r.Reverted -eq 1 -and (Test-Path -LiteralPath "$Raw\P\Q")) 'module X reverted, Y value still there'
    Start-TestEngine
    $r = Invoke-Revert -Module Y 6>$null
    Assert ($r.Reverted -eq 1) 'module Y reverted'
    Assert (-not (Test-Path -LiteralPath $SandboxKey)) 'every key the engine created is gone after both partial reverts'
}

Test-Case 'Existing value: revert restores original value and type; pre-existing key kept' {
    Reset-Sandbox
    Set-RawValue "$Raw\Exist" 'S' 'hello' 'String'
    Start-TestEngine
    $s = Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Exist' -Name 'S' -Value 7 -Type DWord 6>$null
    Assert ($s -eq 'Changed') 'set over a String with a DWord'
    Assert ((Get-RawValue "$Raw\Exist" 'S').Kind -eq 'DWord') 'type changed to DWord'
    [void](Invoke-Revert 6>$null)
    $v = Get-RawValue "$Raw\Exist" 'S'
    Assert ($v -and $v.Kind -eq 'String' -and $v.Value -ceq 'hello') "restored String 'hello' ($($v.Kind) $($v.Value))"
    Assert (Test-Path -LiteralPath "$Raw\Exist") 'pre-existing key not deleted'
}

Test-Case 'Pre-existing empty key is not removed by revert' {
    Reset-Sandbox
    [void](New-Item -Path "$Raw\Keep" -Force)
    Start-TestEngine
    [void](Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Keep' -Name 'X' -Value 'a' -Type String 6>$null)
    [void](Invoke-Revert 6>$null)
    Assert (Test-Path -LiteralPath "$Raw\Keep") 'key that existed before stays'
    Assert ($null -eq (Get-RawValue "$Raw\Keep" 'X')) 'value removed'
}

Test-Case 'Double set keeps the original Old value (across a journal reload)' {
    Reset-Sandbox
    Set-RawValue "$Raw\Twice" 'D' 'orig' 'String'
    Start-TestEngine
    [void](Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Twice' -Name 'D' -Value 1 -Type DWord 6>$null)
    Start-TestEngine   # second run: journal reloaded from disk
    [void](Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Twice' -Name 'D' -Value 2 -Type DWord 6>$null)
    $j = Get-Journal
    Assert ($j.Count -eq 1) "one journal entry ($($j.Count))"
    Assert ($j[0].OldType -eq 'String' -and $j[0].OldValue -ceq 'orig') 'Old keeps the original String'
    Assert ($j[0].NewValue -eq 2) 'New updated to the latest value'
    Start-TestEngine
    [void](Invoke-Revert 6>$null)
    $v = Get-RawValue "$Raw\Twice" 'D'
    Assert ($v.Kind -eq 'String' -and $v.Value -ceq 'orig') 'revert restores the original'
}

Test-Case 'Revert skips a value changed since; -Force overrides' {
    Reset-Sandbox; Start-TestEngine
    [void](Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Since' -Name 'C' -Value 1 -Type DWord 6>$null)
    Set-RawValue "$Raw\Since" 'C' 9 'DWord'
    $r = Invoke-Revert 6>$null
    Assert ($r.Skipped -eq 1 -and $r.Reverted -eq 0) 'skipped as changed since'
    Assert ((Get-RawValue "$Raw\Since" 'C').Value -eq 9) 'value left alone'
    Assert ((Get-Journal).Count -eq 1) 'skipped entry stays in the journal'
    $r = Invoke-Revert -Force 6>$null
    Assert ($r.Reverted -eq 1) 'reverted with -Force'
    Assert ($null -eq (Get-RawValue "$Raw\Since" 'C')) 'value deleted (did not exist before)'
}

Test-Case 'Binary and MultiString round-trip through the journal' {
    Reset-Sandbox
    Set-RawValue "$Raw\Types" 'B' ([byte[]](1, 2, 3)) 'Binary'
    Set-RawValue "$Raw\Types" 'M' ([string[]]@('a')) 'MultiString'
    Start-TestEngine
    [void](Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Types' -Name 'B' -Value ([byte[]](9, 9, 0, 255)) -Type Binary 6>$null)
    [void](Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Types' -Name 'M' -Value ([string[]]@('x', 'y')) -Type MultiString 6>$null)
    [void](Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Types' -Name 'M1' -Value ([string[]]@('only')) -Type MultiString 6>$null)
    [void](Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Types' -Name 'E' -Value '%SystemRoot%\x' -Type ExpandString 6>$null)
    [void](Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Types' -Name 'Q' -Value ([int64]1234567890123) -Type QWord 6>$null)
    [void](Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Types' -Name 'U' -Value 4294967295 -Type DWord 6>$null)
    Assert (Test-SameArray (Get-RawValue "$Raw\Types" 'B').Value @(9, 9, 0, 255)) 'binary written'
    Assert ((Get-RawValue "$Raw\Types" 'E').Value -ceq '%SystemRoot%\x') 'ExpandString written unexpanded'
    $text = [System.IO.File]::ReadAllText($JournalPath)
    Assert ($text -match '"NewValue":\s*\[\s*"only"\s*\]') 'single-element MultiString stored as a JSON array'
    Start-TestEngine   # reload from JSON
    $s = Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Types' -Name 'U' -Value -1 -Type DWord 6>$null
    Assert ($s -eq 'Unchanged') '0xFFFFFFFF and -1 compare equal as DWord'
    $r = Invoke-Revert 6>$null
    Assert ($r.Reverted -eq 6 -and $r.Skipped -eq 0) "all six reverted after reload (reverted $($r.Reverted), skipped $($r.Skipped))"
    $b = Get-RawValue "$Raw\Types" 'B'
    Assert ($b.Kind -eq 'Binary' -and (Test-SameArray $b.Value @(1, 2, 3))) 'binary restored byte-for-byte'
    $m = Get-RawValue "$Raw\Types" 'M'
    Assert ($m.Kind -eq 'MultiString' -and (Test-SameArray $m.Value @('a'))) 'multistring restored'
    Assert ($null -eq (Get-RawValue "$Raw\Types" 'M1') -and $null -eq (Get-RawValue "$Raw\Types" 'Q')) 'values that did not exist are deleted'
}

Test-Case 'HKLM paths are redirected into the sandbox' {
    Reset-Sandbox; Start-TestEngine
    $s = Set-TrackedRegistryValue -Module T -Path 'HKLM:\SOFTWARE\Policies\IMTest\Windows Search' -Name 'P' -Value 0 -Type DWord 6>$null
    Assert ($s -eq 'Changed') 'HKLM write allowed in sandbox without admin'
    Assert ($null -ne (Get-RawValue 'HKCU:\Software\InstallMedia-Test\HKLM\SOFTWARE\Policies\IMTest\Windows Search' 'P')) 'landed under InstallMedia-Test\HKLM'
    Assert (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Policies\IMTest')) 'real HKLM untouched'
    [void](Invoke-Revert 6>$null)
    Assert (-not (Test-Path -LiteralPath $SandboxKey)) 'sandbox removed after revert'
}

Test-Case 'Remove-TrackedRegistryValue journals and reverts' {
    Reset-Sandbox
    Set-RawValue "$Raw\Rm" 'Gone' 42 'DWord'
    Start-TestEngine
    $s = Remove-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Rm' -Name 'Gone' 6>$null
    Assert ($s -eq 'Changed' -and $null -eq (Get-RawValue "$Raw\Rm" 'Gone')) 'value removed'
    [void](Invoke-Revert 6>$null)
    $v = Get-RawValue "$Raw\Rm" 'Gone'
    Assert ($v.Kind -eq 'DWord' -and $v.Value -eq 42) 'value restored'
}

Test-Case 'WhatIf writes nothing' {
    Reset-Sandbox; Start-TestEngine -WhatIf $true
    $s = Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\W' -Name 'V' -Value 1 -Type DWord 6>$null
    $a = Invoke-TrackedAction -Module T -Kind power -Description 'test action' -Capture { [pscustomobject]@{ A = 1 } } -Apply { throw 'must not run' } 6>$null
    Assert ($s -eq 'Planned' -and $a -eq 'Planned') 'returns Planned'
    Assert (-not (Test-Path -LiteralPath $SandboxKey)) 'no registry write'
    Assert (-not (Test-Path -LiteralPath $JournalPath)) 'no journal written'
}

Test-Case 'User scope: entries of another SID are skipped; blocked HKCU writes are skipped' {
    Reset-Sandbox; Start-TestEngine
    [void](Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Sid' -Name 'V' -Value 1 -Type DWord 6>$null)
    $text = [System.IO.File]::ReadAllText($JournalPath) -replace '"UserSid":\s*"[^"]+"', '"UserSid": "S-1-5-21-1-2-3-4242"'
    [System.IO.File]::WriteAllText($JournalPath, $text)
    Start-TestEngine
    $r = Invoke-Revert 6>$null
    Assert ($r.Skipped -eq 1 -and (Get-Journal).Count -eq 1) 'skipped and kept'
    Assert ($null -ne (Get-RawValue "$Raw\Sid" 'V')) 'value untouched'
    Reset-Sandbox; Start-TestEngine -HkcuAllowed $false
    $s = Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\IMTest\Sid' -Name 'V' -Value 1 -Type DWord 6>$null
    Assert ($s -eq 'Skipped') 'HKCU write refused when blocked'
}

Test-Case 'Tracked actions: sandbox never runs Apply/Restore; Key keeps the first Old' {
    Reset-Sandbox; Start-TestEngine
    $script:capt = 1
    Register-TrackedActionHandler -Kind power -Capture { [pscustomobject]@{ V = $script:capt } } -Restore { throw 'restore must not run in sandbox' }
    $a = Invoke-TrackedAction -Module T -Kind power -Key 'k1' -Description 'test power' -Capture { [pscustomobject]@{ V = $script:capt } } -Apply { throw 'apply must not run in sandbox' } 6>$null
    Assert ($a -eq 'Changed') 'action journaled'
    $script:capt = 2
    [void](Invoke-TrackedAction -Module T -Kind power -Key 'k1' -Description 'test power' -Capture { [pscustomobject]@{ V = $script:capt } } -Apply { throw 'x' } 6>$null)
    $j = Get-Journal
    Assert ($j.Count -eq 1 -and $j[0].Old.V -eq 1) 'second run keeps the original Old'
    $n = Invoke-TrackedAction -Module T -Kind appx -Key 'pkg' -Description 'remove test package' -RestoreHint 'Store' -Capture { 'x' } -Apply { throw 'x' } 6>$null
    Assert ((Get-Journal).Count -eq 2 -and -not (Get-Journal)[1].Revertible) 'appx entry is not revertible'
    Start-TestEngine
    $r = Invoke-Revert 6>$null
    Assert ($r.Reverted -eq 1 -and $r.NotRevertible -eq 1) "power reverted (logged), appx listed (reverted $($r.Reverted), not revertible $($r.NotRevertible))"
    Assert ((Get-Journal).Count -eq 1) 'non-revertible entry stays in the journal'
}

Test-Case 'Live-mode paths without writes (WhatIf, guards)' {
    Reset-Sandbox
    $livePath = Join-Path $TmpDir 'live-journal.json'
    Initialize-Engine -Sandbox $false -WhatIf $true -OutputDir $TmpDir -JournalPath $livePath -IsAdmin $false -HkcuAllowed $true 6>$null
    $s1 = Set-TrackedRegistryValue -Module T -Path 'HKCU:\Software\InstallMedia-NoSuchKey\A' -Name 'V' -Value 1 -Type DWord 6>$null
    $s2 = Set-TrackedRegistryValue -Module T -Path 'HKLM:\SOFTWARE\Policies\InstallMedia-NoSuchKey' -Name 'V' -Value 1 -Type DWord 6>$null
    Assert ($s1 -eq 'Planned' -and $s2 -eq 'Skipped') "live WhatIf: HKCU planned, HKLM skipped without admin ($s1, $s2)"
    Assert (-not (Test-Path -LiteralPath 'HKCU:\Software\InstallMedia-NoSuchKey') -and -not (Test-Path -LiteralPath $livePath)) 'nothing written in live WhatIf'
    $g = & (Get-Module Engine) {
        $r1 = Remove-IMRegKeyIfEmpty 'HKCU:\Software\InstallMedia-NoSuchKey'
        $r2 = Remove-IMRegKeyIfEmpty 'HKCU:\Software\InstallMedia-NoSuchKey\A\B'
        "$r1,$r2"
    } 6>$null
    Assert ($g -eq 'Refused,Absent') "live key cleanup refuses shallow keys and ignores absent ones ($g)"
    Start-TestEngine
}

Test-Case 'Profile inheritance merge' {
    $base = @{ A = 1; H = @{ X = 1; Y = @(1, 2) }; L = @(1, 2, 3) }
    $over = @{ B = 2; H = @{ Y = @(9) }; L = @(7) }
    $m = Merge-IMHashtable $base $over
    Assert ($m.A -eq 1 -and $m.B -eq 2) 'keys from both'
    Assert ($m.H.X -eq 1 -and (Test-SameArray $m.H.Y @(9))) 'nested hashtables merge; nested arrays replace'
    Assert (Test-SameArray $m.L @(7)) 'arrays replace'
    Assert (Test-SameArray $base.L @(1, 2, 3)) 'base not modified'
    $bp = Join-Path $root 'profiles\base.psd1'; $zp = Join-Path $root 'profiles\zenbook-s16-um5606g.psd1'
    $b = Import-PowerShellDataFile $bp; $z = Import-PowerShellDataFile $zp
    $mz = Merge-IMHashtable $b $z
    Assert ($z.Inherits -eq 'base') 'zenbook inherits base'
    Assert (@($mz.SearchTweaks).Count -ge 5 -and $mz.Expected.Cpu -like '*465*' -and $mz.Keyboard.Ensure.Count -eq 2 -and $mz.Name -eq 'zenbook-s16-um5606g') 'merged profile has base and machine keys'
    $viaText = ConvertFrom-IMDataText -Text ([System.IO.File]::ReadAllText($zp))
    Assert ((ConvertTo-IMStateJson $viaText) -eq (ConvertTo-IMStateJson $z)) 'restricted text parse equals Import-PowerShellDataFile'
    $bad = $false
    try { [void](ConvertFrom-IMDataText -Text "@{ A = (Get-Date) }") } catch { $bad = $true }
    Assert $bad 'restricted parse rejects commands'
    foreach ($t in $mz.SearchTweaks) {
        if (-not ($t.Path -and $t.Name -and $t.Type -and $null -ne $t.Value -and $t.Note -and $t.Verified -and $t.ContainsKey('Apply'))) { Assert $false "tweak $($t.Name) has all fields" }
    }
}

Test-Case 'Keyboard plan builder' {
    $E = @('0409:00000409', '0419:00000419'); $R = @('0409:00020409'); $O = @('en-US', 'ru-RU'); $yes = { param($t) $true }
    $p = Get-KeyboardLanguagePlan -Current @([pscustomobject]@{ Tag = 'en-US'; Tips = @('0409:00000409') }) -Ensure $E -Remove $R -LanguageOrder $O -IsTipAvailable $yes
    Assert ($p.Changed -and $p.Plan.Count -eq 2 -and $p.Plan[0].Tag -eq 'en-US' -and (Test-SameArray $p.Plan[0].Tips @('0409:00000409')) -and $p.Plan[1].Tag -eq 'ru-RU' -and (Test-SameArray $p.Plan[1].Tips @('0419:00000419'))) 'already-US: adds ru-RU only'
    $p = Get-KeyboardLanguagePlan -Current @([pscustomobject]@{ Tag = 'en-US'; Tips = @('0409:00020409') }) -Ensure $E -Remove $R -LanguageOrder $O -IsTipAvailable $yes
    Assert ($p.Changed -and (Test-SameArray $p.Plan[0].Tips @('0409:00000409')) -and $p.Plan[1].Tag -eq 'ru-RU') 'US-International only: replaced by US, Russian added'
    $p = Get-KeyboardLanguagePlan -Current @([pscustomobject]@{ Tag = 'en-US'; Tips = @('0409:00000409') }, [pscustomobject]@{ Tag = 'ru'; Tips = @('0419:00000419') }) -Ensure $E -Remove $R -LanguageOrder $O -IsTipAvailable $yes
    Assert (-not $p.Changed -and $p.Plan.Count -eq 2) 'Russian already present (tag "ru"): no change'
    $p = Get-KeyboardLanguagePlan -Current @([pscustomobject]@{ Tag = 'bg-BG'; Tips = @('0402:00030402') }, [pscustomobject]@{ Tag = 'en-US'; Tips = @('0409:00020409') }) -Ensure $E -Remove $R -LanguageOrder $O -IsTipAvailable $yes
    Assert ($p.Plan[0].Tag -eq 'bg-BG' -and (Test-SameArray $p.Plan[1].Tips @('0409:00000409')) -and $p.Plan[2].Tag -eq 'ru-RU') 'display language stays first; US replaces US-Int'
    $p = Get-KeyboardLanguagePlan -Current @([pscustomobject]@{ Tag = 'en-US'; Tips = @('0409:00020409') }) -Ensure @('0419:00000419') -Remove $R -LanguageOrder $O -IsTipAvailable $yes
    Assert ((Test-SameArray $p.Plan[0].Tips @('0409:00020409')) -and ($p.Notes -join ' ') -match 'kept') 'only layout of the first language is kept'
    $p = Get-KeyboardLanguagePlan -Current @([pscustomobject]@{ Tag = 'ru-RU'; Tips = @('0419:00000419') }, [pscustomobject]@{ Tag = 'en-GB'; Tips = @('0409:00020409') }) -Ensure @('0419:00000419') -Remove $R -LanguageOrder $O -IsTipAvailable $yes
    Assert ($p.Plan.Count -eq 1 -and $p.Plan[0].Tag -eq 'ru-RU') 'non-first language left with no layouts is dropped'
    $p = Get-KeyboardLanguagePlan -Current @([pscustomobject]@{ Tag = 'en-US'; Tips = @('0409:00000409') }) -Ensure $E -Remove $R -LanguageOrder $O -IsTipAvailable { param($t) $t -ne '0419:00000419' }
    Assert (-not $p.Changed -and ($p.Notes -join ' ') -match 'skipped 0419') 'layout needing a download is skipped and reported'
    Assert (Test-IMKeyboardTipAvailable '0419:00000419') 'Russian layout DLL is built in on this machine'
}

Test-Case 'Bloat matching and selection' {
    $cfg = @{
        Appx    = @('Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Contoso.*')
        Win32   = @('McAfee*', 'Norton*')
        Protect = @('*ASUS*', '*Bing*', 'Microsoft.WindowsStore', '*Contoso.Driver*')
    }
    $appx = @(
        [pscustomobject]@{ Name = 'Clipchamp.Clipchamp'; Publisher = 'CN=Clip'; PackageFullName = 'c1'; Version = '1' },
        [pscustomobject]@{ Name = 'Microsoft.BingNews'; Publisher = 'CN=Microsoft'; PackageFullName = 'b1'; Version = '1' },
        [pscustomobject]@{ Name = 'Microsoft.WindowsStore'; Publisher = 'CN=Microsoft'; PackageFullName = 's1'; Version = '1' },
        [pscustomobject]@{ Name = 'Contoso.Driver.Tool'; Publisher = 'CN=Contoso'; PackageFullName = 'd1'; Version = '1' }
    )
    $win = @(
        [pscustomobject]@{ DisplayName = 'McAfee LiveSafe'; Publisher = 'McAfee, LLC'; EstimatedSize = 2048; RegistryKey = 'k1' },
        [pscustomobject]@{ DisplayName = 'McAfee for ASUS'; Publisher = 'McAfee'; RegistryKey = 'k2' },
        [pscustomobject]@{ DisplayName = 'Norton Security'; Publisher = 'ASUSTeK bundle'; RegistryKey = 'k3' },
        [pscustomobject]@{ DisplayName = 'Realtek Audio'; Publisher = 'Realtek'; RegistryKey = 'k4' }
    )
    $c = Get-BloatCandidates -Bloat $cfg -Appx $appx -Win32 $win
    $names = @($c | ForEach-Object { $_.Name })
    Assert ($names -contains 'Clipchamp.Clipchamp') 'listed Appx offered'
    Assert ($names -contains 'Microsoft.BingNews') 'exact Appx entry beats a Protect wildcard'
    Assert (-not ($names -contains 'Contoso.Driver.Tool')) 'wildcard Appx entry loses to Protect'
    Assert (-not ($names -contains 'Microsoft.WindowsStore')) 'unlisted Appx not offered'
    Assert ($names -contains 'McAfee LiveSafe' -and -not ($names -contains 'McAfee for ASUS') -and -not ($names -contains 'Norton Security')) 'Win32: Protect wins on name or publisher'
    Assert ($names.Count -eq 3) "three candidates ($($names -join ', '))"
    Assert ((ConvertFrom-BloatSelection '' 3).Count -eq 0) 'empty answer = none'
    Assert (Test-SameArray (ConvertFrom-BloatSelection 'all' 3) @(1, 2, 3)) 'all'
    Assert (Test-SameArray (ConvertFrom-BloatSelection ' 3, 1 3' 3) @(3, 1)) 'list with duplicates'
    $t1 = $false; try { [void](ConvertFrom-BloatSelection '4' 3) } catch { $t1 = $true }
    $t2 = $false; try { [void](ConvertFrom-BloatSelection 'x' 3) } catch { $t2 = $true }
    Assert ($t1 -and $t2) 'out of range and non-numbers rejected'
    $base = Import-PowerShellDataFile (Join-Path $root 'profiles\base.psd1')
    Assert (-not (@($base.Bloat.Appx) -contains 'Microsoft.Xbox.TCUI') -and -not (@($base.Bloat.Protect) -contains '*Office*') -and (@($base.Bloat.Protect) -contains 'Microsoft.Office.*')) 'base Bloat lists follow the clarifications'
}

Test-Case 'Power and taskbar helpers' {
    $en = @('Power Setting GUID: 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e  (Turn off display after)',
        '    Minimum Possible Setting: 0x00000000', '    Maximum Possible Setting: 0xffffffff',
        '    Possible Settings increment: 0x00000001', '    Possible Settings units: Seconds',
        '  Current AC Power Setting Index: 0x00000258', '  Current DC Power Setting Index: 0x0000012c')
    $p = ConvertFrom-IMPowercfgQuery $en
    Assert ($p.Ac -eq 600 -and $p.Dc -eq 300) 'English powercfg output'
    $de = @('GUID der Energieeinstellung: 29f6c1db (Standbymodus nach)', '  Minimaler Wert: 0x00000000', '  Maximaler Wert: 0xffffffff',
        '  Einheiten: Sekunden', '  Index der aktuellen Wechselstromeinstellung: 0x00000708', '  Index der aktuellen Gleichstromeinstellung: 0x00000384  ')
    $p = ConvertFrom-IMPowercfgQuery $de
    Assert ($p.Ac -eq 1800 -and $p.Dc -eq 900) 'localized powercfg output'
    $blob = [byte[]](0x30, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff, 0x02, 0, 0, 0, 3, 0, 0, 0)
    $r = Get-IMAutoHideBlob $blob
    Assert ($r.Status -eq 'Ok' -and $r.Blob[8] -eq 3 -and $blob[8] -eq 2 -and $r.Blob.Length -eq 16) 'byte 8 0x02 -> 0x03 on a copy'
    $blob[8] = 3
    Assert ((Get-IMAutoHideBlob $blob).Status -eq 'Already') 'already auto-hide'
    Assert ((Get-IMAutoHideBlob ([byte[]](1, 2, 3))).Status -eq 'Invalid') 'short blob skipped'
    $blob[8] = 0x7a
    Assert ((Get-IMAutoHideBlob $blob).Status -eq 'Invalid') 'unexpected byte skipped'
    Assert ((Get-IMAutoHideBlob $null).Status -eq 'Invalid') 'absent value skipped'
}

Reset-Sandbox
Remove-Item -LiteralPath $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
$guardAfter = Get-GuardSnapshot
Write-Host ''
Assert ($guardBefore -eq $guardAfter) 'real Search/Personalize/StuckRects3 values unchanged by the tests'
Assert (-not (Test-Path -LiteralPath $SandboxKey)) 'sandbox key removed at the end'
Write-Host ''
$color = if ($script:Failed) { 'Red' } else { 'Green' }
Write-Host "Tests: $script:Passed passed, $script:Failed failed" -ForegroundColor $color
if ($script:Failed) { exit 1 } else { exit 0 }
