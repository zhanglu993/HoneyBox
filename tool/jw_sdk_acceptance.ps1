#requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Flutter = 'flutter',
  [Alias('TargetAddress')][string]$Address,
  [ValidateSet('Phase1','History','HistoryReplay','ConfigurationRead','Configuration','ReadOnly','RemainingObserve','RemainingRoutine','RemainingLab')][string]$Mode = 'Phase1',
  [ValidateRange(1,10)][int]$HistoryRounds=2,
  [ValidateRange(1,3600)][int]$HistoryIdleSeconds=30,
  [ValidateRange(1,86400)][int]$HistoryTotalSeconds=1800,
  [ValidateRange(1,128)][int]$HistoryMaxQueueMb=32,
  [string]$Name,
  [ValidateRange(1,3600)][int]$ScanSeconds = 120,
  [ValidateRange(1,10)][int]$ScanAttempts = 3,
  [ValidateRange(1,300)][int]$HeartSeconds = 60,
  [ValidateRange(0,10)][int]$ReconnectRounds = 2,
  [string]$ReferenceCapabilities,
  [string]$ExpectedIdentitySha256,
  [string]$OutputDirectory,
  # RemainingLab requires this switch; Phase1 uses it to authorize destructive first bind.
  [switch]$LabAuthorized,
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $Address -and -not $Name) { throw 'Provide -Address or -Name; target must come from actual scan results.' }
if (-not $OutputDirectory) {
  $OutputDirectory = Join-Path $repo ('output/jw-sdk-acceptance/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$bundle = Join-Path $repo $(if ($Mode -eq 'HistoryReplay') {'output/jw-history-replay/acceptance-host'} elseif ($Mode -like 'Remaining*') {'output/jw-phase5/acceptance-host'} elseif ($Mode -eq 'ReadOnly') {'output/jw-phase4/acceptance-host'} else {'output/jw-sdk-acceptance-host'})
$summaryPath = Join-Path $OutputDirectory 'results.json'
if ((Test-Path -LiteralPath $summaryPath) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'remaining-observe/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'remaining-routine/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'remaining-lab/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'remaining-restart/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'full/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'restart/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'history-replay/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'history-replay-restart/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'history/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'history-restart/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'configuration/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'configuration-read/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'configuration-restart/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'read-only/result.json')) -or
    (Test-Path -LiteralPath (Join-Path $OutputDirectory 'read-only-restart/result.json'))) {
  throw 'Output directory already contains results; choose a fresh directory. Existing reports are preserved.'
}
if ($Mode -eq 'HistoryReplay' -and (-not $ExpectedIdentitySha256 -or -not $Address -or -not $ReferenceCapabilities)) {throw 'HistoryReplay requires the explicit address, existing expected identity digest, and reference capability profile.'}
if (($Mode -eq 'ReadOnly' -or $Mode -like 'Remaining*') -and -not $ExpectedIdentitySha256) { throw 'ReadOnly requires the existing expected identity digest.' }
$firstMode=switch ($Mode) { 'RemainingObserve' {'remaining-observe'} 'RemainingRoutine' {'remaining-routine'} 'RemainingLab' {'remaining-lab'} 'ReadOnly' {'read-only'} 'HistoryReplay' {'history-replay'} 'History' {'history'} 'ConfigurationRead' {'configuration-read'} 'Configuration' {'configuration'} default {'full'} }
$restartMode=if ($Mode -eq 'HistoryReplay') {'history-replay-restart'} elseif ($Mode -like 'Remaining*') {'remaining-restart'} elseif ($Mode -eq 'ReadOnly') {'read-only-restart'} elseif ($Mode -eq 'History') {'history-restart'} elseif ($Mode -like 'Configuration*') {'configuration-restart'} else {'restart'}
$fullPath = Join-Path $OutputDirectory $firstMode
$restartPath = Join-Path $OutputDirectory $restartMode
$process = $null
$summary = [ordered]@{schemaVersion=$(if ($Mode -eq 'HistoryReplay') {6} elseif ($Mode -like 'Remaining*') {5} elseif ($Mode -eq 'ReadOnly') {4} elseif ($Mode -like 'Configuration*') {3} elseif ($Mode -eq 'History') {2} else {1}); mode=$Mode; status='fail'; exitCode=1; startedUtc=[DateTime]::UtcNow.ToString('o'); results=@()}
try {
  Push-Location $repo
  try {
    if (-not $SkipBuild) {
      & $Flutter build windows --debug --no-pub -t lib/validation/jw_sdk_acceptance_main.dart *> (Join-Path $OutputDirectory 'build.txt')
      if ($LASTEXITCODE -ne 0) { throw 'SDK acceptance host build failed; see build.txt.' }
      New-Item -ItemType Directory -Path $bundle -Force | Out-Null
      # Copy into our isolated validation bundle; leave normal UI bundle separate.
      Get-ChildItem -LiteralPath (Join-Path $repo 'build/windows/x64/runner/Debug') | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $bundle -Recurse -Force
      }
    }
  } finally { Pop-Location }
  $exe = Join-Path $bundle 'HoneyBox.exe'
  if (-not (Test-Path -LiteralPath $exe)) { throw 'Validation host missing; run without -SkipBuild.' }
  $reference = $null
  if ($ReferenceCapabilities) { $reference = Get-Content -LiteralPath $ReferenceCapabilities -Raw | ConvertFrom-Json }
  $common = @('--scan-seconds',"$ScanSeconds",'--scan-attempts',"$ScanAttempts",'--heart-seconds',"$HeartSeconds",'--reconnect-rounds',"$ReconnectRounds")
  if ($Address) { $common += @('--address',$Address) }
  if ($Name) { $common += @('--name',$Name) }
  if ($reference) { $common += @('--expect-functions',[string]$reference.function_list,'--expect-factory',[string]$reference.factory_switch) }
  if ($Mode -in @('History','HistoryReplay')) {$common += @('--history-rounds',"$HistoryRounds",'--history-idle-seconds',"$HistoryIdleSeconds",'--history-total-seconds',"$HistoryTotalSeconds",'--history-max-queue-mb',"$HistoryMaxQueueMb")}
  if ($Mode -eq 'RemainingLab' -and -not $LabAuthorized) {throw 'RemainingLab requires the already approved dedicated test-device authorization flag.'}
  if ($LabAuthorized -and ($Mode -like 'Remaining*' -or $Mode -eq 'Phase1')) {$common += @('--lab-authorized','true')}
  $sdkModes=if ($Mode -eq 'ConfigurationRead') {@($firstMode)} else {@($firstMode,$restartMode)}
  $cancellationGraceSeconds=if ($Mode -eq 'Configuration') {$ScanSeconds*$ScanAttempts+120} else {45}
  foreach ($sdkMode in $sdkModes) {
    $out = if ($sdkMode -eq $firstMode) {$fullPath} else {$restartPath}
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $sdkArguments = $common + @('--output',$out,'--mode',$sdkMode)
    if ($sdkMode -eq $firstMode -and $ExpectedIdentitySha256) {$sdkArguments += @('--expected-id-sha256',$ExpectedIdentitySha256)}
    if ($sdkMode -eq $restartMode) { $restartIdentity=if($Mode -like 'Remaining*'){[string]$summary.results[0].remainingDevice.identitySha256}else{[string]$summary.results[0].identitySha256};$sdkArguments += @('--expected-id-sha256',$restartIdentity); if ($Mode -in @('History','HistoryReplay')) {$sdkArguments += @('--history-baseline',(Join-Path $fullPath 'result.json'))}; if ($Mode -eq 'Configuration') {$sdkArguments += @('--configuration-baseline',(Join-Path $fullPath 'configuration-baseline.json'))}; if ($Mode -eq 'ReadOnly') {$sdkArguments += @('--read-only-baseline',(Join-Path $fullPath 'result.json'))};if ($Mode -like 'Remaining*') {$sdkArguments += @('--remaining-baseline',(Join-Path $fullPath 'result.json'))} }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $exe
    $startInfo.WorkingDirectory = $bundle
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($arg in $sdkArguments) { $startInfo.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Cannot start validation host.' }
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    $eventsPath = Join-Path $out 'events.jsonl'
    $seen = 0
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $cycles = if ($sdkMode -eq $firstMode) {if ($Mode -eq 'HistoryReplay') {2} elseif ($Mode -eq 'History') {$HistoryRounds} elseif ($Mode -eq 'Configuration') {2} elseif ($Mode -eq 'ConfigurationRead') {1} else {1 + $ReconnectRounds}} else {1}
    $runBudgetSeconds = $ScanSeconds * $ScanAttempts * $cycles + $HeartSeconds + 240
    if ($Mode -in @('History','HistoryReplay') -and $sdkMode -eq $firstMode) {$runBudgetSeconds += $HistoryTotalSeconds*$(if($Mode -eq 'HistoryReplay'){2}else{$HistoryRounds})}
    $cancellingAt = $null
    Write-Host "SDK $sdkMode started (PID $($process.Id)); scan windows ${ScanSeconds}s x $ScanAttempts; cancel: create $out/cancel"
    while (-not $process.WaitForExit(1000)) {
      if ($watch.Elapsed.TotalSeconds -gt $runBudgetSeconds) {
        [IO.File]::WriteAllText((Join-Path $out 'cancel'),'cancel')
      }
      if ((Test-Path -LiteralPath (Join-Path $out 'cancel')) -and $null -eq $cancellingAt) {
        $cancellingAt = $watch.Elapsed.TotalSeconds
      }
      if ($null -ne $cancellingAt -and $watch.Elapsed.TotalSeconds - $cancellingAt -gt $cancellationGraceSeconds) {
        $process.Kill()
        throw "Owned SDK host did not complete cancellation within${cancellationGraceSeconds}seconds; preserve pending configuration evidence."
      }
      if (Test-Path -LiteralPath (Join-Path $OutputDirectory 'cancel')) {
        [IO.File]::WriteAllText((Join-Path $out 'cancel'),'cancel')
      }
      if (Test-Path -LiteralPath $eventsPath) {
        $lines = @(Get-Content -LiteralPath $eventsPath)
        for ($i=$seen;$i -lt $lines.Count;$i++) {
          try {
            $event = $lines[$i] | ConvertFrom-Json
            if ($event.type -in @('scanStart','scanProgress','scanWindowElapsed','historyProgress','step','finished')) {
              Write-Host ($event | ConvertTo-Json -Compress -Depth 8)
            }
          } catch { } # Concurrent final append is consumed on the next read.
        }
        $seen = $lines.Count
      }
    }
    [IO.File]::WriteAllText((Join-Path $out 'host-stdout.txt'),$stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText((Join-Path $out 'host-stderr.txt'),$stderr.GetAwaiter().GetResult())
    $processExit = $process.ExitCode; $process.Dispose(); $process = $null
    $resultPath = Join-Path $out 'result.json'
    if (-not (Test-Path -LiteralPath $resultPath)) { throw "SDK $sdkMode exited $processExit without a result; see host logs." }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    $result | Add-Member -NotePropertyName nativeExitCode -NotePropertyValue $processExit -Force
    $summary.results += $result
    if ($result.exitCode -ne 0 -or $processExit -ne 0) {
      $summary.status = $result.status
      $summary.exitCode = if ($result.exitCode -ne 0) {[int]$result.exitCode} else {1}
      break
    }
    if ($sdkMode -eq $restartMode -or $Mode -eq 'ConfigurationRead') { $summary.status='pass';$summary.exitCode=0 }
  }
} catch {
  $summary.error = $_.Exception.Message
} finally {
  if ($process -and -not $process.HasExited) {
    # Graceful SDK cancellation only affects the process this script started.
    [IO.File]::WriteAllText((Join-Path $out 'cancel'),'cancel')
    if (-not $process.WaitForExit($cancellationGraceSeconds*1000)) { $process.Kill(); $summary.error="Owned host did not finish cancellation; terminated after${cancellationGraceSeconds}seconds." }
    $process.Dispose()
  }
  $summary.finishedUtc = [DateTime]::UtcNow.ToString('o')
  [IO.File]::WriteAllText($summaryPath,($summary | ConvertTo-Json -Depth 30))
}
Write-Output ($summary | ConvertTo-Json -Compress -Depth 30)
Write-Host "SDK acceptance report: $summaryPath"
exit [int]$summary.exitCode
