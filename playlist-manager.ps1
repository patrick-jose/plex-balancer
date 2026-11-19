# Managed playlist maintenance. Preview by default; -Apply edits only the named
# copy. Watched-head file retirement is opt-in via playlist.config.json.
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$DataDirectory,
    [switch]$Apply,
    [switch]$RecoverOnly,
    [Alias('RetireOneWatchedHead','RetireOneWatchedEpisode')][switch]$RetireOneWatchedItem,
    [switch]$RetireWatchedItems,
    [string]$RepairCycleStopBeforeShow,
    [int]$MovieCadenceEpisodeOffset = -1
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'playlist-lib.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'playlist.config.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw 'Create playlist.config.json from playlist.config.example.json first.' }
$script:PlaylistCfg = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
$script:WatchedRetirementWindow = [int](Get-PlaylistProp $script:PlaylistCfg 'watchedRetirementWindow' 5)
if ($script:WatchedRetirementWindow -lt 1) { throw 'watchedRetirementWindow must be a positive queue-position count.' }
$script:PlaylistBase = ([string]$script:PlaylistCfg.serverUrl).TrimEnd('/')
$serverUri = [uri]$script:PlaylistBase
if ($serverUri.Scheme -notin @('http','https') -or $serverUri.UserInfo -or $serverUri.Query) { throw 'Invalid Plex server URL.' }
if ($script:PlaylistCfg.sourcePlaylist -ceq $script:PlaylistCfg.managedPlaylist) { throw 'Source and managed playlists must be different.' }
if ([int]$script:PlaylistCfg.rotationSize -ne 25 -or [int]$script:PlaylistCfg.episodesPerMovie -ne 5) { throw 'This manager implements 25 shows and five episodes per movie.' }
$token = $env:PLEX_TOKEN
if (-not $token) { $token = (Get-ItemProperty 'HKCU:\Software\Plex, Inc.\Plex Media Server' -ErrorAction SilentlyContinue).PlexOnlineToken }
if (-not $token) { throw 'No Plex token available.' }
$script:PlaylistHeaders = @{ 'X-Plex-Token' = $token; Accept = 'application/xml' }
$script:PlaylistApply = [bool]$Apply
$script:PlaylistAlerts = @{}
$script:PlaylistData = if ($DataDirectory) { [IO.Path]::GetFullPath($DataDirectory) } else { Join-Path $PSScriptRoot 'playlist-data' }
$script:MissingLedgerLabel = [string](Get-PlaylistProp $script:PlaylistCfg 'missingMediaLedgerPath' 'LIBRARY-MISSING-DETAILS.md')
if ($RetireOneWatchedItem -and (-not $Apply -or -not $RecoverOnly)) { throw '-RetireOneWatchedItem requires both -Apply and -RecoverOnly.' }
if ($RetireOneWatchedItem -and -not (Get-PlaylistProp $script:PlaylistCfg 'watchedFileDeletion' $false)) { throw '-RetireOneWatchedItem requires watchedFileDeletion=true in playlist.config.json.' }
if ($RetireWatchedItems -and (-not $Apply -or -not $RecoverOnly)) { throw '-RetireWatchedItems requires both -Apply and -RecoverOnly.' }
if ($RetireWatchedItems -and -not (Get-PlaylistProp $script:PlaylistCfg 'watchedFileDeletion' $false)) { throw '-RetireWatchedItems requires watchedFileDeletion=true in playlist.config.json.' }
if ($RetireWatchedItems -and $RetireOneWatchedItem) { throw 'Choose either -RetireWatchedItems or -RetireOneWatchedItem, not both.' }
[void][IO.Directory]::CreateDirectory($script:PlaylistData)
$statePath = Join-Path $script:PlaylistData 'state.json'
$mutex = [Threading.Mutex]::new($false, 'Global\PlexBalancer')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'A balancer/reconcile/playlist run is active. Retry after it finishes.' }

    function Read-ManagedLibrary {
        $result = [System.Collections.Generic.List[object]]::new()
        foreach ($section in $script:PlaylistSections) {
            $id = $section.GetAttribute('key'); $type = $section.GetAttribute('type')
            if ($type -notin @('show','movie')) { continue }
            $kind = if ($type -eq 'show') { 4 } else { 1 }
            foreach ($node in @(Get-PlaylistPlexItems "/library/sections/$id/all?type=$kind&includeGuids=1")) {
                $result.Add((Convert-PlaylistMedia $node $id))
            }
        }
        return @($result.ToArray())
    }

    function Read-ManagedItems {
        param([string]$Id)
        @(Get-PlaylistPlexItems "/playlists/$Id/items?includeGuids=1" | ForEach-Object { Convert-PlaylistMedia $_ })
    }

    function Update-PlaylistLibrarySection {
        param([string]$SectionId)
        $sectionsNow = @((Invoke-PlaylistPlex '/library/sections').SelectNodes('Directory'))
        $section = @($sectionsNow | Where-Object { $_.GetAttribute('key') -eq $SectionId })
        if ($section.Count -ne 1) { return $false }
        if ($section[0].GetAttribute('refreshing') -notin @('1','true')) {
            [void](Invoke-PlaylistPlex ("/library/sections/{0}/refresh" -f $SectionId))
        }
        $deadline = (Get-Date).AddSeconds([int]$script:PlaylistCfg.scanTimeoutSeconds)
        Start-Sleep -Seconds 2
        do {
            $sectionsNow = @((Invoke-PlaylistPlex '/library/sections').SelectNodes('Directory'))
            $scanning = @($sectionsNow | Where-Object { $_.GetAttribute('key') -eq $SectionId -and $_.GetAttribute('refreshing') -in @('1','true') }).Count -gt 0
            if ($scanning) { Start-Sleep -Seconds 2 }
        } while ($scanning -and (Get-Date) -lt $deadline)
        return (-not $scanning)
    }

    function Invoke-AutomaticRetirement {
        param([object[]]$Desired, $State, [string]$StatePath, [string]$DataDirectory, [int]$WatchedWindow = 5, [switch]$RetryExistingOnly, [switch]$SingleHeadOnly)
        $mainCfg = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'config.json')) | ConvertFrom-Json
        $removed = 0
        # Freeze eligibility to the initial bounded window. Removing an item
        # must not pull queue positions beyond the window into this same run.
        $eligibleRetirementIds = @(Get-PlaylistWatchedQueueItems -Queue $Desired -WindowSize $WatchedWindow | ForEach-Object Identity)
        while ($true) {
            if ($Desired.Count -eq 0) { break }
            $head = @($Desired | Where-Object { $_.Identity -in $eligibleRetirementIds -and $_.Type -in @('episode','movie') -and $_.Watched } | Select-Object -First 1)
            if (-not $head.Count) { break }
            $head = $head[0]
            $transactionPath = Join-Path $DataDirectory ('retirement-' + $head.Key + '.json')
            if ($RetryExistingOnly -and -not (Test-Path -LiteralPath $transactionPath)) { break }
            if (@($head.Paths).Count -ne 1) { Write-Warning "Watched item has multiple/unknown paths, skipping retirement"; break }
        $path = [IO.Path]::GetFullPath($head.Paths[0])
        $retirementRoots = @($mainCfg.libraries | ForEach-Object { $_.roots })
            if (-not (Test-PlaylistPathUnderRoots -Path $path -Roots $retirementRoots) -or -not [IO.File]::Exists($path)) { Write-Warning "Watched item file missing or outside managed roots, skipping retirement"; break }
            if (([IO.FileInfo]::new($path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { Write-Warning "Watched item is a reparse point, skipping retirement"; break }
            if ($head.Type -eq 'movie' -and @($State.Movies | Where-Object Identity -CEQ $head.Identity).Count -ne 1) { throw "Watched movie $($head.Identity) is not present exactly once in saved movie order; no media deleted." }
            $bytes = ([IO.FileInfo]::new($path)).Length
            # Verify the managed queue still has the exact intended order before
            # any destructive action; the watched item must still be queued.
            $remaining = @(Read-ManagedItems $script:ManagedPlaylistId)
        if (($remaining.Identity -join '|') -cne ($Desired.Identity -join '|')) { throw 'Managed playlist changed before watched-episode retirement; no media deleted.' }
            $sessions = Invoke-PlaylistPlex '/status/sessions'
            foreach ($video in $sessions.SelectNodes('Video')) {
                if ($video.GetAttribute('ratingKey') -eq $head.Key -or $video.GetAttribute('guid') -in $head.Ids) {
                    Write-Host "Stopping session $($video.GetAttribute('sessionId')) playing watched item..."
                    [void](Invoke-PlaylistPlex "/status/sessions/$($video.GetAttribute('sessionId'))" 'Delete')
                }
                else {
                    foreach ($part in $video.SelectNodes('Media/Part')) {
                        if ($part.GetAttribute('file') -eq $path) {
                            Write-Host "Stopping session $($video.GetAttribute('sessionId')) using watched item file..."
                            [void](Invoke-PlaylistPlex "/status/sessions/$($video.GetAttribute('sessionId'))" 'Delete')
                        }
                    }
                }
            }
            Start-Sleep -Seconds 2
            $sessions = Invoke-PlaylistPlex '/status/sessions'
            $stillPlaying = $false
            foreach ($video in $sessions.SelectNodes('Video')) {
                if ($video.GetAttribute('ratingKey') -eq $head.Key -or $video.GetAttribute('guid') -in $head.Ids) { $stillPlaying = $true }
                foreach ($part in $video.SelectNodes('Media/Part')) { if ($part.GetAttribute('file') -eq $path) { $stillPlaying = $true } }
            }
            if ($stillPlaying) { Write-Warning 'Watched item is still in an active Plex session; skipping retirement'; break }

            if (Test-Path -LiteralPath $transactionPath) {
                $transaction = [IO.File]::ReadAllText($transactionPath) | ConvertFrom-Json
                if ($transaction.Status -ne 'Pending' -or $transaction.Deleted -or $transaction.QueueUpdated -or
                    $transaction.Item.Identity -cne $head.Identity -or [IO.Path]::GetFullPath([string]$transaction.Path) -cne $path) {
                    throw "Retirement transaction already exists for $($head.Key) with different or unsafe state; inspect before retrying."
                }
                if (-not $transaction.Bytes) { $transaction.Bytes = $bytes }
            }
            else {
                $transaction = [pscustomobject]@{ At=(Get-Date).ToString('o'); Item=$head; Path=$path; Bytes=$bytes
                    Reason='Automatic retirement: Plex-watched managed-playlist item; no active session; torrent check omitted by user policy'
                    Status='Pending'; Deleted=$false; QueueUpdated=$false }
                Write-PlaylistJson (Join-Path $DataDirectory ('before-retirement-'+$head.Key+'.json')) $State
                Write-PlaylistJson $transactionPath $transaction
            }
            try {
                [void](Remove-PlaylistRetirementFile -Path $path)
            }
            catch {
                throw ("Watched-item retirement failed for " + $path + ": " + $_.Exception.Message + "; transaction retained for inspection.")
            }
            $transaction.Deleted = $true; $transaction.Status = 'FileDeleted'
            Write-PlaylistJson $transactionPath $transaction
            $itemLabel = if ($head.Type -eq 'movie') { $head.Title } else { "$($head.Show) S$($head.Season)E$($head.Episode) - $($head.Title)" }
            Write-Host "Auto-retired watched item: $itemLabel ($([math]::Round($bytes/1GB,2)) GB)"
            $removed++
            # Persist the tombstone before repairing the playlist so an
            # interrupted update cannot reintroduce media that was deleted.
            if ($head.Type -eq 'movie') {
                $movieRemoval = Remove-PlaylistMovieSlot -Queue $Desired -MovieOrder @($State.Movies) -Identity $head.Identity
                $Desired = @($movieRemoval.Queue)
                $State.Movies = @($movieRemoval.Movies)
            }
            else { $Desired = @($Desired | Where-Object { $_.Identity -cne $head.Identity }) }
            $State.Queue = $Desired
            $State.BaseQueue = @($State.BaseQueue | Where-Object Identity -ne $head.Identity)
            $State | Add-Member -NotePropertyName Retired -NotePropertyValue (@(Get-PlaylistProp $State 'Retired' @()) + $transaction) -Force
            $State.At=(Get-Date).ToString('o'); $State.Applied=$false
            Write-PlaylistJson $StatePath $State
            $remaining = @(Read-ManagedItems $script:ManagedPlaylistId)
            [void](Set-PlaylistIntendedItems -Desired $Desired -Current $remaining)
            $State.Applied=$true
            Write-PlaylistJson $StatePath $State
            $transaction.QueueUpdated=$true; $transaction.Status='Complete'
            Write-PlaylistJson $transactionPath $transaction
            if ($RetryExistingOnly -or $SingleHeadOnly) { break }
        }
        if ($removed -gt 0) { Write-Host "Auto-retired $removed watched item(s)." }
        return $removed
    }

    $playlists = @(Get-PlaylistPlexItems '/playlists' 'Playlist')
    $source = @($playlists | Where-Object { $_.GetAttribute('title') -ceq $script:PlaylistCfg.sourcePlaylist })
    $target = @($playlists | Where-Object { $_.GetAttribute('title') -ceq $script:PlaylistCfg.managedPlaylist })
    if ($source.Count -ne 1 -or $target.Count -ne 1) { throw 'Source and managed copy must each exist exactly once.' }
    if ($target[0].GetAttribute('smart') -notin @('0','false','')) { throw 'Managed playlist must be a regular playlist.' }
    $script:SourcePlaylistId = $source[0].GetAttribute('ratingKey')
    $script:ManagedPlaylistId = $target[0].GetAttribute('ratingKey')
    if ($script:SourcePlaylistId -eq $script:ManagedPlaylistId) { throw 'Refusing to manage the original playlist.' }
    $original = @(Read-ManagedItems $script:SourcePlaylistId)
    $current = @(Read-ManagedItems $script:ManagedPlaylistId)
    $originalSignature = ($original.Key -join ',')
    $script:PlaylistSections = @((Invoke-PlaylistPlex '/library/sections').SelectNodes('Directory'))
    $library = @(Read-ManagedLibrary)
    $shows = @()
    foreach ($s in @($script:PlaylistSections | Where-Object { $_.GetAttribute('type') -eq 'show' })) {
        foreach ($node in @(Get-PlaylistPlexItems ("/library/sections/{0}/all?type=2&includeGuids=1" -f $s.GetAttribute('key')) 'Directory')) {
            $shows += Convert-PlaylistMedia $node $s.GetAttribute('key')
        }
    }
    $state = $null
    if (Test-Path -LiteralPath $statePath) {
        $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        if ($state.Version -ne 2 -or $state.TargetId -ne $script:ManagedPlaylistId -or $state.Server -ne $script:PlaylistBase) { throw 'State version/server/playlist mismatch. Old rebuilding state must be explicitly restored/rebased; refusing to rewrite the queue.' }
    }
    elseif (-not $RecoverOnly) {
        $state = New-PlaylistContinuationState -Queue $current -Shows $shows -Replacements @($script:PlaylistCfg.replacements) -Server $script:PlaylistBase -SourceId $script:SourcePlaylistId -TargetId $script:ManagedPlaylistId
    }
    # Preserve the persisted order snapshot for the manual-edit guard. Planner
    # repairs later in this run must not be mistaken for user edits to Plex.
    if ($MovieCadenceEpisodeOffset -ge 0) {
        if (-not $Apply -or -not $state -or -not $state.Applied) { throw 'Correcting movie cadence requires an applied state and -Apply.' }
        $state.Queue = @(Set-PlaylistMovieCadenceOffset -Queue @($state.Queue) -EpisodeOffset $MovieCadenceEpisodeOffset -EpisodesPerMovie ([int]$script:PlaylistCfg.episodesPerMovie))
        $state.BaseQueue = @(Set-PlaylistMovieCadenceOffset -Queue @($state.BaseQueue) -EpisodeOffset $MovieCadenceEpisodeOffset -EpisodesPerMovie ([int]$script:PlaylistCfg.episodesPerMovie))
        Add-PlaylistAlert 'movie-cadence-resume-correction' "Restored the existing cadence offset: the first movie follows $MovieCadenceEpisodeOffset queued episodes, then movie slots resume every $([int]$script:PlaylistCfg.episodesPerMovie) episodes."
    }
    if ($RepairCycleStopBeforeShow) {
        if (-not $Apply -or -not $RecoverOnly -or -not $state) { throw 'Cycle-stop repair requires an initialized state and both -RecoverOnly and -Apply.' }
        $repair = Repair-PlaylistQueueBeforeBlockedShow -Queue @($state.BaseQueue) -Shows $shows -ActiveIds @($state.ActiveIds) -StopShow $RepairCycleStopBeforeShow
        $state.BaseQueue = @($repair.Queue)
        $state.Queue = @($repair.Queue)
        $state.Rounds = @()
        $state.CycleConsumed = @($repair.CycleConsumed)
        $state.Cursors = $repair.Cursors
        $state.NextCycleNumber = $repair.NextCycleNumber
        Write-Host ("Repairing saved managed queue: stop before {0}; retained {1} items; Penn & Teller retained and episode-sorted." -f $RepairCycleStopBeforeShow, $repair.Queue.Count)
    }
    # Explicit watched retirement is a removal decision, not a recoverable gap.
    # A partial transaction is recoverable only when its recorded path is absent
    # on a confirmed-ready managed volume. Never delete a file during recovery.
    $retirements = @()
    $recoveredRetirements = @()
    $retryPendingRetirement = $false
    $retirementConfig = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'config.json')) | ConvertFrom-Json
    $retirementRoots = @($retirementConfig.libraries | ForEach-Object { $_.roots })
    foreach ($file in @(Get-ChildItem -LiteralPath $script:PlaylistData -Filter 'retirement-*.json' -File)) {
        $record = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        if ($record.Status -eq 'Complete') { $retirements += $record; continue }
        $confirmedMissingRetirement = $false
        $validPendingRetirementPath = $false
        $pendingRetirementFileExists = $false
        $fileDeletedTransaction = $record.Status -eq 'FileDeleted' -and $record.Deleted -and -not $record.QueueUpdated
        $pendingTransaction = $record.Status -eq 'Pending' -and -not $record.Deleted -and -not $record.QueueUpdated
        if (($pendingTransaction -or $fileDeletedTransaction) -and $record.Path) {
            try {
                $retirementPath = [IO.Path]::GetFullPath([string]$record.Path)
                $validPendingRetirementPath = Test-PlaylistPathUnderRoots -Path $retirementPath -Roots $retirementRoots
                if ($validPendingRetirementPath) {
                    $retirementDrive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($retirementPath))
                    $pendingRetirementFileExists = [IO.File]::Exists($retirementPath)
                    $confirmedMissingRetirement = $retirementDrive.IsReady -and -not $pendingRetirementFileExists
                }
                $script:PlaylistRetirementRecoveryDiagnostic = "managedPath=$validPendingRetirementPath; ready=$($retirementDrive.IsReady); exists=$pendingRetirementFileExists"
            }
            catch { $script:PlaylistRetirementRecoveryDiagnostic = $_.Exception.Message }
        }
        if ([bool]$Apply -and $null -ne $state -and $confirmedMissingRetirement -and ($pendingTransaction -or $fileDeletedTransaction)) {
            $record | Add-Member -NotePropertyName TransactionPath -NotePropertyValue $file.FullName -Force
            $recoveredRetirements += $record
            $recoveredLabel = if ($record.Item.Type -eq 'movie') { $record.Item.Title } else { "$($record.Item.Show) S$($record.Item.Season)E$($record.Item.Episode)" }
            Write-Warning "Recovering watched retirement for ${recoveredLabel}: recorded file is absent on a ready volume; no file deletion will be attempted."
            continue
        }
        if ([bool]$Apply -and $state -and (Get-PlaylistProp $script:PlaylistCfg 'watchedFileDeletion' $false) -and
            $validPendingRetirementPath -and $pendingRetirementFileExists -and $record.Item.Watched -and
            (Get-PlaylistWatchedQueueItem -Queue @($state.Queue) -WindowSize $script:WatchedRetirementWindow).Identity -ceq $record.Item.Identity -and
            (Get-PlaylistWatchedQueueItem -Queue @($current) -WindowSize $script:WatchedRetirementWindow).Identity -ceq $record.Item.Identity) {
            $retryLabel = if ($record.Item.Type -eq 'movie') { $record.Item.Title } else { "$($record.Item.Show) S$($record.Item.Season)E$($record.Item.Episode)" }
            Write-Warning "Retrying existing watched retirement for $retryLabel; it remains the first watched item in the managed queue."
            $retryPendingRetirement = $true
            continue
        }
        throw "Watched retirement needs inspection: $($file.Name). Queue recovery paused to prevent resurrection. (apply=$([bool]$Apply); stateLoaded=$($null -ne $state); confirmedMissing=$confirmedMissingRetirement; check=$script:PlaylistRetirementRecoveryDiagnostic; status=$($record.Status); deleted=$($record.Deleted); queueUpdated=$($record.QueueUpdated); roots=$($retirementRoots.Count))"
    }
    if ($state -and ($retirements.Count -or $recoveredRetirements.Count)) {
        $retiredIds = @($retirements + $recoveredRetirements | ForEach-Object { $_.Item.Identity })
        $state.Queue = @($state.Queue | Where-Object { $_.Identity -notin $retiredIds })
        $state.BaseQueue = @($state.BaseQueue | Where-Object { $_.Identity -notin $retiredIds })
        $state.Movies = @($state.Movies | Where-Object { $_.Identity -notin $retiredIds })
    }
    if ($state -and $state.Applied) {
        # Retain saved order exactly; never reflow existing movie cycles.
        $state.BaseQueue = @($state.Queue)
        $state.Rounds = @()
        $state.Movies = @($state.Queue | Where-Object Type -eq 'movie')
    }
    elseif ($state -and -not $RecoverOnly -and (Test-Path -LiteralPath $statePath)) {
        throw 'An interrupted update has pending intent. Run -Apply -RecoverOnly before extending it.'
    }
    $manualMovieRemovalIds = @()
    if ($state) {
        $retiredMovieIds = @($retirements + $recoveredRetirements | ForEach-Object { $_.Item.Identity })
        $manualMovieRemovalIds = @(Get-PlaylistManualMovieRemovals -Queue @($state.Queue) -Current $current -RetiredIdentities $retiredMovieIds)
    }
    if ($Apply) {
        $backup = [pscustomobject]@{ At = (Get-Date).ToString('o'); SourceId = $script:SourcePlaylistId; TargetId = $script:ManagedPlaylistId; Source = $original; Target = $current }
        Write-PlaylistJson -Path (Join-Path $script:PlaylistData 'before-latest-apply.json') -Value $backup
        # Keep a fixed first-apply snapshot. It is recovery data, not an audit log.
        $firstBackup = Join-Path $script:PlaylistData 'before-first-apply.json'
        if (-not (Test-Path -LiteralPath $firstBackup)) { Write-PlaylistJson $firstBackup $backup }
    }
    if (-not (Get-PlaylistTmdbCredential).Configured) {
        Add-PlaylistAlert 'tmdb-credential' 'TMDb credential missing. TV ending/missing-release checks and online franchise resolution are unavailable. Manual replacement pairs and conservative title/theme grouping remain usable.'
    }

    # Recover the durable intended queue BEFORE adding more media. Re-keyed items
    # are matched by stable identity and their saved key is rewritten in durable
    # state. An item with no Plex match is deferred with its slot intact and is
    # restored automatically if a future section refresh makes it reappear.
    $unresolved = @()
    $ambiguous = @()
    $recovered = @()
    $rebound = @()
    $deferred = @()
    $restored = @()
    $refreshedSections = @{}
    $stateMissing = @()
    $stateMissingHistory = @()
    if ($state) {
        $stateMissing = @(Get-PlaylistProp $state 'Missing' @())
        $stateMissingHistory = @(Get-PlaylistProp $state 'MissingHistory' @())

        # First, look for deferred items that reappeared in Plex. Process them in
        # saved-slot order and shift later slots by the number already inserted.
        $reappeared = @()
        foreach ($entry in @($stateMissing | Where-Object { $_ -and $_.Identity })) {
            $matches = @(Get-PlaylistMediaMatches -Wanted $entry -Library $library)
            if ($matches.Count -gt 1) {
                $ambiguous += $entry
                Add-PlaylistAlert ('ambiguous-missing-' + $entry.Identity) ("Ambiguous library match for deferred item '$($entry.Show) $($entry.Title)'; no automatic restore until the library has one unambiguous identity match.")
                continue
            }
            if ($matches.Count -eq 1) {
                $found = $matches[0]
                $reappeared += [pscustomobject]@{ Entry = $entry; Item = [pscustomobject]@{
                    Identity = $entry.Identity; Ids = @($found.Ids); Key = [string]$found.Key; Type = $found.Type
                    Title = $found.Title; Show = $found.Show; ShowKey = $found.ShowKey; Season = [int]$found.Season
                    Episode = [int]$found.Episode; SectionId = $found.SectionId; Paths = @($found.Paths); Watched = [bool]$found.Watched
                } }
            }
        }
        $restoreOffset = 0
        foreach ($restore in @($reappeared | Sort-Object { [int]$_.Entry.Position })) {
            $entry = $restore.Entry
            $insertAt = [math]::Max(0, [int]$entry.Position + $restoreOffset)
            foreach ($savedName in @('Queue', 'BaseQueue')) {
                $savedItems = @(Get-PlaylistProp $state $savedName @())
                if (-not $savedItems.Count) { continue }
                if ($savedItems.Identity -contains $entry.Identity) { continue }
                $state | Add-Member -NotePropertyName $savedName -NotePropertyValue (Insert-PlaylistQueueItem -Queue $savedItems -Position $insertAt -Item $restore.Item) -Force
            }
            $restoreOffset++
            $stateMissing = @($stateMissing | Where-Object { $_.Identity -ne $entry.Identity })
            $stateMissingHistory = @($stateMissingHistory) + @([pscustomobject]@{
                Identity = $entry.Identity; Show = $entry.Show; Title = $entry.Title; Season = $entry.Season; Episode = $entry.Episode
                Type = $entry.Type; FirstSeen = $entry.FirstSeen; ResolvedAt = (Get-Date).ToString('o'); How = 'Plex library item reappeared after refresh'
            })
            $restored += $restore.Item
            Add-PlaylistAlert ('restored-missing-' + $entry.Identity) ("Restored '$($entry.Show) S$($entry.Season)E$($entry.Episode)' to its saved slot #$($insertAt + 1) after it reappeared in Plex.")
        }
        $state.Movies = @(@($state.Queue) | Where-Object Type -eq 'movie')

        # Resolve every active queue item. A single identity match rebinds the
        # saved key; no match defers the item; more than one match is ambiguous.
        $rebinding = @{}
        $activeQueue = @($state.Queue)
        for ($qi = 0; $qi -lt $activeQueue.Count; $qi++) {
            $wanted = $activeQueue[$qi]
            if ($wanted.Identity -in $manualMovieRemovalIds) { continue }
            $matches = @(Get-PlaylistMediaMatches -Wanted $wanted -Library $library)
            # Plex's library record is authoritative. A file path that is not
            # accessible to this process does not make the item missing; the
            # later integrity pass reports it without dropping the queue slot.
            $found = if ($matches.Count -eq 1) { $matches[0] } else { $null }
            if (-not $found -and $Apply) {
                $sectionId = [string]$wanted.SectionId
                if (-not $refreshedSections.ContainsKey($sectionId)) {
                    # Plex section refresh is the recovery mechanism; do not
                    # search local roots for the item's former path.
                    $refreshedSections[$sectionId] = Update-PlaylistLibrarySection $sectionId
                    if ($refreshedSections[$sectionId]) { $library = @(Read-ManagedLibrary) }
                }
                if ($refreshedSections[$sectionId]) {
                    $matches = @(Get-PlaylistMediaMatches -Wanted $wanted -Library $library)
                    $found = if ($matches.Count -eq 1) { $matches[0] } else { $null }
                }
            }
            if ($found) {
                $recovered += $found
                if ([string]$found.Key -cne [string]$wanted.Key -or (@($found.Paths) -join '|') -cne (@($wanted.Paths) -join '|')) {
                    $rebinding[[string]$wanted.Identity] = $found
                }
                if (-not (Test-PlaylistMediaPresent $found) -and $Apply) {
                    Add-PlaylistAlert ('file-unavailable-' + $found.Identity) ("Plex still lists $($found.Show) $($found.Title), so it remains in the managed queue. Its reported path is not accessible to this process: $($found.Paths -join ', ').")
                }
            }
            elseif ($matches.Count -gt 1) {
                $ambiguous += $wanted
                Add-PlaylistAlert ('ambiguous-' + $wanted.Identity) ("Ambiguous library match for '$($wanted.Show) $($wanted.Title)'; playlist edits are paused until one unambiguous identity match remains.")
            }
            else {
                $entry = @($stateMissing | Where-Object { $_.Identity -eq $wanted.Identity } | Select-Object -First 1)[0]
                if (-not $entry) {
                    $entry = New-PlaylistMissingEntry -Item $wanted -Position $qi
                    $stateMissing = @($stateMissing) + @($entry)
                }
                else { $entry.LastChecked = (Get-Date).ToString('o') }
                $deferred += $entry
                Add-PlaylistAlert ('unresolved-' + $wanted.Identity) ("Deferred missing item: $($wanted.Show) $($wanted.Title). Expected: $($wanted.Paths -join ', '). Saved slot #$([int]$entry.Position + 1) is retained in $script:MissingLedgerLabel and will be restored automatically if Plex lists it again.")
            }
        }
        $rebindingKeys = @($rebinding.Keys)
        if ($rebindingKeys.Count) {
            foreach ($savedName in @('Queue', 'BaseQueue', 'Movies')) {
                $savedItems = @(Get-PlaylistProp $state $savedName @())
                if (-not $savedItems.Count) { continue }
                $updated = @($savedItems | ForEach-Object {
                    $item = $_
                    if ($rebinding.ContainsKey([string]$item.Identity)) {
                        $new = $rebinding[[string]$item.Identity]
                        $item.Key = [string]$new.Key
                        $item.Ids = @($new.Ids)
                        $item.Paths = @($new.Paths)
                        $item.SectionId = $new.SectionId
                    }
                    $item
                })
                $state | Add-Member -NotePropertyName $savedName -NotePropertyValue $updated -Force
            }
            $rebound = @($rebindingKeys | ForEach-Object { $rebinding[$_] })
            Add-PlaylistAlert 'rebound-playlist-keys' ("Persisted $($rebindingKeys.Count) re-keyed Plex item(s) by stable identity across Queue, BaseQueue and Movies.")
        }
        $deferredIds = @($deferred | ForEach-Object Identity)
        if ($deferredIds.Count) {
            foreach ($savedName in @('Queue', 'BaseQueue', 'Movies')) {
                $savedItems = @(Get-PlaylistProp $state $savedName @())
                if ($savedItems.Count) { $state | Add-Member -NotePropertyName $savedName -NotePropertyValue @($savedItems | Where-Object { $_.Identity -notin $deferredIds }) -Force }
            }
            $state.Rounds = @()
            Add-PlaylistAlert 'deferred-missing-media' ("Deferred $($deferredIds.Count) missing item(s) from synchronization; their saved slots remain in $script:MissingLedgerLabel for automatic restoration.")
        }
        $state | Add-Member -NotePropertyName 'Missing' -NotePropertyValue @($stateMissing) -Force
        $state | Add-Member -NotePropertyName 'MissingHistory' -NotePropertyValue @($stateMissingHistory) -Force
        if ($Apply) {
            $ledgerSetting = $script:MissingLedgerLabel
            $ledgerPath = if ([IO.Path]::IsPathRooted($ledgerSetting)) { $ledgerSetting } else { Join-Path $PSScriptRoot $ledgerSetting }
            Update-PlaylistMissingLedger -Path $ledgerPath -Missing $stateMissing -History $stateMissingHistory | Out-Null
        }
    }
    $unresolved = @($ambiguous)
    if ($unresolved.Count) {
        throw 'Ambiguous Plex identity matches remain; refusing playlist edits until the library contains one unambiguous match per saved item.'
    }

    $episodes = @($library | Where-Object Type -eq 'episode')
    $movies = @($library | Where-Object Type -eq 'movie')
    $showMovieAnchors = @(Get-PlaylistShowMovieAnchors -Shows $shows -Episodes $episodes -Movies $movies -ShowMovieLinks @($script:PlaylistCfg.showMovieLinks))
    $reservedShowMovieIds = @($showMovieAnchors | ForEach-Object MovieIdentity)
    $groups = @(Get-PlaylistMovieGroups -Movies @($movies | Where-Object Identity -notin $reservedShowMovieIds) -ThematicGroups @($script:PlaylistCfg.thematicGroups))
    if ($manualMovieRemovalIds.Count -and -not $unresolved.Count) {
        $replacements = @(Get-PlaylistMovieReplacements -Movies $movies -Groups $groups -MovieOrder @($state.Movies) -MissingIdentities $manualMovieRemovalIds -ReservedIdentities $reservedShowMovieIds -Seed ([int]$script:PlaylistCfg.randomSeed))
        $queueRepair = Replace-PlaylistMissingMovieSlots -Queue @($state.Queue) -MovieOrder @($state.Movies) -MissingIdentities $manualMovieRemovalIds -Replacements $replacements
        $baseRepair = Replace-PlaylistMissingMovieSlots -Queue @($state.BaseQueue) -MovieOrder @($state.BaseQueue | Where-Object Type -eq 'movie') -MissingIdentities $manualMovieRemovalIds -Replacements $replacements
        $state.Queue = @($queueRepair.Queue)
        $state.BaseQueue = @($baseRepair.Queue)
        $state.Movies = @($queueRepair.Movies)
        Add-PlaylistAlert 'manual-movie-replacements' ("Replaced $($manualMovieRemovalIds.Count) manually removed movie slot(s) with random movies selected using franchise ordering and show-linked movie reservations.")
    }
    if ($state -and $showMovieAnchors.Count) {
        $oldQueueOrder = @($state.Queue | ForEach-Object Identity)
        $state.Queue = @(Set-PlaylistAnchoredMovieQueue -Queue @($state.Queue) -Anchors $showMovieAnchors)
        $state.BaseQueue = @(Set-PlaylistAnchoredMovieQueue -Queue @($state.BaseQueue) -Anchors $showMovieAnchors)
        $state.Movies = @($state.Queue | Where-Object Type -eq 'movie')
        if (($oldQueueOrder -join '|') -cne (@($state.Queue | ForEach-Object Identity) -join '|')) {
            Add-PlaylistAlert 'show-movie-anchor-correction' 'Moved show-associated movies out of random positions; each is reserved for the last show episode released before that movie.'
        }
    }
    $status = @{}
    $downloadItems = @()
    # Watched is not missing: a viewed episode whose file was later retired or
    # deleted must never be offered for download again. TMDb episode ids are the
    # stable identity shared by Plex items, saved queue entries and retired records.
    $watchedSources = @($episodes | Where-Object { $_.Watched })
    if ($state) {
        $watchedSources += @($state.Queue | Where-Object { $_.Watched })
        $watchedSources += @($state.BaseQueue | Where-Object { $_.Watched })
        $watchedSources += @($state.Retired | ForEach-Object { $_.Item } | Where-Object { $_.Watched })
    }
    $watchedEpisodeIds = @()
    foreach ($watchedItem in $watchedSources) {
        foreach ($watchedId in @($watchedItem.Ids | Where-Object { $_ -like 'tmdb://*' })) {
            $watchedEpisodeIds += [string]$watchedId
        }
    }
    $watchedEpisodeIds = @($watchedEpisodeIds | Select-Object -Unique)
    # No title searches: provider IDs must match exactly. Only the show's remaining
    # timeline (at/after the manual seed) is relevant to missing-episode notices.
    if (-not $RecoverOnly) {
        foreach ($show in $shows) {
            $seed = @($original | Where-Object { $_.ShowKey -eq $show.Key } | Sort-Object Season, Episode | Select-Object -First 1)
            $anchor = if ($seed.Count) { [long]$seed[0].Season * 10000 + $seed[0].Episode } else { 1 }
            if ($state) {
                $savedCursor = Get-PlaylistProp $state.Cursors $show.Identity 0
                if (-not $seed.Count -and -not [long]$savedCursor) {
                    $firstLocal = @($episodes | Where-Object { $_.ShowKey -eq $show.Key -and $_.Season -gt 0 -and -not $_.Watched } | Sort-Object Season, Episode | Select-Object -First 1)
                    if ($firstLocal.Count) { $anchor = [long]$firstLocal[0].Season * 10000 + $firstLocal[0].Episode }
                }
                $anchor = [math]::Max($anchor, [long]$savedCursor + 1)
            }
            elseif (-not $seed.Count) {
                $firstLocal = @($episodes | Where-Object { $_.ShowKey -eq $show.Key -and $_.Season -gt 0 -and -not $_.Watched } | Sort-Object Season, Episode | Select-Object -First 1)
                if ($firstLocal.Count) { $anchor = [long]$firstLocal[0].Season * 10000 + $firstLocal[0].Episode }
            }
            # The download list starts at the show's collection start and never moves
            # with the cursor, so aired episodes already passed in an earlier rotation
            # are still reported when their file goes missing.
            $collectionAnchor = if ($seed.Count) { [long]$seed[0].Season * 10000 + $seed[0].Episode } else { 1 }
            if (-not $seed.Count) {
                $firstLocal = @($episodes | Where-Object { $_.ShowKey -eq $show.Key -and $_.Season -gt 0 -and -not $_.Watched } | Sort-Object Season, Episode | Select-Object -First 1)
                if ($firstLocal.Count) { $collectionAnchor = [long]$firstLocal[0].Season * 10000 + $firstLocal[0].Episode }
            }
            $st = Get-PlaylistTvStatus $show $episodes $anchor $collectionAnchor $watchedEpisodeIds
            $status[$show.Identity] = $st
            $toDownload = @(Get-PlaylistProp $st 'DownloadMissing' @($st.Missing))
            if ($st.Known -and $toDownload.Count) {
                $names = @($toDownload | ForEach-Object { 'S{0:00}E{1:00}' -f $_.Season, $_.Episode }) -join ', '
                foreach ($missingEpisode in $toDownload) {
                    $downloadItems += [pscustomobject]@{ Show = $show.Title; Season = $missingEpisode.Season; Episode = $missingEpisode.Episode; AirDate = $missingEpisode.AirDate }
                }
                Add-PlaylistAlert ('tv-missing-' + $show.Identity) ("$($show.Title): aired/released episodes absent locally: $names. Air dates do not guarantee download availability.")
            }
            elseif (-not $st.Known -and (Get-PlaylistTmdbCredential).Configured) { Add-PlaylistAlert ('tv-unknown-' + $show.Identity) ("$($show.Title): TV status unavailable; no automatic retirement.") }
        }
        # Episodes permanently lost from disk (e.g. a Recycle Bin purge) can sit
        # behind the rotation cursor, so the TMDb check never reports them. Add
        # those from the move logs unless the TMDb check already found them.
        foreach ($lost in @(Get-PlaylistDestroyedMedia -LogDirectory (Join-Path $PSScriptRoot 'logs') -Library $library)) {
            $wasWatched = @($watchedSources | Where-Object {
                [string]$_.Show -ieq $lost.Show -and [int]$_.Season -eq $lost.Season -and [int]$_.Episode -eq $lost.Episode
            }).Count
            if ($wasWatched) { continue }
            $alreadyListed = @($downloadItems | Where-Object {
                [string]$_.Show -ieq $lost.Show -and [int]$_.Season -eq $lost.Season -and [int]$_.Episode -eq $lost.Episode
            }).Count
            if (-not $alreadyListed) { $downloadItems += $lost }
        }
        # A file that the balancer relocated is not missing: verify the move-log
        # destination still exists and drop it from the download list even if Plex
        # has not indexed the new path yet.
        $relocatedList = @(Get-PlaylistRelocatedMedia -LogDirectory (Join-Path $PSScriptRoot 'logs'))
        foreach ($relocated in $relocatedList) {
            $matches = @($downloadItems | Where-Object {
                [string]$_.Show -ieq $relocated.Show -and [int]$_.Season -eq $relocated.Season -and [int]$_.Episode -eq $relocated.Episode
            })
            if (-not $matches.Count) { continue }
            $downloadItems = @($downloadItems | Where-Object {
                -not ([string]$_.Show -ieq $relocated.Show -and [int]$_.Season -eq $relocated.Season -and [int]$_.Episode -eq $relocated.Episode)
            })
            Add-PlaylistAlert ('file-relocated-not-in-plex-' + $relocated.Show + '-S' + $relocated.Season + 'E' + $relocated.Episode) (
                "$($relocated.Show) S$('{0:00}' -f $relocated.Season)E$('{0:00}' -f $relocated.Episode) still exists at $($relocated.Path) after a balancer move, but Plex does not list it. Refresh the library section; do not re-download."
            )
        }
        if ($relocatedList.Count) {
            foreach ($show in $shows) {
                $st = $status[$show.Identity]
                if (-not $st -or -not $st.PSObject.Properties['DownloadMissing']) { continue }
                $st.DownloadMissing = @($st.DownloadMissing | Where-Object {
                    $entry = $_
                    -not @($relocatedList | Where-Object {
                        [string]$_.Show -ieq $show.Title -and [int]$_.Season -eq [int]$entry.Season -and [int]$_.Episode -eq [int]$entry.Episode
                    }).Count
                })
            }
        }
    }

    [object[]]$rounds = @(); if ($state) { $rounds = @($state.Rounds) }
    [object[]]$existingMovies = @(); if ($state) { $existingMovies = @($state.Movies) }
    $cursors = @{}
    if ($state -and $state.Cursors) {
        if ($state.Cursors -is [hashtable]) {
            foreach ($k in $state.Cursors.Keys) { $cursors[$k] = [long]$state.Cursors[$k] }
        }
        else {
            foreach ($p in $state.Cursors.PSObject.Properties) { $cursors[$p.Name] = [long]$p.Value }
        }
    }
    [string[]]$activeIds = @(); if ($state) { $activeIds = @($state.ActiveIds) }
    $cycleConsumed = @(Get-PlaylistProp $state 'CycleConsumed' @())
    $cycleNumber = [int](Get-PlaylistProp $state 'NextCycleNumber' 1)
    $newRounds = [pscustomobject]@{ Rounds = @(); ActiveIds = $activeIds; Cursors = $cursors; Replacements = @(); Stop = @(); CycleConsumed = $cycleConsumed; NextCycleNumber = $cycleNumber }
    $moviePlan = [pscustomobject]@{ Movies = $existingMovies; Stop = '' }
    [object[]]$roundMovieAnchors = @()
    if ($state -and -not $groups.Count) { $groups = @($state.Groups) }
    if (-not $RecoverOnly -and -not $unresolved.Count) {
        $preserveCursorIds = @()
        if ($state -and $state.BaseQueue) {
            $baseEpisodeShowKeys = @($state.BaseQueue | Where-Object { $_.Type -eq 'episode' -and $_.ShowKey } | ForEach-Object { [string]$_.ShowKey } | Select-Object -Unique)
            if ($baseEpisodeShowKeys.Count) {
                $preserveCursorIds = @($shows | Where-Object { [string]$_.Key -in $baseEpisodeShowKeys } | ForEach-Object Identity | Where-Object { $_ })
            }
        }
        $newRounds = Get-PlaylistRounds -Shows $shows -Episodes $episodes -Original $original -Replacements @($script:PlaylistCfg.replacements) -TvStatus $status -Cursors $cursors -ActiveIds $activeIds -StartRound $cycleNumber -CycleConsumed $cycleConsumed -PreserveCursorIds $preserveCursorIds
        foreach ($reason in $newRounds.Stop) { Add-PlaylistAlert ('round-shortage-' + $reason.Split(':')[0]) $reason }
        foreach ($change in $newRounds.Replacements) { Add-PlaylistAlert ('replacement-' + $change.From) ("Round $($change.Round): $($change.From) replaced by $($change.To). Manual override: $($change.ManualOverride).") }
        $rounds += @($newRounds.Rounds)
        # Keep the user's existing random movie choices as the initial draw order.
        # They are preferences, NOT permission to append the whole copied tail.
        $baseMovieCount = @($state.BaseQueue | Where-Object Type -eq 'movie').Count
        $context = Get-PlaylistContinuationContext @($state.BaseQueue)
        $plannedEpisodeIds = @($newRounds.Rounds | ForEach-Object { $_.Episodes } | ForEach-Object Identity)
        $roundMovieAnchors = @($showMovieAnchors | Where-Object { $_.EpisodeIdentity -in $plannedEpisodeIds })
        $cadencePlan = Get-PlaylistCadencePlan -Rounds @($newRounds.Rounds) -EpisodeOffset $context.Offset -EpisodesPerMovie ([int]$script:PlaylistCfg.episodesPerMovie) -Anchors $roundMovieAnchors
        $newMovieSlots = [int][math]::Max(0, $cadencePlan.RegularMovieSlots - @($context.Tail).Count)
        $moviePlan = Get-PlaylistMovies -Movies $movies -Groups $groups -Slots ($baseMovieCount + $newMovieSlots) -Seed ([int]$script:PlaylistCfg.randomSeed) -Existing $existingMovies -ReservedIdentities $reservedShowMovieIds
        foreach ($movieAnchor in $cadencePlan.TriggeredAnchors) {
            if ($movieAnchor.MovieIdentity -notin @($moviePlan.Movies | ForEach-Object Identity)) { $moviePlan.Movies = @($moviePlan.Movies) + @($movieAnchor.Movie) }
        }
        if ($moviePlan.Stop) { Add-PlaylistAlert 'movie-shortage' $moviePlan.Stop }
    }
    Add-PlaylistAlert 'cycle-progress' (Get-PlaylistCycleNotification -CycleNumber $newRounds.NextCycleNumber `
        -ConsumedCount @($newRounds.CycleConsumed).Count -CycleSize ([int]$script:PlaylistCfg.rotationSize))
    Add-PlaylistAlert 'episode-download-summary' (Get-PlaylistEpisodeAvailabilitySummary -TvStatus $status -NotChecked:$RecoverOnly)
    $script:PlaylistAlerts['status-checked-at'] = (Get-Date).ToString('o')

    $alertPath = Join-Path $script:PlaylistData 'notifications.json'
    $previousAlerts = @{}
    if (Test-Path -LiteralPath $alertPath) {
        $oldAlerts = [IO.File]::ReadAllText($alertPath) | ConvertFrom-Json
        foreach ($p in $oldAlerts.PSObject.Properties) { $previousAlerts[$p.Name] = $p.Value }
    }
    foreach ($id in $script:PlaylistAlerts.Keys) {
        if (-not $previousAlerts.ContainsKey($id) -or $previousAlerts[$id] -ne $script:PlaylistAlerts[$id]) { Write-Warning $script:PlaylistAlerts[$id] }
    }
    Write-PlaylistJson -Path $alertPath -Value $script:PlaylistAlerts

    # Keep the short download checklist fresh on every normal run. Recovery-only runs
    # skip the release check, so they must not overwrite it with an empty list.
    if (-not $RecoverOnly) {
        $downloadSetting = [string](Get-PlaylistProp $script:PlaylistCfg 'downloadListPath' 'LIBRARY-MISSING.md')
        $downloadPath = if ([IO.Path]::IsPathRooted($downloadSetting)) { $downloadSetting } else { Join-Path $PSScriptRoot $downloadSetting }
        Write-PlaylistDownloadList -Path $downloadPath -DownloadItems $downloadItems
    }

    if ($RecoverOnly -and -not $state) { throw 'Recovery requires an initialized intended queue. Run a preview/initial apply first.' }
    $desired = @()
    if ($RecoverOnly -or $unresolved.Count) { if ($state) { $desired = @($state.Queue) } }
    else { $desired = @(Merge-PlaylistContinuation -BaseQueue @($state.BaseQueue) -Rounds $rounds -Movies @($moviePlan.Movies) -MovieAnchors @($roundMovieAnchors)) }
    # Resolve old round/movie records through stable IDs after any Plex section refresh.
    $resolvedDesired = @()
    foreach ($wanted in $desired) {
        $found = Resolve-PlaylistMedia $wanted $library
        if ($found -and -not (Test-PlaylistMediaPresent $found) -and $Apply -and -not $refreshedSections.ContainsKey([string]$found.SectionId)) {
            $sectionId = [string]$found.SectionId
            $refreshedSections[$sectionId] = Update-PlaylistLibrarySection $sectionId
            if ($refreshedSections[$sectionId]) {
                $library = @(Read-ManagedLibrary)
                $found = Resolve-PlaylistMedia $wanted $library
            }
        }
        if ($found) {
            $resolvedDesired += $found
            if (-not (Test-PlaylistMediaPresent $found)) {
                Add-PlaylistAlert ('file-unavailable-' + $found.Identity) ("Plex still lists $($found.Title), so it remains in the managed queue. Its reported file path is not accessible to this process: $($found.Paths -join ', '). File probing is skipped; playlist membership follows Plex's library record.")
            }
        }
        else { if ($wanted.Identity -notin $unresolved.Identity) { $unresolved += $wanted }; $resolvedDesired += $wanted }
    }
    $desired = $resolvedDesired
    if ($state) {
        [void](Assert-PlaylistBaseQueuePreserved -BaseQueue @($state.BaseQueue) -Desired $desired)
    }
    # Historical 4-episode blocks are normally reported only. With backfill on,
    # an available downloaded next episode is inserted at each hole so a deleted
    # show does not permanently leave the managed cadence short. Insertion never
    # reorders existing entries, and the filled queue becomes the new protected
    # base so a later run cannot remove the inserted items as "unwanted".
    $cadenceFills = [pscustomobject]@{ Queue = $desired; Filled = @(); Unfilled = @() }
    if ((Get-PlaylistProp $script:PlaylistCfg 'cadenceBackfill' $true) -and $state -and -not $RecoverOnly -and -not $unresolved.Count) {
        $cadenceFills = Fill-PlaylistCadenceGaps -Queue $desired -Shows $shows -Episodes $episodes `
            -Cursors $cursors -ActiveIds @($newRounds.ActiveIds) -TvStatus $status `
            -EpisodesPerMovie ([int]$script:PlaylistCfg.episodesPerMovie) `
            -RotationSize ([int](Get-PlaylistProp $script:PlaylistCfg 'rotationSize' 25))
        if (@($cadenceFills.Filled).Count) {
            $desired = @($cadenceFills.Queue)
            foreach ($fill in @($cadenceFills.Filled)) {
                $ep = $fill.Episode
                $number = [long]$ep.Season * 10000 + [long]$ep.Episode
                $cursors[[string]$fill.Show.Identity] = $number
                $newRounds.Cursors[[string]$fill.Show.Identity] = $number
                Add-PlaylistAlert ('cadence-backfill-' + $ep.Identity) ("Filled a short TV block between '{0}' and '{1}' with {2} S{3:00}E{4:00} '{5}'." -f $fill.PreviousMovie.Title, $fill.NextMovie.Title, $fill.Show.Title, $ep.Season, $ep.Episode, $ep.Title)
            }
        }
    }
    foreach ($gap in @(Get-PlaylistCadenceGaps -Queue $current -EpisodesPerMovie ([int]$script:PlaylistCfg.episodesPerMovie))) {
        $key = 'cadence-gap-live-' + $gap.PreviousMovie.Identity + '-' + $gap.NextMovie.Identity
        Add-PlaylistAlert $key ("Managed live playlist cadence gap: {0} TV episodes between movie #{1} '{2}' and movie #{3} '{4}' (expected {5}). Review the managed order; no source-playlist or media changes were made." -f $gap.EpisodeCount,$gap.PreviousPosition,$gap.PreviousMovie.Title,$gap.NextPosition,$gap.NextMovie.Title,[int]$script:PlaylistCfg.episodesPerMovie)
    }
    foreach ($gap in @(Get-PlaylistCadenceGaps -Queue $desired -EpisodesPerMovie ([int]$script:PlaylistCfg.episodesPerMovie))) {
        $key = 'cadence-gap-intended-' + $gap.PreviousMovie.Identity + '-' + $gap.NextMovie.Identity
        Add-PlaylistAlert $key ("Managed intended playlist cadence gap: {0} TV episodes between movie #{1} '{2}' and movie #{3} '{4}' (expected {5}). Review the proposed order before applying." -f $gap.EpisodeCount,$gap.PreviousPosition,$gap.PreviousMovie.Title,$gap.NextPosition,$gap.NextMovie.Title,[int]$script:PlaylistCfg.episodesPerMovie)
    }
    $mediaIntegrityProbeCount = 0
    $mediaIntegrityFailureCount = 0
    if (Get-PlaylistProp $script:PlaylistCfg 'mediaIntegrityCheckEnabled' $false) {
        $mediaInfoPath = [string](Get-PlaylistProp $script:PlaylistCfg 'mediaInfoPath' '')
        if (-not $mediaInfoPath) {
            $mediaInfoCommand = Get-Command MediaInfo.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($mediaInfoCommand) { $mediaInfoPath = $mediaInfoCommand.Source }
        }
        elseif (-not (Test-Path -LiteralPath $mediaInfoPath -PathType Leaf)) {
            $mediaInfoCommand = Get-Command $mediaInfoPath -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($mediaInfoCommand) { $mediaInfoPath = $mediaInfoCommand.Source }
        }
        if (-not $mediaInfoPath -or -not (Test-Path -LiteralPath $mediaInfoPath -PathType Leaf)) {
            Add-PlaylistAlert 'media-integrity-tool' 'Media integrity check skipped: configure mediaInfoPath or install MediaInfo.exe.'
        }
        else {
            $probeCache = @{}
            $probeCachePath = Join-Path $script:PlaylistData 'media-integrity-cache.json'
            if (Test-Path -LiteralPath $probeCachePath) {
                try {
                    $savedProbeCache = Get-Content -LiteralPath $probeCachePath -Raw | ConvertFrom-Json
                    foreach ($entry in $savedProbeCache.PSObject.Properties) { $probeCache[$entry.Name] = $entry.Value }
                } catch { $probeCache = @{} }
            }
            $probeCacheDirty = $false
            $countedProbePaths = @{}
            foreach ($item in $desired) {
                $partFailures = @()
                foreach ($path in @($item.Paths)) {
                    if (-not $path) { continue }
                    if (-not [IO.File]::Exists($path)) { continue } # Missing files are reported by the recovery guard above.
                    $fileInfo = [IO.FileInfo]::new($path)
                    $cacheKey = $path.ToLowerInvariant()
                    $cached = $probeCache[$cacheKey]
                    if (-not $cached -or [long]$cached.Length -ne $fileInfo.Length -or [long]$cached.LastWriteTimeUtcTicks -ne $fileInfo.LastWriteTimeUtc.Ticks) {
                        $probeCache[$cacheKey] = [pscustomobject]@{ Length=$fileInfo.Length; LastWriteTimeUtcTicks=$fileInfo.LastWriteTimeUtc.Ticks
                            Result=(Test-PlaylistMediaPartIntegrity -Path $path -MediaInfoPath $mediaInfoPath) }
                        $probeCacheDirty = $true
                        $cached = $probeCache[$cacheKey]
                    }
                    $probe = $cached.Result
                    if (-not $countedProbePaths.ContainsKey($cacheKey)) {
                        $countedProbePaths[$cacheKey] = $true
                        if ($probe.Available) {
                            $mediaIntegrityProbeCount++
                            if (-not $probe.Healthy) { $mediaIntegrityFailureCount++ }
                        }
                    }
                    if ($probe.Available -and -not $probe.Healthy) { $partFailures += ("{0}: {1}" -f [IO.Path]::GetFileName($path),$probe.Reason) }
                }
                if ($partFailures.Count) {
                    Add-PlaylistAlert ('media-integrity-' + $item.Identity) ("Possible damaged media for '$($item.Title)': $($partFailures -join '; '). Review or re-download the file; the manager will not modify it.")
                }
            }
            if ($probeCacheDirty) { Write-PlaylistJson -Path $probeCachePath -Value $probeCache }
        }
    }
    $duplicateIds = @($desired | Group-Object Identity | Where-Object Count -gt 1)
    if ($duplicateIds.Count) {
        throw "Refusing to write a playlist with duplicate identities: $($duplicateIds.Name -join ', ')"
    }
    $savedBase = @($state.BaseQueue)
    if (@($cadenceFills.Filled).Count) { $savedBase = @($desired) }
    $candidate = [pscustomobject]@{ Version = 2; At = (Get-Date).ToString('o'); Server = $script:PlaylistBase
        SourceId = $script:SourcePlaylistId; TargetId = $script:ManagedPlaylistId; Queue = $desired
        BaseQueue = $savedBase
        Missing = @($stateMissing); MissingHistory = @($stateMissingHistory)
        Retired = @($retirements + $recoveredRetirements)
        Rounds = $rounds; Movies = @($moviePlan.Movies); Groups = $groups
        Cursors = $newRounds.Cursors; ActiveIds = $newRounds.ActiveIds
        CycleConsumed = @($newRounds.CycleConsumed); NextCycleNumber = $newRounds.NextCycleNumber
        DeletionEnabled = $false; Applied = $false }
    $ops = @(Get-PlaylistSyncOperations -Desired $desired -Current $current)
    $result = [pscustomobject]@{ At = (Get-Date).ToString('o'); Apply = [bool]$Apply; CurrentCount = $current.Count; DesiredCount = $desired.Count
        Rounds = $rounds.Count; AddedRounds = @($newRounds.Rounds).Count; AddedEpisodes = @($newRounds.Rounds | ForEach-Object { $_.Episodes } | ForEach-Object { $_ }).Count; Movies = @($moviePlan.Movies).Count
        Adds = @($ops | Where-Object Kind -eq 'add').Count; RemovesFromCopy = @($ops | Where-Object Kind -eq 'remove').Count
        Unresolved = $unresolved.Count; MediaProbeFiles = $mediaIntegrityProbeCount; MediaProbeFailures = $mediaIntegrityFailureCount
        DeferredMissing = @($deferred).Count; RestoredMissing = @($restored).Count; ReboundKeys = @($rebound).Count
        CadenceFills = @($cadenceFills.Filled).Count; UnfilledGaps = @($cadenceFills.Unfilled).Count
        CycleStopReasons = @($newRounds.Stop)
        Replacements = $newRounds.Replacements; Alerts = $script:PlaylistAlerts; Verified = $false }
    Write-PlaylistJson -Path (Join-Path $script:PlaylistData 'proposed-state.json') -Value $candidate
    Write-PlaylistJson -Path (Join-Path $script:PlaylistData 'last-result.json') -Value $result

    if ($Apply) {
        if ($unresolved.Count) {
            # Unresolved saved-queue items block full synchronization, but watched
            # retirement operates on the live managed head and must still run.
            $retiredCount = 0
            if ((Get-PlaylistProp $script:PlaylistCfg 'watchedFileDeletion' $false) -and (-not $RecoverOnly -or $retryPendingRetirement -or $RetireOneWatchedItem -or $RetireWatchedItems)) {
                $fresh = @(Read-ManagedItems $script:ManagedPlaylistId)
                if (($fresh.Key -join ',') -cne ($current.Key -join ',')) { throw 'Managed playlist changed during planning; retry without overwriting concurrent edits.' }
                $retiredCount = Invoke-AutomaticRetirement -Desired $fresh -State $candidate -StatePath $statePath -DataDirectory $script:PlaylistData -WatchedWindow $script:WatchedRetirementWindow -RetryExistingOnly:($RecoverOnly -and $retryPendingRetirement) -SingleHeadOnly:$RetireOneWatchedItem
                $desired = @($candidate.Queue)
                $result = Update-PlaylistResultAfterRetirement -Result $result -RetiredCount $retiredCount -DesiredCount $desired.Count -MovieCount @($candidate.Movies).Count
                Write-PlaylistJson -Path (Join-Path $script:PlaylistData 'last-result.json') -Value $result
            }
            $msg = 'Unresolved media remains. Notifications saved; existing playlist and intended state retained.'
            if ($retiredCount -gt 0) { $msg += " Watched retirement removed $retiredCount item(s) from the live head before this check." }
            throw $msg
        }
        if ($moviePlan.Stop) { throw 'Movie shortage prevents a valid complete queue; playlist unchanged.' }
        if (-not $desired.Count) { throw 'Refusing to clear a playlist with an empty proposal.' }
        # Optimistic concurrency check before the first mutation.
        $fresh = @(Read-ManagedItems $script:ManagedPlaylistId)
        if (($fresh.Key -join ',') -cne ($current.Key -join ',')) { throw 'Managed playlist changed during planning; retry without overwriting concurrent edits.' }
        # Durable intent BEFORE writes: interrupted updates can be retried safely.
        Write-PlaylistJson $statePath $candidate
        [void](Set-PlaylistIntendedItems -Desired $desired -Current $current)
        $sourceNow = @(Read-ManagedItems $script:SourcePlaylistId)
        if (($sourceNow.Key -join ',') -cne $originalSignature) {
            $completedRetirementIds = @($retirements + $recoveredRetirements | ForEach-Object { $_.Item.Identity })
            if (Test-PlaylistSourceMatchesAfterRetirements -Original $original -Current $sourceNow -RetiredIdentities $completedRetirementIds) {
                Write-Warning 'Plex removed only completed watched-retirement items from the source playlist after their media deletion; no source-playlist write was made.'
            }
            else { throw 'Original playlist changed concurrently beyond Plex pruning completed retirements; inspect before proceeding. This manager never writes to it.' }
        }
        # Set-PlaylistIntendedItems has verified the final managed order. Refresh
        # cadence notices from that verified queue so resolved gaps do not linger
        # in the status screen as if they were still live.
        foreach ($alertId in @($script:PlaylistAlerts.Keys | Where-Object { $_ -like 'cadence-gap-live-*' -or $_ -like 'cadence-gap-intended-*' })) {
            $script:PlaylistAlerts.Remove($alertId)
        }
        foreach ($gap in @(Get-PlaylistCadenceGaps -Queue $desired -EpisodesPerMovie ([int]$script:PlaylistCfg.episodesPerMovie))) {
            $key = 'cadence-gap-live-' + $gap.PreviousMovie.Identity + '-' + $gap.NextMovie.Identity
            Add-PlaylistAlert $key ("Managed live playlist cadence gap: {0} TV episodes between movie #{1} '{2}' and movie #{3} '{4}' (expected {5}). Review the managed order; no source-playlist or media changes were made." -f $gap.EpisodeCount,$gap.PreviousPosition,$gap.PreviousMovie.Title,$gap.NextPosition,$gap.NextMovie.Title,[int]$script:PlaylistCfg.episodesPerMovie)
        }
        $result.Alerts = $script:PlaylistAlerts
        Write-PlaylistJson -Path $alertPath -Value $script:PlaylistAlerts
        $candidate.Applied = $true; $result.Verified = $true
        Write-PlaylistJson $statePath $candidate
        foreach ($transaction in $recoveredRetirements) {
            $transaction.QueueUpdated = $true
            $transaction.Status = 'Complete'
            $transaction.PSObject.Properties.Remove('TransactionPath')
            Write-PlaylistJson (Join-Path $script:PlaylistData ('retirement-' + $transaction.Item.Key + '.json')) $transaction
        }
        Write-PlaylistJson -Path (Join-Path $script:PlaylistData 'last-result.json') -Value $result
    }
    $retiredCount = 0
    if ($Apply -and (Get-PlaylistProp $script:PlaylistCfg 'watchedFileDeletion' $false) -and (-not $RecoverOnly -or $retryPendingRetirement -or $RetireOneWatchedItem -or $RetireWatchedItems)) {
        $retiredCount = Invoke-AutomaticRetirement -Desired $desired -State $candidate -StatePath $statePath -DataDirectory $script:PlaylistData -WatchedWindow $script:WatchedRetirementWindow -RetryExistingOnly:($RecoverOnly -and $retryPendingRetirement) -SingleHeadOnly:$RetireOneWatchedItem
    }
    $desired = @($candidate.Queue)
    $result = Update-PlaylistResultAfterRetirement -Result $result -RetiredCount $retiredCount -DesiredCount $desired.Count -MovieCount @($candidate.Movies).Count
    Write-PlaylistJson -Path (Join-Path $script:PlaylistData 'last-result.json') -Value $result

    $lines = @('# Managed playlist proposal', '', "Generated: $($result.At)", "Apply: $Apply; verified: $($result.Verified)",
        "Current: $($current.Count); intended: $($desired.Count); newly planned cycle segments: $($rounds.Count); movies: $($result.Movies)", '', '## Notifications')
    foreach ($id in $script:PlaylistAlerts.Keys) { $lines += '- ' + $script:PlaylistAlerts[$id] }
    $lines += @('', '## Intended order')
    for ($i = 0; $i -lt $desired.Count; $i++) {
        $e = $desired[$i]
        $label = if ($e.Type -eq 'episode') { '{0} S{1:00}E{2:00} - {3}' -f $e.Show, $e.Season, $e.Episode, $e.Title } else { $e.Title }
        $lines += ('{0}. {1}' -f ($i + 1), $label)
    }
    [IO.File]::WriteAllText((Join-Path $script:PlaylistData 'queue.md'), ($lines -join "`r`n"), [Text.UTF8Encoding]::new($false))
    "Managed copy: $($script:PlaylistCfg.managedPlaylist); apply=$Apply; verified=$($result.Verified)"
    "New episodes=$($result.AddedEpisodes), movies=$($result.Movies), intended=$($desired.Count), add=$($result.Adds), remove from copy=$($result.RemovesFromCopy)"
    "Reports and durable intent: $script:PlaylistData"
}
finally {
    if ($held) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
