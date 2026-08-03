$ErrorActionPreference = 'Stop'

$sourceScript = Join-Path $PSScriptRoot '..\..\scripts\test-camera-windows-preview.ps1'
if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) {
    throw "Camera preview test script is missing: $sourceScript"
}
$scriptHost = (Get-Command powershell.exe -ErrorAction Stop).Source

function New-TestSandbox {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) (
        'honeybox-camera-preview-script-test-' + [guid]::NewGuid().ToString('N'))
    $repository = Join-Path $root 'repository'
    $scripts = Join-Path $repository 'scripts'
    $tools = Join-Path $root 'tools'
    $log = Join-Path $root 'calls.log'
    New-Item -ItemType Directory -Force -Path $scripts, $tools | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $repository 'windows\camera') | Out-Null
    Copy-Item -LiteralPath $sourceScript -Destination (Join-Path $scripts 'test-camera-windows-preview.ps1')

    $fakeToolSource = @'
using System;
using System.IO;

public static class Program {
  public static int Main(string[] args) {
    var log = Environment.GetEnvironmentVariable("HONEYBOX_CAMERA_SCRIPT_LOG");
    File.AppendAllText(log, Path.GetFileName(Environment.GetCommandLineArgs()[0]) + "|" + string.Join("|", args) + Environment.NewLine);
    return 0;
  }
}
'@
    $cmake = Join-Path $tools 'cmake.exe'
    Add-Type -TypeDefinition $fakeToolSource -OutputAssembly $cmake -OutputType ConsoleApplication
    Copy-Item -LiteralPath $cmake -Destination (Join-Path $tools 'ctest.exe')

    [pscustomobject]@{
        Root = $root
        Script = Join-Path $scripts 'test-camera-windows-preview.ps1'
        Tools = $tools
        Log = $log
    }
}

function Remove-TestSandbox([string]$Path) {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a path outside temp: $resolvedPath"
    }
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function Invoke-CameraScript($sandbox, [string[]]$Arguments) {
    $previousPath = $env:Path
    $previousLog = $env:HONEYBOX_CAMERA_SCRIPT_LOG
    try {
        $env:Path = $sandbox.Tools + ';' + $previousPath
        $env:HONEYBOX_CAMERA_SCRIPT_LOG = $sandbox.Log
        $output = & $scriptHost -NoProfile -ExecutionPolicy Bypass -File $sandbox.Script @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    } finally {
        $env:Path = $previousPath
        $env:HONEYBOX_CAMERA_SCRIPT_LOG = $previousLog
    }
}

function Get-Calls($sandbox) {
    if (-not (Test-Path -LiteralPath $sandbox.Log -PathType Leaf)) {
        return @()
    }
    return @(Get-Content -LiteralPath $sandbox.Log)
}

$defaultSandbox = New-TestSandbox
try {
    $result = Invoke-CameraScript $defaultSandbox @()
    if ($result.ExitCode -ne 0) {
        throw "Default invocation failed: $($result.Output -join [Environment]::NewLine)"
    }
    $buildCalls = @(Get-Calls $defaultSandbox | Where-Object { $_ -match '^cmake\.exe\|--build\|' })
    if ($buildCalls.Count -ne 2) {
        throw "Default invocation must build Debug and Release; observed $($buildCalls.Count) build calls."
    }
    if (@($buildCalls | Where-Object { $_ -match '\|--target\|' }).Count -ne 0) {
        throw 'Default invocation must build every CTest target, not only honey_camera_windows_tests.'
    }
} finally {
    Remove-TestSandbox $defaultSandbox.Root
}

$focusedSandbox = New-TestSandbox
try {
    $result = Invoke-CameraScript $focusedSandbox @('-Configuration', 'Release', '-TestRegex', 'camera_preview_')
    if ($result.ExitCode -ne 0) {
        throw "Focused invocation failed: $($result.Output -join [Environment]::NewLine)"
    }
    $calls = Get-Calls $focusedSandbox
    if (@($calls | Where-Object { $_ -match '^cmake\.exe\|--build\|.*\|--target\|honey_camera_windows_tests$' }).Count -ne 1) {
        throw 'Focused invocation must retain the camera-only build target.'
    }
    if (@($calls | Where-Object { $_ -match '^ctest\.exe\|.*\|-R\|camera_preview_$' }).Count -ne 1) {
        throw 'Focused invocation must pass TestRegex through to CTest.'
    }
} finally {
    Remove-TestSandbox $focusedSandbox.Root
}

Write-Host 'Camera preview test script build-scope checks passed.'
