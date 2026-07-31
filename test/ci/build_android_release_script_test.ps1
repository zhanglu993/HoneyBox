$ErrorActionPreference = 'Stop'

$sourceScript = Join-Path $PSScriptRoot '..\..\tool\build-android-release.ps1'
if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) {
    throw "Build script is missing: $sourceScript"
}

function New-TestSandbox([ValidateSet('symlink', 'failure')][string]$PubMode) {
    $sandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("honeybox-build-script-test-" + [guid]::NewGuid().ToString('N'))
    $repoRoot = Join-Path $sandboxRoot 'hmi_android_apk'
    $scriptDir = Join-Path $repoRoot 'tool'
    $toolRoot = Join-Path $sandboxRoot '.codex-build-tools'
    $flutterBin = Join-Path $toolRoot 'flutter\bin'

    New-Item -ItemType Directory -Force -Path $scriptDir, $flutterBin | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $toolRoot 'jdk17'), (Join-Path $toolRoot 'android-sdk') | Out-Null
    Copy-Item -LiteralPath $sourceScript -Destination (Join-Path $scriptDir 'build-android-release.ps1')
    Set-Content -LiteralPath (Join-Path $repoRoot 'pubspec.yaml') -Encoding ASCII -Value "name: test_app`n"
    Set-Content -LiteralPath (Join-Path $repoRoot 'pubspec.lock') -Encoding ASCII -Value "packages: {}`n"

    if ($PubMode -eq 'symlink') {
        $pubResult = @'
echo Got dependencies!
echo Building with plugins requires symlink support. 1>&2
exit /b 1
'@
    } else {
        $pubResult = @'
echo Network dependency failure. 1>&2
exit /b 1
'@
    }

    $fakeFlutter = @"
@echo off
echo %*>> "%~dp0..\..\flutter-calls.log"
if "%1 %2 %3"=="pub get --enforce-lockfile" (
$pubResult
)
if "%1 %2 %3 %4"=="build apk --release --no-pub" (
    mkdir "build\app\outputs\apk\release" 2>nul
    echo fake-apk> "build\app\outputs\apk\release\HoneyBox-release.apk"
    exit /b 0
)
echo Unexpected flutter arguments: %* 1>&2
exit /b 2
"@
    Set-Content -LiteralPath (Join-Path $flutterBin 'flutter.bat') -Encoding ASCII -Value $fakeFlutter

    [pscustomobject]@{
        Root = $sandboxRoot
        Repo = $repoRoot
        Script = Join-Path $scriptDir 'build-android-release.ps1'
        Calls = Join-Path $toolRoot 'flutter-calls.log'
        Apk = Join-Path $repoRoot 'build\app\outputs\apk\release\HoneyBox-release.apk'
    }
}

function Remove-TestSandbox([string]$Path) {
    $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove a path outside the temp directory: $resolvedPath"
    }
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function Invoke-BuildScript([string]$Path) {
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

$successSandbox = New-TestSandbox -PubMode symlink
try {
    $successResult = Invoke-BuildScript $successSandbox.Script
    if ($successResult.ExitCode -ne 0) {
        throw "Known symlink fallback must succeed, exit $($successResult.ExitCode)`: $($successResult.Output -join [Environment]::NewLine)"
    }
    if (-not (Test-Path -LiteralPath $successSandbox.Apk -PathType Leaf)) {
        throw 'Known symlink fallback must produce the release APK.'
    }
    $calls = Get-Content -LiteralPath $successSandbox.Calls -Raw
    if ($calls -notmatch 'pub get --enforce-lockfile') {
        throw 'Build script must prepare dependencies with --enforce-lockfile.'
    }
    if ($calls -notmatch 'build apk --release --no-pub') {
        throw 'Build script must run the release build with --no-pub.'
    }
    if (($successResult.Output -join [Environment]::NewLine) -notmatch 'SHA-256') {
        throw 'Successful build output must include the APK SHA-256.'
    }
    if (($successResult.Output -join [Environment]::NewLine) -match 'NativeCommandError') {
        throw 'Successful build output must not wrap Flutter stderr as NativeCommandError.'
    }
} finally {
    Remove-TestSandbox $successSandbox.Root
}

$failureSandbox = New-TestSandbox -PubMode failure
try {
    $failureResult = Invoke-BuildScript $failureSandbox.Script
    if ($failureResult.ExitCode -eq 0) {
        throw 'Unexpected dependency failures must stop the build.'
    }
    $calls = Get-Content -LiteralPath $failureSandbox.Calls -Raw
    if ($calls -match 'build apk --release --no-pub') {
        throw 'Release build must not run after an unexpected dependency failure.'
    }
    if (Test-Path -LiteralPath $failureSandbox.Apk) {
        throw 'Unexpected dependency failures must not produce an APK.'
    }
} finally {
    Remove-TestSandbox $failureSandbox.Root
}

Write-Host 'Android release build script behavior checks passed.'
