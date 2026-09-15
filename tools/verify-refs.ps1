<#
.SYNOPSIS
    Statically validates a patched plugin against the game's assemblies.

.DESCRIPTION
    Loads the plugin with Mono.Cecil, resolves every referenced type, method and field against the
    Valheim managed assemblies and the BepInEx core, and reports anything that does not resolve.
    This is what catches API drift such as the Character.Message change without having to launch
    the game.

.EXAMPLE
    .\verify-refs.ps1
    .\verify-refs.ps1 -Assembly ..\dist\Sailing.dll
#>
[CmdletBinding()]
param(
    [string]$Assembly,
    [string]$ValheimDir,
    [string]$BepInExCoreDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $Assembly) { $Assembly = Join-Path $root 'dist\Sailing.dll' }
if (-not (Test-Path $Assembly)) { throw "Assembly not found: $Assembly. Run build.ps1 first." }

if (-not $ValheimDir) { $ValheimDir = $env:VALHEIM_DIR }

# Discover the same locations build.ps1 uses.
$managedCandidates = @()
if ($ValheimDir) { $managedCandidates += (Join-Path $ValheimDir 'valheim_Data\Managed') }
$managedCandidates += 'C:\Program Files (x86)\Steam\steamapps\common\Valheim\valheim_Data\Managed'
try {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
    if ($steam) { $managedCandidates += (Join-Path ($steam -replace '/', '\') 'steamapps\common\Valheim\valheim_Data\Managed') }
} catch { }

$managed = $managedCandidates | Where-Object { $_ -and (Test-Path (Join-Path $_ 'assembly_valheim.dll')) } | Select-Object -First 1
if (-not $managed) { throw 'Could not locate valheim_Data\Managed.' }

$coreCandidates = @()
if ($BepInExCoreDir) { $coreCandidates += $BepInExCoreDir }
$coreCandidates += (Join-Path $env:APPDATA 'r2modmanPlus-local\Valheim\profiles\Default\BepInEx\core')

$core = $coreCandidates | Where-Object { $_ -and (Test-Path (Join-Path $_ 'BepInEx.dll')) } | Select-Object -First 1
if (-not $core) { throw 'Could not locate the BepInEx core directory.' }

Write-Host "Assembly : $Assembly"
Write-Host "Managed  : $managed"
Write-Host "Core     : $core"
Write-Host ''

Add-Type -Path (Join-Path $core 'Mono.Cecil.dll')

$searchDirs = @($managed, $core, (Split-Path -Parent $Assembly))

$resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
foreach ($dir in $searchDirs) { $resolver.AddSearchDirectory($dir) }

$parameters = New-Object Mono.Cecil.ReaderParameters
$parameters.AssemblyResolver = $resolver

$module = [Mono.Cecil.ModuleDefinition]::ReadModule($Assembly, $parameters)
$ownNamespace = $module.Assembly.Name.Name

$unresolved = New-Object System.Collections.Generic.List[string]
$visitedTypes = New-Object 'System.Collections.Generic.HashSet[string]'
$visitedMethods = New-Object 'System.Collections.Generic.HashSet[string]'
$usedGameApi = New-Object 'System.Collections.Generic.HashSet[string]'

function Check-Type([Mono.Cecil.TypeReference]$type) {
    if ($null -eq $type) { return }

    # Generic parameters (!0 / !!0) are placeholders, not references to resolve.
    if ($type -is [Mono.Cecil.GenericParameter]) { return }

    $name = $type.FullName
    if ($visitedTypes.Contains($name)) { return }
    [void]$visitedTypes.Add($name)

    if ($type -is [Mono.Cecil.GenericInstanceType]) {
        foreach ($argument in $type.GenericArguments) { Check-Type $argument }
        Check-Type $type.ElementType
        return
    }

    if ($type -is [Mono.Cecil.TypeSpecification]) {
        Check-Type $type.ElementType
        return
    }

    if ($type.Namespace -and $type.Namespace.StartsWith($ownNamespace)) { return }

    try {
        $resolved = $type.Resolve()
    } catch {
        $resolved = $null
    }

    if ($null -eq $resolved) {
        $unresolved.Add("TYPE   $name")
    } else {
        $assemblyName = $resolved.Module.Assembly.Name.Name
        if ($assemblyName -eq 'assembly_valheim' -or $assemblyName -eq 'assembly_guiutils') {
            [void]$usedGameApi.Add("$name  [$assemblyName]")
        }
    }

    Check-Type $type.DeclaringType
}

function Check-Method([Mono.Cecil.MethodReference]$method) {
    if ($null -eq $method) { return }
    $key = $method.FullName
    if ($visitedMethods.Contains($key)) { return }
    [void]$visitedMethods.Add($key)

    Check-Type $method.DeclaringType
    Check-Type $method.ReturnType
    foreach ($parameter in $method.Parameters) { Check-Type $parameter.ParameterType }

    if ($method -is [Mono.Cecil.GenericInstanceMethod]) {
        foreach ($argument in $method.GenericArguments) { Check-Type $argument }
    }

    try {
        $resolved = $method.Resolve()
    } catch {
        $resolved = $null
    }

    if ($null -eq $resolved) { $unresolved.Add("METHOD $key") }
}

function Check-Field([Mono.Cecil.FieldReference]$field) {
    if ($null -eq $field) { return }
    Check-Type $field.DeclaringType
    Check-Type $field.FieldType
    try {
        $resolved = $field.Resolve()
    } catch {
        $resolved = $null
    }
    if ($null -eq $resolved) { $unresolved.Add("FIELD  $($field.FullName)") }
}

foreach ($type in $module.Types) {
    Check-Type $type.BaseType
    foreach ($interface in $type.Interfaces) { Check-Type $interface.InterfaceType }
    foreach ($field in $type.Fields) { Check-Field $field; Check-Type $field.FieldType }
    foreach ($typeRef in $type.Properties) { Check-Method $typeRef.GetMethod; Check-Method $typeRef.SetMethod }

    foreach ($method in $type.Methods) {
        Check-Method $method
        if (-not $method.HasBody) { continue }
        foreach ($variable in $method.Body.Variables) { Check-Type $variable.VariableType }
        foreach ($instruction in $method.Body.Instructions) {
            $operand = $instruction.Operand
            if ($operand -is [Mono.Cecil.MethodReference]) { Check-Method $operand }
            elseif ($operand -is [Mono.Cecil.FieldReference]) { Check-Field $operand }
            elseif ($operand -is [Mono.Cecil.TypeReference]) { Check-Type $operand }
        }
    }
}

if ($unresolved.Count -gt 0) {
    Write-Host "UNRESOLVED REFERENCES ($($unresolved.Count)):" -ForegroundColor Red
    $unresolved | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'All referenced types, methods and fields resolve correctly.' -ForegroundColor Green
Write-Host ''
Write-Host "Game / Unity API used by the plugin ($($usedGameApi.Count)):" -ForegroundColor Cyan
$usedGameApi | Sort-Object | ForEach-Object { Write-Host "  $_" }
exit 0
