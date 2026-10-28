# Shared playlist engine. Dot-source this file; it has no startup side effects.
# Personal state and credentials are never stored alongside publishable code.
function Get-PlaylistProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Write-PlaylistJson {
    param([string]$Path, $Value)
    $parent = [IO.Path]::GetDirectoryName($Path)
    [void][IO.Directory]::CreateDirectory($parent)
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Value -Depth 30), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, $Path + '.bak') }
        else { [IO.File]::Move($tmp, $Path) }
    }
    finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}

function Invoke-PlaylistPlex {
    param([string]$Path, [ValidateSet('Get','Post','Put','Delete')][string]$Method = 'Get')
    if (-not $Path.StartsWith('/')) { throw 'Plex requests must use local relative API paths.' }
    # No DELETE library/metadata or filesystem operation is supported here.
    if ($Method -ne 'Get' -and $Path -notmatch '^/playlists/\d+(/items(/\d+(/move)?)?)?(\?|$)') {
        throw 'Playlist writes are restricted to the managed playlist.'
    }
    if ($Method -ne 'Get' -and ($Path -notmatch ('^/playlists/' + [regex]::Escape([string]$script:ManagedPlaylistId) + '(/|\?|$)') -or
        [string]$script:ManagedPlaylistId -eq [string]$script:SourcePlaylistId)) { throw 'Refusing a write outside the managed copy.' }
    if ($Method -ne 'Get' -and -not $script:PlaylistApply) { throw 'Writes require -Apply.' }
    $r = Invoke-WebRequest -Uri ($script:PlaylistBase + $Path) -Method $Method -Headers $script:PlaylistHeaders -UseBasicParsing -TimeoutSec 45 -ErrorAction Stop
    if ($r.RawContentStream.Length -gt 0) {
        $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        if ($text.TrimStart().StartsWith('<')) { return ([xml]$text).DocumentElement }
    }
}

function Get-PlaylistPlexItems {
    param([string]$Path, [string]$Tag = 'Video')
    $offset = 0
    do {
        $sep = if ($Path.Contains('?')) { '&' } else { '?' }
        $page = Invoke-PlaylistPlex ($Path + $sep + "X-Plex-Container-Start=$offset&X-Plex-Container-Size=200")
        $nodes = @($page.SelectNodes($Tag))
        foreach ($node in $nodes) { Write-Output $node }
        $offset += $nodes.Count
        $total = if ($page.HasAttribute('totalSize')) { [int]$page.GetAttribute('totalSize') } else { [int]$page.GetAttribute('size') }
        if ($nodes.Count -eq 0 -and $offset -lt $total) { throw 'Plex returned an incomplete page.' }
    } while ($offset -lt $total)
}

function Convert-PlaylistMedia {
    param($Node, [string]$SectionId = '')
    $ids = @($Node.SelectNodes('Guid') | ForEach-Object { $_.GetAttribute('id') } | Where-Object { $_ } | Sort-Object -Unique)
    $guid = $Node.GetAttribute('guid')
    if ($guid) { $ids += $guid }
    $ids = @($ids | Sort-Object -Unique)
    if (-not $ids.Count) { throw ('No stable identity for ' + $Node.GetAttribute('title')) }
    $identity = @($ids | Where-Object { $_ -match '^plex://' } | Select-Object -First 1)
    if (-not $identity.Count) { $identity = @($ids[0]) }
    $sort = $Node.GetAttribute('titleSort')
    if (-not $sort) { $sort = $Node.GetAttribute('title') -replace '^(?i)(the|a|an)\s+', '' }
    $section = $Node.GetAttribute('librarySectionID')
    if (-not $section) { $section = $SectionId }
    return [pscustomobject]@{ Identity = $identity[0]; Ids = $ids; Key = $Node.GetAttribute('ratingKey')
        PlaylistItemId = $Node.GetAttribute('playlistItemID'); Type = $Node.GetAttribute('type')
        Title = $Node.GetAttribute('title'); SortTitle = $sort; Show = $Node.GetAttribute('grandparentTitle')
        ShowKey = $Node.GetAttribute('grandparentRatingKey'); Season = [int]$Node.GetAttribute('parentIndex')
        Episode = [int]$Node.GetAttribute('index'); ReleaseDate = $Node.GetAttribute('originallyAvailableAt')
        Watched = ([int]$Node.GetAttribute('viewCount') -gt 0); SectionId = $section
        Paths = @($Node.SelectNodes('Media/Part') | ForEach-Object { $_.GetAttribute('file') } | Where-Object { $_ })
        Collections = @($Node.SelectNodes('Collection') | ForEach-Object { $_.GetAttribute('tag') }) }
}

function Resolve-PlaylistMedia {
    param($Wanted, [object[]]$Library)
    $matches = @($Library | Where-Object {
        $candidate = $_
        $candidate.Type -eq $Wanted.Type -and @($Wanted.Ids | Where-Object { $_ -in $candidate.Ids }).Count -gt 0
    })
    if ($matches.Count -eq 1) { return $matches[0] }
    # Multiple editions/matches must never be resolved by arbitrarily taking one.
    return $null
}

function Test-PlaylistMediaPresent {
    param($Item)
    foreach ($path in $Item.Paths) {
        try {
            $root = [IO.Path]::GetPathRoot($path)
            $drive = [IO.DriveInfo]::new($root)
            if (-not $drive.IsReady) { continue }
            if ([IO.File]::Exists($path)) { return $true }
        } catch { }
    }
    return $false
}

function Get-PlaylistTmdbCredential {
    param($Config = $script:PlaylistCfg)
    $token = ([string](Get-PlaylistProp $Config 'tmdbReadToken' '')).Trim()
    $key = ([string](Get-PlaylistProp $Config 'tmdbApiKey' '')).Trim()
    # An explicitly saved local credential takes precedence over stale environment
    # values. Either field is enough; never emit this object in console reports.
    if (-not $token -and -not $key) {
        $token = ([string]$env:TMDB_READ_TOKEN).Trim()
        $key = ([string]$env:TMDB_API_KEY).Trim()
    }
    $token = $token -replace '^(?i)Bearer\s+', ''
    return [pscustomobject]@{ Token=$token; ApiKey=$key; Configured=([bool]($token -or $key)) }
}

function Get-PlaylistMetadata {
    param([string]$Path, [switch]$Fresh)
    $cachePath = Join-Path $script:PlaylistData ('metadata/' + (($Path -replace '[^a-zA-Z0-9-]', '_')) + '.json')
    if (-not $Fresh -and (Test-Path -LiteralPath $cachePath)) {
        $file = Get-Item -LiteralPath $cachePath
        if ($file.LastWriteTime -gt (Get-Date).AddHours(-[double](Get-PlaylistProp $script:PlaylistCfg 'metadataCacheHours' 24))) {
            return [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
        }
    }
    $headers = @{ Accept = 'application/json' }
    $credential = Get-PlaylistTmdbCredential
    if ($credential.Token) { $headers.Authorization = 'Bearer ' + $credential.Token }
    elseif ($credential.ApiKey) { $sep = if ($Path.Contains('?')) { '&' } else { '?' }; $Path += $sep + 'api_key=' + [uri]::EscapeDataString($credential.ApiKey) }
    else { throw 'TMDb credential missing: fill tmdbReadToken or tmdbApiKey in playlist.config.json.' }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-WebRequest -Uri ('https://api.themoviedb.org/3/' + $Path.TrimStart('/')) -Headers $headers -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $data = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
        if (-not $Fresh) { Write-PlaylistJson -Path $cachePath -Value $data }
        return $data
    }
    catch { throw 'TMDb metadata request failed; credential and request URL suppressed.' }
}

function Get-PlaylistProviderId {
    param($Item, [string]$Provider)
    $id = @($Item.Ids | Where-Object { $_ -match ('^' + [regex]::Escape($Provider) + '://') } | Select-Object -First 1)
    if ($id.Count) { return ($id[0] -replace '^[^:]+://', '') }
    return ''
}

function Get-PlaylistTvStatus {
    param($Show, [object[]]$Episodes, [long]$Anchor)
    $id = Get-PlaylistProviderId $Show 'tmdb'
    $local = @($Episodes | Where-Object { $_.ShowKey -eq $Show.Key -and $_.Season -gt 0 })
    if (-not $id) { return [pscustomobject]@{ Known = $false; Ended = $false; Final = 0; Missing = @(); Message = 'No TMDb ID'; NextAirDate = '' } }
    try {
        $tv = Get-PlaylistMetadata "tv/$id"
        $released = @()
        $future = @()
        foreach ($season in @($tv.seasons | Where-Object { $_.season_number -gt 0 })) {
            $detail = Get-PlaylistMetadata "tv/$id/season/$($season.season_number)"
            foreach ($e in $detail.episodes) {
                $number = [long]$e.season_number * 10000 + [long]$e.episode_number
                if (-not $e.air_date) { continue }
                $entry = [pscustomobject]@{ Number = $number; Season = $e.season_number; Episode = $e.episode_number; AirDate = $e.air_date }
                if ([datetime]$e.air_date -le (Get-Date).Date) { $released += $entry } else { $future += $entry }
            }
        }
        $localNumbers = @($local | ForEach-Object { [long]$_.Season * 10000 + $_.Episode })
        $missing = @($released | Where-Object { $_.Number -ge $Anchor -and $_.Number -notin $localNumbers })
        $allNumbers = @($released.Number) + @($future.Number)
        $final = if ($allNumbers.Count) { [long](($allNumbers | Measure-Object -Maximum).Maximum) } else { 0 }
        return [pscustomobject]@{ Known = $true; Ended = ($tv.status -in @('Ended','Canceled')); Final = $final; Missing = $missing; Future = $future
            Message = [string]$tv.status; NextAirDate = if ($future.Count) { ($future | Sort-Object AirDate | Select-Object -First 1).AirDate } else { '' } }
    }
    catch { return [pscustomobject]@{ Known = $false; Ended = $false; Final = 0; Missing = @(); Message = $_.Exception.Message; NextAirDate = '' } }
}

function Get-PlaylistRounds {
    param([object[]]$Shows, [object[]]$Episodes, [object[]]$Original, [object[]]$Replacements,
        [hashtable]$TvStatus, [int]$Count = 25, [int]$StartRound = 1, [hashtable]$Cursors = @{}, [string[]]$ActiveIds = @(),
        [string[]]$CycleConsumed = @())
    $standby = @($Replacements | ForEach-Object { $_.to })
    $active = if ($ActiveIds.Count) { @($Shows | Where-Object { $_.Identity -in $ActiveIds }) } else { @($Shows | Where-Object { $_.Title -notin $standby }) }
    $missingActiveIds = @($ActiveIds | Where-Object { $_ -notin $Shows.Identity })
    $queue = @{}
    foreach ($show in $Shows) {
        $seed = @($Original | Where-Object { $_.Type -eq 'episode' -and $_.ShowKey -eq $show.Key } | Sort-Object Season, Episode | Select-Object -First 1)
        $anchor = if ($seed.Count) { [long]$seed[0].Season * 10000 + $seed[0].Episode } else { 1 }
        $after = if ($Cursors.ContainsKey($show.Identity)) { [long]$Cursors[$show.Identity] } else { 0 }
        $queue[$show.Identity] = @($Episodes | Where-Object {
            $_.ShowKey -eq $show.Key -and $_.Season -gt 0 -and -not $_.Watched -and
            ([long]$_.Season * 10000 + $_.Episode) -ge $anchor -and ([long]$_.Season * 10000 + $_.Episode) -gt $after
        } | Sort-Object Season, Episode, Key | Group-Object Season, Episode | ForEach-Object { $_.Group[0] })
        $status = $TvStatus[$show.Identity]
        if ($status -and $status.Known -and @($status.Missing).Count) {
            $firstMissing = [long](($status.Missing.Number | Measure-Object -Minimum).Minimum)
            $queue[$show.Identity] = @($queue[$show.Identity] | Where-Object { ([long]$_.Season * 10000 + $_.Episode) -lt $firstMissing })
        }
        if ($status -and $status.Known -and @(Get-PlaylistProp $status 'Future' @()).Count) {
            $futureNumbers = @($status.Future.Number)
            $queue[$show.Identity] = @($queue[$show.Identity] | Where-Object { ([long]$_.Season * 10000 + $_.Episode) -notin $futureNumbers })
        }
    }
    if ($active.Count -lt $Count) {
        $reason = if ($missingActiveIds.Count) {
            "TV rotation paused: only $($active.Count) active shows are visible in Plex; a saved active show is missing. Refresh/recover it before changing the roster."
        } else {
            "TV rotation paused: only $($active.Count) active shows have downloaded unwatched episodes; $Count are required."
        }
        $safeCursors = @{}; foreach ($key in $Cursors.Keys) { $safeCursors[$key] = $Cursors[$key] }
        $savedActiveIds = if ($missingActiveIds.Count) { @($ActiveIds) } else { @($active.Identity) }
        return [pscustomobject]@{ Rounds=@(); ActiveIds=$savedActiveIds; Cursors=$safeCursors; Replacements=@()
            Stop=@($reason); CycleConsumed=@($CycleConsumed); NextCycleNumber=$StartRound }
    }
    if ($active.Count -gt $Count) { throw "Rotation needs $Count active shows; found $($active.Count). Configure standby replacements explicitly." }
    $rounds = @()
    $cursor = @{}; foreach ($k in $Cursors.Keys) { $cursor[$k] = $Cursors[$k] }
    $retired = @()
    $stop = @()
    [string[]]$consumed = @($CycleConsumed | Where-Object { $_ })
    $number = $StartRound
    while ($true) {
        $nextActive = @($active)
        $blocked = @{}
        foreach ($show in @($active)) {
            if ($show.Identity -in $consumed) { continue }
            if ($queue[$show.Identity].Count) { continue }
            $replacement = @($Replacements | Where-Object { $_.from -eq $show.Title })
            $status = $TvStatus[$show.Identity]
            $last = if ($cursor.ContainsKey($show.Identity)) { [long]$cursor[$show.Identity] } else { 0 }
            # An explicitly configured pairing is a manual override. Otherwise
            # require confirmed ending AND its final episode already queued.
            $manual = $replacement.Count -eq 1
            if ($manual -and $status -and $status.Known -and @($status.Missing).Count) {
                $blocked[$show.Identity] = "$($show.Title): released episodes missing; replacement deferred"
                continue
            }
            $finished = $status -and $status.Known -and $status.Ended -and $status.Final -gt 0 -and $last -ge $status.Final
            # Downloadability, not production/status labels, controls replacement:
            # any released-but-missing episode blocks it; otherwise an exhausted
            # show may be replaced when an inactive show has downloadable episodes.
            $noMissing = $status -and $status.Known -and @($status.Missing).Count -eq 0
            $done = $finished -or $noMissing
            if ($manual) {
                $candidate = @($Shows | Where-Object { $_.Title -eq $replacement[0].to })
                # A replacement is eligible only when the Plex library already
                # contains an unwatched local episode for it; downloadability or
                # metadata alone is not sufficient.
                if ($candidate.Count -eq 1 -and $candidate[0].Identity -notin $nextActive.Identity -and $queue[$candidate[0].Identity].Count) {
                    $nextActive = @($nextActive | Where-Object { $_.Identity -ne $show.Identity }) + $candidate[0]
                    $retired += [pscustomobject]@{ From = $show.Title; To = $candidate[0].Title; Round = $number; ManualOverride = $true }
                    continue
                }
            }
            elseif ($done) {
                # Stop at the blocker when no replacement is actually available.
                # If a newly downloaded standby is ready, substitute it into the
                # active roster; emission below sorts it into the rotation order.
                $downloadedStandby = @($Shows | Where-Object { $_.Identity -notin $nextActive.Identity -and $queue[$_.Identity].Count } | Sort-Object SortTitle, Identity)
                if ($downloadedStandby.Count) {
                    $candidate = $downloadedStandby[0]
                    $nextActive = @($nextActive | Where-Object { $_.Identity -ne $show.Identity }) + $candidate
                    $retired += [pscustomobject]@{ From = $show.Title; To = $candidate.Title; Round = $number; ManualOverride = $false }
                    continue
                }
                $blocked[$show.Identity] = "$($show.Title): no downloadable episodes remain; cycle stops here"
                continue
            }
            $reason = if ($status -and $status.Known -and $status.NextAirDate) { 'waiting until ' + $status.NextAirDate } else { 'no next local episode; update content or verify series status' }
            $blocked[$show.Identity] = "$($show.Title): $reason"
        }
        $active = @($nextActive)
        $items = @()
        foreach ($show in @($active | Sort-Object SortTitle, Identity)) {
            if ($show.Identity -in $consumed) { continue }
            $q = @($queue[$show.Identity])
            if (-not $q.Count) {
                $stop += if ($blocked.ContainsKey($show.Identity)) { $blocked[$show.Identity] } else { "$($show.Title): no next local episode" }
                break
            }
            $items += $q[0]
            $e = $q[0]
            $cursor[$show.Identity] = [long]$e.Season * 10000 + $e.Episode
            $queue[$show.Identity] = @($q | Select-Object -Skip 1)
            $consumed += $show.Identity
        }
        if ($items.Count) { $rounds += [pscustomobject]@{ Number = $number; Episodes = $items; Complete = ($consumed.Count -eq $Count) } }
        if ($stop.Count) { break }
        if ($consumed.Count -ne $Count) { throw 'Invalid rotation progress.' }
        $consumed = @(); $number++
    }
    return [pscustomobject]@{ Rounds = $rounds; ActiveIds = @($active.Identity); Cursors = $cursor; Replacements = $retired; Stop = @($stop | Select-Object -Unique)
        CycleConsumed = $consumed; NextCycleNumber = $number }
}

function Get-PlaylistMovieGroups {
    param([object[]]$Movies, [object[]]$ThematicGroups)
    $groups = @()
    $assigned = @{}
    foreach ($g in $ThematicGroups) {
        $members = @($Movies | Where-Object { $_.Title -match $g.titlePattern -or $_.Title -in $g.extraTitles } | Sort-Object ReleaseDate, Identity)
        if ($members.Count -gt 1) {
            $group = [pscustomobject]@{ Id = 'theme:' + $g.name; Name = $g.name; Kind = 'documentary'; Members = $members; Evidence = 'User-confirmed theme + Plex release dates' }
            $groups += $group
            foreach ($m in $members) { $assigned[$m.Identity] = $true }
        }
    }
    if ((Get-PlaylistTmdbCredential).Configured) {
        $collectionIds = @{}
        foreach ($movie in $Movies) {
            if ($assigned.ContainsKey($movie.Identity)) { continue }
            $id = Get-PlaylistProviderId $movie 'tmdb'
            if (-not $id) { continue }
            try {
                $detail = Get-PlaylistMetadata "movie/$id"
                if ($detail.belongs_to_collection) { $collectionIds[[string]$detail.belongs_to_collection.id] = $true }
            } catch { Add-PlaylistAlert 'movie-metadata' 'TMDb movie grouping is incomplete; unresolved items will not be guessed from shared actors or broad universes.' }
        }
        foreach ($id in $collectionIds.Keys) {
            try {
                $c = Get-PlaylistMetadata "collection/$id"
                $members = @()
                foreach ($part in @($c.parts | Sort-Object release_date, id)) {
                    $local = @($Movies | Where-Object { ('tmdb://' + $part.id) -in $_.Ids })
                    if ($local.Count -eq 1 -and -not $assigned.ContainsKey($local[0].Identity)) { $members += $local[0] }
                }
                if ($members.Count -gt 1) {
                    $groups += [pscustomobject]@{ Id = 'tmdb:' + $id; Name = $c.name; Kind = 'franchise'; Members = $members
                        Evidence = 'TMDb collection, release/installment order; custom narrative orders require an override' }
                    foreach ($m in $members) { $assigned[$m.Identity] = $true }
                }
            } catch { }
        }
    }
    # Conservative title fallback: same base with numeric/Roman installment
    # suffixes. A shared actor, genre or director is NOT a franchise.
    $bases = @{}
    $prefixes = @($Movies | Where-Object { -not $assigned.ContainsKey($_.Identity) -and $_.Title -match '^(.+?):\s+' } |
        ForEach-Object { ($_.Title -split ':', 2)[0] } | Select-Object -Unique)
    foreach ($prefix in $prefixes) {
        $members = @($Movies | Where-Object {
            -not $assigned.ContainsKey($_.Identity) -and $_.Title -match ('^' + [regex]::Escape($prefix) + '(?:\s*[:(]|$)')
        } | Sort-Object ReleaseDate, Identity)
        if ($members.Count -gt 1) {
            $groups += [pscustomobject]@{ Id = 'title-series:' + $prefix; Name = $prefix; Kind = 'franchise'; Members = $members
                Evidence = 'Shared series title prefix, release order (fallback; no broad actor/genre grouping)' }
            foreach ($m in $members) { $assigned[$m.Identity] = $true }
        }
    }
    foreach ($m in $Movies) {
        if ($assigned.ContainsKey($m.Identity)) { continue }
        $base = ($m.Title -replace '(?i)\s+(?:part\s+)?(?:\d+|[IVX]+)(?:\s*[:\-].*)?$', '').Trim()
        if (-not $bases.ContainsKey($base)) { $bases[$base] = @() }
        $bases[$base] += $m
    }
    foreach ($base in $bases.Keys) {
        $members = @($bases[$base] | Sort-Object ReleaseDate, Identity)
        if ($members.Count -gt 1) {
            $groups += [pscustomobject]@{ Id = 'title:' + $base; Name = $base; Kind = 'franchise'; Members = $members; Evidence = 'Numbered-title fallback, release order' }
        }
    }
    return $groups
}

function Get-PlaylistMovies {
    param([object[]]$Movies, [object[]]$Groups, [int]$Slots, [int]$Seed, [object[]]$Existing = @(), [object[]]$Preferred = @())
    $pool = @($Movies | Where-Object { -not $_.Watched } | Sort-Object Identity)
    $byId = @{}; foreach ($m in $pool) { $byId[$m.Identity] = $m }
    $groupByMovie = @{}
    foreach ($g in $Groups) { foreach ($m in $g.Members) {
        if ($groupByMovie.ContainsKey($m.Identity)) { throw 'A movie belongs to multiple scheduling groups; resolve the ambiguity.' }
        $groupByMovie[$m.Identity] = $g
    } }
    [object[]]$result = @($Existing | Where-Object { $null -ne $_ })
    $used = @{}; foreach ($m in $result) { $used[$m.Identity] = $true }
    $random = [Random]::new($Seed)
    $activeGroups = @()
    foreach ($g in $Groups) { if (@($result.Identity | Where-Object { $_ -in $g.Members.Identity }).Count) { $activeGroups += $g } }
    $stop = ''
    while ($true) {
        $pending = @($activeGroups | Where-Object { @($_.Members | Where-Object { -not $used.ContainsKey($_.Identity) -and $byId.ContainsKey($_.Identity) }).Count })
        if ($result.Count -ge $Slots -and -not $pending.Count) { break }
        $next = $null
        if ($pending.Count) {
            $g = $pending[0]
            $positions = @(for ($i = 0; $i -lt $result.Count; $i++) { if ($result[$i].Identity -in $g.Members.Identity) { $i } })
            $gap = if ($positions.Count) { $result.Count - 1 - $positions[-1] } else { $result.Count }
            if ($gap -ge 2) { $next = @($g.Members | Where-Object { -not $used.ContainsKey($_.Identity) -and $byId.ContainsKey($_.Identity) })[0] }
            else {
                # Fillers are unrelated singletons, so filling one group cannot
                # recursively enqueue every other franchise in the library.
                $filler = @($pool | Where-Object { -not $used.ContainsKey($_.Identity) -and -not $groupByMovie.ContainsKey($_.Identity) })
                if (-not $filler.Count) { $stop = 'Not enough unrelated movies to finish the selected group with two-movie spacing.'; break }
                $preferredFiller = @($Preferred | Where-Object { $_.Identity -in $filler.Identity } | Select-Object -First 1)
                $next = if ($preferredFiller.Count) { $byId[$preferredFiller[0].Identity] } else { $filler[$random.Next($filler.Count)] }
            }
        }
        else {
            $choices = @($pool | Where-Object { -not $used.ContainsKey($_.Identity) })
            if (-not $choices.Count) { $stop = 'Not enough unwatched movies for the ready TV rounds.'; break }
            $preferredChoice = @($Preferred | Where-Object { $_.Identity -in $choices.Identity } | Select-Object -First 1)
            $draw = if ($preferredChoice.Count) { $byId[$preferredChoice[0].Identity] } else { $choices[$random.Next($choices.Count)] }
            if ($groupByMovie.ContainsKey($draw.Identity)) {
                $g = $groupByMovie[$draw.Identity]
                $activeGroups += $g
                # Restart at the group's FIRST available entry, not the randomly
                # drawn sequel. Two random movies precede its first entry too.
                continue
            }
            $next = $draw
        }
        $result += $next; $used[$next.Identity] = $true
    }
    return [pscustomobject]@{ Movies = $result; Stop = $stop }
}

function Merge-PlaylistQueue {
    param([object[]]$Rounds, [object[]]$Movies, [int]$EpisodesPerMovie = 5, [int]$EpisodeOffset = 0)
    $queue = @(); $mi = 0; $episodeCount = $EpisodeOffset
    foreach ($round in $Rounds) {
        if (@($round.Episodes).Count -gt 25) { throw 'Rotation segment cannot contain more than 25 shows.' }
        for ($i = 0; $i -lt $round.Episodes.Count; $i++) {
            $queue += $round.Episodes[$i]
            $episodeCount++
            if ($episodeCount % $EpisodesPerMovie -eq 0) {
                if ($mi -ge $Movies.Count) { throw 'Not enough movies to complete the TV/movie cadence.' }
                $queue += $Movies[$mi]; $mi++
            }
        }
    }
    while ($mi -lt $Movies.Count) { $queue += $Movies[$mi]; $mi++ }
    return $queue
}

function Get-PlaylistSyncOperations {
    param([object[]]$Desired, [object[]]$Current)
    if (@($Desired.Identity | Select-Object -Unique).Count -ne $Desired.Count) { throw 'Desired playlist contains duplicates.' }
    $ops = @()
    foreach ($item in $Current) {
        if ($item.Identity -notin $Desired.Identity) { $ops += [pscustomobject]@{ Kind = 'remove'; Item = $item } }
    }
    foreach ($item in $Desired) {
        if ($item.Identity -notin $Current.Identity) { $ops += [pscustomobject]@{ Kind = 'add'; Item = $item } }
    }
    return $ops
}

function New-PlaylistContinuationState {
    param([object[]]$Queue, [object[]]$Shows, [object[]]$Replacements,
        [string]$Server, [string]$SourceId, [string]$TargetId)
    if (-not $Queue.Count) { throw 'A continuation needs an existing queue; refusing to invent a new starting point.' }
    if (@($Queue.Identity | Select-Object -Unique).Count -ne $Queue.Count) { throw 'Existing queue contains duplicates; explicit review required.' }
    $cursors = @{}
    foreach ($show in $Shows) {
        $queued = @($Queue | Where-Object { $_.Type -eq 'episode' -and $_.ShowKey -eq $show.Key })
        if ($queued.Count) { $cursors[$show.Identity] = [long](($queued | ForEach-Object { [long]$_.Season * 10000 + $_.Episode } | Measure-Object -Maximum).Maximum) }
    }
    $excluded = @()
    foreach ($pair in $Replacements) {
        $incoming = @($Shows | Where-Object Title -eq $pair.to)
        if ($incoming.Count -eq 1 -and $incoming[0].Key -in $Queue.ShowKey) { $excluded += $pair.from }
        else { $excluded += $pair.to }
    }
    return [pscustomobject]@{ Version = 2; At = (Get-Date).ToString('o'); Server = $Server
        SourceId = $SourceId; TargetId = $TargetId; Queue = @($Queue); BaseQueue = @($Queue)
        Rounds = @(); Movies = @($Queue | Where-Object Type -eq 'movie'); Groups = @()
        Cursors = $cursors; ActiveIds = @($Shows | Where-Object { $_.Title -notin $excluded } | ForEach-Object { $_.Identity })
        CycleConsumed = @(); NextCycleNumber = 1
        DeletionEnabled = $false; Applied = $false }
}

function Get-PlaylistWatchedQueueHead {
    param([object[]]$Queue)
    if (-not $Queue.Count) { return $null }
    $head = $Queue[0]
    if ($head.Type -ne 'episode' -or -not $head.Watched) { return $null }
    return $head
}

function Replace-PlaylistMissingMovieSlots {
    param([object[]]$Queue, [object[]]$MovieOrder, [string[]]$MissingIdentities, [object[]]$Replacements)
    if ($MissingIdentities.Count -ne $Replacements.Count) { throw 'Each removed filler movie needs exactly one replacement.' }
    $updatedQueue = @($Queue)
    $updatedMovies = @($MovieOrder)
    $used = @($updatedQueue.Identity | Where-Object { $_ -notin $MissingIdentities })
    for ($n = 0; $n -lt $MissingIdentities.Count; $n++) {
        $identity = $MissingIdentities[$n]
        $oldQueue = @(for ($i = 0; $i -lt $updatedQueue.Count; $i++) { if ($updatedQueue[$i].Identity -eq $identity -and $updatedQueue[$i].Type -eq 'movie') { $i } })
        $oldMovie = @(for ($i = 0; $i -lt $updatedMovies.Count; $i++) { if ($updatedMovies[$i].Identity -eq $identity) { $i } })
        if ($oldQueue.Count -ne 1 -or $oldMovie.Count -ne 1) { throw "Expected one queue and movie-order slot for $identity." }
        $replacement = $Replacements[$n]
        if ($replacement.Type -ne 'movie' -or $replacement.Watched -or $replacement.Identity -in $used) { throw 'Replacement must be a unique, unwatched movie.' }
        $updatedQueue[$oldQueue[0]] = $replacement
        $updatedMovies[$oldMovie[0]] = $replacement
        $used += $replacement.Identity
    }
    if (@($updatedQueue.Identity | Select-Object -Unique).Count -ne $updatedQueue.Count) { throw 'Movie slot replacement created duplicate queue identities.' }
    return [pscustomobject]@{ Queue = $updatedQueue; Movies = $updatedMovies }
}

function Get-PlaylistRetirementCandidate {
    param([object[]]$Current, $State, [string]$Show, [int]$Season, [int]$Episode, [bool]$Confirmed)
    if (-not $Confirmed) { throw 'User confirmation of playlist viewing is required.' }
    if (($Current.Identity -join '|') -cne ($State.Queue.Identity -join '|')) { throw 'Queue changed; no retirement allowed.' }
    $matches = @($Current | Where-Object { $_.Type -eq 'episode' -and $_.Show -ceq $Show -and $_.Season -eq $Season -and $_.Episode -eq $Episode })
    if ($matches.Count -ne 1) { throw 'Expected exactly one matching episode.' }
    $item = $matches[0]
    if ($Current[0].Identity -ne $item.Identity -or $item.Identity -notin $State.BaseQueue.Identity) { throw 'Only the imported queue head can be retired.' }
    if (-not $item.Watched) { throw 'Episode is not watched in Plex.' }
    if (@($item.Paths).Count -ne 1) { throw 'Multiple/unknown media parts require review.' }
    return $item
}

function Merge-PlaylistContinuation {
    param([object[]]$BaseQueue, [object[]]$Rounds, [object[]]$Movies)
    # Preserve existing relative order, but continue the TV sequence BEFORE the
    # movie-only reserve. A full five-episode block consumes its following movie;
    # a partial block resumes before that movie, carrying its episode count.
    $baseMovies = @($BaseQueue | Where-Object Type -eq 'movie')
    if ($Movies.Count -lt $baseMovies.Count -or
        ((@($Movies | Select-Object -First $baseMovies.Count).Identity -join '|') -cne ($baseMovies.Identity -join '|'))) {
        throw 'Continuation must preserve the existing movie order.'
    }
    $newMovies = @($Movies | Select-Object -Skip $baseMovies.Count)
    $context = Get-PlaylistContinuationContext $BaseQueue
    $availableMovies = @($context.Tail) + $newMovies
    $extension = @(Merge-PlaylistQueue -Rounds $Rounds -Movies $availableMovies -EpisodeOffset $context.Offset)
    $result = @($context.Prefix) + $extension
    if (@($result.Identity | Select-Object -Unique).Count -ne $result.Count) { throw 'Continuation would re-add an already queued item.' }
    return $result
}

function Get-PlaylistContinuationContext {
    param([object[]]$Queue)
    $lastTv = -1
    for ($i=0; $i -lt $Queue.Count; $i++) { if ($Queue[$i].Type -eq 'episode') { $lastTv=$i } }
    if ($lastTv -lt 0) { return [pscustomobject]@{ Prefix=@($Queue); Tail=@(); Offset=0 } }
    $run = 0
    for ($i=$lastTv; $i -ge 0 -and $Queue[$i].Type -eq 'episode'; $i--) { $run++ }
    $end = $lastTv
    $offset = $run % 5
    if ($offset -eq 0 -and $lastTv+1 -lt $Queue.Count -and $Queue[$lastTv+1].Type -eq 'movie') { $end++ }
    return [pscustomobject]@{ Prefix=@($Queue | Select-Object -First ($end+1)); Tail=@($Queue | Select-Object -Skip ($end+1)); Offset=$offset }
}

function Repair-PlaylistQueueBeforeBlockedShow {
    param([object[]]$Queue, [object[]]$Shows, [string[]]$ActiveIds, [string]$StopShow,
        [string]$RequiredActiveShow = 'Penn & Teller: Fool Us', [int]$CycleSize = 25, [int]$EpisodesPerMovie = 5)
    $blocker = @($Shows | Where-Object Title -CEQ $StopShow)
    if ($blocker.Count -ne 1) { throw "Expected exactly one rotation show named '$StopShow'." }
    $active = @($Shows | Where-Object Identity -in $ActiveIds | Sort-Object SortTitle, Identity)
    if ($active.Count -ne $CycleSize) { throw "Expected $CycleSize active shows; found $($active.Count)." }
    if (@($active | Where-Object Title -CEQ $RequiredActiveShow).Count -ne 1) {
        throw "Required show '$RequiredActiveShow' is not active; refusing to remove it from the queue."
    }
    $blockIndex = -1
    for ($i = 0; $i -lt $Queue.Count; $i++) {
        if ($Queue[$i].Type -eq 'episode' -and $Queue[$i].ShowKey -eq $blocker[0].Key) { $blockIndex = $i }
    }
    if ($blockIndex -lt 0) { throw "No queued episode found for blocked show '$StopShow'." }
    $blockTvOrdinal = @($Queue | Select-Object -First ($blockIndex + 1) | Where-Object Type -eq 'episode').Count
    $cycleNumber = [int][math]::Floor(($blockTvOrdinal - 1) / $CycleSize) + 1
    $cycleFirstOrdinal = (($cycleNumber - 1) * $CycleSize) + 1
    $tvOrdinal = 0; $cycleStartIndex = -1
    for ($i = 0; $i -le $blockIndex; $i++) {
        if ($Queue[$i].Type -eq 'episode') {
            $tvOrdinal++
            if ($tvOrdinal -eq $cycleFirstOrdinal) { $cycleStartIndex = $i; break }
        }
    }
    if ($cycleStartIndex -lt 0) { throw 'Could not locate the blocked show rotation-cycle start.' }
    $blockerPosition = -1
    for ($i = 0; $i -lt $active.Count; $i++) { if ($active[$i].Identity -eq $blocker[0].Identity) { $blockerPosition = $i; break } }
    if ($blockerPosition -lt 0) { throw "Blocked show '$StopShow' is not active." }

    $prefix = @($Queue | Select-Object -First $cycleStartIndex)
    $cycleItems = @($Queue | Select-Object -Skip $cycleStartIndex -First ($blockIndex - $cycleStartIndex + 1))
    $cycleEpisodes = @($cycleItems | Where-Object Type -eq 'episode')
    $cycleMovies = @($cycleItems | Where-Object Type -eq 'movie')
    $rebuiltCycle = @(); $consumed = @(); $movieIndex = 0
    $tvCount = @($prefix | Where-Object Type -eq 'episode').Count
    for ($i = 0; $i -lt $blockerPosition; $i++) {
        $show = $active[$i]
        $available = @($cycleEpisodes | Where-Object ShowKey -eq $show.Key | Sort-Object Season, Episode)
        if (-not $available.Count) { break }
        $episode = $available[0]
        $rebuiltCycle += $episode
        $tvCount++
        $consumed += $show.Identity
        if (($tvCount % $EpisodesPerMovie) -eq 0) {
            if ($movieIndex -ge $cycleMovies.Count) { throw 'The existing movie cadence is incomplete before the blocked show.' }
            $rebuiltCycle += $cycleMovies[$movieIndex]
            $movieIndex++
        }
    }
    if (-not $consumed.Count) { throw 'No preceding shows could be retained before the blocker.' }
    $rebuilt = @($prefix) + @($rebuiltCycle)

    # Keep Penn & Teller in the rotation and repair episode order at its existing
    # positions; never infer that missing released episodes make it replaceable.
    $pennSlots = @(); $pennItems = @()
    for ($i = 0; $i -lt $rebuilt.Count; $i++) {
        if ($rebuilt[$i].Type -eq 'episode' -and $rebuilt[$i].Show -ceq $RequiredActiveShow) {
            $pennSlots += $i; $pennItems += $rebuilt[$i]
        }
    }
    $pennItems = @($pennItems | Sort-Object Season, Episode)
    for ($i = 0; $i -lt $pennSlots.Count; $i++) { $rebuilt[$pennSlots[$i]] = $pennItems[$i] }

    $cursors = @{}
    foreach ($show in $Shows) {
        $last = @($rebuilt | Where-Object { $_.Type -eq 'episode' -and $_.ShowKey -eq $show.Key } | Sort-Object Season, Episode | Select-Object -Last 1)
        if ($last.Count) { $cursors[$show.Identity] = [long]$last[0].Season * 10000 + [long]$last[0].Episode }
    }
    return [pscustomobject]@{ Queue = $rebuilt; CycleConsumed = @($consumed); Cursors = $cursors; NextCycleNumber = $cycleNumber }
}

function Get-PlaylistEpisodeOffset {
    param([object[]]$Queue)
    $count = 0
    for ($i = $Queue.Count - 1; $i -ge 0 -and $Queue[$i].Type -eq 'episode'; $i--) { $count++ }
    return ($count % 5)
}

function Set-PlaylistIntendedItems {
    param([object[]]$Desired, [object[]]$Current)
    if (-not $script:PlaylistApply) { throw 'Playlist writes require -Apply.' }
    if (-not $Desired.Count) { throw 'Refusing an empty managed playlist.' }
    if ($script:ManagedPlaylistId -eq $script:SourcePlaylistId) { throw 'Refusing to edit the original playlist.' }
    $ops = @(Get-PlaylistSyncOperations $Desired $Current)
    foreach ($op in $ops) {
        if ($op.Kind -eq 'remove') { [void](Invoke-PlaylistPlex ("/playlists/{0}/items/{1}" -f $script:ManagedPlaylistId, $op.Item.PlaylistItemId) 'Delete') }
        elseif ($op.Kind -eq 'add') {
            $server = (Invoke-PlaylistPlex '/identity').GetAttribute('machineIdentifier')
            $uri = "server://$server/com.plexapp.plugins.library/library/metadata/$($op.Item.Key)"
            [void](Invoke-PlaylistPlex ("/playlists/{0}/items?uri={1}" -f $script:ManagedPlaylistId, [uri]::EscapeDataString($uri)) 'Put')
        }
    }
    $actual = @(Read-ManagedItems $script:ManagedPlaylistId)
    if (@($actual.Identity | Select-Object -Unique).Count -ne $actual.Count) { throw 'Duplicate entries after update; durable intent retained.' }
    for ($i = 0; $i -lt $Desired.Count; $i++) {
        $index = -1
        for ($j = $i; $j -lt $actual.Count; $j++) { if ($actual[$j].Identity -eq $Desired[$i].Identity) { $index = $j; break } }
        if ($index -lt 0) { throw 'An intended item is absent after adding; verification failed.' }
        if ($index -eq $i) { continue }
        $path = "/playlists/$($script:ManagedPlaylistId)/items/$($actual[$index].PlaylistItemId)/move"
        if ($i -gt 0) { $path += '?after=' + $actual[$i - 1].PlaylistItemId }
        [void](Invoke-PlaylistPlex $path 'Put')
        # Do not simulate the server's move in memory. Plex can normalize its
        # underlying positions differently after several edits; use its actual
        # returned order to choose every subsequent playlistItemID/after target.
        $actual = @(Read-ManagedItems $script:ManagedPlaylistId)
        if ($actual[$i].Identity -cne $Desired[$i].Identity) {
            # Some existing Plex lists contain conflicting internal positions:
            # /move returns 200 but does not actually move an adjacent item.
            # Rebuild ONLY playlist references, in one ordered URI, keeping the
            # same playlist ID. Durable intent and snapshots precede this call.
            $server = (Invoke-PlaylistPlex '/identity').GetAttribute('machineIdentifier')
            $uri = "server://$server/com.plexapp.plugins.library/library/metadata/" + ($Desired.Key -join ',')
            [void](Invoke-PlaylistPlex "/playlists/$($script:ManagedPlaylistId)/items" 'Delete')
            [void](Invoke-PlaylistPlex ("/playlists/{0}/items?uri={1}" -f $script:ManagedPlaylistId, [uri]::EscapeDataString($uri)) 'Put')
            break
        }
    }
    $verified = @(Read-ManagedItems $script:ManagedPlaylistId)
    if (($verified.Identity -join '|') -cne ($Desired.Identity -join '|')) { throw 'Verification failed: playlist does not match every intended item in order.' }
    return $true
}

function Add-PlaylistAlert {
    param([string]$Id, [string]$Message)
    $script:PlaylistAlerts[$Id] = $Message
}

