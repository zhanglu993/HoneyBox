param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$GradleArguments
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$androidDirectory = Join-Path $repositoryRoot 'android'
$javaHome = $env:JAVA_HOME
if ([string]::IsNullOrWhiteSpace($javaHome) -or
    -not (Test-Path -LiteralPath (Join-Path $javaHome 'bin\java.exe')) -or
    -not (Test-Path -LiteralPath (Join-Path $javaHome 'bin\javac.exe'))) {
    throw 'JAVA_HOME must name a usable JDK containing bin\java.exe and bin\javac.exe.'
}

$localProperties = Join-Path $androidDirectory 'local.properties'
if (-not (Test-Path -LiteralPath $localProperties)) {
    $flutterRoot = $env:FLUTTER_ROOT
    $androidSdkRoot = $env:ANDROID_SDK_ROOT
    if ([string]::IsNullOrWhiteSpace($flutterRoot) -or -not (Test-Path -LiteralPath $flutterRoot)) {
        throw 'FLUTTER_ROOT must name an existing Flutter SDK when android/local.properties is absent.'
    }
    if ([string]::IsNullOrWhiteSpace($androidSdkRoot) -or -not (Test-Path -LiteralPath $androidSdkRoot)) {
        throw 'ANDROID_SDK_ROOT must name an existing Android SDK when android/local.properties is absent.'
    }
    @(
        "flutter.sdk=$($flutterRoot.Replace('\', '/'))"
        "sdk.dir=$($androidSdkRoot.Replace('\', '/'))"
    ) | Set-Content -LiteralPath $localProperties -Encoding ascii
}

$gradleCommand = Join-Path $androidDirectory 'gradlew.bat'
if (-not (Test-Path -LiteralPath $gradleCommand)) {
    $wrapperProperties = Join-Path $androidDirectory 'gradle\wrapper\gradle-wrapper.properties'
    $properties = Get-Content -LiteralPath $wrapperProperties
    $distributionLine = $properties | Where-Object { $_ -match '^distributionUrl=' } | Select-Object -First 1
    $checksumLine = $properties | Where-Object { $_ -match '^distributionSha256Sum=' } | Select-Object -First 1
    if ($null -eq $distributionLine -or $null -eq $checksumLine) {
        throw 'gradle-wrapper.properties must provide distributionUrl and distributionSha256Sum.'
    }
    $distributionUrl = (($distributionLine -replace '^distributionUrl=', '')).Replace('\:', ':')
    $checksum = ($checksumLine -replace '^distributionSha256Sum=', '').Trim().ToLowerInvariant()
    $uri = [Uri]$distributionUrl
    if ($uri.Scheme -ne 'https') {
        throw 'Gradle distributionUrl must use HTTPS.'
    }
    $toolsDirectory = Join-Path $repositoryRoot 'build\tools'
    New-Item -ItemType Directory -Force -Path $toolsDirectory | Out-Null
    $archive = Join-Path $toolsDirectory ([IO.Path]::GetFileName($uri.LocalPath))
    if (-not (Test-Path -LiteralPath $archive)) {
        Invoke-WebRequest -Uri $uri -OutFile $archive
    }
    $actualChecksum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualChecksum -ne $checksum) {
        throw "Gradle distribution SHA-256 mismatch: expected $checksum, got $actualChecksum."
    }
    $distributionName = ([IO.Path]::GetFileNameWithoutExtension($archive)) -replace '-bin$', ''
    $distributionDirectory = Join-Path $toolsDirectory $distributionName
    $gradleCommand = Join-Path $distributionDirectory 'bin\gradle.bat'
    if (-not (Test-Path -LiteralPath $gradleCommand)) {
        Expand-Archive -LiteralPath $archive -DestinationPath $toolsDirectory -Force
    }
    if (-not (Test-Path -LiteralPath $gradleCommand)) {
        throw "Expanded Gradle launcher was not found at $gradleCommand."
    }
}

Push-Location $androidDirectory
try {
    & $gradleCommand @GradleArguments
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
