$ErrorActionPreference = 'Stop'

$workspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$registrantPath = Join-Path $workspaceRoot 'windows\flutter\generated_plugin_registrant.cc'
$pluginsPath = Join-Path $workspaceRoot 'windows\flutter\generated_plugins.cmake'

$registrant = Get-Content -Raw -LiteralPath $registrantPath
$plugins = Get-Content -Raw -LiteralPath $pluginsPath

if ($registrant -notmatch 'FlutterBluePlusPluginRegisterWithRegistrar') {
    throw 'flutter_blue_plus_winrt is missing from the Windows plugin registrant.'
}

if ($plugins -notmatch '(?m)^\s*flutter_blue_plus_winrt\s*$') {
    throw 'flutter_blue_plus_winrt is missing from the Windows plugin build list.'
}

Write-Output 'Windows BLE plugin registration test passed.'
