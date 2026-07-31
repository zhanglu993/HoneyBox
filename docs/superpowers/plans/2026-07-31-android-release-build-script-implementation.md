# Android Release 编译脚本实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 提供一个可直接运行、能兼容当前 Windows symlink 限制和中文用户目录的 HoneyBox Android Release 编译脚本。

**Architecture:** 单个 `tool/build-android-release.ps1` 负责环境定位、依赖准备、兼容判断、构建和产物摘要；单个无第三方依赖的 PowerShell 合约测试负责语法和关键安全约束。脚本只接受“依赖已完成但 Windows symlink 创建失败”这一种非零 `pub get` 结果，其他错误立即终止。

**Tech Stack:** Windows PowerShell、Flutter 3.44.x、Dart/Flutter Pub、JDK 17、Android SDK、Git、PowerShell Parser。

## Global Constraints

- 脚本路径固定为 `tool/build-android-release.ps1`，不接收参数。
- 工具链固定从仓库同级 `.codex-build-tools` 目录定位。
- `PUB_CACHE` 必须使用 `.codex-build-tools/pub-cache` 的纯英文路径。
- 必须执行 `flutter pub get --enforce-lockfile`，构建阶段必须使用 `--no-pub`。
- 只允许删除被 Git 忽略的 `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`。
- 成功时必须输出 `HoneyBox-release.apk` 的绝对路径、大小、修改时间和 SHA-256。
- 不修改任何既有受 Git 跟踪文件；不声称完成真机安装或功能回归。

---

### Task 1: 编译脚本及其合约测试

**Files:**
- Create: `tool/build-android-release.ps1`
- Create: `test/ci/build_android_release_script_test.ps1`

**Interfaces:**
- Consumes: 仓库根目录的 `pubspec.yaml`、`pubspec.lock`、`android/local.properties`，以及同级 `.codex-build-tools` 工具链。
- Produces: 无参数命令 `powershell -NoProfile -ExecutionPolicy Bypass -File .\tool\build-android-release.ps1`；成功退出码为 0，产物为 `build/app/outputs/apk/release/HoneyBox-release.apk`。

- [ ] **Step 1: 写入会失败的静态合约测试**

创建 `test/ci/build_android_release_script_test.ps1`：

```powershell
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\..\tool\build-android-release.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Build script is missing: $scriptPath"
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -ne 0) {
    throw "Build script has parser errors: $($parseErrors.Message -join '; ')"
}

$script = Get-Content -LiteralPath $scriptPath -Raw
function Assert-Contains([string]$Pattern, [string]$Message) {
    if ($script -notmatch $Pattern) { throw $Message }
}

Assert-Contains 'PUB_CACHE' 'Build script must set an ASCII PUB_CACHE.'
Assert-Contains 'pub get --enforce-lockfile' 'Build script must enforce pubspec.lock.'
Assert-Contains 'Got dependencies!' 'Build script must verify dependency completion before accepting the symlink fallback.'
Assert-Contains 'Building with plugins requires symlink support' 'Build script must narrowly detect the Windows symlink failure.'
Assert-Contains 'check-ignore' 'Build script must verify the stale registrant is ignored before deletion.'
Assert-Contains 'build apk --release --no-pub' 'Build script must build the release APK without a second pub get.'
Assert-Contains 'Get-FileHash' 'Build script must print an APK hash.'

if ($script -match "``\r?\n") {
    throw 'Build script must not use PowerShell backtick line continuations.'
}

Write-Host 'Android release build script contract checks passed.'
```

- [ ] **Step 2: 运行测试并确认先失败**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\ci\build_android_release_script_test.ps1
```

Expected: FAIL，错误包含 `Build script is missing`。

- [ ] **Step 3: 实现最小可用编译脚本**

创建 `tool/build-android-release.ps1`，实现以下结构：

```powershell
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
    & $flutter pub get --enforce-lockfile 2>&1 | Tee-Object -FilePath $pubLog
    $pubExit = $LASTEXITCODE
    if ($pubExit -ne 0) {
        $pubOutput = Get-Content -LiteralPath $pubLog -Raw
        $knownSymlinkFailure =
            $pubOutput.Contains('Got dependencies!') -and
            $pubOutput.Contains('Building with plugins requires symlink support')
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
    if ($apk.Length -le 0) { throw "Release APK 为空：$apkPath" }
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
```

- [ ] **Step 4: 运行静态合约测试并确认通过**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\ci\build_android_release_script_test.ps1
```

Expected: PASS，输出 `Android release build script contract checks passed.`。

- [ ] **Step 5: 实际运行编译脚本**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tool\build-android-release.ps1
```

Expected: exit 0，输出 `编译完成。`、APK 绝对路径、非零大小和 SHA-256；`build/app/outputs/apk/release/HoneyBox-release.apk` 存在。

- [ ] **Step 6: 核验 APK 元数据和签名**

Run:

```powershell
$toolRoot = 'F:\sourcecode\8773EWE\.codex-build-tools'
$env:JAVA_HOME = "$toolRoot\jdk17"
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
$buildTools = (Get-ChildItem "$toolRoot\android-sdk\build-tools" -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$apk = 'build\app\outputs\apk\release\HoneyBox-release.apk'
& "$buildTools\aapt.exe" dump badging $apk | Select-String '^(package:|application-label:|sdkVersion:|targetSdkVersion:)'
& "$buildTools\apksigner.bat" verify --verbose --print-certs $apk
```

Expected: 包名为 `com.honeygui.honeybox`，版本与 `pubspec.yaml` 一致，`Verifies` 且 APK Signature Scheme v2 为 `true`。

- [ ] **Step 7: 检查改动范围并提交**

Run:

```powershell
git diff --check
git status --short
git add -- tool/build-android-release.ps1 test/ci/build_android_release_script_test.ps1
git diff --cached --check
git commit -m "build: 添加 Android Release 一键编译脚本"
```

Expected: 提交只包含脚本和对应合约测试；`build/`、`.dart_tool/` 和本地工具缓存不进入提交。
