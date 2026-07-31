[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-PathExists([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Description 不存在：$Path"
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$workspaceRoot = Split-Path -Parent $repoRoot
$toolRoot = Join-Path $workspaceRoot '.codex-build-tools'
$flutter = Join-Path $toolRoot 'flutter\bin\flutter.bat'
$jdkRoot = Join-Path $toolRoot 'jdk17'
$androidSdk = Join-Path $toolRoot 'android-sdk'
$pubCache = Join-Path $toolRoot 'pub-cache'
$pubspec = Join-Path $repoRoot 'pubspec.yaml'
$lockFile = Join-Path $repoRoot 'pubspec.lock'
$pubLog = Join-Path $repoRoot 'build\flutter-pub-get.log'
$registrantRelative = 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'
$registrant = Join-Path $repoRoot $registrantRelative
$apkPath = Join-Path $repoRoot 'build\app\outputs\apk\release\HoneyBox-release.apk'

Assert-PathExists $flutter 'Flutter'
Assert-PathExists $jdkRoot 'JDK 17'
Assert-PathExists $androidSdk 'Android SDK'
Assert-PathExists $pubspec 'pubspec.yaml'
Assert-PathExists $lockFile 'pubspec.lock'

New-Item -ItemType Directory -Force -Path $pubCache | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $pubLog) | Out-Null

$env:JAVA_HOME = $jdkRoot
$env:ANDROID_HOME = $androidSdk
$env:ANDROID_SDK_ROOT = $androidSdk
$env:FLUTTER_ROOT = Join-Path $toolRoot 'flutter'
$env:PUB_CACHE = $pubCache
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PATH = "$env:FLUTTER_ROOT\bin;$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:PATH"

Push-Location $repoRoot
try {
    Write-Host '正在准备 Flutter 依赖...'
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $pubCommand = '""{0}" pub get --enforce-lockfile 2>&1"' -f $flutter
        & $env:ComSpec /d /s /c $pubCommand | Tee-Object -FilePath $pubLog
        $pubExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($pubExit -ne 0) {
        $pubOutput = Get-Content -LiteralPath $pubLog -Raw
        $knownSymlinkFailure = (
            $pubOutput.Contains('Got dependencies!') -and
            $pubOutput.Contains('Building with plugins requires symlink support')
        )
        if (-not $knownSymlinkFailure) {
            throw "flutter pub get 失败，退出码：$pubExit。日志：$pubLog"
        }
        Write-Warning '依赖已准备完成；跳过 Windows 桌面插件 symlink 创建。'
    }

    if (Test-Path -LiteralPath $registrant) {
        & git -C $repoRoot check-ignore --quiet -- $registrantRelative
        if ($LASTEXITCODE -ne 0) {
            throw "发现旧插件注册文件但它未被 Git 忽略，拒绝删除：$registrant"
        }
        Remove-Item -LiteralPath $registrant -Force
        Write-Host "已清理旧插件注册文件：$registrant"
    }

    Write-Host '正在编译 Android Release APK...'
    & $flutter build apk --release --no-pub
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter Release 构建失败，退出码：$LASTEXITCODE"
    }

    Assert-PathExists $apkPath 'Release APK'
    $apk = Get-Item -LiteralPath $apkPath
    if ($apk.Length -le 0) {
        throw "Release APK 为空：$apkPath"
    }
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $apkPath

    Write-Host ''
    Write-Host '编译完成。'
    Write-Host "APK：$($apk.FullName)"
    Write-Host "大小：$($apk.Length) 字节"
    Write-Host "时间：$($apk.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "SHA-256：$($hash.Hash)"
} finally {
    Pop-Location
}
