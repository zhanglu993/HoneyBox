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
    $lockContent = @'
packages:
  sample:
    dependency: transitive
    description:
      name: sample
      sha256: test-hash
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
'@
    Set-Content -LiteralPath (Join-Path $repoRoot 'pubspec.lock') -Encoding ASCII -Value $lockContent

    if ($PubMode -eq 'symlink') {
        $pubResult = @'
if not exist "%~dp0..\..\pub-retry.marker" (
    echo attempted> "%~dp0..\..\pub-retry.marker"
    echo Got dependencies!
    echo Building with plugins requires symlink support. 1>&2
    exit /b 1
)
mkdir "android\app\src\main\java\io\flutter\plugins" 2>nul
echo generated> "android\app\src\main\java\io\flutter\plugins\GeneratedPluginRegistrant.java"
echo Got dependencies!
exit /b 0
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
if not "%PUB_HOSTED_URL%"=="https://pub.dev" (
    echo Lock source mismatch: %PUB_HOSTED_URL% 1>&2
    exit /b 65
)
if not "%1 %2 %3"=="pub get --enforce-lockfile" goto build_command
$pubResult
:build_command
if "%1 %2 %3 %4"=="build apk --release --no-pub" (
    if not exist "android\app\src\main\java\io\flutter\plugins\GeneratedPluginRegistrant.java" (
        echo GeneratedPluginRegistrant.java is missing. 1>&2
        exit /b 66
    )
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
    $pubCalls = @([regex]::Matches($calls, '(?m)^pub get --enforce-lockfile\s*$'))
    if ($pubCalls.Count -ne 2) {
        throw "Known symlink failure must retry dependency preparation once; observed $($pubCalls.Count) calls."
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
