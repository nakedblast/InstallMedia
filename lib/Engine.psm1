# InstallMedia engine: journal, tracked changes, revert, logging, user checks,
# sandbox redirection. Every registry or system change goes through this module
# so that its previous state is recorded before the change is made.

$ErrorActionPreference = 'Stop'

$script:State = @{
    Initialized = $false
    Sandbox     = $false
    WhatIf      = $false
    OutputDir   = $null
    JournalPath = $null
    Journal     = (New-Object System.Collections.ArrayList)
    IsAdmin     = $false
    HkcuAllowed = $true
    UserSid     = $null
    UserName    = $null
    Handlers    = @{}
}
$script:SandboxSubKey = 'Software\InstallMedia-Test'
$script:RegTypes = @('DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString')
$script:ActionKinds = @('power', 'language', 'appx', 'win32', 'system')
$script:NonRevertibleKinds = @('appx', 'win32', 'system')

# ---------------------------------------------------------------- logging

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][ValidateSet('Info', 'Ok', 'Warn', 'Fail')][string]$Level = 'Info'
    )
    $tag = @{ Info = '[    ]'; Ok = '[ OK ]'; Warn = '[WARN]'; Fail = '[FAIL]' }[$Level]
    $color = @{ Info = 'Gray'; Ok = 'Green'; Warn = 'Yellow'; Fail = 'Red' }[$Level]
    Write-Host ('{0} {1}' -f $tag, $Message) -ForegroundColor $color
}

function Write-IMTextFile {
    # Writes output-folder files directly (never affected by -WhatIf: the output folder is allowed).
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Content)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Invoke-IMNative {
    # Runs a native command, returns exit code and output lines; never throws on stderr.
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$Arguments = @())
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    [pscustomobject]@{ ExitCode = $code; Output = @($out) }
}

# ---------------------------------------------------------------- identity

function Test-IMIsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-IMCurrentUser {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    [pscustomobject]@{ Name = $id.Name; Sid = $id.User.Value }
}

function Get-IMInteractiveUser {
    # Owner of explorer.exe in this process's session (the signed-in desktop user), or $null.
    $session = (Get-Process -Id $PID).SessionId
    $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $session })
    foreach ($p in $procs) {
        try {
            $sid = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid
            if ($sid.ReturnValue -ne 0 -or -not $sid.Sid) { continue }
            $own = Invoke-CimMethod -InputObject $p -MethodName GetOwner
            $name = if ($own.ReturnValue -eq 0) { '{0}\{1}' -f $own.Domain, $own.User } else { $sid.Sid }
            return [pscustomobject]@{ Name = $name; Sid = $sid.Sid }
        } catch { continue }
    }
    return $null
}

# ---------------------------------------------------------------- data helpers

function ConvertFrom-IMDataText {
    # Restricted-language data parse of PSD1 text (same mechanism as Import-PowerShellDataFile).
    param([Parameter(Mandatory = $true)][string]$Text, [string]$SourceName = 'data')
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw "Cannot parse ${SourceName}: $($errors[0].Message)" }
    $ht = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.HashtableAst] }, $false)
    if (-not $ht) { throw "No hashtable found in $SourceName" }
    return $ht.SafeGetValue()
}

function Copy-IMData {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $Value.Keys) { $h[$k] = Copy-IMData $Value[$k] }
        return $h
    }
    if ($Value -is [array]) {
        $list = @(foreach ($v in $Value) { , (Copy-IMData $v) })
        return , $list
    }
    return $Value
}

function Merge-IMHashtable {
    # Base first, then override keys; hashtables merge recursively, everything else (arrays included) replaces.
    param([System.Collections.IDictionary]$Base, [System.Collections.IDictionary]$Override)
    $result = Copy-IMData $Base
    if (-not $result) { $result = @{} }
    if ($Override) {
        foreach ($k in $Override.Keys) {
            $o = $Override[$k]
            if ($result.ContainsKey($k) -and $result[$k] -is [System.Collections.IDictionary] -and $o -is [System.Collections.IDictionary]) {
                $result[$k] = Merge-IMHashtable $result[$k] $o
            } else {
                $result[$k] = Copy-IMData $o
            }
        }
    }
    return $result
}

function ConvertTo-IMCanonical {
    # Recursively sorts keys so that captured states compare independent of key order.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in ($Value.Keys | Sort-Object)) { $o[[string]$k] = ConvertTo-IMCanonical $Value[$k] }
        return $o
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = @(foreach ($v in $Value) { , (ConvertTo-IMCanonical $v) })
        return , $list
    }
    $o = [ordered]@{}
    foreach ($p in ($Value.PSObject.Properties | Sort-Object Name)) { $o[$p.Name] = ConvertTo-IMCanonical $p.Value }
    return $o
}

function ConvertTo-IMStateJson {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    ConvertTo-Json -InputObject (ConvertTo-IMCanonical $Value) -Depth 10 -Compress
}

function Repair-IMJsonArray {
    # Windows PowerShell 5.1 can serialize arrays as {"value":[...],"Count":n}; accept both shapes.
    param($Value)
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $names = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names.Count -eq 2 -and $names -contains 'value' -and $names -contains 'Count') { return , @($Value.value) }
    }
    return , $Value
}

# ---------------------------------------------------------------- module results

function New-ModuleResult {
    param([Parameter(Mandatory = $true)][string]$Module)
    [pscustomobject]@{
        Module    = $Module
        Changed   = 0
        Unchanged = 0
        Skipped   = 0
        Failed    = 0
        Notes     = (New-Object System.Collections.ArrayList)
    }
}

function Add-ModuleResultStatus {
    param([Parameter(Mandatory = $true)]$Result, [Parameter(Mandatory = $true)][string]$Status, [string]$Note)
    switch ($Status) {
        'Changed' { $Result.Changed++ }
        'Planned' { $Result.Changed++ }
        'Unchanged' { $Result.Unchanged++ }
        'Skipped' { $Result.Skipped++ }
        default { $Result.Failed++ }
    }
    if ($Note) { [void]$Result.Notes.Add($Note) }
}

# ---------------------------------------------------------------- initialization and journal

function Initialize-Engine {
    [CmdletBinding()]
    param(
        [bool]$Sandbox = $false,
        [bool]$WhatIf = $false,
        [string]$OutputDir,
        [string]$JournalPath,
        [bool]$IsAdmin = $false,
        [bool]$HkcuAllowed = $true
    )
    $s = $script:State
    $s.Sandbox = $Sandbox
    $s.WhatIf = $WhatIf
    $s.OutputDir = $OutputDir
    $s.IsAdmin = $IsAdmin
    $s.HkcuAllowed = $HkcuAllowed
    $u = Get-IMCurrentUser
    $s.UserSid = $u.Sid
    $s.UserName = $u.Name
    if (-not $JournalPath) {
        if ($Sandbox) { $JournalPath = Join-Path $env:TEMP 'InstallMedia-Sandbox\journal.json' }
        else { $JournalPath = Join-Path $env:ProgramData 'InstallMedia\journal.json' }
    }
    $s.JournalPath = $JournalPath
    $s.Journal = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $JournalPath) {
        $text = [System.IO.File]::ReadAllText($JournalPath)
        if ($text.Trim()) {
            # A journal that cannot be parsed must never be replaced by an empty one.
            try { $data = ConvertFrom-Json -InputObject $text }
            catch { throw "Journal $JournalPath is unreadable ($($_.Exception.Message)); fix or move it before running again." }
            $items = Repair-IMJsonArray $data
            foreach ($e in $items) {
                if ($null -eq $e) { continue }
                foreach ($p in 'OldValue', 'NewValue', 'CreatedKeys') {
                    if ($e.PSObject.Properties[$p]) { $e.$p = Repair-IMJsonArray $e.$p }
                }
                [void]$s.Journal.Add($e)
            }
        }
    }
    $s.Initialized = $true
    $mode = if ($Sandbox) { 'sandbox' } else { 'live' }
    Write-Log ("Engine ready ({0}{1}); journal {2} ({3} entries)" -f $mode, $(if ($WhatIf) { ', WhatIf' } else { '' }), $JournalPath, $s.Journal.Count)
}

function Get-EngineState {
    [pscustomobject]@{
        Sandbox = $script:State.Sandbox; WhatIf = $script:State.WhatIf; JournalPath = $script:State.JournalPath
        IsAdmin = $script:State.IsAdmin; HkcuAllowed = $script:State.HkcuAllowed; UserSid = $script:State.UserSid
    }
}

function Get-EngineJournal { , @($script:State.Journal) }

function Assert-EngineReady {
    if (-not $script:State.Initialized) { throw 'Initialize-Engine has not been called.' }
}

function Save-IMJournal {
    if ($script:State.WhatIf) { return }
    $path = $script:State.JournalPath
    $dir = [System.IO.Path]::GetDirectoryName($path)
    [void][System.IO.Directory]::CreateDirectory($dir)
    $json = ConvertTo-Json -InputObject ([object[]]@($script:State.Journal)) -Depth 8
    if ($script:State.Journal.Count -eq 0) { $json = '[]' }
    $tmp = "$path.tmp"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $json, $enc)
    if ([System.IO.File]::Exists($path)) { [System.IO.File]::Replace($tmp, $path, [NullString]::Value) }
    else { [System.IO.File]::Move($tmp, $path) }
}

function Copy-EngineJournal {
    param([Parameter(Mandatory = $true)][string]$Destination)
    if (Test-Path -LiteralPath $script:State.JournalPath) {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Destination))
        [System.IO.File]::Copy($script:State.JournalPath, $Destination, $true)
        return $true
    }
    return $false
}

function Register-TrackedActionHandler {
    # Capture/Restore handlers per action Kind; needed by Invoke-Revert in a later process.
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [scriptblock]$Capture,
        [scriptblock]$Restore
    )
    $script:State.Handlers[$Kind] = @{ Capture = $Capture; Restore = $Restore }
}

# ---------------------------------------------------------------- registry primitives

function ConvertTo-IMRegLocation {
    param([Parameter(Mandatory = $true)][string]$Path)
    $p = ($Path -replace '^Registry::', '').TrimEnd('\')
    if ($p -match '^(HKCU|HKEY_CURRENT_USER):?(\\(.+))?$') { $hive = 'HKCU'; $sub = $Matches[3] }
    elseif ($p -match '^(HKLM|HKEY_LOCAL_MACHINE):?(\\(.+))?$') { $hive = 'HKLM'; $sub = $Matches[3] }
    else { throw "Unsupported registry path '$Path' (use HKCU:\... or HKLM:\...)" }
    if (-not $sub) { throw "Registry path '$Path' has no subkey" }
    $sub = $sub.Trim('\')
    [pscustomobject]@{ Hive = $hive; SubKey = $sub; Logical = "${hive}:\$sub" }
}

function Resolve-IMRegTarget {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Real)
    $loc = ConvertTo-IMRegLocation $Path
    if ($script:State.Sandbox -and -not $Real) {
        return [pscustomobject]@{
            Hive = 'HKCU'; SubKey = "$script:SandboxSubKey\$($loc.Hive)\$($loc.SubKey)"
            Logical = $loc.Logical; LogicalHive = $loc.Hive; LogicalSubKey = $loc.SubKey; Display = "[sandbox] $($loc.Logical)"
        }
    }
    [pscustomobject]@{ Hive = $loc.Hive; SubKey = $loc.SubKey; Logical = $loc.Logical; LogicalHive = $loc.Hive; LogicalSubKey = $loc.SubKey; Display = $loc.Logical }
}

function Get-IMBaseKey {
    param([string]$Hive)
    $h = if ($Hive -eq 'HKLM') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
    [Microsoft.Win32.RegistryKey]::OpenBaseKey($h, [Microsoft.Win32.RegistryView]::Registry64)
}

function Test-IMRegKeyExists {
    param([string]$Hive, [string]$SubKey)
    $base = Get-IMBaseKey $Hive
    try {
        $k = $base.OpenSubKey($SubKey, $false)
        if ($null -eq $k) { return $false }
        $k.Close(); return $true
    } finally { $base.Close() }
}

function Get-IMRegState {
    param([Parameter(Mandatory = $true)]$Target, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name)
    $base = Get-IMBaseKey $Target.Hive
    try {
        $key = $base.OpenSubKey($Target.SubKey, $false)
        if ($null -eq $key) { return [pscustomobject]@{ KeyExists = $false; ValueExists = $false; Type = $null; Value = $null } }
        try {
            $names = @($key.GetValueNames())
            if (-not ($names -contains $Name)) { return [pscustomobject]@{ KeyExists = $true; ValueExists = $false; Type = $null; Value = $null } }
            $kind = $key.GetValueKind($Name).ToString()
            $val = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [pscustomobject]@{ KeyExists = $true; ValueExists = $true; Type = $kind; Value = $val }
        } finally { $key.Close() }
    } finally { $base.Close() }
}

function ConvertTo-IMRegNative {
    param([Parameter(Mandatory = $true)][string]$Type, [AllowNull()]$Value)
    switch ($Type) {
        'DWord' {
            if ($Value -is [uint32]) { return [BitConverter]::ToInt32([BitConverter]::GetBytes($Value), 0) }
            $l = [int64]$Value
            if ($l -gt [int32]::MaxValue -and $l -le [uint32]::MaxValue) { $l = $l - 4294967296 }
            if ($l -lt [int32]::MinValue -or $l -gt [int32]::MaxValue) { throw "DWord value out of range: $Value" }
            return [int32]$l
        }
        'QWord' {
            if ($Value -is [uint64]) { return [BitConverter]::ToInt64([BitConverter]::GetBytes($Value), 0) }
            $d = [decimal]$Value
            if ($d -gt [decimal][int64]::MaxValue) { $d = $d - [decimal]'18446744073709551616' }
            return [int64]$d
        }
        'String' { if ($null -eq $Value) { return '' }; return [string]$Value }
        'ExpandString' { if ($null -eq $Value) { return '' }; return [string]$Value }
        'MultiString' {
            if ($null -eq $Value) { return , ([string[]]@()) }
            $Value = Repair-IMJsonArray $Value
            $arr = [string[]]@(foreach ($v in @($Value)) { [string]$v })
            return , $arr
        }
        'Binary' {
            if ($null -eq $Value) { return , ([byte[]]@()) }
            if ($Value -is [string]) { return , ([Convert]::FromBase64String($Value)) }
            $Value = Repair-IMJsonArray $Value
            return , ([byte[]]@(foreach ($v in @($Value)) { [byte]$v }))
        }
        default { throw "Unsupported registry type '$Type'" }
    }
}

function Test-IMRegEqual {
    param([string]$TypeA, $ValueA, [string]$TypeB, $ValueB)
    if ($TypeA -ne $TypeB) { return $false }
    $a = ConvertTo-IMRegNative $TypeA $ValueA
    $b = ConvertTo-IMRegNative $TypeB $ValueB
    if ($TypeA -eq 'Binary' -or $TypeA -eq 'MultiString') {
        if ($a.Length -ne $b.Length) { return $false }
        for ($i = 0; $i -lt $a.Length; $i++) {
            if ($TypeA -eq 'MultiString') {
                if (-not [string]::Equals($a[$i], $b[$i], [System.StringComparison]::Ordinal)) { return $false }
            } elseif ($a[$i] -ne $b[$i]) { return $false }
        }
        return $true
    }
    if ($TypeA -eq 'String' -or $TypeA -eq 'ExpandString') { return [string]::Equals($a, $b, [System.StringComparison]::Ordinal) }
    return ($a -eq $b)
}

function ConvertTo-IMJournalValue {
    param([string]$Type, $Value)
    if (-not $Type) { return $null }
    $n = ConvertTo-IMRegNative $Type $Value
    if ($Type -eq 'Binary') { return [Convert]::ToBase64String($n) }
    if ($Type -eq 'MultiString') { return , $n }
    return $n
}

function Format-IMRegValue {
    param([string]$Type, $Value)
    if (-not $Type) { return '<absent>' }
    $n = ConvertTo-IMRegNative $Type $Value
    switch ($Type) {
        'Binary' { return ('hex:' + (($n | ForEach-Object { $_.ToString('x2') }) -join ',')) }
        'MultiString' { return ('[' + (($n | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']') }
        'DWord' { return ('{0} (0x{1})' -f $n, ([uint32]([int64]$n -band 0xFFFFFFFFL)).ToString('x8')) }
        default { return [string]$n }
    }
}

function Get-IMMissingKeyChain {
    # Logical paths (shallowest first) of keys that do not exist yet for this target.
    param($Target)
    $segments = $Target.LogicalSubKey -split '\\'
    $prefixReal = $Target.SubKey.Substring(0, $Target.SubKey.Length - $Target.LogicalSubKey.Length)
    $missing = New-Object System.Collections.ArrayList
    $acc = ''
    $found = $false
    foreach ($seg in $segments) {
        $acc = if ($acc) { "$acc\$seg" } else { $seg }
        if (-not $found) {
            if (Test-IMRegKeyExists $Target.Hive ($prefixReal + $acc)) { continue }
            $found = $true
        }
        [void]$missing.Add("$($Target.LogicalHive):\$acc")
    }
    , @($missing)
}

function Write-IMRegValue {
    param($Target, [string]$Name, [string]$Type, $Value)
    $base = Get-IMBaseKey $Target.Hive
    try {
        $key = $base.CreateSubKey($Target.SubKey)
        if ($null -eq $key) { throw "Cannot open or create $($Target.Hive):\$($Target.SubKey)" }
        try {
            $kind = [Microsoft.Win32.RegistryValueKind]$Type
            $native = ConvertTo-IMRegNative $Type $Value
            $key.SetValue($Name, $native, $kind)
        } finally { $key.Close() }
    } finally { $base.Close() }
}

function Remove-IMRegValueRaw {
    param($Target, [string]$Name)
    $base = Get-IMBaseKey $Target.Hive
    try {
        $key = $base.OpenSubKey($Target.SubKey, $true)
        if ($null -eq $key) { return }
        try { $key.DeleteValue($Name, $false) } finally { $key.Close() }
    } finally { $base.Close() }
}

function Remove-IMRegKeyIfEmpty {
    # Deletes the key for a logical path only if it has no values and no subkeys.
    # Returns 'Deleted', 'NotEmpty', 'Absent' or 'Refused'.
    param([string]$LogicalPath)
    $t = Resolve-IMRegTarget $LogicalPath
    if (-not $script:State.Sandbox) {
        $depth = @($t.LogicalSubKey -split '\\').Count
        if ($depth -lt 3) { Write-Log "Not deleting shallow key $LogicalPath" Warn; return 'Refused' }
    }
    $base = Get-IMBaseKey $t.Hive
    try {
        $k = $base.OpenSubKey($t.SubKey, $false)
        if ($null -eq $k) { return 'Absent' }
        $empty = ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0)
        $k.Close()
        if (-not $empty) { return 'NotEmpty' }
        $base.DeleteSubKey($t.SubKey, $false)
        return 'Deleted'
    } finally { $base.Close() }
}

function Remove-IMSandboxRootIfEmpty {
    if (-not $script:State.Sandbox) { return }
    $base = Get-IMBaseKey 'HKCU'
    try {
        foreach ($sub in @("$script:SandboxSubKey\HKCU", "$script:SandboxSubKey\HKLM", $script:SandboxSubKey)) {
            $k = $base.OpenSubKey($sub, $false)
            if ($null -eq $k) { continue }
            $empty = ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0)
            $k.Close()
            if ($empty) { $base.DeleteSubKey($sub, $false) }
        }
    } finally { $base.Close() }
}

function Get-IMRegWriteBlock {
    # Returns a reason string when a write to this target must not happen, else $null.
    param($Target)
    if ($Target.LogicalHive -eq 'HKCU' -and -not $script:State.HkcuAllowed) {
        return 'HKCU writes are blocked (process user differs from the signed-in user)'
    }
    if ($Target.LogicalHive -eq 'HKLM' -and -not $script:State.Sandbox -and -not $script:State.IsAdmin) {
        return 'needs admin (HKLM)'
    }
    return $null
}

function Find-IMRegEntry {
    param([string]$Logical, [string]$Name)
    foreach ($e in $script:State.Journal) {
        if ($e.Kind -eq 'registry' -and $e.Path -eq $Logical -and $e.Name -eq $Name -and [bool]$e.Sandbox -eq $script:State.Sandbox) { return $e }
    }
    return $null
}

function Read-IMRegistryValue {
    # Read through the engine's redirection. -FallbackToReal: in sandbox, read the real value
    # (read-only) when the sandbox copy does not exist.
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name, [switch]$FallbackToReal)
    $t = Resolve-IMRegTarget $Path
    $st = Get-IMRegState $t $Name
    if (-not $st.ValueExists -and $FallbackToReal -and $script:State.Sandbox) {
        $st = Get-IMRegState (Resolve-IMRegTarget $Path -Real) $Name
    }
    return $st
}

function Invoke-IMRegChange {
    param([string]$Module, $Target, [string]$Name, [string]$NewType, $NewValue, $Current, [string]$Description)
    $label = "$($Target.Display)\$Name"
    $existing = Find-IMRegEntry $Target.Logical $Name
    $missing = @()
    if ($NewType) { $missing = Get-IMMissingKeyChain $Target }

    # Write-ahead: the journal records the change before it is made.
    $backup = $null
    if ($existing) {
        $backup = @{ NewType = $existing.NewType; NewValue = $existing.NewValue; Time = $existing.Time; CreatedKeys = $existing.CreatedKeys }
        $existing.NewType = $(if ($NewType) { $NewType } else { $null })
        $existing.NewValue = ConvertTo-IMJournalValue $NewType $NewValue
        $existing.Time = (Get-Date).ToString('o')
        $ck = @($existing.CreatedKeys | Where-Object { $_ })
        foreach ($m in $missing) { if ($ck -notcontains $m) { $ck += $m } }
        $existing.CreatedKeys = [string[]]$ck
        $entry = $existing
    } else {
        $entry = [pscustomobject][ordered]@{
            Id               = [guid]::NewGuid().ToString()
            Time             = (Get-Date).ToString('o')
            Module           = $Module
            Kind             = 'registry'
            Path             = $Target.Logical
            Name             = $Name
            ExistedBefore    = [bool]$Current.ValueExists
            OldValue         = $(if ($Current.ValueExists) { ConvertTo-IMJournalValue $Current.Type $Current.Value } else { $null })
            OldType          = $(if ($Current.ValueExists) { $Current.Type } else { $null })
            NewValue         = ConvertTo-IMJournalValue $NewType $NewValue
            NewType          = $(if ($NewType) { $NewType } else { $null })
            Old              = $null
            New              = $null
            Key              = $null
            KeyExistedBefore = [bool]$Current.KeyExists
            CreatedKeys      = [string[]]@($missing)
            Description      = $Description
            RestoreHint      = $null
            Revertible       = $true
            UserSid          = $script:State.UserSid
            Sandbox          = $script:State.Sandbox
        }
        [void]$script:State.Journal.Add($entry)
    }
    Save-IMJournal

    try {
        if ($NewType) { Write-IMRegValue $Target $Name $NewType $NewValue }
        else { Remove-IMRegValueRaw $Target $Name }
    } catch {
        $err = $_.Exception.Message
        if ($existing) {
            foreach ($k in $backup.Keys) { $existing.$k = $backup[$k] }
        } else {
            $script:State.Journal.Remove($entry)
        }
        foreach ($m in ($missing | Sort-Object { $_.Length } -Descending)) { try { [void](Remove-IMRegKeyIfEmpty $m) } catch { } }
        Save-IMJournal
        Write-Log "Failed to change ${label}: $err" Fail
        return 'Failed'
    }
    $shown = if ($NewType) { "$NewType $(Format-IMRegValue $NewType $NewValue)" } else { '<deleted>' }
    $was = if ($Current.ValueExists) { Format-IMRegValue $Current.Type $Current.Value } else { '<absent>' }
    Write-Log "Changed $label : $was -> $shown" Ok
    return 'Changed'
}

function Set-TrackedRegistryValue {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Module,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][AllowEmptyCollection()]$Value,
        [Parameter(Mandatory = $true)][ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString')][string]$Type,
        [string]$Description
    )
    Assert-EngineReady
    $t = Resolve-IMRegTarget $Path
    $label = "$($t.Display)\$Name"
    $block = Get-IMRegWriteBlock $t
    if ($block) { Write-Log "Skipped ${label}: $block" Warn; return 'Skipped' }
    try {
        $new = ConvertTo-IMRegNative $Type $Value
        $cur = Get-IMRegState $t $Name
    } catch { Write-Log "Cannot read ${label}: $($_.Exception.Message)" Fail; return 'Failed' }
    if ($cur.ValueExists -and ($script:RegTypes -notcontains $cur.Type)) {
        Write-Log "Skipped ${label}: existing value has unsupported type $($cur.Type)" Fail
        return 'Failed'
    }
    if ($cur.ValueExists -and (Test-IMRegEqual $cur.Type $cur.Value $Type $new)) {
        Write-Log "Unchanged $label = $(Format-IMRegValue $Type $new)"
        return 'Unchanged'
    }
    $was = if ($cur.ValueExists) { Format-IMRegValue $cur.Type $cur.Value } else { '<absent>' }
    if ($script:State.WhatIf -or -not $PSCmdlet.ShouldProcess($label, "Set $Type $(Format-IMRegValue $Type $new)")) {
        Write-Log "WhatIf: would set $label : $was -> $Type $(Format-IMRegValue $Type $new)"
        return 'Planned'
    }
    Invoke-IMRegChange -Module $Module -Target $t -Name $Name -NewType $Type -NewValue $new -Current $cur -Description $Description
}

function Remove-TrackedRegistryValue {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Module,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name,
        [string]$Description
    )
    Assert-EngineReady
    $t = Resolve-IMRegTarget $Path
    $label = "$($t.Display)\$Name"
    $block = Get-IMRegWriteBlock $t
    if ($block) { Write-Log "Skipped ${label}: $block" Warn; return 'Skipped' }
    $cur = Get-IMRegState $t $Name
    if (-not $cur.ValueExists) { Write-Log "Unchanged $label (absent)"; return 'Unchanged' }
    if ($script:RegTypes -notcontains $cur.Type) { Write-Log "Skipped ${label}: unsupported type $($cur.Type)" Fail; return 'Failed' }
    if ($script:State.WhatIf -or -not $PSCmdlet.ShouldProcess($label, 'Delete value')) {
        Write-Log "WhatIf: would delete $label (now $(Format-IMRegValue $cur.Type $cur.Value))"
        return 'Planned'
    }
    Invoke-IMRegChange -Module $Module -Target $t -Name $Name -NewType $null -NewValue $null -Current $cur -Description $Description
}

# ---------------------------------------------------------------- tracked actions

function Invoke-TrackedAction {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Module,
        [Parameter(Mandatory = $true)][ValidateSet('power', 'language', 'appx', 'win32', 'system')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Capture,
        [Parameter(Mandatory = $true)][scriptblock]$Apply,
        [scriptblock]$Restore,
        [scriptblock]$Test,          # param($old): $true when already in the desired state
        [string]$Key,                # identity: a second run keeps the original Old
        [string]$RestoreHint
    )
    Assert-EngineReady
    if ($Restore -and -not $script:State.Handlers.ContainsKey($Kind)) { Register-TrackedActionHandler -Kind $Kind -Capture $Capture -Restore $Restore }
    $revertible = ($script:NonRevertibleKinds -notcontains $Kind)
    try { $old = & $Capture } catch { Write-Log "Cannot capture state for '$Description': $($_.Exception.Message)" Fail; return 'Failed' }
    if ($Test -and (& $Test $old)) { Write-Log "Unchanged: $Description"; return 'Unchanged' }
    if ($script:State.WhatIf -or -not $PSCmdlet.ShouldProcess($Description, $Kind)) {
        Write-Log "WhatIf: would $Description"
        return 'Planned'
    }
    $existing = $null
    if ($Key) {
        foreach ($e in $script:State.Journal) {
            if ($e.Kind -eq $Kind -and $e.Module -eq $Module -and $e.Key -eq $Key -and [bool]$e.Sandbox -eq $script:State.Sandbox) { $existing = $e; break }
        }
    }
    if ($existing) {
        $entry = $existing
        $entry.Time = (Get-Date).ToString('o')
    } else {
        $entry = [pscustomobject][ordered]@{
            Id = [guid]::NewGuid().ToString(); Time = (Get-Date).ToString('o'); Module = $Module; Kind = $Kind
            Path = $null; Name = $null; ExistedBefore = $null; OldValue = $null; OldType = $null; NewValue = $null; NewType = $null
            Old = $old; New = $null; Key = $Key; KeyExistedBefore = $null; CreatedKeys = $null
            Description = $Description; RestoreHint = $RestoreHint; Revertible = $revertible
            UserSid = $script:State.UserSid; Sandbox = $script:State.Sandbox
        }
        [void]$script:State.Journal.Add($entry)
    }
    Save-IMJournal
    try {
        if ($script:State.Sandbox) { Write-Log "Sandbox: would apply: $Description" }
        else { [void](& $Apply $old) }
    } catch {
        $err = $_.Exception.Message
        if (-not $existing) {
            if ($revertible) {
                # Keep the entry when the failure may have left a partial change; the revert path restores Old.
                try { $now = & $Capture } catch { $now = $null }
                if ($null -ne $now -and (ConvertTo-IMStateJson $now) -eq (ConvertTo-IMStateJson $old)) { $script:State.Journal.Remove($entry) }
                else { $entry.New = $now }
            } else { $script:State.Journal.Remove($entry) }
            Save-IMJournal
        }
        Write-Log "Failed: ${Description}: $err" Fail
        return 'Failed'
    }
    if ($revertible) {
        try { $entry.New = & $Capture } catch { $entry.New = $null }
    }
    Save-IMJournal
    Write-Log "Done: $Description" Ok
    return 'Changed'
}

# ---------------------------------------------------------------- revert

function Invoke-IMRegRevert {
    param($Entry, [bool]$Force)
    $t = Resolve-IMRegTarget $Entry.Path
    $label = "$($t.Display)\$($Entry.Name)"
    $cur = Get-IMRegState $t $Entry.Name
    if ($Entry.NewType) {
        $isSame = $cur.ValueExists -and ($script:RegTypes -contains $cur.Type) -and (Test-IMRegEqual $cur.Type $cur.Value $Entry.NewType $Entry.NewValue)
    } else {
        $isSame = -not $cur.ValueExists
    }
    if (-not $isSame) {
        $now = if ($cur.ValueExists) { "$($cur.Type) $(Format-IMRegValue $cur.Type $cur.Value)" } else { '<absent>' }
        if (-not $Force) {
            Write-Log "Skipped $label : changed since (now $now, expected $(Format-IMRegValue $Entry.NewType $Entry.NewValue)); use -Force to restore anyway" Warn
            return 'Skipped'
        }
        Write-Log "$label changed since (now $now); restoring anyway (-Force)" Warn
    }
    $target = if ($Entry.ExistedBefore) { "$($Entry.OldType) $(Format-IMRegValue $Entry.OldType $Entry.OldValue)" } else { '<deleted>' }
    if ($script:State.WhatIf) { Write-Log "WhatIf: would restore $label -> $target"; return 'Planned' }
    if ($Entry.ExistedBefore) { Write-IMRegValue $t $Entry.Name $Entry.OldType $Entry.OldValue }
    else { Remove-IMRegValueRaw $t $Entry.Name }
    Write-Log "Restored $label -> $target" Ok
    $created = @($Entry.CreatedKeys | Where-Object { $_ }) | Sort-Object { $_.Length } -Descending
    $prefix = if ($script:State.Sandbox) { '[sandbox] ' } else { '' }
    foreach ($k in $created) {
        $r = Remove-IMRegKeyIfEmpty $k
        if ($r -eq 'Deleted') { Write-Log "  removed empty key $prefix$k (created by InstallMedia)" }
        elseif ($r -eq 'NotEmpty') {
            # Still holds other values: hand the key to the remaining entries under it, so the
            # last of them deletes it once it is empty.
            foreach ($o in $script:State.Journal) {
                if ([object]::ReferenceEquals($o, $Entry) -or $o.Kind -ne 'registry' -or [bool]$o.Sandbox -ne $script:State.Sandbox) { continue }
                if ($o.Path -ne $k -and -not ("$($o.Path)".StartsWith("$k\", [System.StringComparison]::OrdinalIgnoreCase))) { continue }
                $ck = @($o.CreatedKeys | Where-Object { $_ })
                if ($ck -notcontains $k) { $o.CreatedKeys = [string[]]($ck + $k) }
            }
        }
    }
    return 'Reverted'
}

function Invoke-IMActionRevert {
    param($Entry, [bool]$Force)
    $h = $script:State.Handlers[$Entry.Kind]
    if (-not $h -or -not $h.Restore) { Write-Log "Skipped '$($Entry.Description)': no restore handler for kind '$($Entry.Kind)' is loaded" Warn; return 'Skipped' }
    if ($h.Capture -and $null -ne $Entry.New) {
        $now = & $h.Capture
        if ((ConvertTo-IMStateJson $now) -ne (ConvertTo-IMStateJson $Entry.New)) {
            if (-not $Force) {
                Write-Log "Skipped '$($Entry.Description)': changed since; use -Force to restore anyway" Warn
                Write-Log "  now:      $(ConvertTo-IMStateJson $now)"
                Write-Log "  expected: $(ConvertTo-IMStateJson $Entry.New)"
                return 'Skipped'
            }
            Write-Log "'$($Entry.Description)' changed since; restoring anyway (-Force)" Warn
        }
    }
    if ($script:State.WhatIf) { Write-Log "WhatIf: would restore: $($Entry.Description)"; return 'Planned' }
    if ($script:State.Sandbox) { Write-Log "Sandbox: would restore: $($Entry.Description) -> $(ConvertTo-IMStateJson $Entry.Old)" }
    else { [void](& $h.Restore $Entry.Old) }
    Write-Log "Restored: $($Entry.Description)" Ok
    return 'Reverted'
}

function Invoke-Revert {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string[]]$Module, [switch]$Force)
    Assert-EngineReady
    $summary = [pscustomobject]@{ Reverted = 0; Skipped = 0; Failed = 0; NotRevertible = 0; Planned = 0; Modules = @{} }
    $entries = @($script:State.Journal)
    [array]::Reverse($entries)
    if ($Module -and $Module.Count -gt 0) { $entries = @($entries | Where-Object { $Module -contains $_.Module }) }
    if ($entries.Count -eq 0) { Write-Log 'Nothing to revert (journal has no matching entries).' }
    foreach ($e in $entries) {
        $what = if ($e.Kind -eq 'registry') { "$($e.Path)\$($e.Name)" } else { $e.Description }
        if ([bool]$e.Sandbox -ne $script:State.Sandbox) { Write-Log "Skipped $what : entry belongs to the other mode (sandbox/live)" Warn; $summary.Skipped++; continue }
        if (-not $e.Revertible) {
            $hint = if ($e.RestoreHint) { $e.RestoreHint } else { 'use the restore point' }
            Write-Log "Not revertible: $what - to restore: $hint" Warn
            $summary.NotRevertible++
            continue
        }
        $isUserScoped = ($e.Kind -eq 'language') -or ($e.Kind -eq 'registry' -and "$($e.Path)" -like 'HKCU:*')
        if ($isUserScoped -and $e.UserSid -and $e.UserSid -ne $script:State.UserSid) {
            Write-Log "Skipped $what : recorded for user $($e.UserSid), current user is $($script:State.UserSid)" Warn
            $summary.Skipped++; continue
        }
        if ($isUserScoped -and -not $script:State.HkcuAllowed) {
            Write-Log "Skipped $what : HKCU work is blocked for this process" Warn
            $summary.Skipped++; continue
        }
        try {
            if ($e.Kind -eq 'registry') { $r = Invoke-IMRegRevert -Entry $e -Force ([bool]$Force) }
            else { $r = Invoke-IMActionRevert -Entry $e -Force ([bool]$Force) }
        } catch {
            Write-Log "Failed to revert ${what}: $($_.Exception.Message)" Fail
            $r = 'Failed'
        }
        switch ($r) {
            'Reverted' {
                $summary.Reverted++
                $script:State.Journal.Remove($e)
                Save-IMJournal
                if (-not $summary.Modules.ContainsKey($e.Module)) { $summary.Modules[$e.Module] = 0 }
                $summary.Modules[$e.Module]++
            }
            'Planned' { $summary.Planned++ }
            'Skipped' { $summary.Skipped++ }
            default { $summary.Failed++ }
        }
    }
    if (-not $script:State.WhatIf) { Remove-IMSandboxRootIfEmpty }
    return $summary
}

Export-ModuleMember -Function Write-Log, Write-IMTextFile, Invoke-IMNative, Test-IMIsAdmin, Get-IMCurrentUser,
Get-IMInteractiveUser, ConvertFrom-IMDataText, Merge-IMHashtable, ConvertTo-IMStateJson, New-ModuleResult,
Add-ModuleResultStatus, Initialize-Engine, Get-EngineState, Get-EngineJournal, Copy-EngineJournal,
Register-TrackedActionHandler, Read-IMRegistryValue, Set-TrackedRegistryValue, Remove-TrackedRegistryValue,
Invoke-TrackedAction, Invoke-Revert, Test-IMRegEqual, ConvertTo-IMRegNative
