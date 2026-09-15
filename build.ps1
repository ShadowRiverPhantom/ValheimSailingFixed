<#
.SYNOPSIS
    Adapts the released Sailing plugin to the current Valheim build and packages it.

.DESCRIPTION
    Sailing was last built before Valheim 1.0. The 1.0 update added a `bool log` parameter to
    Character.Message, so the released plugin calls a signature that no longer exists and throws
    MissingMethodException whenever it reports a sailing-skill message.

    This script takes the upstream Sailing.dll, rewrites those call sites (see
    src\fix-character-message.ps1), validates the result, and writes a drop-in replacement plus a
    Thunderstore / r2modman package into dist\.

    Mono.Cecil from the BepInEx core is the only tooling needed - no C# compiler, no .NET SDK.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -SourceDll "C:\Downloads\Sailing.dll" -Deploy
#>
[CmdletBinding()]
param(
    [string]$SourceDll,
    [string]$ValheimDir,
    [string]$BepInExCoreDir,
    [string]$OutputDir,
    [string]$Version,
    [switch]$Deploy,
    [switch]$NoPackage,
    [string]$ProfilePluginsDir
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $root 'dist' }
$assemblyName = 'Sailing'

if (-not $Version) {
    $manifestPath = Join-Path $root 'manifest.json'
    if (Test-Path $manifestPath) {
        $Version = (Get-Content -Path $manifestPath -Raw | ConvertFrom-Json).version_number
    }
    if (-not $Version) { $Version = '1.0.0' }
}

function Find-ValheimDir {
    param([string]$Explicit)

    if ($Explicit) {
        if (Test-Path (Join-Path $Explicit 'valheim_Data\Managed\assembly_valheim.dll')) { return $Explicit }
        throw "ValheimDir '$Explicit' does not look like a Valheim install."
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:VALHEIM_DIR) { $candidates.Add($env:VALHEIM_DIR) }

    $steamRoots = New-Object System.Collections.Generic.List[string]
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $item = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($item.SteamPath) { $steamRoots.Add($item.SteamPath) }
            if ($item.InstallPath) { $steamRoots.Add($item.InstallPath) }
        } catch { }
    }
    $steamRoots.Add('C:\Program Files (x86)\Steam')

    foreach ($steamRoot in $steamRoots) {
        if (-not $steamRoot) { continue }
        $steamRoot = $steamRoot -replace '/', '\'
        $candidates.Add((Join-Path $steamRoot 'steamapps\common\Valheim'))

        $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            $text = Get-Content -Path $vdf -Raw
            foreach ($match in [regex]::Matches($text, '"path"\s+"([^"]+)"')) {
                $library = $match.Groups[1].Value -replace '\\\\', '\'
                $candidates.Add((Join-Path $library 'steamapps\common\Valheim'))
            }
        }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'valheim_Data\Managed\assembly_valheim.dll'))) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw 'Valheim not found. Pass -ValheimDir "D:\...\Valheim" or set $env:VALHEIM_DIR.'
}

function Find-BepInExCore {
    param([string]$Valheim, [string]$Explicit)

    if ($Explicit) {
        if (Test-Path (Join-Path $Explicit 'BepInEx.dll')) { return (Resolve-Path $Explicit).Path }
        throw "BepInExCoreDir '$Explicit' does not contain BepInEx.dll."
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:BEPINEX_CORE_DIR) { $candidates.Add($env:BEPINEX_CORE_DIR) }
    $candidates.Add((Join-Path $Valheim 'BepInEx\core'))

    $profilesRoot = Join-Path $env:APPDATA 'r2modmanPlus-local\Valheim\profiles'
    if (Test-Path $profilesRoot) {
        $profiles = Get-ChildItem -Path $profilesRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property @{ Expression = { if ($_.Name -eq 'Default') { 0 } else { 1 } } }, Name
        foreach ($profile in $profiles) {
            $candidates.Add((Join-Path $profile.FullName 'BepInEx\core'))
        }
    }

    $cacheRoot = Join-Path $env:APPDATA 'r2modmanPlus-local\Valheim\cache'
    if (Test-Path $cacheRoot) {
        $pack = Get-ChildItem -Path $cacheRoot -Recurse -Filter 'BepInEx.dll' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($pack) { $candidates.Add($pack.DirectoryName) }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'BepInEx.dll'))) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw 'BepInEx core not found. Install BepInExPack_Valheim (r2modman) or pass -BepInExCoreDir.'
}

function Find-UpstreamDll {
    param([string]$Explicit, [string]$Name)

    if ($Explicit) {
        if (Test-Path $Explicit) { return (Resolve-Path $Explicit).Path }
        throw "Source plugin not found: $Explicit"
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $fromEnv = [Environment]::GetEnvironmentVariable('SAILING_SOURCE_DLL')
    if ($fromEnv) { $candidates.Add($fromEnv) }
    $candidates.Add((Join-Path $root "upstream\$Name.dll"))

    $cacheRoot = Join-Path $env:APPDATA 'r2modmanPlus-local\Valheim\cache'
    if (Test-Path $cacheRoot) {
        Get-ChildItem -Path $cacheRoot -Recurse -Filter "$Name.dll" -ErrorAction SilentlyContinue |
            Sort-Object -Property FullName -Descending |
            ForEach-Object { $candidates.Add($_.FullName) }
    }

    $downloads = Join-Path $env:USERPROFILE 'Downloads'
    if (Test-Path $downloads) {
        Get-ChildItem -Path $downloads -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$Name*" } |
            ForEach-Object { $candidates.Add((Join-Path $_.FullName "$Name.dll")) }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return (Resolve-Path $candidate).Path }
    }

    throw "The upstream $Name.dll was not found. Download the Sailing release, then either drop it in upstream\ or pass -SourceDll. See README.md."
}

# ---------------------------------------------------------------------------

$valheim = Find-ValheimDir -Explicit $ValheimDir
$bepInExCore = Find-BepInExCore -Valheim $valheim -Explicit $BepInExCoreDir
$source = Find-UpstreamDll -Explicit $SourceDll -Name $assemblyName

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
$outputDir = (Resolve-Path $OutputDir).Path
$outputDll = Join-Path $outputDir "$assemblyName.dll"

Write-Host "Valheim      : $valheim"
Write-Host "BepInEx core : $bepInExCore"
Write-Host "Upstream     : $source"
Write-Host "Source SHA256: $((Get-FileHash $source -Algorithm SHA256).Hash)"

if ([System.IO.Path]::GetFullPath($source) -eq [System.IO.Path]::GetFullPath($outputDll)) {
    throw 'The upstream plugin and the build output resolve to the same file.'
}

# ---------------------------------------------------------------------------
# 1. Adapt the plugin
# ---------------------------------------------------------------------------

Write-Host ''
& (Join-Path $root 'src\fix-character-message.ps1') `
    -SrcDll $source `
    -OutDll $outputDll `
    -ValheimDir $valheim `
    -BepInExCoreDir $bepInExCore

# ---------------------------------------------------------------------------
# 2. Validate the result
# ---------------------------------------------------------------------------

Write-Host ''
& (Join-Path $root 'tools\verify-refs.ps1') `
    -Assembly $outputDll `
    -ValheimDir $valheim `
    -BepInExCoreDir $bepInExCore
if ($LASTEXITCODE -ne 0) { throw 'Reference validation failed.' }

Write-Host ''
Write-Host "Built: $outputDll" -ForegroundColor Green
Write-Host "SHA256: $((Get-FileHash $outputDll -Algorithm SHA256).Hash)"

# ---------------------------------------------------------------------------
# 3. Thunderstore / r2modman package (import local mod -> pick the zip)
# ---------------------------------------------------------------------------

$packageRoot = Join-Path $outputDir 'package'
if (-not $NoPackage) {
    if (Test-Path $packageRoot) { Remove-Item -Path $packageRoot -Recurse -Force }
    $packagePlugins = Join-Path $packageRoot 'BepInEx\plugins'
    New-Item -ItemType Directory -Path $packagePlugins -Force | Out-Null

    Copy-Item -Path $outputDll -Destination (Join-Path $packagePlugins "$assemblyName.dll") -Force
    foreach ($extra in @('manifest.json', 'icon.png', 'README.md')) {
        $path = Join-Path $root $extra
        if (-not (Test-Path $path)) { continue }
        if ($extra -eq 'manifest.json') {
            # The package manifest must advertise the built version.
            $manifest = Get-Content -Path $path -Raw | ConvertFrom-Json
            $manifest.version_number = $Version
            $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $packageRoot $extra) -Encoding UTF8
        } else {
            Copy-Item -Path $path -Destination (Join-Path $packageRoot $extra) -Force
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $outputDir "$assemblyName-$Version.zip"
    if (Test-Path $zipPath) { Remove-Item -Path $zipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($packageRoot, $zipPath)
    Write-Host "Package: $zipPath" -ForegroundColor Green
}

if ($Deploy) {
    if (-not $ProfilePluginsDir) {
        $defaultProfile = Join-Path $env:APPDATA 'r2modmanPlus-local\Valheim\profiles\Default\BepInEx\plugins'
        if (Test-Path $defaultProfile) {
            $ProfilePluginsDir = $defaultProfile
        }
    }

    if (-not $ProfilePluginsDir) {
        Write-Warning 'Deploy skipped: no r2modman profile found, pass -ProfilePluginsDir.'
    } else {
        $target = Join-Path $ProfilePluginsDir "kagegawa-$assemblyName"
        if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target | Out-Null }
        Copy-Item -Path $outputDll -Destination $target -Force
        Write-Host "Deployed to: $target" -ForegroundColor Green
    }
}
