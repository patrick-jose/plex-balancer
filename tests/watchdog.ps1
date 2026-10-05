# The watchdog: the guard that stops one stuck run from becoming an unusable
# machine.
#
# On 2026-10-03 a watcher scan blocked on failing drives with no timeout. The
# scheduled task sat at "Running" forever, a second watcher started at 23:45
# anyway, and the blocked processes piled on top of a system already failing to
# page. Invoke-Child is the deadline that stops that; Test-RunInFlight is what
# refuses to start a second run on top of the first.
#
# One trap worth naming: a Windows mutex is recursive. A thread that already owns
# Global\PlexBalancer re-acquires it successfully and WaitOne reports success, so
# testing the in-flight case on the same thread that holds the mutex falsely
# reports "idle". The in-flight check below therefore uses a separate process.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

. (Lift-Functions -Script 'watch.ps1' -Names @('Write-WatchLog', 'Invoke-Child', 'Test-RunInFlight'))
''

$tmp = Join-Path $env:TEMP ('pbwatch-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# Write-WatchLog writes here; Invoke-Child calls it when a child times out.
$watchLog = Join-Path $tmp 'watch.log'

function New-Child {
    param([string]$Name, [string]$Body)
    $p = Join-Path $tmp $Name
    [System.IO.File]::WriteAllText($p, $Body, (New-Object System.Text.UTF8Encoding $false))
    return $p
}

# ---- 1. a child that finishes is reported honestly --------------------------
$ok = New-Child 'ok.ps1' @'
Write-Output 'hello from the child'
exit 0
'@
$r = Invoke-Child -Script $ok -TimeoutSeconds 60
Assert-False 'fast child did not time out'      $r.TimedOut
Assert-Equal  'fast child exit code is 0'        $r.ExitCode 0
Assert-True   'fast child stdout was captured'   (($r.Output -join "`n") -match 'hello from the child')

# ---- 2. a child that hangs is killed at the deadline -------------------------
# This is the whole point. A thread blocked in disk I/O cannot be asked politely,
# so the process is taken down outright.
$hang = New-Child 'hang.ps1' @'
while ($true) { Start-Sleep -Milliseconds 200 }
'@
$r = Invoke-Child -Script $hang -TimeoutSeconds 3
Assert-True  'hanging child reported as timed out' $r.TimedOut
Assert-True  'the kill was written to the watcher log' `
    ((Get-Content $watchLog -Raw -ErrorAction SilentlyContinue) -match 'did not finish within')

# ---- 3. stderr is surfaced, not swallowed ------------------------------------
$noisy = New-Child 'noisy.ps1' @'
[Console]::Error.WriteLine('something went wrong')
Write-Output 'normal line'
'@
$r = Invoke-Child -Script $noisy -TimeoutSeconds 60
Assert-True 'stdout kept'  (($r.Output -join "`n") -match 'normal line')
Assert-True 'stderr kept'  (($r.Output -join "`n") -match 'stderr: .*something went wrong')

# ---- 4. a missing script must not throw or hang ------------------------------
# PowerShell itself reports the missing file, so this surfaces on stderr rather
# than as a launch failure. Either is fine; what matters is that it comes back as
# a result instead of an exception, and that nothing is left running.
$r = Invoke-Child -Script (Join-Path $tmp 'not-here.ps1') -TimeoutSeconds 10
Assert-False 'missing child is not reported as a timeout' $r.TimedOut
Assert-True  'missing child surfaces the problem instead of throwing' `
    ((($r.Output -join "`n") -match 'failed to launch') -or ($r.Output.Count -gt 0))

# ---- 5. no temp files left behind --------------------------------------------
# Invoke-Child makes two GetTempFileName files per child; compare a tight
# before/after so an unrelated temp file cannot make this flaky.
$before = @(Get-ChildItem $env:TEMP -Filter 'tmp*.tmp' -File -ErrorAction SilentlyContinue).Count
[void](Invoke-Child -Script $ok -TimeoutSeconds 60)
$after = @(Get-ChildItem $env:TEMP -Filter 'tmp*.tmp' -File -ErrorAction SilentlyContinue).Count
Assert-Equal 'Invoke-Child cleaned up its temp files' $after $before

# ---- 6. Test-RunInFlight: idle ----------------------------------------------
$script:MutexHeldHere = $false
Assert-False 'no run in flight when nothing holds the mutex' (Test-RunInFlight)

# ---- 7. the recursive-mutex guard -------------------------------------------
# If this thread already owns the mutex, WaitOne would report success and the
# function would wrongly answer "idle". The guard makes it answer "busy".
$script:MutexHeldHere = $true
Assert-True 'guard reports busy when this thread owns the mutex' (Test-RunInFlight)
$script:MutexHeldHere = $false

# ---- 8. Test-RunInFlight: a real run, in another process --------------------
$ready = Join-Path $tmp 'held.marker'
$holder = New-Child 'holder.ps1' @"
`$m = New-Object System.Threading.Mutex(`$false, 'Global\PlexBalancer')
[void]`$m.WaitOne(0)
[System.IO.File]::WriteAllText('$ready', 'held')
while (`$true) { Start-Sleep -Milliseconds 200 }
"@
$me = $PID
$held = Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holder) -NoNewWindow -PassThru
try {
    $gone = $false
    for ($i = 0; $i -lt 50; $i++) {
        if (Test-Path $ready) { $gone = $true; break }
        Start-Sleep -Milliseconds 200
    }
    Assert-True 'the separate holder process took the mutex' $gone
    # give the file handle a moment to be visible as held
    if ($gone) { Start-Sleep -Milliseconds 300 }
    Assert-True 'a run in another process is detected' (Test-RunInFlight)
}
finally {
    # Never leave a holder behind: it would block every future balancer run.
    Stop-Process -Id $held.Id -Force -ErrorAction SilentlyContinue
    [void]$held.WaitForExit(10000)
    Remove-Item $ready -Force -ErrorAction SilentlyContinue
}

# ---- 9. and it clears once that process is gone ------------------------------
for ($i = 0; $i -lt 25; $i++) {
    if (-not (Test-RunInFlight)) { break }
    Start-Sleep -Milliseconds 200
}
Assert-False 'the mutex is free again once the run ends' (Test-RunInFlight)

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-TestResult -Suite 'watchdog'
