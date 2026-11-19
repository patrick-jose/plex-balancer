# One-time repair of two backfill side effects in the managed playlist:
#  1. Reacher S1E1 was left in cycle 7 while S1E2..S1E7 filled cycles 1..6.
#     Reassign S1E1..S1E7 across its seven existing slots, in queue order.
#  2. The short block between 'Nocturnal Animals' and '40 Acres' gets the
#     already-downloaded Euphoria S3E8 at its alphabetical position.
# Preview by default; -Apply edits only the named managed copy.
[CmdletBinding()]
param([switch]$Apply, [string]$DataDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'playlist-lib.ps1')
$script:PlaylistData = if ($DataDirectory) { [IO.Path]::GetFullPath($DataDirectory) } else { Join-Path $PSScriptRoot 'playlist-data' }
$config = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'playlist.config.json')) | ConvertFrom-Json
$script:PlaylistBase = ([string]$config.serverUrl).TrimEnd('/')
$token = $env:PLEX_TOKEN
if (-not $token) { $token = (Get-ItemProperty 'HKCU:\Software\Plex, Inc.\Plex Media Server' -ErrorAction SilentlyContinue).PlexOnlineToken }
if (-not $token) { throw 'No Plex token available.' }
$script:PlaylistHeaders = @{ 'X-Plex-Token' = $token; Accept = 'application/xml' }
$script:PlaylistApply = [bool]$Apply
$mutex = [Threading.Mutex]::new($false, 'Global\PlexBalancer')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another balancer/playlist operation is running; retry after it finishes.' }

    $statePath = Join-Path $script:PlaylistData 'state.json'
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    if ($state.Version -ne 2) { throw 'Unsupported saved state version.' }
    $script:SourcePlaylistId = [string]$state.SourceId
    $script:ManagedPlaylistId = [string]$state.TargetId
    if ($script:SourcePlaylistId -eq $script:ManagedPlaylistId) { throw 'Refusing to edit the original playlist.' }

    function Read-ManagedItems {
        param([string]$Id)
        @(Get-PlaylistPlexItems "/playlists/$Id/items?includeGuids=1" | ForEach-Object { Convert-PlaylistMedia $_ })
    }
    function Read-TvLibrary {
        @((Invoke-PlaylistPlex '/library/sections').SelectNodes('Directory') |
            Where-Object { $_.GetAttribute('type') -eq 'show' } |
            ForEach-Object {
                $id = $_.GetAttribute('key')
                @(Get-PlaylistPlexItems "/library/sections/$id/all?type=4&includeGuids=1" 'Video' |
                    ForEach-Object { Convert-PlaylistMedia $_ $id })
            })
    }
    $current = @(Read-ManagedItems $script:ManagedPlaylistId)
    $source = @(Read-ManagedItems $script:SourcePlaylistId)
    if (($current.Identity -join '|') -cne ($state.Queue.Identity -join '|')) {
        throw 'Managed live playlist differs from saved intent; preserve user edits and review before correction.'
    }

    $libraryByKey = @{}
    foreach ($item in @(Read-TvLibrary)) { $libraryByKey[[string]$item.Key] = $item }

    # 1. Reacher: seven slots, seven episodes, sequential by queue position.
    $reacherPositions = @()
    for ($i = 0; $i -lt $current.Count; $i++) {
        if ($current[$i].Show -ceq 'Reacher') { $reacherPositions += $i }
    }
    if ($reacherPositions.Count -ne 7) { throw "Expected 7 Reacher slots; found $($reacherPositions.Count)." }
    $reacherKeys = @('4499', '4500', '4501', '4502', '4503', '4504', '4505')
    foreach ($key in $reacherKeys) {
        if (-not $libraryByKey.ContainsKey($key)) { throw "Reacher episode key $key is not in the library." }
        if (@($current | Where-Object { [string]$_.Key -eq $key }).Count -ne 1) { throw "Reacher episode key $key is not queued exactly once." }
    }

    # 2. Short block between the two named movies.
    $startMovie = @($current | Where-Object { $_.Type -eq 'movie' -and $_.Title -ceq 'Nocturnal Animals' })
    $endMovie = @($current | Where-Object { $_.Type -eq 'movie' -and $_.Title -ceq '40 Acres' })
    if ($startMovie.Count -ne 1 -or $endMovie.Count -ne 1) { throw 'Expected one Nocturnal Animals and one 40 Acres movie anchor.' }
    $startIndex = [array]::IndexOf($current, $startMovie[0])
    $endIndex = [array]::IndexOf($current, $endMovie[0])
    if ($endIndex -le $startIndex) { throw 'Movie anchors are out of order.' }
    $block = @($current | Select-Object -Skip ($startIndex + 1) -First ($endIndex - $startIndex - 1))
    if (@($block | Where-Object Type -eq 'movie').Count) { throw 'A movie sits inside the short block.' }
    if ($block.Count -ne 4) { throw "Expected 4 episodes in the short block; found $($block.Count)." }
    $expectedShows = @('Doctor Who', "It's Always Sunny in Philadelphia", 'Modern Family', 'Parks and Recreation')
    if ((@($block | ForEach-Object Show | Sort-Object) -join '|') -cne (@($expectedShows | Sort-Object) -join '|')) {
        throw 'Short block shows are not the expected four; refusing a broad edit.'
    }
    $fillKey = '4413'  # Euphoria S3E8, downloaded and unwatched
    if (-not $libraryByKey.ContainsKey($fillKey)) { throw 'Euphoria S3E8 key 4413 is not in the library.' }
    if (@($current | Where-Object { [string]$_.Key -eq $fillKey }).Count) { throw 'Euphoria S3E8 is already queued.' }
    $fill = $libraryByKey[$fillKey]
    if ($fill.Show -cne 'Euphoria' -or [int]$fill.Season -ne 3 -or [int]$fill.Episode -ne 8) { throw 'Euphoria S3E8 metadata is unexpected.' }
    if ($current[$startIndex + 1].Show -cne 'Doctor Who') { throw 'Expected Doctor Who at the short-block head.' }

    # Rebuild with the corrected Reacher sequence and the inserted episode.
    $desired = @()
    for ($i = 0; $i -lt $current.Count; $i++) {
        $reacherSlot = [array]::IndexOf($reacherPositions, $i)
        if ($reacherSlot -ge 0) { $desired += $libraryByKey[$reacherKeys[$reacherSlot]]; continue }
        if ($i -eq ($startIndex + 1)) { $desired += $current[$i]; $desired += $fill; continue }
        $desired += $current[$i]
    }
    if ($desired.Count -ne ($current.Count + 1)) { throw 'Correction produced an unexpected queue length.' }
    if (@($desired.Identity | Select-Object -Unique).Count -ne $desired.Count) { throw 'Correction would duplicate an item.' }
    $beforeOther = @($current | Where-Object { [string]$_.Key -notin $reacherKeys } | ForEach-Object Key)
    $afterOther = @($desired | Where-Object { [string]$_.Key -notin $reacherKeys -and $_.Key -ne $fillKey } | ForEach-Object Key)
    if (($beforeOther -join ',') -cne ($afterOther -join ',')) { throw 'Correction changed unrelated queue entries.' }

    Write-Host ("Correction apply=$Apply; before={0}; after={1}" -f $current.Count, $desired.Count)
    Write-Host 'Reacher slots after correction:'
    for ($k = 0; $k -lt $reacherPositions.Count; $k++) {
        $item = @($desired | Where-Object { [string]$_.Key -eq $reacherKeys[$k] })[0]
        Write-Host ("  slot #{0} -> S{1}E{2} key={3}" -f ($reacherPositions[$k] + 1), $item.Season, $item.Episode, $item.Key)
    }
    Write-Host 'Short block after correction:'
    for ($i = 0; $i -lt 5; $i++) {
        $item = $desired[$startIndex + 1 + $i]
        Write-Host ("  #{0} {1} S{2}E{3}" -f ($startIndex + 2 + $i), $item.Show, $item.Season, $item.Episode)
    }
    Write-Host 'Original source playlist and media files are never changed.'

    if ($Apply) {
        $archive = Join-Path $script:PlaylistData ('before-cadence-sequence-fix-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        Write-PlaylistJson $archive ([pscustomobject]@{ PreviousState = $state; BeforeCorrection = $current; AfterCorrection = $desired })
        $state.Queue = $desired
        $state.BaseQueue = $desired
        $state.Movies = @($desired | Where-Object Type -eq 'movie')
        $state.Applied = $false
        $state.At = (Get-Date).ToString('o')
        Write-PlaylistJson $statePath $state
        [void](Set-PlaylistIntendedItems -Desired $desired -Current $current)
        $sourceNow = @(Read-ManagedItems $script:SourcePlaylistId)
        if (($sourceNow.Identity -join '|') -cne ($source.Identity -join '|')) {
            throw 'Original playlist changed concurrently; inspect before claiming correction.'
        }
        $state.Applied = $true
        $state.At = (Get-Date).ToString('o')
        Write-PlaylistJson $statePath $state
        Write-Host 'Correction applied and verified; durable intent updated.'
    }
}
finally {
    if ($held) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
