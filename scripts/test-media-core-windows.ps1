param(
    [ValidateSet('Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel')]
    [string]$Configuration = 'Debug'
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
$sourceDirectory = Join-Path $repositoryRoot 'media_core'
$buildDirectory = Join-Path $repositoryRoot ("build/media-core-" + $Configuration.ToLowerInvariant())

& $cmake -S $sourceDirectory -B $buildDirectory
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $cmake --build $buildDirectory --config $Configuration
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $ctest --test-dir $buildDirectory -C $Configuration --output-on-failure
exit $LASTEXITCODE
