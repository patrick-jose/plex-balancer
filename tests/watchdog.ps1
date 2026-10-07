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
#
# The second trap is this suite's own. Test-RunInFlight answers one question -
# "is the real balancer mutex held right now?" - and the checks below assert on
# the ANSWER, including asserting it is free. A scheduled run that starts while
# this suite is executing holds that same mutex, so those assertions fail for a
# reason that has nothing to do with the code under test. Observed on 2026-10-07:
# the hourly task fired at 00:40 mid-suite and two checks failed with "a run is in
# flight" while the watcher was working perfectly. A suite that fails for reasons
# outside its control is one you learn to ignore, which costs more than it buys.
#
# So the suite waits for the machine to be quiet before touching anything, and
# reports SKIPPED - distinctly from passing and from failing - if it never gets
# that. Exit code 3 means skipped; Run-Tests.ps1 treats that as its own outcome
# rather than folding it into the verdict.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

. (Lift-Functions -Script 'watch.ps1' -Names @('Write-WatchLog', 'Invoke-Child', 'Test-RunInFlight'))
''

# ---- 0. wait for the balancer to be idle -------------------------------------
# Bounded, and it says so while it waits, so a long pause is visibly a wait and
# not a hang. The default is longer than a normal run because the run that started
# a minute ago may be a long one: the recorded deadline is 1800s.
$quietWaitSeconds = if ($env:PB_TEST_QUIET_WAIT) { [int]$env:PB_TEST_QUIET_WAIT } else { 1800 }
if (Test-RunInFlight) {
    "waiting up to ${quietWaitSeconds}s for the balancer to finish - it is running now"
    $waited = 0
    while ($waited -lt $quietWaitSeconds -and (Test-RunInFlight)) {
        Start-Sleep -Seconds 5
        $waited += 5
    }
}

if (Test-RunInFlight) {
    "SKIPPED: the balancer has been running for over ${quietWaitSeconds}s and still holds"
    "         Global\PlexBalancer. This suite asserts on whether that mutex is free, so it"
    "         cannot run alongside a real one without failing for the wrong reason."
    "         Re-run it when the machine is idle, or lower PB_TEST_QUIET_WAIT."
    exit 3
}

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
# Waits rather than asserting immediately: the killed holder releases the mutex in
# the kernel, but the process object can take a moment to be reaped, and a fixed
# sleep here used to be a race that only lost when the machine was busy.
$cleared = $false
for ($i = 0; $i -lt 50; $i++) {
    if (-not (Test-RunInFlight)) { $cleared = $true; break }
    Start-Sleep -Milliseconds 200
}
Assert-True 'the mutex is free again once the run ends' $cleared

# ---- 10. the machine is still idle after the suite ---------------------------
# The suite took a real mutex and released it. If a scheduled run started and
# finished in the meantime that is legitimate and not this suite's business, so
# this asserts only what the suite is responsible for: that it left nothing
# holding the mutex itself. $held is dead by now, so a "still busy" here means
# something leaked.
Assert-Equal 'the suite left nothing holding the mutex' (Test-RunInFlight) $false

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-TestResult -Suite 'watchdog'
