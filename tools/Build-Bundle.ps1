<#
.SYNOPSIS
    Builds one self-contained dist\InstallMedia-<profile>-<version>.ps1 for a profile.
.DESCRIPTION
    The bundle holds Setup.ps1's parameter block and main logic, the engine as a dynamic module,
    every module, and the profile chain (base first) embedded as here-strings that are parsed
    with the restricted data parser. It behaves like Setup.ps1 -Profile <name>.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Profile,
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

function Read-Text([string]$Path) { [System.IO.File]::ReadAllText($Path) }

$setup = Read-Text (Join-Path $root 'Setup.ps1')
if ($setup -notmatch "\`$InstallMediaVersion = '([^']+)'") { throw 'InstallMediaVersion not found in Setup.ps1' }
$version = $Matches[1]
$startMarker = '#region IM-LOADER'
$endMarker = '#endregion IM-LOADER'
$i = $setup.IndexOf($startMarker)
$j = $setup.IndexOf($endMarker)
if ($i -lt 0 -or $j -lt $i) { throw 'IM-LOADER region markers not found in Setup.ps1' }
$head = $setup.Substring(0, $i)
$tail = $setup.Substring($j + $endMarker.Length)

# Profile chain: the requested profile and everything it inherits from.
$profileDir = Join-Path $root 'profiles'
$profiles = [ordered]@{}
$name = $Profile
$seen = @()
while ($name) {
    if ($seen -contains $name) { throw "Profile inheritance loop at '$name'" }
    $seen += $name
    $path = Join-Path $profileDir "$name.psd1"
    if (-not (Test-Path -LiteralPath $path)) { throw "Profile not found: $path" }
    $text = Read-Text $path
    if ($text -match "(?m)^'@") { throw "Profile $name contains a line starting with '@ and cannot be embedded" }
    $profiles[$name] = $text
    $name = [string](Import-PowerShellDataFile -LiteralPath $path).Inherits
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("$startMarker (bundled: profile $Profile, version $version, built $(Get-Date -Format 'yyyy-MM-dd HH:mm'))")
[void]$sb.AppendLine('$script:IMProfileDir = $null')
[void]$sb.AppendLine('$script:IMEmbeddedProfiles = @{}')
foreach ($k in $profiles.Keys) {
    [void]$sb.AppendLine("`$script:IMEmbeddedProfiles['$k'] = @'")
    [void]$sb.AppendLine($profiles[$k].TrimEnd())
    [void]$sb.AppendLine("'@")
}
[void]$sb.AppendLine('$null = New-Module -Name InstallMediaEngine -ScriptBlock {')
[void]$sb.AppendLine((Read-Text (Join-Path $root 'lib\Engine.psm1')).TrimEnd())
[void]$sb.AppendLine('} | Import-Module -Force -DisableNameChecking')
foreach ($m in 'Audit', 'Search', 'Keyboard', 'Display', 'Bloat', 'Stress') {
    [void]$sb.AppendLine("# ---- module $m")
    [void]$sb.AppendLine((Read-Text (Join-Path $root "modules\$m.ps1")).TrimEnd())
}
[void]$sb.Append($endMarker)

$bundle = $head + $sb.ToString() + $tail
$bundle = ($bundle -replace "`r?`n", "`r`n")

$bad = [regex]::Matches($bundle, '[^\x00-\x7F]')
if ($bad.Count) { throw "Bundle contains $($bad.Count) non-ASCII character(s)" }

[void][System.IO.Directory]::CreateDirectory($OutDir)
$out = Join-Path $OutDir ("InstallMedia-{0}-{1}.ps1" -f $Profile, $version)
[System.IO.File]::WriteAllText($out, $bundle, [System.Text.Encoding]::ASCII)

$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($out, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Bundle does not parse: $($errors[0].Message) at line $($errors[0].Extent.StartLineNumber)" }

$hash = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
Write-Host "Bundle: $out"
Write-Host "Profiles embedded: $(@($profiles.Keys) -join ', ')"
Write-Host "Size: $((Get-Item -LiteralPath $out).Length) bytes"
Write-Host "SHA256: $hash"
