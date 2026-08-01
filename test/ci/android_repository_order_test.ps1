$ErrorActionPreference = 'Stop'

$workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$settings = Get-Content -Raw -LiteralPath (Join-Path $workspaceRoot 'android\settings.gradle')
$build = Get-Content -Raw -LiteralPath (Join-Path $workspaceRoot 'android\build.gradle')

function Assert-Before(
    [string]$Content,
    [string]$First,
    [string]$Second,
    [string]$Message
) {
    $firstIndex = $Content.IndexOf($First, [StringComparison]::Ordinal)
    $secondIndex = $Content.IndexOf($Second, [StringComparison]::Ordinal)
    if ($firstIndex -lt 0 -or $secondIndex -lt 0 -or $firstIndex -ge $secondIndex) {
        throw $Message
    }
}

Assert-Before $settings 'google()' 'maven.aliyun.com' `
    'Official Google plugin repository must precede Aliyun mirrors.'
Assert-Before $settings 'mavenCentral()' 'maven.aliyun.com' `
    'Maven Central plugin repository must precede Aliyun mirrors.'
Assert-Before $build 'google()' 'maven.aliyun.com' `
    'Official Google dependency repository must precede Aliyun mirrors.'
Assert-Before $build 'mavenCentral()' 'maven.aliyun.com' `
    'Maven Central dependency repository must precede Aliyun mirrors.'

Write-Output 'Android repository order test passed.'
