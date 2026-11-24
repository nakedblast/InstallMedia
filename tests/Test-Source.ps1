<#
.SYNOPSIS
    Acceptance check 7: every .ps1/.psm1/.psd1 (and an optional bundle) is ASCII-only and parses
    with zero errors under Windows PowerShell 5.1.
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Source.ps1 [-Extra dist\bundle.ps1]
#>
param([string[]]$Extra = @())
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { '.ps1', '.psm1', '.psd1' -contains $_.Extension -and $_.FullName -notlike "$root\dist\*" -and $_.FullName -notlike "$root\.git\*" } |
        ForEach-Object { $_.FullName })
$files += @($Extra | Where-Object { $_ } | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
$bad = 0
Write-Host "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
    $bytes = [System.IO.File]::ReadAllBytes($f)
    $nonAscii = 0
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
    $ok = ($errors.Count -eq 0 -and $nonAscii -eq 0)
    if (-not $ok) { $bad++ }
    $rel = if ($f.StartsWith($root)) { $f.Substring($root.Length + 1) } else { $f }
    Write-Host ('{0}  {1,-45} parse errors {2}, non-ASCII bytes {3}' -f $(if ($ok) { 'pass' } else { 'FAIL' }), $rel, $errors.Count, $nonAscii)
    foreach ($e in $errors) { Write-Host "      line $($e.Extent.StartLineNumber): $($e.Message)" }
}
Write-Host "Files: $($files.Count), failing: $bad"
if ($bad) { exit 1 } else { exit 0 }
