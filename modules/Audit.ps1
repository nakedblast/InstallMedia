# Audit: read-only hardware/OS report compared with the profile's Expected values.
# Every probe is isolated: a failed probe is reported as "unavailable" and never aborts the audit.

function Invoke-IMProbe {
    param([string]$Name, [scriptblock]$Script)
    try { $v = & $Script; return , $v }
    catch {
        Write-Log "Audit: $Name unavailable ($($_.Exception.Message))" Warn
        return 'unavailable'
    }
}

function Get-IMTouchInfo {
    if (-not ('InstallMedia.NativeMetrics' -as [type])) {
        Add-Type -Namespace InstallMedia -Name NativeMetrics -MemberDefinition '[DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);'
    }
    $digitizer = [InstallMedia.NativeMetrics]::GetSystemMetrics(94)   # SM_DIGITIZER
    $maxTouches = [InstallMedia.NativeMetrics]::GetSystemMetrics(95)  # SM_MAXIMUMTOUCHES
    [ordered]@{
        Present        = [bool](($digitizer -band 0x01) -or ($digitizer -band 0x02))
        Ready          = [bool]($digitizer -band 0x80)
        MaximumTouches = $maxTouches
    }
}

function Get-IMBatteryInfo {
    param([string]$OutputDir)
    $html = Join-Path $OutputDir 'battery-report.html'
    $xml = Join-Path $OutputDir 'battery-report.xml'
    $r1 = Invoke-IMNative 'powercfg.exe' @('/batteryreport', '/output', $html)
    $r2 = Invoke-IMNative 'powercfg.exe' @('/batteryreport', '/xml', '/output', $xml)
    $info = [ordered]@{
        ReportHtml = $(if (Test-Path -LiteralPath $html) { 'battery-report.html' } else { "not created (exit $($r1.ExitCode))" })
        Batteries  = @()
    }
    if (-not (Test-Path -LiteralPath $xml)) { $info.Note = "battery XML not created (exit $($r2.ExitCode))"; return $info }
    [xml]$doc = [System.IO.File]::ReadAllText($xml)
    $list = @()
    $bats = @()
    if ($doc.BatteryReport.Batteries) { $bats = @($doc.BatteryReport.Batteries.Battery) }
    foreach ($b in $bats) {
        if ($null -eq $b) { continue }
        $design = [double]$b.DesignCapacity
        $full = [double]$b.FullChargeCapacity
        $health = if ($design -gt 0) { [math]::Round(100 * $full / $design, 1) } else { $null }
        $list += [ordered]@{
            Id                    = [string]$b.Id
            Manufacturer          = [string]$b.Manufacturer
            Chemistry             = [string]$b.Chemistry
            DesignCapacityWh      = [math]::Round($design / 1000, 1)
            FullChargeCapacityWh  = [math]::Round($full / 1000, 1)
            HealthPercent         = $health
            CycleCount            = $(if ("$($b.CycleCount)" -match '^\d+$') { [int]$b.CycleCount } else { $null })
        }
    }
    $info.Batteries = $list
    if ($list.Count -eq 0) { $info.Note = 'no battery reported' }
    return $info
}

function Get-IMEventSummary {
    param([datetime]$Since)
    $defs = @(
        @{ Label = 'WHEA-Logger'; Filter = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger' } },
        @{ Label = 'Kernel-Power 41'; Filter = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41 } },
        @{ Label = 'BugCheck 1001'; Filter = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } }
    )
    $out = [ordered]@{}
    foreach ($d in $defs) {
        $f = $d.Filter.Clone()
        $f.StartTime = $Since
        try {
            $ev = @(Get-WinEvent -FilterHashtable $f -ErrorAction Stop)
        } catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.Exception.Message -like '*No events were found*') { $ev = @() }
            else { $out[$d.Label] = "unavailable ($($_.Exception.Message))"; continue }
        }
        $out[$d.Label] = [ordered]@{
            Count  = $ev.Count
            Recent = @($ev | Select-Object -First 5 | ForEach-Object { '{0:yyyy-MM-dd HH:mm} id {1}' -f $_.TimeCreated, $_.Id })
        }
    }
    return $out
}

function Test-IMExpected {
    # Returns a check row: Item, Expected, Actual, Status (PASS/WARN/FAIL).
    param([string]$Item, [string]$Expected, $Actual, [bool]$Pass, [bool]$Critical, [string]$Detail)
    $status = if ($null -eq $Actual -or "$Actual" -eq 'unavailable' -or "$Actual" -like 'needs admin*') {
        'WARN'
    } elseif ($Pass) { 'PASS' } elseif ($Critical) { 'FAIL' } else { 'WARN' }
    [ordered]@{ Item = $Item; Expected = $Expected; Actual = "$Actual"; Status = $status; Detail = $Detail }
}

function Test-IMWithinPercent {
    param([double]$Value, [double]$Target, [double]$Percent)
    [math]::Abs($Value - $Target) -le ($Target * $Percent / 100)
}

function ConvertTo-IMMarkdownValue {
    param($Value, [int]$Indent = 0)
    $pad = '  ' * $Indent
    $lines = New-Object System.Collections.ArrayList
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) {
            $v = $Value[$k]
            if ($v -is [System.Collections.IDictionary] -or ($v -is [array] -and $v.Count -gt 0 -and -not ($v[0] -is [string] -or $v[0] -is [ValueType]))) {
                [void]$lines.Add("$pad- **$k**:")
                foreach ($l in (ConvertTo-IMMarkdownValue $v ($Indent + 1))) { [void]$lines.Add($l) }
            } elseif ($v -is [array]) {
                [void]$lines.Add("$pad- **$k**: " + $(if ($v.Count) { ($v -join '; ') } else { '(none)' }))
            } else {
                [void]$lines.Add("$pad- **$k**: $v")
            }
        }
    } elseif ($Value -is [array]) {
        $i = 0
        foreach ($item in $Value) {
            $i++
            if ($item -is [System.Collections.IDictionary]) {
                [void]$lines.Add("$pad- #${i}:")
                foreach ($l in (ConvertTo-IMMarkdownValue $item ($Indent + 1))) { [void]$lines.Add($l) }
            } else { [void]$lines.Add("$pad- $item") }
        }
        if ($i -eq 0) { [void]$lines.Add("$pad- (none)") }
    } else {
        [void]$lines.Add("$pad- $Value")
    }
    return , @($lines)
}

function Invoke-AuditModule {
    param([hashtable]$Profile, [hashtable]$Context)
    $res = New-ModuleResult 'Audit'
    $isAdmin = [bool]$Context.IsAdmin
    $needsAdmin = 'needs admin'
    $outDir = $Context.OutputDir
    $r = [ordered]@{}
    $r.Generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $r.Profile = $Context.ProfileName
    $r.RunAsAdmin = $isAdmin

    Write-Log 'Audit: collecting system information (read-only)...'

    $r.System = Invoke-IMProbe 'system' {
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        [ordered]@{
            Manufacturer = [string]$cs.Manufacturer
            Model        = [string]$cs.Model
            SystemFamily = [string]$cs.SystemFamily
            SerialNumber = [string]$bios.SerialNumber
            BiosVersion  = [string]$bios.SMBIOSBIOSVersion
            BiosDate     = $(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { '' })
        }
    }

    $r.Windows = Invoke-IMProbe 'windows' {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        [ordered]@{
            Edition        = [string]$os.Caption
            EditionId      = [string]$cv.EditionID
            DisplayVersion = [string]$cv.DisplayVersion
            Build          = '{0}.{1}' -f $os.BuildNumber, $cv.UBR
            Architecture   = [string]$env:PROCESSOR_ARCHITECTURE
            InstallDate    = $(if ($os.InstallDate) { $os.InstallDate.ToString('yyyy-MM-dd') } else { '' })
        }
    }

    $r.Activation = Invoke-IMProbe 'activation' {
        $p = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL")
        if ($p.Count -eq 0) { return [ordered]@{ Activated = $false; Detail = 'no Windows license with a product key found' } }
        $lic = $p | Where-Object { $_.LicenseStatus -eq 1 } | Select-Object -First 1
        if (-not $lic) { $lic = $p[0] }
        $names = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OOB grace'; 3 = 'OOT grace'; 4 = 'Non-genuine grace'; 5 = 'Notification'; 6 = 'Extended grace' }
        [ordered]@{
            Activated     = ($lic.LicenseStatus -eq 1)
            LicenseStatus = $names[[int]$lic.LicenseStatus]
            Channel       = [string]$lic.Description
        }
    }

    $r.Cpu = Invoke-IMProbe 'cpu' {
        $c = @(Get-CimInstance Win32_Processor)
        [ordered]@{
            Name              = ([string]$c[0].Name).Trim()
            Cores             = ($c | Measure-Object NumberOfCores -Sum).Sum
            LogicalProcessors = ($c | Measure-Object NumberOfLogicalProcessors -Sum).Sum
            MaxClockMHz       = $c[0].MaxClockSpeed
        }
    }

    $r.Memory = Invoke-IMProbe 'memory' {
        $m = @(Get-CimInstance Win32_PhysicalMemory)
        $cs = Get-CimInstance Win32_ComputerSystem
        $total = ($m | Measure-Object Capacity -Sum).Sum
        [ordered]@{
            InstalledGB        = $(if ($total) { [math]::Round($total / 1GB, 1) } else { $null })
            VisibleToWindowsGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            Modules            = $m.Count
            SpeedMTs           = (@($m | ForEach-Object { $_.Speed } | Where-Object { $_ }) | Select-Object -Unique) -join ', '
            ConfiguredSpeedMTs = (@($m | ForEach-Object { $_.ConfiguredClockSpeed } | Where-Object { $_ }) | Select-Object -Unique) -join ', '
            Manufacturer       = (@($m | ForEach-Object { ([string]$_.Manufacturer).Trim() } | Where-Object { $_ }) | Select-Object -Unique) -join ', '
            PartNumber         = (@($m | ForEach-Object { ([string]$_.PartNumber).Trim() } | Where-Object { $_ }) | Select-Object -Unique) -join ', '
        }
    }

    $r.Disks = Invoke-IMProbe 'disks' {
        $list = @()
        foreach ($d in @(Get-PhysicalDisk)) {
            $item = [ordered]@{
                Model       = ([string]$d.FriendlyName).Trim()
                SizeGB      = [math]::Round($d.Size / 1e9, 1)
                BusType     = [string]$d.BusType
                MediaType   = [string]$d.MediaType
                Health      = [string]$d.HealthStatus
                Operational = ([string[]]$d.OperationalStatus) -join ', '
            }
            if ($isAdmin) {
                try {
                    $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
                    $item.WearPercent = $rc.Wear
                    $item.TemperatureC = $rc.Temperature
                    $item.PowerOnHours = $rc.PowerOnHours
                    $item.ReadErrorsTotal = $rc.ReadErrorsTotal
                    $item.WriteErrorsTotal = $rc.WriteErrorsTotal
                } catch { $item.Reliability = "unavailable ($($_.Exception.Message))" }
            } else {
                $item.Reliability = $needsAdmin
            }
            $list += $item
        }
        , $list
    }

    $r.Battery = Invoke-IMProbe 'battery' { Get-IMBatteryInfo -OutputDir $outDir }

    $r.Display = Invoke-IMProbe 'display' {
        $vc = @(Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution })
        $d = [ordered]@{
            Resolution    = $(if ($vc.Count) { '{0}x{1}' -f $vc[0].CurrentHorizontalResolution, $vc[0].CurrentVerticalResolution } else { 'unavailable' })
            RefreshRateHz = $(if ($vc.Count) { $vc[0].CurrentRefreshRate } else { $null })
        }
        try {
            $mons = @(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorID -ErrorAction Stop)
            $d.Panels = @($mons | ForEach-Object {
                    $dec = { param($a) (-join ($a | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ })).Trim() }
                    '{0} {1} ({2})' -f (& $dec $_.ManufacturerName), (& $dec $_.UserFriendlyName), (& $dec $_.ProductCodeID)
                })
        } catch {
            $d.Panels = $(if ($isAdmin) { "unavailable ($($_.Exception.Message))" } else { $needsAdmin })
        }
        $d
    }

    $r.Gpu = Invoke-IMProbe 'gpu' {
        , @(Get-CimInstance Win32_VideoController | ForEach-Object {
                [ordered]@{
                    Name          = [string]$_.Name
                    DriverVersion = [string]$_.DriverVersion
                    DriverDate    = $(if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { '' })
                }
            })
    }

    $r.WiFi = Invoke-IMProbe 'wifi' {
        , @(Get-NetAdapter -Physical -ErrorAction Stop |
                Where-Object { $_.NdisPhysicalMedium -eq 9 -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|802\.11|WLAN' } |
                ForEach-Object { [ordered]@{ Adapter = [string]$_.InterfaceDescription; Driver = [string]$_.DriverVersion; Status = [string]$_.Status } })
    }

    $r.Devices = Invoke-IMProbe 'devices' {
        $cams = @(Get-PnpDevice -PresentOnly -Class Camera, Image -ErrorAction SilentlyContinue | ForEach-Object { '{0} [{1}]' -f $_.FriendlyName, $_.Status })
        $audio = @(Get-PnpDevice -PresentOnly -Class AudioEndpoint -ErrorAction SilentlyContinue | ForEach-Object { '{0} [{1}]' -f $_.FriendlyName, $_.Status })
        [ordered]@{ Cameras = $cams; AudioEndpoints = $audio }
    }

    $r.Touch = Invoke-IMProbe 'touch' { Get-IMTouchInfo }

    $r.Security = Invoke-IMProbe 'security' {
        $s = [ordered]@{}
        $sb = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue
        $s.SecureBoot = if ($null -eq $sb) { 'not supported (legacy BIOS?)' } elseif ($sb.UEFISecureBootEnabled -eq 1) { 'on' } else { 'off' }
        if ($isAdmin) {
            try {
                $t = Get-Tpm -ErrorAction Stop
                $spec = (Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue).SpecVersion
                $s.Tpm = 'present={0} ready={1} spec={2}' -f $t.TpmPresent, $t.TpmReady, (([string]$spec) -split ',')[0]
            } catch { $s.Tpm = "unavailable ($($_.Exception.Message))" }
            try {
                $v = Get-CimInstance -Namespace root/cimv2/Security/MicrosoftVolumeEncryption -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$($env:SystemDrive)'" -ErrorAction Stop
                $ps = @{ 0 = 'off'; 1 = 'on'; 2 = 'unknown' }[[int]$v.ProtectionStatus]
                $cs = @{ 0 = 'fully decrypted'; 1 = 'fully encrypted'; 2 = 'encrypting'; 3 = 'decrypting'; 4 = 'encryption paused'; 5 = 'decryption paused' }[[int]$v.ConversionStatus]
                $s.Encryption = "protection $ps, $cs"
            } catch { $s.Encryption = "unavailable ($($_.Exception.Message))" }
        } else {
            $s.Tpm = $needsAdmin
            try {
                $shell = New-Object -ComObject Shell.Application
                $val = $shell.NameSpace(17).ParseName($env:SystemDrive).ExtendedProperty('System.Volume.BitLockerProtection')
                $map = @{ 1 = 'on'; 2 = 'off'; 3 = 'encrypting'; 4 = 'decrypting'; 5 = 'suspended'; 6 = 'on (locked)' }
                $s.Encryption = if ($null -ne $val -and $map.ContainsKey([int]$val)) { "$($map[[int]$val]) (shell; details need admin)" } elseif ($null -ne $val) { "unknown (shell value $val; details need admin)" } else { $needsAdmin }
            } catch { $s.Encryption = $needsAdmin }
        }
        $s
    }

    $r.ProblemDevices = Invoke-IMProbe 'pnp' {
        , @(Get-PnpDevice -PresentOnly -ErrorAction Stop |
                Where-Object { 'Error', 'Degraded', 'Unknown' -contains [string]$_.Status } |
                ForEach-Object { '{0} [{1}, class {2}, problem {3}]' -f $_.FriendlyName, $_.Status, $_.Class, $_.Problem })
    }

    $r.Events14Days = Invoke-IMProbe 'events' { Get-IMEventSummary -Since (Get-Date).AddDays(-14) }

    # ------------------------------------------------ compare with Expected
    $checks = New-Object System.Collections.ArrayList
    $exp = $Profile.Expected
    if ($exp) {
        $sys = $r.System
        $get = { param($obj, $name) if ($obj -is [System.Collections.IDictionary]) { $obj[$name] } else { 'unavailable' } }
        if ($exp.Model) {
            $m = & $get $sys 'Model'
            [void]$checks.Add((Test-IMExpected 'Model' $exp.Model $m ($m -like $exp.Model) $true))
        }
        if ($exp.Manufacturer) {
            $m = & $get $sys 'Manufacturer'
            [void]$checks.Add((Test-IMExpected 'Manufacturer' $exp.Manufacturer $m ($m -like $exp.Manufacturer) $false))
        }
        if ($exp.Cpu) {
            $c = & $get $r.Cpu 'Name'
            [void]$checks.Add((Test-IMExpected 'CPU' $exp.Cpu $c ($c -like $exp.Cpu) $true))
        }
        if ($exp.RamGB) {
            $g = & $get $r.Memory 'InstalledGB'
            if ($null -eq $g) { $g = & $get $r.Memory 'VisibleToWindowsGB' }
            $min = [double]$exp.RamGB - 1
            [void]$checks.Add((Test-IMExpected 'RAM (GB)' ">= $min" $g (($g -as [double]) -ge $min) $true))
        }
        if ($exp.DiskGB) {
            $disks = $r.Disks
            $size = $null
            if ($disks -is [array]) {
                $internal = @($disks | Where-Object { $_.BusType -ne 'USB' })
                if ($internal.Count) { $size = ($internal | ForEach-Object { $_.SizeGB } | Measure-Object -Maximum).Maximum }
            } else { $size = $disks }
            [void]$checks.Add((Test-IMExpected 'Disk (decimal GB)' "$($exp.DiskGB) +-5%" $size ($null -ne ($size -as [double]) -and (Test-IMWithinPercent $size $exp.DiskGB 5)) $true))
        }
        if ($exp.Edition) {
            $e = & $get $r.Windows 'Edition'
            [void]$checks.Add((Test-IMExpected 'Windows edition' $exp.Edition $e ($e -like $exp.Edition) $true))
        }
        if ($exp.BatteryDesignWh) {
            $wh = $null
            if ($r.Battery -is [System.Collections.IDictionary] -and @($r.Battery.Batteries).Count -gt 0) {
                $wh = (@($r.Battery.Batteries) | ForEach-Object { $_.DesignCapacityWh } | Measure-Object -Sum).Sum
            } elseif ($r.Battery -is [System.Collections.IDictionary]) { $wh = 'no battery' } else { $wh = $r.Battery }
            $ok = ($null -ne ($wh -as [double])) -and (Test-IMWithinPercent $wh $exp.BatteryDesignWh 5)
            [void]$checks.Add((Test-IMExpected 'Battery design (Wh)' "$($exp.BatteryDesignWh) +-5%" $wh $ok $false))
        }
        if ($exp.DisplayResolution) {
            $resolution = & $get $r.Display 'Resolution'
            [void]$checks.Add((Test-IMExpected 'Display resolution' $exp.DisplayResolution $resolution ($resolution -eq $exp.DisplayResolution) $false))
        }
        if ($null -ne $exp.Touch) {
            $t = & $get $r.Touch 'Present'
            [void]$checks.Add((Test-IMExpected 'Touch screen' "$($exp.Touch)" $t ("$t" -eq "$($exp.Touch)") $false))
        }
    }

    # ------------------------------------------------ findings independent of Expected
    $findings = New-Object System.Collections.ArrayList
    $act = $r.Activation
    if ($act -is [System.Collections.IDictionary]) {
        if ($act.Activated) { [void]$findings.Add([ordered]@{ Status = 'PASS'; Text = "Windows activated ($($act.Channel))" }) }
        else { [void]$findings.Add([ordered]@{ Status = 'WARN'; Text = "Windows not activated: $($act.LicenseStatus) $($act.Detail)" }) }
    }
    if ($r.Battery -is [System.Collections.IDictionary]) {
        foreach ($b in @($r.Battery.Batteries)) {
            if ($null -ne $b.CycleCount -and $b.CycleCount -gt 10) { [void]$findings.Add([ordered]@{ Status = 'WARN'; Text = "Battery cycle count $($b.CycleCount) is high for a new unit" }) }
            if ($null -ne $b.HealthPercent -and $b.HealthPercent -lt 95) { [void]$findings.Add([ordered]@{ Status = 'WARN'; Text = "Battery full-charge capacity is $($b.HealthPercent)% of design" }) }
        }
    }
    if ($r.Disks -is [array]) {
        foreach ($d in $r.Disks) {
            if ($d.Health -and $d.Health -ne 'Healthy') { [void]$findings.Add([ordered]@{ Status = 'FAIL'; Text = "Disk $($d.Model) health: $($d.Health)" }) }
            if ($d.Contains('ReadErrorsTotal') -and (($d.ReadErrorsTotal -gt 0) -or ($d.WriteErrorsTotal -gt 0))) { [void]$findings.Add([ordered]@{ Status = 'WARN'; Text = "Disk $($d.Model) has read/write errors" }) }
        }
    }
    if ($r.Security -is [System.Collections.IDictionary]) {
        if ("$($r.Security.Encryption)" -match '^(protection on|on|encrypting)') {
            [void]$findings.Add([ordered]@{ Status = 'WARN'; Text = 'Device encryption/BitLocker is on: back up the recovery key (Microsoft account: aka.ms/myrecoverykey)' })
        }
        if ($r.Security.SecureBoot -ne 'on') { [void]$findings.Add([ordered]@{ Status = 'WARN'; Text = "Secure Boot: $($r.Security.SecureBoot)" }) }
    }
    if ($r.ProblemDevices -is [array] -and $r.ProblemDevices.Count -gt 0) {
        [void]$findings.Add([ordered]@{ Status = 'WARN'; Text = "$($r.ProblemDevices.Count) device(s) with problems (see report)" })
    }
    if ($r.Events14Days -is [System.Collections.IDictionary]) {
        foreach ($k in $r.Events14Days.Keys) {
            $v = $r.Events14Days[$k]
            if ($v -is [System.Collections.IDictionary] -and $v.Count -gt 0 -and $v['Count'] -gt 0) {
                [void]$findings.Add([ordered]@{ Status = 'WARN'; Text = "$($v['Count']) '$k' event(s) in the last 14 days" })
            }
        }
    }
    $r.Checks = @($checks)
    $r.Findings = @($findings)

    # ------------------------------------------------ write report
    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("# InstallMedia audit: $env:COMPUTERNAME")
    [void]$md.AppendLine('')
    [void]$md.AppendLine("Generated $($r.Generated); profile $($r.Profile); admin: $isAdmin")
    [void]$md.AppendLine('')
    [void]$md.AppendLine('## Expected vs actual')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Status | Item | Expected | Actual |')
    [void]$md.AppendLine('|---|---|---|---|')
    foreach ($c in $checks) { [void]$md.AppendLine("| $($c.Status) | $($c.Item) | $($c.Expected) | $($c.Actual) |") }
    [void]$md.AppendLine('')
    [void]$md.AppendLine('## Findings')
    [void]$md.AppendLine('')
    if ($findings.Count -eq 0) { [void]$md.AppendLine('- none') }
    foreach ($f in $findings) { [void]$md.AppendLine("- $($f.Status): $($f.Text)") }
    foreach ($section in 'System', 'Windows', 'Activation', 'Cpu', 'Memory', 'Disks', 'Battery', 'Display', 'Gpu', 'WiFi', 'Devices', 'Touch', 'Security', 'ProblemDevices', 'Events14Days') {
        [void]$md.AppendLine('')
        [void]$md.AppendLine("## $section")
        [void]$md.AppendLine('')
        foreach ($l in (ConvertTo-IMMarkdownValue $r[$section])) { [void]$md.AppendLine($l) }
    }
    Write-IMTextFile -Path (Join-Path $outDir 'report.md') -Content $md.ToString()
    Write-IMTextFile -Path (Join-Path $outDir 'report.json') -Content (ConvertTo-Json -InputObject $r -Depth 8)

    # ------------------------------------------------ console summary
    foreach ($c in $checks) {
        $lvl = @{ PASS = 'Ok'; WARN = 'Warn'; FAIL = 'Fail' }[$c.Status]
        Write-Log ('{0,-20} expected {1,-22} actual {2}' -f $c.Item, $c.Expected, $c.Actual) $lvl
    }
    foreach ($f in $findings) {
        $lvl = @{ PASS = 'Ok'; WARN = 'Warn'; FAIL = 'Fail' }[$f.Status]
        Write-Log $f.Text $lvl
    }
    $pass = @($checks | Where-Object { $_.Status -eq 'PASS' }).Count
    $warn = @($checks | Where-Object { $_.Status -eq 'WARN' }).Count + @($findings | Where-Object { $_.Status -eq 'WARN' }).Count
    $fail = @($checks | Where-Object { $_.Status -eq 'FAIL' }).Count + @($findings | Where-Object { $_.Status -eq 'FAIL' }).Count
    Write-Log "Audit report: $(Join-Path $outDir 'report.md')"
    $res.Unchanged = 1
    [void]$res.Notes.Add("audit: $pass PASS, $warn WARN, $fail FAIL")
    $Context.AuditFailCount = $fail
    return $res
}
