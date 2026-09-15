<#
.SYNOPSIS
    Points the four-parameter Character.Message call sites of a plugin at the five-parameter
    overload that Valheim 1.0 added.

.DESCRIPTION
    Valheim 1.0 changed

        Character.Message(MessageType, string, int, Sprite)

    to

        Character.Message(MessageType, string, int, Sprite, bool log)

    Any plugin built before 1.0 still references the old signature and throws
    MissingMethodException at runtime whenever it shows one of those messages.

    The fix is mechanical and does not need the plugin's source: insert `ldc.i4.0` (log = false,
    which is what every pre-1.0 call meant) and retarget the call to the new overload.

    Requires Mono.Cecil (ships with BepInEx) and the game's assembly_valheim.dll.

.PARAMETER SrcDll
    The plugin to patch, for example the released Sailing.dll.

.PARAMETER OutDll
    Where the patched plugin is written. Must not be the same file as SrcDll.

.PARAMETER ValheimDir
    Valheim install directory. Defaults to $env:VALHEIM_DIR.

.PARAMETER BepInExCoreDir
    BepInEx core directory that contains Mono.Cecil.dll. Defaults to $env:BEPINEX_CORE_DIR.

.EXAMPLE
    .\fix-character-message.ps1 -SrcDll .\upstream\Sailing.dll -OutDll .\dist\Sailing.dll
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SrcDll,
    [Parameter(Mandatory = $true)][string]$OutDll,
    [string]$ValheimDir,
    [string]$BepInExCoreDir
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SrcDll)) { throw "Source plugin not found: $SrcDll" }
if ([System.IO.Path]::GetFullPath($SrcDll) -eq [System.IO.Path]::GetFullPath($OutDll)) {
    throw 'OutDll must not be the same file as SrcDll.'
}

# ---------------------------------------------------------------------------
# Locate the game and BepInEx
# ---------------------------------------------------------------------------

function Find-Managed {
    param([string]$Explicit)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Explicit) { $candidates.Add((Join-Path $Explicit 'valheim_Data\Managed')) }
    if ($env:VALHEIM_DIR) { $candidates.Add((Join-Path $env:VALHEIM_DIR 'valheim_Data\Managed')) }
    $candidates.Add('C:\Program Files (x86)\Steam\steamapps\common\Valheim\valheim_Data\Managed')
    $candidates.Add('C:\Program Files\Steam\steamapps\common\Valheim\valheim_Data\Managed')

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'assembly_valheim.dll'))) {
            return (Resolve-Path $candidate).Path
        }
    }
    throw 'Valheim managed assemblies not found. Pass -ValheimDir or set $env:VALHEIM_DIR.'
}

function Find-Core {
    param([string]$Explicit)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Explicit) { $candidates.Add($Explicit) }
    if ($env:BEPINEX_CORE_DIR) { $candidates.Add($env:BEPINEX_CORE_DIR) }
    if ($env:VALHEIM_DIR) { $candidates.Add((Join-Path $env:VALHEIM_DIR 'BepInEx\core')) }
    $candidates.Add((Join-Path $env:APPDATA 'r2modmanPlus-local\Valheim\profiles\Default\BepInEx\core'))
    $candidates.Add('C:\Program Files (x86)\Steam\steamapps\common\Valheim\BepInEx\core')

    $cacheRoot = Join-Path $env:APPDATA 'r2modmanPlus-local\Valheim\cache'
    if (Test-Path $cacheRoot) {
        $pack = Get-ChildItem -Path $cacheRoot -Recurse -Filter 'Mono.Cecil.dll' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($pack) { $candidates.Add($pack.DirectoryName) }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path (Join-Path $candidate 'Mono.Cecil.dll'))) {
            return (Resolve-Path $candidate).Path
        }
    }
    throw 'BepInEx core not found. Install BepInExPack_Valheim or pass -BepInExCoreDir.'
}

$managed = Find-Managed -Explicit $ValheimDir
$core = Find-Core -Explicit $BepInExCoreDir

Add-Type -Path (Join-Path $core 'Mono.Cecil.dll') | Out-Null

# ---------------------------------------------------------------------------
# Resolve the current five-parameter overload
# ---------------------------------------------------------------------------

$resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
$resolver.AddSearchDirectory($managed)
$readerParameters = New-Object Mono.Cecil.ReaderParameters
$readerParameters.AssemblyResolver = $resolver

$game = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((Join-Path $managed 'assembly_valheim.dll'), $readerParameters)
$replacement = $null
foreach ($method in $game.MainModule.GetType('Character').Methods) {
    if ($method.Name -eq 'Message' -and $method.Parameters.Count -eq 5) { $replacement = $method }
}
if ($null -eq $replacement) { throw 'Character.Message with five parameters not found in assembly_valheim.dll.' }
$game.Dispose()

Write-Host "Old signature : Character.Message(..., 4 parameters)"
Write-Host "New signature : $($replacement.FullName)"

# ---------------------------------------------------------------------------
# Rewrite every call site
# ---------------------------------------------------------------------------

$code = [Mono.Cecil.Cil.Code]
$opcodes = [Mono.Cecil.Cil.OpCodes]

$assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($SrcDll)
$imported = $assembly.MainModule.ImportReference($replacement)

$count = 0
$owners = New-Object System.Collections.ArrayList

function Repair-Type($type) {
    foreach ($method in $type.Methods) {
        if (-not $method.HasBody) { continue }
        $il = $method.Body.GetILProcessor()
        foreach ($instruction in @($method.Body.Instructions)) {
            if (($instruction.OpCode.Code -ne $code::Call -and $instruction.OpCode.Code -ne $code::Callvirt)) { continue }
            $operand = $instruction.Operand
            if ($operand -isnot [Mono.Cecil.MethodReference]) { continue }
            if ($operand.Name -ne 'Message') { continue }
            if ($operand.Parameters.Count -ne 4) { continue }
            if ($operand.DeclaringType.FullName -ne 'Character') { continue }

            # log = false, exactly what a pre-1.0 call meant
            $il.InsertBefore($instruction, $il.Create($opcodes::Ldc_I4_0))
            $instruction.Operand = $imported
            $script:count++
            $null = $script:owners.Add($method.FullName)
        }
    }
    foreach ($nested in $type.NestedTypes) { Repair-Type $nested }
}

foreach ($type in $assembly.MainModule.Types) { Repair-Type $type }

if ($count -eq 0) {
    $assembly.Dispose()
    throw 'No four-parameter Character.Message call site found - nothing to adapt.'
}

$directory = Split-Path $OutDll -Parent
if ($directory -and -not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }

$assembly.Write($OutDll)
$assembly.Dispose()

Write-Host ''
Write-Host "Adapted call sites: $count" -ForegroundColor Green
$owners | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }
Write-Host ("-> {0} ({1} bytes)" -f $OutDll, (Get-Item $OutDll).Length)
