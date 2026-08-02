param(
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel')]
    [string[]]$Configuration,
    [string]$TestRegex,
    [switch]$Performance,
    [string]$EvidencePath
)

$ErrorActionPreference = 'Stop'

function Find-CMake {
    $command = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $installationPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($installationPath)) {
            $candidate = Join-Path $installationPath.Trim() 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    throw 'cmake.exe was not found on PATH or in the current Visual Studio installation.'
}

$cmake = Find-CMake
$ctest = Join-Path (Split-Path -Parent $cmake) 'ctest.exe'
if (-not (Test-Path -LiteralPath $ctest)) {
    throw "ctest.exe was not found beside $cmake."
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourceDirectory = Join-Path $repositoryRoot 'windows/media'
$buildDirectory = Join-Path $repositoryRoot 'build/media-windows-adapter-msvc-x64'
$configurations = if ($Performance) {
    @('Release')
}
elseif ($PSBoundParameters.ContainsKey('Configuration')) {
    @($Configuration)
}
else {
    @('Debug', 'Release')
}

& $cmake `
    -S $sourceDirectory `
    -B $buildDirectory `
    -G 'Visual Studio 17 2022' `
    -A x64 `
    -DBUILD_TESTING=ON `
    -DBUILD_SHARED_LIBS=OFF
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

foreach ($currentConfiguration in $configurations) {
    Write-Host "Building honey_media_windows ($currentConfiguration)..."
    & $cmake `
        --build $buildDirectory `
        --config $currentConfiguration `
        --parallel
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "Testing honey_media_windows ($currentConfiguration)..."
    $ctestArguments = @(
        '--test-dir', $buildDirectory,
        '-C', $currentConfiguration,
        '--output-on-failure',
        '--no-tests=error'
    )
    if (-not [string]::IsNullOrWhiteSpace($TestRegex)) {
        $ctestArguments += @('-R', $TestRegex)
    }
    & $ctest @ctestArguments
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

if ($Performance) {
    $benchmark = Join-Path $buildDirectory 'tests/Release/hmw_windows_media_benchmark.exe'
    if (-not (Test-Path -LiteralPath $benchmark -PathType Leaf)) {
        throw "Benchmark executable was not produced at $benchmark."
    }
    $requestedEvidencePath = if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
        Join-Path $repositoryRoot 'output/windows-media-performance.json'
    }
    elseif ([System.IO.Path]::IsPathRooted($EvidencePath)) {
        $EvidencePath
    }
    else {
        Join-Path $repositoryRoot $EvidencePath
    }
    $resolvedEvidencePath =
        [System.IO.Path]::GetFullPath($requestedEvidencePath)
    Write-Host "Running Windows media reference benchmark..."
    & $benchmark --json $resolvedEvidencePath
    $benchmarkExitCode = $LASTEXITCODE
    exit $benchmarkExitCode
}
