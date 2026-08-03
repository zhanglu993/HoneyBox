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
using System.Text;

public static class Program {
  public static int Main(string[] args) {
    var log = Environment.GetEnvironmentVariable("HONEYBOX_CAMERA_SCRIPT_LOG");
    using (var writer = new StreamWriter(new FileStream(log, FileMode.Append, FileAccess.Write, FileShare.Read), new UTF8Encoding(false))) {
      writer.WriteLine(Path.GetFileName(Environment.GetCommandLineArgs()[0]));
      writer.WriteLine(args.Length);
      foreach (var arg in args) {
        writer.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
      }
    }
    return 0;
  }
}
'@
    $cmake = Join-Path $tools 'cmake.exe'
    Add-Type -TypeDefinition $fakeToolSource -OutputAssembly $cmake -OutputType ConsoleApplication
    Copy-Item -LiteralPath $cmake -Destination (Join-Path $tools 'ctest.exe')

    [pscustomobject]@{
        Root = $root
        Repository = $repository
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
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $env:Path = $sandbox.Tools + ';' + $previousPath
        $env:HONEYBOX_CAMERA_SCRIPT_LOG = $sandbox.Log
        $encodedNameLiterals = @()
        $encodedValueLiterals = @()
        for ($index = 0; $index -lt $Arguments.Count; $index += 2) {
            if ($index + 1 -ge $Arguments.Count) {
                throw 'Camera-script test arguments must be complete name/value pairs.'
            }
            $parameterName = $Arguments[$index]
            if (-not $parameterName.StartsWith('-')) {
                throw "Camera-script test argument is not a parameter name: $parameterName"
            }
            $encodedName = [System.Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($parameterName.Substring(1)))
            $encodedValue = [System.Convert]::ToBase64String(
                [System.Text.Encoding]::UTF8.GetBytes($Arguments[$index + 1]))
            $encodedNameLiterals += "'$encodedName'"
            $encodedValueLiterals += "'$encodedValue'"
        }
        $encodedNames = '@(' + ($encodedNameLiterals -join ', ') + ')'
        $encodedValues = '@(' + ($encodedValueLiterals -join ', ') + ')'
        $escapedScript = $sandbox.Script.Replace("'", "''")
        $childCommand = @"
`$encodedNames = $encodedNames
`$encodedValues = $encodedValues
`$parameters = @{}
for (`$index = 0; `$index -lt `$encodedNames.Count; `$index += 1) {
    `$name = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(`$encodedNames[`$index]))
    `$value = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(`$encodedValues[`$index]))
    `$parameters[`$name] = `$value
}
& '$escapedScript' @parameters
exit `$LASTEXITCODE
"@
        $encodedCommand = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childCommand))
        $output = & $scriptHost -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    } finally {
        $env:Path = $previousPath
        $env:HONEYBOX_CAMERA_SCRIPT_LOG = $previousLog
        $ErrorActionPreference = $previousErrorAction
    }
}

function Get-Calls($sandbox) {
    if (-not (Test-Path -LiteralPath $sandbox.Log -PathType Leaf)) {
        return @()
    }
    $lines = [System.IO.File]::ReadAllLines($sandbox.Log)
    $calls = @()
    for ($index = 0; $index -lt $lines.Length;) {
        $tool = $lines[$index]
        $index += 1
        $argumentCount = 0
        if (-not [int]::TryParse($lines[$index], [ref]$argumentCount)) {
            throw "Invalid fake-tool argument count for $tool"
        }
        $index += 1
        if ($index + $argumentCount -gt $lines.Length) {
            throw "Truncated fake-tool record for $tool"
        }
        $arguments = @()
        for ($argumentIndex = 0; $argumentIndex -lt $argumentCount; $argumentIndex += 1) {
            $arguments += [System.Text.Encoding]::UTF8.GetString(
                [System.Convert]::FromBase64String($lines[$index]))
            $index += 1
        }
        $calls += [pscustomobject]@{ Tool = $tool; Arguments = $arguments }
    }
    return $calls
}

function Assert-Arguments($call, [string[]]$expected, [string]$label) {
    if ($call.Arguments.Count -ne $expected.Count) {
        throw "$label argument count mismatch: expected $($expected.Count), got $($call.Arguments.Count)."
    }
    for ($index = 0; $index -lt $expected.Count; $index += 1) {
        if (-not [string]::Equals($call.Arguments[$index], $expected[$index], [System.StringComparison]::Ordinal)) {
            throw "$label argument $index mismatch: expected <$($expected[$index])>, got <$($call.Arguments[$index])>."
        }
    }
}

function Get-BuildDirectory($sandbox) {
    return Join-Path $sandbox.Repository 'build\camera-windows-preview-msvc-x64'
}

function Assert-DefaultInvocation($sandbox, $calls, [string]$label) {
    $buildDirectory = Get-BuildDirectory $sandbox
    $buildCalls = @($calls | Where-Object { $_.Tool -eq 'cmake.exe' -and $_.Arguments[0] -eq '--build' })
    $ctestCalls = @($calls | Where-Object { $_.Tool -eq 'ctest.exe' })
    if ($buildCalls.Count -ne 2 -or $ctestCalls.Count -ne 2) {
        throw "$label must issue two build calls and two CTest calls; observed build=$($buildCalls.Count), CTest=$($ctestCalls.Count)."
    }
    foreach ($index in 0..1) {
        $configuration = @('Debug', 'Release')[$index]
        Assert-Arguments $buildCalls[$index] @('--build', $buildDirectory, '--config', $configuration) "$label build $configuration"
        Assert-Arguments $ctestCalls[$index] @('--test-dir', $buildDirectory, '-C', $configuration, '--output-on-failure', '--no-tests=error') "$label CTest $configuration"
    }
}

function Assert-InvocationSucceeded($result, [string]$label) {
    if ($result.ExitCode -ne 0) {
        throw "$label failed: $($result.Output -join [Environment]::NewLine)"
    }
}

$defaultSandbox = New-TestSandbox
try {
    $result = Invoke-CameraScript $defaultSandbox @()
    Assert-InvocationSucceeded $result 'Default invocation'
    Assert-DefaultInvocation $defaultSandbox (Get-Calls $defaultSandbox) 'Default invocation'
} finally {
    Remove-TestSandbox $defaultSandbox.Root
}

$focusedSandbox = New-TestSandbox
try {
    $regex = 'camera preview|foo[0-9]$'
    $result = Invoke-CameraScript $focusedSandbox @('-Configuration', 'Release', '-TestRegex', $regex)
    Assert-InvocationSucceeded $result 'Focused invocation'
    $buildDirectory = Get-BuildDirectory $focusedSandbox
    $calls = Get-Calls $focusedSandbox
    $buildCalls = @($calls | Where-Object { $_.Tool -eq 'cmake.exe' -and $_.Arguments[0] -eq '--build' })
    $ctestCalls = @($calls | Where-Object { $_.Tool -eq 'ctest.exe' })
    if ($buildCalls.Count -ne 1 -or $ctestCalls.Count -ne 1) {
        throw 'Focused invocation must issue one build call and one CTest call.'
    }
    Assert-Arguments $buildCalls[0] @('--build', $buildDirectory, '--config', 'Release', '--target', 'honey_camera_windows_tests') 'Focused build'
    Assert-Arguments $ctestCalls[0] @('--test-dir', $buildDirectory, '-C', 'Release', '--output-on-failure', '--no-tests=error', '-R', $regex) 'Focused CTest'
} finally {
    Remove-TestSandbox $focusedSandbox.Root
}

foreach ($regex in @('', '   ')) {
    $blankSandbox = New-TestSandbox
    try {
        $result = Invoke-CameraScript $blankSandbox @('-TestRegex', $regex)
        Assert-InvocationSucceeded $result "Blank TestRegex <$regex> invocation"
        Assert-DefaultInvocation $blankSandbox (Get-Calls $blankSandbox) "Blank TestRegex <$regex> invocation"
    } finally {
        Remove-TestSandbox $blankSandbox.Root
    }
}

Write-Host 'Camera preview test script build-scope checks passed.'
