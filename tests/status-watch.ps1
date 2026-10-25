$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')
. (Lift-Functions -Script 'status.ps1' -Names 'Get-StatusWatchDelay','Watch-Status')
$now = [datetime]'2026-10-24T12:00:00'
Assert-Equal 'no task waits silently without a busy loop' (Get-StatusWatchDelay $null $now) 60000
Assert-Equal 'scheduled deadline determines the final sleep' (Get-StatusWatchDelay ($now.AddSeconds(7)) $now) 7000
Assert-Equal 'fractional deadline uses millisecond sleep' (Get-StatusWatchDelay ($now.AddMilliseconds(350)) $now) 350
Assert-Equal 'far-away deadline allows silent schedule checks' (Get-StatusWatchDelay ($now.AddHours(1)) $now) 60000
Assert-Equal 'stale deadline cannot busy-loop' (Get-StatusWatchDelay ($now.AddMinutes(-2)) $now) 60000
Assert-Equal 'missing default timestamp cannot busy-loop' (Get-StatusWatchDelay ([datetime]::MinValue) $now) 60000

# Run the real loop with a fake clock. Silent polls must NOT call Show-Snapshot.
function Get-Date { return $script:FakeNow }
function Show-Snapshot {
    $script:Snapshots += $script:FakeNow
    $script:StatusNextRunTime = if($script:Snapshots.Count -eq 1 -or $script:Stale){$script:Due}else{$now.AddHours(1)}
}
function Get-StatusNextScheduledRun {
    if($null -eq $script:Due){return $null}
    if($script:FakeNow -ge $script:Due -and -not $script:Stale){return $now.AddHours(1)}
    return $script:Due
}
function Start-Sleep {
    param([int]$Milliseconds)
    $script:Delays += $Milliseconds
    $script:FakeNow = $script:FakeNow.AddMilliseconds($Milliseconds)
    if($script:Delays.Count -eq 5){throw 'test-watch-finished'}
}
function Run-FakeWatch {
    param($Due,[bool]$Stale=$false)
    $script:Due=$Due; $script:Stale=$Stale; $script:FakeNow=$now
    $script:Snapshots=@(); $script:Delays=@()
    try { Watch-Status } catch { if($_.Exception.Message -ne 'test-watch-finished'){throw} }
}
Run-FakeWatch ($now.AddSeconds(90))
Assert-Equal 'only initial snapshot and scheduled run redraw the screen' $script:Snapshots.Count 2
Assert-Equal 'redraw occurs at the actual scheduled deadline' $script:Snapshots[1] ($now.AddSeconds(90))
Assert-True 'silent polling does not redraw at one minute' ($now.AddMinutes(1) -notin $script:Snapshots)
Assert-Equal 'first schedule check is silent, not a 30-second redraw' $script:Delays[0] 60000
Assert-Equal 'final wait aligns with the deadline' $script:Delays[1] 30000
Run-FakeWatch ($now.AddSeconds(7)) $true
Assert-Equal 'scheduler keeping an old deadline cannot repeat redraws' $script:Snapshots.Count 2
Run-FakeWatch $null
Assert-Equal 'no registered task never triggers periodic redraws' $script:Snapshots.Count 1
Write-TestResult -Suite 'status-watch'
