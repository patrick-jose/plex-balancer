# Storage history: the durable record of what was on disk, and when it left.
#
# Everything here is about the difference between "this file is gone" and "I
# could not see this file this time". A storage scan that marks files missing
# because a USB disk was unplugged, or because one folder failed to enumerate,
# would manufacture exactly the alarm the script exists to answer. So the tests
# cover the quiet cases as carefully as the loud ones:
#
#   appeared / changed / moved / vanished / reappeared   the five transitions
#   offline and partial roots                            never judged missing
#   the 48 hour move window                              old absences stay losses
#   append-only ingest offsets                           no lost or double events
#   watched-retirement records                           ingested once, by name
#   dry run                                              writes nothing
#   source text                                          no media-deleting cmdlet
#
# The functions are lifted from the shipping script, so a rename or a changed
# signature fails here instead of letting a stale copy of the logic pass.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

. (Lift-Functions -Script 'storage-history.ps1' -Names @(
        'New-StorageEntry', 'Get-StorageIndex', 'Save-StorageIndex', 'Add-StorageEvent',
        'Get-StorageScan', 'Compare-StorageHistory', 'Test-StorageScanDue',
        'Invoke-StorageIngest', 'Get-StorageEvents', 'Get-StorageHistoryReport',
        'Format-StorageHistoryReport'))

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('storage-history-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
try {
    $tvRoot = Join-Path $tmp 'TV'
    $movieRoot = Join-Path $tmp 'Movies'
    $season = Join-Path $tvRoot 'Show\Season 1'
    $null = New-Item -ItemType Directory -Path $season -Force
    $null = New-Item -ItemType Directory -Path $movieRoot -Force

    $ep1 = Join-Path $season 'ep1.mkv'
    $ep2 = Join-Path $season 'ep2.mkv'
    $film = Join-Path $movieRoot 'film.mkv'
    [IO.File]::WriteAllText($ep1, ('a' * 100))
    [IO.File]::WriteAllText($ep2, ('b' * 200))
    [IO.File]::WriteAllText($film, ('c' * 300))
    [IO.File]::WriteAllText((Join-Path $season 'note.txt'), 'not media')

    $cfg = [pscustomobject]@{
        libraries = @(
            [pscustomobject]@{ name = 'TV'; roots = @($tvRoot); mediaExtensions = @('.mkv') },
            [pscustomobject]@{ name = 'Movies'; roots = @($movieRoot); mediaExtensions = @('.mkv') }
        )
    }
    $tvKey = $tvRoot.TrimEnd('\').ToLowerInvariant()
    $t0 = [datetime]'2026-11-14T08:00:00'

    # ---- first scan ---------------------------------------------------------
    $empty = [pscustomobject]@{ Version = 1; At = ''; Files = @{}; RootHealth = @{} }
    $scan1 = Get-StorageScan -Config $cfg
    $r1 = Compare-StorageHistory -Index $empty -Scan $scan1 -At $t0
    Assert-Equal 'first scan reports every media file as appeared' @($r1.Events | Where-Object { $_.event -eq 'appeared' }).Count 3
    Assert-Equal 'non-media files are not tracked' $r1.Index.Files.Count 3
    Assert-Equal 'first scan keeps the root health it measured' ([string]$r1.Index.RootHealth[$tvKey].State) 'ok'

    $key = $ep1.ToLowerInvariant()
    Assert-Equal 'a new entry starts Present' ([string]$r1.Index.Files[$key].State) 'Present'
    Assert-Equal 'first seen is stamped at the scan time' ([string]$r1.Index.Files[$key].FirstSeen) $t0.ToString('o')
    Assert-Equal 'the library name travels with the entry' ([string]$r1.Index.Files[$key].Library) 'TV'

    # ---- no change ----------------------------------------------------------
    $r2 = Compare-StorageHistory -Index $r1.Index -Scan (Get-StorageScan -Config $cfg) -At $t0.AddMinutes(5)
    Assert-Equal 'a rescan with no change emits no events' $r2.Events.Count 0
    Assert-Equal 'a rescan with no change keeps the entry count' $r2.Index.Files.Count 3

    # ---- changed ------------------------------------------------------------
    [IO.File]::WriteAllText($ep1, ('a' * 150))
    $r3 = Compare-StorageHistory -Index $r2.Index -Scan (Get-StorageScan -Config $cfg) -At $t0.AddHours(1)
    $changed = @($r3.Events | Where-Object { $_.event -eq 'changed' })
    Assert-Equal 'a size change is recorded as changed' $changed.Count 1
    Assert-Equal 'the changed event names the old size' ([long]$changed[0].oldSize) 100
    Assert-Equal 'the entry follows the new size' ([long]$r3.Index.Files[$key].Size) 150

    # ---- moved --------------------------------------------------------------
    $ep2Dest = Join-Path $movieRoot 'ep2.mkv'
    Move-Item -LiteralPath $ep2 -Destination $ep2Dest
    $ep2FirstSeen = [string]$r1.Index.Files[$ep2.ToLowerInvariant()].FirstSeen
    $r4 = Compare-StorageHistory -Index $r3.Index -Scan (Get-StorageScan -Config $cfg) -At $t0.AddHours(2)
    $moved = @($r4.Events | Where-Object { $_.event -eq 'moved' })
    Assert-Equal 'a file that reappears under another root is recorded as moved' $moved.Count 1
    Assert-Equal 'the move keeps the historical first-seen' ([string]$r4.Index.Files[$ep2Dest.ToLowerInvariant()].FirstSeen) $ep2FirstSeen
    Assert-Equal 'no vanished event for a matched move' @($r4.Events | Where-Object { $_.event -eq 'vanished' }).Count 0
    Assert-Equal 'a move does not change the tracked file count' $r4.Index.Files.Count 3

    # ---- vanished -----------------------------------------------------------
    Remove-Item -LiteralPath $ep1 -Force
    $r5 = Compare-StorageHistory -Index $r4.Index -Scan (Get-StorageScan -Config $cfg) -At $t0.AddHours(3)
    $vanished = @($r5.Events | Where-Object { $_.event -eq 'vanished' })
    Assert-Equal 'a clean scan records a disappearance' $vanished.Count 1
    Assert-Equal 'the vanished entry is kept as Missing' ([string]$r5.Index.Files[$key].State) 'Missing'
    Assert-True 'MissingSince is stamped' ([bool]$r5.Index.Files[$key].MissingSince)

    $r6 = Compare-StorageHistory -Index $r5.Index -Scan (Get-StorageScan -Config $cfg) -At $t0.AddHours(4)
    Assert-Equal 'a file already Missing is not reported again' @($r6.Events | Where-Object { $_.event -eq 'vanished' }).Count 0

    # ---- reappeared ---------------------------------------------------------
    [IO.File]::WriteAllText($ep1, ('a' * 150))
    $r7 = Compare-StorageHistory -Index $r6.Index -Scan (Get-StorageScan -Config $cfg) -At $t0.AddHours(5)
    $reappeared = @($r7.Events | Where-Object { $_.event -eq 'reappeared' })
    Assert-Equal 'the same path coming back is reappeared' $reappeared.Count 1
    Assert-Equal 'reappeared clears Missing' ([string]$r7.Index.Files[$key].State) 'Present'
    Assert-Equal 'reappeared keeps the original first-seen' ([string]$r7.Index.Files[$key].FirstSeen) $t0.ToString('o')
    Assert-True 'reappeared clears MissingSince' (-not [bool]$r7.Index.Files[$key].MissingSince)

    # ---- an offline root never fakes a loss ---------------------------------
    $offlineRoot = Join-Path $tmp 'Offline'
    $offlineCfg = [pscustomobject]@{
        libraries = @([pscustomobject]@{ name = 'TV'; roots = @($offlineRoot); mediaExtensions = @('.mkv') })
    }
    $offlinePath = Join-Path $offlineRoot 'gone.mkv'
    $offlineFiles = @{}
    $offlineFiles[$offlinePath.ToLowerInvariant()] = New-StorageEntry -Path $offlinePath -Size 10 `
        -LastWrite $t0.ToString('o') -FirstSeen $t0.ToString('o') -LastSeen $t0.ToString('o') `
        -State 'Present' -MissingSince $null -Library 'TV' -Root $offlineRoot
    $offlineIndex = [pscustomobject]@{ Version = 1; At = $t0.ToString('o'); Files = $offlineFiles; RootHealth = @{} }
    $r8 = Compare-StorageHistory -Index $offlineIndex -Scan (Get-StorageScan -Config $offlineCfg) -At $t0.AddHours(1)
    Assert-Equal 'an offline root never marks its files missing' @($r8.Events | Where-Object { $_.event -eq 'vanished' }).Count 0
    Assert-Equal 'an offline root is reported as an event' @($r8.Events | Where-Object { $_.event -eq 'root-offline' }).Count 1
    Assert-Equal 'root health records the offline state' ([string]$r8.Index.RootHealth[$offlineRoot.TrimEnd('\').ToLowerInvariant()].State) 'offline'

    # ---- a partial root never fakes a loss ----------------------------------
    $partialFiles = @{}
    $partialFiles[$key] = New-StorageEntry -Path $ep1 -Size 150 `
        -LastWrite $t0.ToString('o') -FirstSeen $t0.ToString('o') -LastSeen $t0.ToString('o') `
        -State 'Present' -MissingSince $null -Library 'TV' -Root $tvRoot
    $partialHealth = @{}
    $partialHealth[$tvKey] = [pscustomobject]@{ Root = $tvRoot; State = 'ok'; At = $t0.ToString('o') }
    $partialIndex = [pscustomobject]@{ Version = 1; At = $t0.ToString('o'); Files = $partialFiles; RootHealth = $partialHealth }
    $partialScan = [pscustomobject]@{
        Files  = @{}
        Health = @{ $tvKey = 'partial' }
        Roots  = @{ $tvKey = $tvRoot }
    }
    $r9 = Compare-StorageHistory -Index $partialIndex -Scan $partialScan -At $t0.AddHours(1)
    Assert-Equal 'a partial root never marks its unread files missing' @($r9.Events | Where-Object { $_.event -eq 'vanished' }).Count 0
    Assert-Equal 'a partial root is reported as an event' @($r9.Events | Where-Object { $_.event -eq 'root-partial' }).Count 1

    # ---- the move window has an edge ---------------------------------------
    $oldPath = Join-Path $season 'old.mkv'
    $sameNameElsewhere = Join-Path $movieRoot 'old.mkv'
    [IO.File]::WriteAllText($sameNameElsewhere, ('d' * 400))
    $staleFiles = @{}
    $staleLast = $t0.AddHours(-72)
    $staleFiles[$oldPath.ToLowerInvariant()] = New-StorageEntry -Path $oldPath -Size 400 `
        -LastWrite $staleLast.ToString('o') -FirstSeen $staleLast.ToString('o') -LastSeen $staleLast.ToString('o') `
        -State 'Present' -MissingSince $null -Library 'TV' -Root $tvRoot
    $staleIndex = [pscustomobject]@{ Version = 1; At = $staleLast.ToString('o'); Files = $staleFiles; RootHealth = @{} }
    $r10 = Compare-StorageHistory -Index $staleIndex -Scan (Get-StorageScan -Config $cfg) -At $t0
    Assert-Equal 'a same-name file outside the 48 hour window is not called a move' @($r10.Events | Where-Object { $_.event -eq 'moved' }).Count 0
    Assert-Equal 'the old path is still recorded as vanished after the window' @($r10.Events | Where-Object { $_.event -eq 'vanished' -and $_.path -eq $oldPath }).Count 1

    # ---- a scan can be due or not ------------------------------------------
    $duePath = Join-Path $tmp 'due\index.json'
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $duePath) -Force
    Assert-True 'a missing index means a scan is due' (Test-StorageScanDue -IndexPath $duePath -MinIntervalMinutes 60)
    [IO.File]::WriteAllText($duePath, (ConvertTo-Json -InputObject ([pscustomobject]@{ Version = 1; At = (Get-Date).ToString('o') }) -Compress))
    Assert-False 'a fresh index is not scanned again inside the interval' (Test-StorageScanDue -IndexPath $duePath -MinIntervalMinutes 60)
    Assert-True 'an interval of zero always scans' (Test-StorageScanDue -IndexPath $duePath -MinIntervalMinutes 0)
    [IO.File]::WriteAllText($duePath, (ConvertTo-Json -InputObject ([pscustomobject]@{ Version = 1; At = (Get-Date).AddHours(-2).ToString('o') }) -Compress))
    Assert-True 'an index older than the interval is scanned again' (Test-StorageScanDue -IndexPath $duePath -MinIntervalMinutes 60)

    # ---- ingest: move_failed and partial events, read once ------------------
    $proj = Join-Path $tmp 'proj'
    $projLogs = Join-Path $proj 'logs'
    $retDir = Join-Path $proj 'playlist-data'
    $data = Join-Path $tmp 'data'
    $null = New-Item -ItemType Directory -Path $projLogs, $retDir -Force
    $log = Join-Path $projLogs 'moves-20261107.jsonl'
    $lines = @(
        '{"at":"2026-11-07T10:00:00-03:00","event":"moved","source":"D:\\a.mkv","dest":"F:\\a.mkv"}',
        '{"at":"2026-11-07T10:01:00-03:00","event":"move_failed","path":"K:\\S\\x.mkv","sizeGB":4.2,"error":"access denied"}',
        '{"at":"2026-11-07T10:02:00-03:00","event":"partial_removed","path":"K:\\S\\y.mkv","sizeGB":1.1}'
    )
    [IO.File]::WriteAllText($log, (($lines -join "`n") + "`n"))
    $i1 = Invoke-StorageIngest -ProjectRoot $proj -DataDirectory $data
    Assert-Equal 'ingest keeps move_failed and partial_removed' $i1.Events.Count 2
    Assert-Equal 'a successful moved line is not duplicated into history' @($i1.Events | Where-Object { $_.event -eq 'moved' }).Count 0
    Assert-Equal 'the ingest event names its source log' ([string]$i1.Events[0].source) 'moves-20261107.jsonl'
    Assert-True 'ingest state is written' (Test-Path -LiteralPath (Join-Path $data 'ingest.json'))
    $i2 = Invoke-StorageIngest -ProjectRoot $proj -DataDirectory $data
    Assert-Equal 'a second ingest reads nothing twice' $i2.Events.Count 0

    [IO.File]::AppendAllText($log, '{"at":"2026-11-07T11:00:00-03:00","event":"move_failed","path":"K:\\S\\z.mkv","sizeGB":2}' + "`n")
    $i3 = Invoke-StorageIngest -ProjectRoot $proj -DataDirectory $data
    Assert-Equal 'only the appended line is ingested the next time' $i3.Events.Count 1
    Assert-True 'the appended event names its path' ($i3.Events[0].path -match 'z\.mkv')

    # A torn last line must wait for its newline, not be lost or half-parsed.
    $incomplete = '{"at":"2026-11-07T12:00:00-03:00","event":"move_failed","path":"K:\\S\\w.mkv","sizeGB":3}'
    [IO.File]::AppendAllText($log, $incomplete)
    $i4 = Invoke-StorageIngest -ProjectRoot $proj -DataDirectory $data
    Assert-Equal 'an incomplete last line is not ingested yet' $i4.Events.Count 0
    [IO.File]::AppendAllText($log, "`n")
    $i5 = Invoke-StorageIngest -ProjectRoot $proj -DataDirectory $data
    Assert-Equal 'the completed line is ingested exactly once' $i5.Events.Count 1
    Assert-True 'the completed event names its path' ($i5.Events[0].path -match 'w\.mkv')

    # ---- ingest: watched-retirement records ---------------------------------
    $record = Join-Path $retDir 'retirement-1.json'
    [IO.File]::WriteAllText($record, '{"At":"2026-11-13T22:00:00-03:00","Deleted":true,"Path":"F:\\S\\Watched.mkv","Item":{"Title":"Pilot","Show":"Some Show","Season":1,"Episode":1}}')
    $i6 = Invoke-StorageIngest -ProjectRoot $proj -DataDirectory $data
    $retired = @($i6.Events | Where-Object { $_.event -eq 'retired' })
    Assert-Equal 'a deleted retirement record becomes a retired event' $retired.Count 1
    Assert-Equal 'the retired event names the show' ([string]$retired[0].show) 'Some Show'
    Assert-Equal 'the retired event carries the season' ([int]$retired[0].season) 1
    $i7 = Invoke-StorageIngest -ProjectRoot $proj -DataDirectory $data
    Assert-Equal 'a retirement record is ingested once' $i7.Events.Count 0

    $notDeleted = Join-Path $retDir 'retirement-2.json'
    [IO.File]::WriteAllText($notDeleted, '{"At":"2026-11-13T23:00:00-03:00","Deleted":false,"Path":"F:\\S\\Kept.mkv","Item":{"Title":"Still Here","Show":"Some Show","Season":1,"Episode":2}}')
    $i8 = Invoke-StorageIngest -ProjectRoot $proj -DataDirectory $data
    Assert-Equal 'a retirement that did not delete anything is not a loss' $i8.Events.Count 0

    # ---- report -------------------------------------------------------------
    $report = Get-StorageHistoryReport -DataDirectory $data -Pattern 'x.mkv'
    Assert-Equal 'the report finds the ingested failure' $report.Events.Count 1
    $text = (Format-StorageHistoryReport -Report $report -Pattern 'x.mkv') -join "`n"
    Assert-True 'the report names the failure event' ($text -match 'move_failed')
    Assert-True 'the report shows the stored error' ($text -match 'access denied')
    $none = Get-StorageHistoryReport -DataDirectory $data -Pattern 'nothing-here'
    $noneText = (Format-StorageHistoryReport -Report $none -Pattern 'nothing-here') -join "`n"
    Assert-True 'an unmatched report says so' ($noneText -match 'No storage history matches')

    # ---- index round-trip and version guard --------------------------------
    $indexPath = Join-Path $data 'index-rw.json'
    $rwFiles = @{}
    $rwFiles[$key] = New-StorageEntry -Path $ep1 -Size 150 -LastWrite $t0.ToString('o') `
        -FirstSeen $t0.ToString('o') -LastSeen $t0.ToString('o') -State 'Present' `
        -MissingSince $null -Library 'TV' -Root $tvRoot
    $rw = [pscustomobject]@{ Version = 1; At = $t0.ToString('o'); Files = $rwFiles; RootHealth = @{} }
    Save-StorageIndex -Path $indexPath -Index $rw
    $loaded = Get-StorageIndex -Path $indexPath
    Assert-Equal 'the index round-trips through disk' $loaded.Files.Count 1
    Assert-Equal 'the round-trip keeps the state' ([string]$loaded.Files[$key].State) 'Present'
    Assert-Equal 'the round-trip keeps the scan time' ([string]$loaded.At) $t0.ToString('o')

    $badPath = Join-Path $data 'index-bad.json'
    [IO.File]::WriteAllText($badPath, '{"Version":2,"Files":{}}')
    $threw = $false
    try { [void](Get-StorageIndex -Path $badPath) } catch { $threw = $true }
    Assert-True 'an unknown index version is refused, not overwritten' $threw

    # ---- a dry run writes nothing ------------------------------------------
    $dryData = Join-Path $tmp 'drydata'
    $dry = Invoke-StorageIngest -ProjectRoot $proj -DataDirectory $dryData -DryRun
    Assert-True 'a dry-run ingest still reports what it found' ($dry.Events.Count -gt 0)
    Assert-False 'a dry-run ingest writes no state' (Test-Path -LiteralPath (Join-Path $dryData 'ingest.json'))
    Assert-False 'a dry-run ingest creates no event files' (Test-Path -LiteralPath $dryData)

    # ---- the script itself never touches media -----------------------------
    $src = [IO.File]::ReadAllText((Join-Path $script:TestRoot 'storage-history.ps1'))
    Assert-False 'storage history uses no media-moving or deleting cmdlet' `
        ($src -match '(?m)\b(Remove-Item|Move-Item|Rename-Item)\b|\[IO\.File\]::Delete|\[IO\.Directory\]::Delete')
    Assert-True 'storage history writes only under its data directory' ($src -match 'DataDirectory')

    # ---- the watcher runs it, bounded and non-fatally ----------------------
    $wiring = Get-SourceBetween -Script 'watch.ps1' -Start '# Storage history is durable' -End 'if ($Once) { break }'
    Assert-True 'the watcher wiring block exists' ([bool]$wiring)
    Assert-True 'the watcher runs the storage-history scan' ($wiring -match 'storage-history\.ps1')
    Assert-True 'the watcher passes the shared config path' ($wiring -match "'-ConfigPath'")
    Assert-True 'the watcher bounds the scan with a timeout' ($wiring -match '-TimeoutSeconds')
    Assert-True 'the watcher honours the enable switch' ($wiring -match 'storageHistoryEnabled')
    Assert-True 'the watcher caps the scan frequency' ($wiring -match 'storageHistoryIntervalMinutes')
    Assert-True 'a history failure is logged rather than raised' ($wiring -match "'WARN'")
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-TestResult 'storage-history'
