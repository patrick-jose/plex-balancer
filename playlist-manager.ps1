# Managed playlist maintenance. Preview by default; -Apply edits only the named
# copy. Never deletes media, changes watch state, or touches Plex's database.
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$DataDirectory,
    [switch]$Apply,
    [switch]$RecoverOnly,
    [switch]$AcceptManualOrder,
    [string]$RepairCycleStopBeforeShow
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'playlist-lib.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'playlist.config.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw 'Create playlist.config.json from playlist.config.example.json first.' }
$script:PlaylistCfg = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
$script:PlaylistBase = ([string]$script:PlaylistCfg.serverUrl).TrimEnd('/')
$serverUri = [uri]$script:PlaylistBase
if ($serverUri.Scheme -notin @('http','https') -or $serverUri.UserInfo -or $serverUri.Query) { throw 'Invalid Plex server URL.' }
if ($script:PlaylistCfg.sourcePlaylist -ceq $script:PlaylistCfg.managedPlaylist) { throw 'Source and managed playlists must be different.' }
if ([int]$script:PlaylistCfg.rotationSize -ne 25 -or [int]$script:PlaylistCfg.episodesPerMovie -ne 5) { throw 'This manager implements 25 shows and five episodes per movie.' }
if (Get-PlaylistProp $script:PlaylistCfg 'watchedFileDeletion' $false) { throw 'Watched-file deletion is not approved/configured and cannot be enabled here.' }
$token = $env:PLEX_TOKEN
if (-not $token) { $token = (Get-ItemProperty 'HKCU:\Software\Plex, Inc.\Plex Media Server' -ErrorAction SilentlyContinue).PlexOnlineToken }
if (-not $token) { throw 'No Plex token available.' }
$script:PlaylistHeaders = @{ 'X-Plex-Token' = $token; Accept = 'application/xml' }
$script:PlaylistApply = [bool]$Apply
$script:PlaylistAlerts = @{}
$script:PlaylistData = if ($DataDirectory) { [IO.Path]::GetFullPath($DataDirectory) } else { Join-Path $PSScriptRoot 'playlist-data' }
[void][IO.Directory]::CreateDirectory($script:PlaylistData)
$statePath = Join-Path $script:PlaylistData 'state.json'
$mutex = [Threading.Mutex]::new($false, 'Global\PlexBalancer')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'A balancer/reconcile/playlist run is active. Retry after it finishes.' }

    function Read-ManagedLibrary {
        $result = @()
        foreach ($section in $script:PlaylistSections) {
            $id = $section.GetAttribute('key'); $type = $section.GetAttribute('type')
            if ($type -notin @('show','movie')) { continue }
            $kind = if ($type -eq 'show') { 4 } else { 1 }
            foreach ($node in @(Get-PlaylistPlexItems "/library/sections/$id/all?type=$kind&includeGuids=1")) {
                $result += Convert-PlaylistMedia $node $id
            }
        }
        return $result
    }

    function Read-ManagedItems {
        param([string]$Id)
        @(Get-PlaylistPlexItems "/playlists/$Id/items?includeGuids=1" | ForEach-Object { Convert-PlaylistMedia $_ })
    }

    function Get-RecoveryFolders {
        param($Item)
        $section = @($script:PlaylistSections | Where-Object { $_.GetAttribute('key') -eq $Item.SectionId })
        if ($section.Count -ne 1) { return @() }
        $roots = @($section[0].SelectNodes('Location') | ForEach-Object { $_.GetAttribute('path').TrimEnd('\') })
        $candidates = @()
        foreach ($old in $Item.Paths) {
            foreach ($root in $roots) {
                if (-not $old.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
                $relative = $old.Substring($root.Length).TrimStart('\')
                foreach ($target in $roots) {
                    $path = Join-Path $target $relative
                    # Do not scan an entire offline drive or a root whose known
                    # file has disappeared. A moved file can be on any library root.
                    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($path))
                    if ($drive.IsReady -and [IO.File]::Exists($path)) { $candidates += [IO.Path]::GetDirectoryName($path) }
                }
            }
        }
        return @($candidates | Select-Object -Unique)
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
    # A partial transaction must be inspected rather than re-adding deleted media.
    $retirements = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $script:PlaylistData -Filter 'retirement-*.json' -File)) {
        $record = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        if ($record.Status -ne 'Complete') { throw "Watched retirement needs inspection: $($file.Name). Queue recovery paused to prevent resurrection." }
        $retirements += $record
    }
    if ($state -and $retirements.Count) {
        $retiredIds = @($retirements | ForEach-Object { $_.Item.Identity })
        $state.Queue = @($state.Queue | Where-Object { $_.Identity -notin $retiredIds })
        $state.BaseQueue = @($state.BaseQueue | Where-Object { $_.Identity -notin $retiredIds })
    }
    if ($state -and $state.Applied) {
        # Existing relative order is fixed. New TV entries continue before the
        # movie-only reserve, reusing its movies rather than appending past it.
        $state.BaseQueue = @($state.Queue)
        $state.Rounds = @()
        $state.Movies = @($state.Queue | Where-Object Type -eq 'movie')
    }
    elseif ($state -and -not $RecoverOnly -and (Test-Path -LiteralPath $statePath)) {
        throw 'An interrupted update has pending intent. Run -Apply -RecoverOnly before extending it.'
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

    # Recover the durable intended queue BEFORE adding more media. Never shrink it
    # simply because a disk vanished, Plex lost a ratingKey, or a scan is delayed.
    $unresolved = @()
    $recovered = @()
    if ($state) {
        foreach ($wanted in @($state.Queue)) {
            $found = Resolve-PlaylistMedia $wanted $library
            if (-not $found -and $Apply) {
                $folders = @(Get-RecoveryFolders $wanted)
                if ($folders.Count) {
                    foreach ($folder in $folders) {
                        [void](Invoke-PlaylistPlex ("/library/sections/{0}/refresh?path={1}" -f $wanted.SectionId, [uri]::EscapeDataString($folder)))
                    }
                    $deadline = (Get-Date).AddSeconds([int]$script:PlaylistCfg.scanTimeoutSeconds)
                    # Give an asynchronous scanner time to start before checking.
                    Start-Sleep -Seconds 2
                    do {
                        $sectionsNow = @((Invoke-PlaylistPlex '/library/sections').SelectNodes('Directory'))
                        $scanning = @($sectionsNow | Where-Object { $_.GetAttribute('key') -eq $wanted.SectionId -and $_.GetAttribute('refreshing') -in @('1','true') }).Count -gt 0
                        if ($scanning) { Start-Sleep -Seconds 2 }
                    } while ($scanning -and (Get-Date) -lt $deadline)
                    if (-not $scanning) { $library = @(Read-ManagedLibrary); $found = Resolve-PlaylistMedia $wanted $library }
                }
            }
            if ($found) { $recovered += $found }
            else {
                $unresolved += $wanted
                Add-PlaylistAlert ('unresolved-' + $wanted.Identity) ("Missing/ambiguous item: $($wanted.Show) $($wanted.Title). Expected: $($wanted.Paths -join ', '). Check disks/library. No playlist write until recovery is complete.")
            }
        }
    }

    $episodes = @($library | Where-Object Type -eq 'episode')
    $movies = @($library | Where-Object Type -eq 'movie')
    $status = @{}
    # No title searches: provider IDs must match exactly. Only the show's remaining
    # timeline (at/after the manual seed) is relevant to missing-episode notices.
    if (-not $RecoverOnly) {
        foreach ($show in $shows) {
            $seed = @($original | Where-Object { $_.ShowKey -eq $show.Key } | Sort-Object Season, Episode | Select-Object -First 1)
            $anchor = if ($seed.Count) { [long]$seed[0].Season * 10000 + $seed[0].Episode } else { 1 }
            if ($state) {
                $savedCursor = Get-PlaylistProp $state.Cursors $show.Identity 0
                $anchor = [math]::Max($anchor, [long]$savedCursor + 1)
            }
            $st = Get-PlaylistTvStatus $show $episodes $anchor
            $status[$show.Identity] = $st
            if ($st.Known -and @($st.Missing).Count) {
                $names = @($st.Missing | ForEach-Object { 'S{0:00}E{1:00}' -f $_.Season, $_.Episode }) -join ', '
                Add-PlaylistAlert ('tv-missing-' + $show.Identity) ("$($show.Title): aired/released episodes absent locally: $names. Air dates do not guarantee download availability.")
            }
            elseif (-not $st.Known -and (Get-PlaylistTmdbCredential).Configured) { Add-PlaylistAlert ('tv-unknown-' + $show.Identity) ("$($show.Title): TV status unavailable; no automatic retirement.") }
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
    [object[]]$groups = @(); if ($state) { $groups = @($state.Groups) }
    if (-not $RecoverOnly -and -not $unresolved.Count) {
        $newRounds = Get-PlaylistRounds -Shows $shows -Episodes $episodes -Original $original -Replacements @($script:PlaylistCfg.replacements) -TvStatus $status -Cursors $cursors -ActiveIds $activeIds -StartRound $cycleNumber -CycleConsumed $cycleConsumed
        foreach ($reason in $newRounds.Stop) { Add-PlaylistAlert ('round-shortage-' + $reason.Split(':')[0]) $reason }
        foreach ($change in $newRounds.Replacements) { Add-PlaylistAlert ('replacement-' + $change.From) ("Round $($change.Round): $($change.From) replaced by $($change.To). Manual override: $($change.ManualOverride).") }
        $rounds += @($newRounds.Rounds)
        $groups = @(Get-PlaylistMovieGroups -Movies $movies -ThematicGroups @($script:PlaylistCfg.thematicGroups))
        # Keep the user's existing random movie choices as the initial draw order.
        # They are preferences, NOT permission to append the whole copied tail.
        $baseMovieCount = @($state.BaseQueue | Where-Object Type -eq 'movie').Count
        $episodeCount = @($rounds | ForEach-Object { $_.Episodes } | ForEach-Object { $_ }).Count
        $context = Get-PlaylistContinuationContext @($state.BaseQueue)
        $newMovieSlots = [int][math]::Max(0, [math]::Floor(($context.Offset + $episodeCount) / 5) - @($context.Tail).Count)
        $moviePlan = Get-PlaylistMovies -Movies $movies -Groups $groups -Slots ($baseMovieCount + $newMovieSlots) -Seed ([int]$script:PlaylistCfg.randomSeed) -Existing $existingMovies
        if ($moviePlan.Stop) { Add-PlaylistAlert 'movie-shortage' $moviePlan.Stop }
    }
    if ($RecoverOnly -and -not $state) { throw 'Recovery requires an initialized intended queue. Run a preview/initial apply first.' }
    $desired = @()
    if ($RecoverOnly -or $unresolved.Count) { if ($state) { $desired = @($state.Queue) } }
    else { $desired = @(Merge-PlaylistContinuation -BaseQueue @($state.BaseQueue) -Rounds $rounds -Movies @($moviePlan.Movies)) }
    # Resolve old round/movie records through stable IDs after any cross-disk scan.
    $resolvedDesired = @()
    foreach ($wanted in $desired) {
        $found = Resolve-PlaylistMedia $wanted $library
        if ($found) {
            $resolvedDesired += $found
            if (-not (Test-PlaylistMediaPresent $found)) {
                if ($found.Identity -notin $unresolved.Identity) { $unresolved += $found }
                Add-PlaylistAlert ('file-unavailable-' + $found.Identity) ("Plex lists $($found.Title), but its file/drive is unavailable: $($found.Paths -join ', '). Playlist updates paused; no deletion or trash operation.")
            }
        }
        else { if ($wanted.Identity -notin $unresolved.Identity) { $unresolved += $wanted }; $resolvedDesired += $wanted }
    }
    $desired = $resolvedDesired
    $candidate = [pscustomobject]@{ Version = 2; At = (Get-Date).ToString('o'); Server = $script:PlaylistBase
        SourceId = $script:SourcePlaylistId; TargetId = $script:ManagedPlaylistId; Queue = $desired
        BaseQueue = @($state.BaseQueue)
        Retired = $retirements
        Rounds = $rounds; Movies = @($moviePlan.Movies); Groups = $groups
        Cursors = $newRounds.Cursors; ActiveIds = $newRounds.ActiveIds
        CycleConsumed = @($newRounds.CycleConsumed); NextCycleNumber = $newRounds.NextCycleNumber
        DeletionEnabled = $false; Applied = $false }
    $ops = @(Get-PlaylistSyncOperations -Desired $desired -Current $current)
    $result = [pscustomobject]@{ At = (Get-Date).ToString('o'); Apply = [bool]$Apply; CurrentCount = $current.Count; DesiredCount = $desired.Count
        Rounds = $rounds.Count; AddedRounds = @($newRounds.Rounds).Count; AddedEpisodes = @($newRounds.Rounds | ForEach-Object { $_.Episodes } | ForEach-Object { $_ }).Count; Movies = @($moviePlan.Movies).Count
        Adds = @($ops | Where-Object Kind -eq 'add').Count; RemovesFromCopy = @($ops | Where-Object Kind -eq 'remove').Count
        Unresolved = $unresolved.Count; Replacements = $newRounds.Replacements; Alerts = $script:PlaylistAlerts; Verified = $false }
    Write-PlaylistJson -Path (Join-Path $script:PlaylistData 'proposed-state.json') -Value $candidate
    Write-PlaylistJson -Path (Join-Path $script:PlaylistData 'last-result.json') -Value $result

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

    if ($Apply) {
        if ($unresolved.Count) { throw 'Unresolved media remains. Notifications saved; existing playlist and intended state retained.' }
        if ($moviePlan.Stop) { throw 'Movie shortage prevents a valid complete queue; playlist unchanged.' }
        if (-not $desired.Count) { throw 'Refusing to clear a playlist with an empty proposal.' }
        # If an established managed queue was deliberately edited or reordered,
        # do not guess whether it was manual or a Plex failure. Missing-only cases
        # are recoverable; novel extras/order changes require explicit acceptance.
        if ($state -and $state.Applied -and -not $AcceptManualOrder) {
            $knownQueue = @($state.Queue | ForEach-Object { $match = Resolve-PlaylistMedia $_ $library; if ($match) { $match } else { $_ } })
            $extras = @($current | Where-Object { $_.Identity -notin $knownQueue.Identity })
            $retained = @($current | Where-Object { $_.Identity -in $knownQueue.Identity } | ForEach-Object { $_.Identity })
            $expectedRetained = @($knownQueue | Where-Object { $_.Identity -in $current.Identity } | ForEach-Object { $_.Identity })
            if ($extras.Count -or ($retained -join '|') -cne ($expectedRetained -join '|')) { throw 'Manual playlist edits detected. Review the preview; rerun with -AcceptManualOrder only to explicitly restore the saved intended order.' }
        }
        # Optimistic concurrency check before the first mutation.
        $fresh = @(Read-ManagedItems $script:ManagedPlaylistId)
        if (($fresh.Key -join ',') -cne ($current.Key -join ',')) { throw 'Managed playlist changed during planning; retry without overwriting concurrent edits.' }
        # Durable intent BEFORE writes: interrupted updates can be retried safely.
        Write-PlaylistJson $statePath $candidate
        [void](Set-PlaylistIntendedItems -Desired $desired -Current $current)
        $sourceNow = @(Read-ManagedItems $script:SourcePlaylistId)
        if (($sourceNow.Key -join ',') -cne $originalSignature) { throw 'Original playlist changed concurrently; inspect before proceeding. This manager never writes to it.' }
        $candidate.Applied = $true; $result.Verified = $true
        Write-PlaylistJson $statePath $candidate
        Write-PlaylistJson -Path (Join-Path $script:PlaylistData 'last-result.json') -Value $result
    }
    $lines = @('# Managed playlist proposal', '', "Generated: $($result.At)", "Apply: $Apply; verified: $($result.Verified)",
        "Current: $($current.Count); intended: $($desired.Count); newly planned cycle segments: $($rounds.Count); movies: $(@($moviePlan.Movies).Count)", '', '## Notifications')
    foreach ($id in $script:PlaylistAlerts.Keys) { $lines += '- ' + $script:PlaylistAlerts[$id] }
    $lines += @('', '## Intended order')
    for ($i = 0; $i -lt $desired.Count; $i++) {
        $e = $desired[$i]
        $label = if ($e.Type -eq 'episode') { '{0} S{1:00}E{2:00} - {3}' -f $e.Show, $e.Season, $e.Episode, $e.Title } else { $e.Title }
        $lines += ('{0}. {1}' -f ($i + 1), $label)
    }
    [IO.File]::WriteAllText((Join-Path $script:PlaylistData 'queue.md'), ($lines -join "`r`n"), [Text.UTF8Encoding]::new($false))
    "Managed copy: $($script:PlaylistCfg.managedPlaylist); apply=$Apply; verified=$($result.Verified)"
    "New episodes=$($result.AddedEpisodes), movies=$(@($moviePlan.Movies).Count), intended=$($desired.Count), add=$($result.Adds), remove from copy=$($result.RemovesFromCopy)"
    "Reports and durable intent: $script:PlaylistData"
}
finally {
    if ($held) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}

