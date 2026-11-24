# Search: applies the profile's SearchTweaks through the engine (each change journaled).

function Invoke-SearchModule {
    param([hashtable]$Profile, [hashtable]$Context)
    $res = New-ModuleResult 'Search'
    $tweaks = @($Profile.SearchTweaks)
    if ($tweaks.Count -eq 0) { Add-ModuleResultStatus $res 'Skipped' 'no SearchTweaks in profile'; return $res }
    foreach ($tw in $tweaks) {
        $label = "$($tw.Path)\$($tw.Name)"
        if ($tw.ContainsKey('Apply') -and -not $tw.Apply) {
            Write-Log "Not applied: $label ($($tw.Verified))"
            Add-ModuleResultStatus $res 'Skipped'
            continue
        }
        if ($tw.SkipOnHome -and $Context.IsHome) {
            Write-Log "Skipped on Home edition (policy has no effect there): $label"
            Add-ModuleResultStatus $res 'Skipped'
            continue
        }
        $status = Set-TrackedRegistryValue -Module 'Search' -Path $tw.Path -Name $tw.Name -Value $tw.Value -Type $tw.Type -Description ("Search tweak: " + $tw.Note)
        Add-ModuleResultStatus $res $status
    }
    if ($res.Changed -gt 0) {
        $Context.NeedsExplorerRestart = $true
        [void]$res.Notes.Add('restart Explorer or sign out for search changes to apply')
    }
    return $res
}
