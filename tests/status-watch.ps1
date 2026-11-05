$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')
. (Lift-Functions -Script 'status.ps1' -Names 'Get-StatusWatchDelay','Watch-Status','Get-PlaylistNoticeRows','Get-PlaylistRunSummary','Format-StatusWrappedText')
$sampleNotices = [pscustomobject]@{
    'tv-missing-show' = 'South Park: aired/released episodes absent locally: S29E04. Air dates do not guarantee download availability.'
    'cadence-gap-live-a-b' = "Managed live playlist cadence gap: 4 TV episodes between movie #139 'Movie A' and movie #144 'Movie B' (expected 5). Review the managed order; no source-playlist or media changes were made."
    'cycle-paused' = 'Cycle 6 paused: only 24 of 25 active shows have eligible downloaded unwatched episodes; blocked: VisionQuest: no next local episode; update content or verify series status; no partial cycle queued.'
}
$statusRows = @(Get-PlaylistNoticeRows ([pscustomobject]@{
    'cycle-progress' = 'Cycle 8: 11/25 show slots scheduled; 14 remain until cycle end.'
    'episode-download-summary' = 'Download check: no known aired/released episodes are missing locally across 25 checked shows.'
    'status-checked-at' = '2026-11-04T20:00:00-03:00'
}))
Assert-Equal 'cycle progress is rendered in the cycle category' (@($statusRows | Where-Object Category -eq 'CYCLE').Count) 1
Assert-Equal 'episode availability is rendered as a check, including the no-missing case' (@($statusRows | Where-Object { $_.Category -eq 'CHECK' -and $_.Text -match 'no known aired/released episodes are missing locally' }).Count) 1
Assert-Equal 'status timestamp is metadata and does not render as a notification' (@($statusRows | Where-Object Text -match '2026-11-04T20:00:00').Count) 0
$noticeRows = @(Get-PlaylistNoticeRows $sampleNotices)
Assert-Equal 'playlist actions sort ahead of informational notices' $noticeRows[0].Category 'ACTION'
Assert-Equal 'cadence notice is compacted with positions and movie boundary' $noticeRows[0].Text 'Cadence 4/5 episodes (#139 -> #144): Movie A -> Movie B'
Assert-Equal 'cycle shortage is labeled separately from action items' (@($noticeRows | Where-Object Category -eq 'CYCLE').Count) 1
$dedupCycleRows = @(Get-PlaylistNoticeRows -Notices $sampleNotices -CycleStopReasons @('Cycle 6 paused: only 24 of 25 active shows have eligible downloaded unwatched episodes; blocked: VisionQuest: no next local episode; no partial cycle queued.'))
Assert-Equal 'cycle alert and persisted stop reason do not render twice' (@($dedupCycleRows | Where-Object Category -eq 'CYCLE').Count) 1
$fallbackCycleRows = @(Get-PlaylistNoticeRows -Notices ([pscustomobject]@{}) -CycleStopReasons @('Cycle 7 paused: only 23 of 25 active shows have eligible downloaded unwatched episodes; blocked: VisionQuest: no next local episode; update content; no partial cycle queued.'))
Assert-Equal 'cycle stop reason renders even when alert cache is empty' $fallbackCycleRows[0].Category 'CYCLE'
Assert-Equal 'cycle stop reason includes the blocked show and cause' $fallbackCycleRows[0].Text 'Cycle 7 paused: 23/25 eligible; blocked: VisionQuest: no next local episode; update content; no partial cycle was queued.'
$stoppedRows = @(Get-PlaylistNoticeRows -Notices ([pscustomobject]@{}) -CycleStopReasons @('Cycle 2 stopped after 13 of 25 show slots; blocked: show14: no next local episode. Resume at this show when an eligible episode or replacement is available.'))
Assert-Equal 'partial cycle stop is rendered with its exact prefix length' $stoppedRows[0].Text 'Cycle 2 stopped after 13/25 slots; blocked: show14: no next local episode. Resume here when content/replacement is ready.'
$unverifiedRun = Get-PlaylistRunSummary ([pscustomobject]@{Apply=$true;Verified=$false;CurrentCount=227;DesiredCount=244})
Assert-Equal 'unverified apply summary remains available even when there are no notices' $unverifiedRun.Text 'LAST APPLY NOT VERIFIED: 227 live / 244 proposed; see queue preview before retrying.'
$previewRun = Get-PlaylistRunSummary ([pscustomobject]@{Apply=$false;Verified=$false;CurrentCount=227;DesiredCount=244})
Assert-Equal 'preview summary clearly reports that no playlist writes occurred' $previewRun.Text 'Latest run was preview only: 227 live / 244 proposed; no playlist writes.'
$wrapped = @(Format-StatusWrappedText -Text 'A long playlist notification should wrap at readable word boundaries without losing its final words.' -Width 40 -Prefix '  ! ')
Assert-True 'playlist notification wraps to the terminal width' (@($wrapped | Where-Object Length -gt 40).Count -eq 0)
Assert-True 'wrapped notification preserves the complete message' (($wrapped -join ' ') -match 'final words\.')
Assert-True 'wrapped continuation aligns under text, not the bullet' ($wrapped.Count -gt 1 -and $wrapped[1].StartsWith('    ') -and -not $wrapped[1].StartsWith('  ! '))
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
