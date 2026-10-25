# Read-only Plex playlist discovery and round preview. This script only sends
# GET requests. It never edits playlists, watch state, or files in a library.
[CmdletBinding()]
param(
    [string]$ServerUrl = 'http://127.0.0.1:32400',
    [string]$SourcePlaylist = 'Patrick',
    [string[]]$ShowRatingKeys = @(),
    [string]$OutputDirectory,
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'logs\playlist-preview' }

function Read-PreviewPlex {
    param([string]$Path)
    # XML avoids PowerShell 5.1's JSON collision between guid and Guid. Decode
    # bytes explicitly so accented titles survive servers without a charset.
    $r = Invoke-WebRequest -Uri ($ServerUrl.TrimEnd('/') + $Path) -Headers $script:PlexHeaders -UseBasicParsing -TimeoutSec 45
    return ([xml][System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())).DocumentElement
}

function Read-PreviewPlexItems {
    param([string]$Path, [string]$Tag = 'Video')
    $start = 0
    do {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $page = Read-PreviewPlex ($Path + $separator + "X-Plex-Container-Start=$start&X-Plex-Container-Size=200")
        $nodes = @($page.SelectNodes($Tag))
        foreach ($node in $nodes) { Write-Output $node }
        $start += $nodes.Count
        $total = if ($page.HasAttribute('totalSize')) { [int]$page.GetAttribute('totalSize') } else { [int]$page.GetAttribute('size') }
        if ($nodes.Count -eq 0 -and $start -lt $total) { throw 'Plex returned an incomplete page; refusing an incomplete preview.' }
    } while ($start -lt $total)
}

function Get-PreviewRounds {
    param([object[]]$Shows, [object[]]$Episodes)
    $roster = @($Shows | Sort-Object SortTitle, Key)
    if ($roster.Count -ne 25) {
        return [pscustomobject]@{ Rounds = @(); MovieSlots = 0; StopReason = "Select exactly 25 distinct shows; $($roster.Count) are selected."; Missing = @() }
    }
    if (@($roster.Key | Select-Object -Unique).Count -ne 25) { throw 'The rotation contains duplicate shows.' }
    $queues = @{}
    foreach ($show in $roster) {
        $queues[$show.Key] = @($Episodes | Where-Object { $_.ShowKey -eq $show.Key -and -not $_.Watched -and $_.Season -gt 0 } |
            Sort-Object Season, Episode, Key | Group-Object Season, Episode | ForEach-Object { $_.Group[0] })
    }
    $rounds = @()
    $offset = 0
    while ($true) {
        $missing = @()
        $items = @()
        foreach ($show in $roster) {
            if ($queues[$show.Key].Count -le $offset) { $missing = @($show.Title); break }
            $items += $queues[$show.Key][$offset]
        }
        if ($items.Count) { $rounds += [pscustomobject]@{ Number = $offset + 1; Episodes = $items; MovieSlots = [int][math]::Floor($items.Count / 5); Complete = ($items.Count -eq 25) } }
        if ($missing.Count) { break }
        $offset++
    }
    $episodeCount = @($rounds | ForEach-Object { $_.Episodes } | ForEach-Object { $_ }).Count
    return [pscustomobject]@{ Rounds = $rounds; MovieSlots = [int][math]::Floor($episodeCount / 5)
        StopReason = 'Stopped at the first missing show episode: ' + ($missing -join ', '); Missing = $missing }
}

function Get-PreviewWikidataGroups {
    param([object[]]$Movies)
    $ids = @($Movies.Imdb | Where-Object { $_ -match '^tt\d+$' } | Select-Object -Unique)
    if (-not $ids.Count) { return @() }
    # P179 also covers lists, universes and other non-franchises. These results
    # are evidence for review, never automatically accepted franchise rules.
    $values = ($ids | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $query = 'SELECT ?imdb ?series ?seriesLabel WHERE { VALUES ?imdb { ' + $values +
        ' } ?item wdt:P345 ?imdb; wdt:P179 ?series. SERVICE wikibase:label { bd:serviceParam wikibase:language "en". } }'
    $url = 'https://query.wikidata.org/sparql?format=json&query=' + [uri]::EscapeDataString($query)
    $r = Invoke-WebRequest -Uri $url -Headers @{ Accept = 'application/sparql-results+json'; 'User-Agent' = 'plex-balancer-playlist-preview/0.1' } -UseBasicParsing -TimeoutSec 45
    $data = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    foreach ($group in @($data.results.bindings | Group-Object { $_.series.value })) {
        $members = @($Movies | Where-Object { $_.Imdb -in @($group.Group | ForEach-Object { $_.imdb.value }) })
        [pscustomobject]@{ Name = $group.Group[0].seriesLabel.value; Source = 'Wikidata P179 (unverified)'
            SourceId = $group.Name; Members = @($members | Sort-Object ReleaseDate, Title)
            Status = 'Review required: may be a franchise, universe, documentary series, or unrelated list.' }
    }
}

$token = $env:PLEX_TOKEN
if (-not $token) {
    $preferences = Get-ItemProperty 'HKCU:\Software\Plex, Inc.\Plex Media Server' -ErrorAction SilentlyContinue
    if ($preferences) { $token = $preferences.PlexOnlineToken }
}
if (-not $token) { throw 'Set PLEX_TOKEN or run as the local Plex server owner. No token is saved in the preview.' }
$script:PlexHeaders = @{ 'X-Plex-Token' = $token; Accept = 'application/xml' }

$playlists = @(Read-PreviewPlexItems '/playlists' 'Playlist')
$source = @($playlists | Where-Object { $_.GetAttribute('title') -ceq $SourcePlaylist })
if ($source.Count -ne 1) { throw "Expected one playlist named '$SourcePlaylist'; found $($source.Count)." }
$sourceItems = @(Read-PreviewPlexItems ("/playlists/{0}/items" -f $source[0].GetAttribute('ratingKey')))
$sections = (Read-PreviewPlex '/library/sections').SelectNodes('Directory')
$shows = @()
$episodes = @()
$movies = @()
foreach ($section in $sections) {
    $key = $section.GetAttribute('key')
    if ($section.GetAttribute('type') -eq 'show') {
        foreach ($show in @(Read-PreviewPlexItems "/library/sections/$key/all?type=2" 'Directory')) {
            $sort = $show.GetAttribute('titleSort')
            if (-not $sort) { $sort = $show.GetAttribute('title') }
            $shows += [pscustomobject]@{ Key = $show.GetAttribute('ratingKey'); Title = $show.GetAttribute('title'); SortTitle = $sort }
        }
        foreach ($episode in @(Read-PreviewPlexItems "/library/sections/$key/all?type=4")) {
            $episodes += [pscustomobject]@{ Key = $episode.GetAttribute('ratingKey'); ShowKey = $episode.GetAttribute('grandparentRatingKey')
                Show = $episode.GetAttribute('grandparentTitle'); Title = $episode.GetAttribute('title')
                Season = [int]$episode.GetAttribute('parentIndex'); Episode = [int]$episode.GetAttribute('index')
                Watched = ([int]$episode.GetAttribute('viewCount') -gt 0) }
        }
    }
    elseif ($section.GetAttribute('type') -eq 'movie') {
        foreach ($movie in @(Read-PreviewPlexItems "/library/sections/$key/all?type=1&includeGuids=1")) {
            $imdb = @($movie.SelectNodes('Guid') | ForEach-Object { $_.GetAttribute('id') } | Where-Object { $_ -match '^imdb://tt\d+$' })
            $movies += [pscustomobject]@{ Key = $movie.GetAttribute('ratingKey'); Title = $movie.GetAttribute('title')
                ReleaseDate = $movie.GetAttribute('originallyAvailableAt'); Watched = ([int]$movie.GetAttribute('viewCount') -gt 0)
                Imdb = if ($imdb.Count) { $imdb[0].Substring(7) } else { '' }
                Collections = @($movie.SelectNodes('Collection') | ForEach-Object { $_.GetAttribute('tag') }) }
        }
    }
}

$eligible = @($shows | Where-Object { $_.Key -in @($episodes | Where-Object { -not $_.Watched -and $_.Season -gt 0 } | ForEach-Object { $_.ShowKey }) } | Sort-Object SortTitle, Key)
$selected = $eligible
if ($ShowRatingKeys.Count) {
    if (@($ShowRatingKeys | Select-Object -Unique).Count -ne $ShowRatingKeys.Count) { throw 'ShowRatingKeys contains duplicates.' }
    $unknown = @($ShowRatingKeys | Where-Object { $_ -notin $shows.Key })
    if ($unknown.Count) { throw ('Unknown show IDs: ' + ($unknown -join ', ')) }
    # Keep selected but exhausted shows: they must block the next round, not be
    # silently replaced by another available series.
    $selected = @($shows | Where-Object { $_.Key -in $ShowRatingKeys })
}
$plan = Get-PreviewRounds -Shows $selected -Episodes $episodes
$groups = @()
foreach ($collection in @($movies.Collections | ForEach-Object { $_ } | Select-Object -Unique)) {
    if (-not $collection) { continue }
    $groups += [pscustomobject]@{ Name = $collection; Source = 'Plex collection'; SourceId = ''
        Members = @($movies | Where-Object { $collection -in $_.Collections } | Sort-Object ReleaseDate, Title)
        Status = 'Review required: collection tags do not guarantee installment order.' }
}
$onlineStatus = 'Skipped (-Offline)'
if (-not $Offline) {
    try { $groups += @(Get-PreviewWikidataGroups -Movies $movies); $onlineStatus = 'Wikidata lookup completed; results are candidates, not confirmed franchises.' }
    catch { $onlineStatus = 'Wikidata unavailable; no online relationships assumed.' }
}
$theroux = @($movies | Where-Object { $_.Title -match '^Louis Theroux' } | Sort-Object ReleaseDate, Title)
if ($theroux.Count) {
    $groups += [pscustomobject]@{ Name = 'Louis Theroux documentaries'; Source = 'Title fallback'; SourceId = ''
        Members = $theroux; Status = 'Release-date order. Title-only detection misses films without his name, such as My Scientology Movie.' }
}
$report = [pscustomobject]@{ GeneratedAt = (Get-Date).ToString('o'); ReadOnly = $true
    OriginalPlaylist = $SourcePlaylist; OriginalItemCount = $sourceItems.Count
    EligibleShows = $eligible; SelectedShows = $selected; RoundPreview = $plan
    MovieCount = $movies.Count; UnwatchedMovies = @($movies | Where-Object { -not $_.Watched }).Count
    OnlineStatus = $onlineStatus; RelatedGroupCandidates = $groups
    MovieOrderingStatus = 'Not generated until the 25-show roster and related-group membership/order are resolved. No movie backlog added.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$jsonPath = Join-Path $OutputDirectory 'preview.json'
[System.IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
$lines = @('# Plex playlist preview', '', 'Read-only: no playlist or media changes.', '',
    "Original: $SourcePlaylist ($($sourceItems.Count) items)", "Eligible shows: $($eligible.Count)",
    "Complete rounds: $(@($plan.Rounds).Count); movie slots: $($plan.MovieSlots)", $plan.StopReason, '',
    '## Eligible shows', '', '| ID | Show | Available episodes |', '|---|---|---:|')
foreach ($show in $eligible) {
    $count = @($episodes | Where-Object { $_.ShowKey -eq $show.Key -and -not $_.Watched -and $_.Season -gt 0 }).Count
    $lines += "| $($show.Key) | $($show.Title.Replace('|','/')) | $count |"
}
$lines += @('', '## Related movie candidates', '', $onlineStatus, '')
foreach ($group in $groups) {
    $lines += @("### $($group.Name)", $group.Source, $group.Status, '')
    foreach ($member in $group.Members) { $lines += "- $($member.ReleaseDate): $($member.Title)" }
    $lines += ''
}
$lines += @('## Movie queue', '', $report.MovieOrderingStatus)
foreach ($round in $plan.Rounds) {
    $lines += @('', "## Round $($round.Number)")
    for ($i = 0; $i -lt $round.Episodes.Count; $i++) {
        $e = $round.Episodes[$i]
        $lines += ('- {0} S{1:00}E{2:00}: {3}' -f $e.Show, $e.Season, $e.Episode, $e.Title)
        if (($i + 1) % 5 -eq 0) { $lines += '- [Movie slot - not yet selected]' }
    }
}
$mdPath = Join-Path $OutputDirectory 'preview.md'
[System.IO.File]::WriteAllText($mdPath, ($lines -join "`r`n"), [System.Text.UTF8Encoding]::new($false))
"Read-only preview: $mdPath"
"Eligible shows: $($eligible.Count); complete rounds: $(@($plan.Rounds).Count); movie slots: $($plan.MovieSlots)"
$plan.StopReason
$onlineStatus
