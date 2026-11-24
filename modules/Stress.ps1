# Stress: optional CPU load test using built-in PowerShell only (one runspace per logical processor).

function Get-IMStressSample {
    param([datetime]$Start, [bool]$TryTemp)
    $pi = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
    $util = [double]$pi.PercentProcessorUtility
    $perf = [double]$pi.PercentProcessorPerformance
    $freq = [double]$pi.ProcessorFrequency
    $onAc = $null; $batPct = $null
    try {
        $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
        $onAc = ($ps.PowerLineStatus -ne 'Offline')
        $noBattery = ([int]$ps.BatteryChargeStatus -band 128) -ne 0
        if (-not $noBattery -and $ps.BatteryLifePercent -le 1) { $batPct = [math]::Round($ps.BatteryLifePercent * 100) }
    } catch { }
    $temp = $null
    if ($TryTemp) {
        try {
            $tz = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
            if ($tz.Count) { $temp = [math]::Round(($tz | ForEach-Object { $_.CurrentTemperature / 10 - 273.15 } | Measure-Object -Maximum).Maximum, 1) }
        } catch { $temp = 'unsupported' }
    }
    [pscustomobject]@{
        Time           = (Get-Date).ToString('HH:mm:ss')
        ElapsedSec     = [math]::Round(((Get-Date) - $Start).TotalSeconds)
        UtilityPct     = [math]::Round($util, 1)
        PerformancePct = [math]::Round($perf, 1)
        FrequencyMHz   = $freq
        EffectiveMHz   = [math]::Round($freq * $perf / 100)
        OnAC           = $onAc
        BatteryPct     = $batPct
        TempC          = $temp
    }
}

function Get-IMStressEvents {
    param([datetime]$Since)
    $found = New-Object System.Collections.ArrayList
    $filters = @(
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $Since },
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Level = 1, 2; StartTime = $Since },
        @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $Since }
    )
    foreach ($f in $filters) {
        try { foreach ($e in @(Get-WinEvent -FilterHashtable $f -ErrorAction Stop)) { [void]$found.Add(('{0:HH:mm:ss} {1} id {2}' -f $e.TimeCreated, $e.ProviderName, $e.Id)) } }
        catch { }
    }
    , @($found)
}

function Invoke-StressModule {
    param([hashtable]$Profile, [hashtable]$Context)
    $res = New-ModuleResult 'Stress'
    $minutes = if ($Context.StressMinutes -gt 0) { [int]$Context.StressMinutes } else { 10 }
    $n = [Environment]::ProcessorCount
    if ($Context.WhatIf) {
        Write-Log "WhatIf: would run a $minutes-minute CPU load test on $n logical processors"
        Add-ModuleResultStatus $res 'Skipped'
        return $res
    }
    Add-Type -AssemblyName System.Windows.Forms
    try {
        if ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Offline') {
            Write-Log 'The laptop is on battery. Plug in the charger for a meaningful test.' Warn
            $a = Read-Host 'Type y to start the test anyway (after plugging in), anything else to skip'
            if ($a -notmatch '^(y|yes)$') { Add-ModuleResultStatus $res 'Skipped' 'stress test skipped (on battery)'; return $res }
        }
    } catch { }

    $csv = Join-Path $Context.OutputDir 'stress.csv'
    $samples = New-Object System.Collections.ArrayList
    $sync = [hashtable]::Synchronized(@{ Stop = $false })
    $worker = {
        param($sync)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $buf = New-Object byte[] 1048576
        $count = 0
        while (-not $sync.Stop) { [void]$sha.ComputeHash($buf); $count++ }
        $sha.Dispose()
        $count
    }
    $baseline = @(Get-Runspace | Where-Object { $_.RunspaceStateInfo.State -eq 'Opened' }).Count
    $start = Get-Date
    $end = $start.AddMinutes($minutes)
    $tryTemp = $true
    $completed = $false
    $pool = $null
    $jobs = New-Object System.Collections.ArrayList
    Write-Log "Stress: $n worker(s) for $minutes minute(s); sampling every 5 s. Ctrl+C stops early."
    try {
        $pool = [runspacefactory]::CreateRunspacePool(1, $n)
        $pool.Open()
        for ($i = 0; $i -lt $n; $i++) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($worker).AddArgument($sync)
            [void]$jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }
        $lastReport = $start
        while ((Get-Date) -lt $end) {
            Start-Sleep -Seconds 5
            try {
                $s = Get-IMStressSample -Start $start -TryTemp $tryTemp
                if ($s.TempC -eq 'unsupported') { $tryTemp = $false; $s.TempC = $null }
                [void]$samples.Add($s)
            } catch { Write-Log "Sample failed: $($_.Exception.Message)" Warn }
            if (((Get-Date) - $lastReport).TotalSeconds -ge 60 -and $samples.Count) {
                $l = $samples[$samples.Count - 1]
                Write-Log ('  {0}s: utility {1}%, effective {2} MHz{3}' -f $l.ElapsedSec, $l.UtilityPct, $l.EffectiveMHz, $(if ($null -ne $l.TempC) { ", $($l.TempC) C" } else { '' }))
                $lastReport = Get-Date
            }
        }
        $completed = $true
    } finally {
        $sync.Stop = $true
        foreach ($j in $jobs) {
            try {
                if ($j.Handle.AsyncWaitHandle.WaitOne(10000)) { [void]$j.PS.EndInvoke($j.Handle) } else { $j.PS.Stop() }
            } catch { }
            $j.PS.Dispose()
        }
        if ($pool) { $pool.Close(); $pool.Dispose() }
        if ($samples.Count) {
            $lines = @($samples | ConvertTo-Csv -NoTypeInformation)
            Write-IMTextFile -Path $csv -Content (($lines -join "`r`n") + "`r`n")
        }
        Write-Log "Stress workers stopped; samples written to $csv"
    }

    $duration = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
    $total = if ($samples.Count) { $samples[$samples.Count - 1].ElapsedSec } else { 0 }
    $first = @($samples | Where-Object { $_.ElapsedSec -le 60 })
    $last = @($samples | Where-Object { $_.ElapsedSec -ge ($total - 60) })
    $mFirst = if ($first.Count) { ($first | Measure-Object EffectiveMHz -Average).Average } else { 0 }
    $mLast = if ($last.Count) { ($last | Measure-Object EffectiveMHz -Average).Average } else { 0 }
    $ratio = if ($mFirst -gt 0) { [math]::Round($mLast / $mFirst, 2) } else { $null }
    Write-Log ('Stress completed {0} of {1} min; mean effective clock first minute {2:N0} MHz, last minute {3:N0} MHz (ratio {4})' -f $duration, $minutes, $mFirst, $mLast, $ratio)
    if ($null -ne $ratio -and $ratio -lt 0.6) { Write-Log 'Heavy throttling: last-minute clock is below 60% of the first minute.' Warn; [void]$res.Notes.Add('heavy throttling') }

    $events = Get-IMStressEvents -Since $start
    if ($events.Count) {
        foreach ($e in $events) { Write-Log "Hardware/power error event: $e" Fail }
        Add-ModuleResultStatus $res 'Failed' "$($events.Count) error event(s) during the test"
    } else {
        Add-ModuleResultStatus $res 'Unchanged' ("completed {0} min, clock ratio {1}" -f $duration, $ratio)
    }

    Start-Sleep -Seconds 3
    $left = @(Get-Runspace | Where-Object { $_.RunspaceStateInfo.State -eq 'Opened' }).Count - $baseline
    try { $idle = (Get-IMStressSample -Start $start -TryTemp $false).UtilityPct } catch { $idle = 'unavailable' }
    Write-Log "After the test: CPU utility $idle%, leftover runspaces $left"
    if ($left -gt 0) { Write-Log 'Some worker runspaces are still open.' Warn; [void]$res.Notes.Add("leftover runspaces: $left") }
    if (-not $completed) { [void]$res.Notes.Add('stopped early') }
    Write-Log 'Ask the owner about fan noise and how hot the keyboard deck feels.'
    return $res
}
