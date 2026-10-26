[CmdletBinding()]
param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'playlist-lib.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'playlist.config.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw 'Create playlist.config.json from its example first.' }
$script:PlaylistCfg = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
$script:PlaylistBase = ([string]$script:PlaylistCfg.serverUrl).TrimEnd('/')
$script:PlaylistData = Join-Path $PSScriptRoot 'playlist-data'
$token = $env:PLEX_TOKEN
if (-not $token) { $token = (Get-ItemProperty 'HKCU:\Software\Plex, Inc.\Plex Media Server' -ErrorAction SilentlyContinue).PlexOnlineToken }
if (-not $token) { throw 'No Plex token available.' }
$script:PlaylistHeaders = @{ 'X-Plex-Token'=$token; Accept='application/xml' }

$sections = @((Invoke-PlaylistPlex '/library/sections').SelectNodes('Directory'))
$showSections = @($sections | Where-Object { $_.GetAttribute('type') -eq 'show' })
$shows = @()
$episodes = @()
foreach ($section in $showSections) {
    $sectionId = $section.GetAttribute('key')
    foreach ($node in @(Get-PlaylistPlexItems "/library/sections/$sectionId/all?type=2&includeGuids=1" 'Directory')) {
        $show = Convert-PlaylistMedia $node $sectionId
        $shows += $show
        foreach ($episodeNode in @(Get-PlaylistPlexItems ("/library/metadata/{0}/allLeaves?includeGuids=1" -f $show.Key) 'Video')) {
            $episodes += Convert-PlaylistMedia $episodeNode $sectionId
        }
    }
}

$playlists = @(Get-PlaylistPlexItems '/playlists' 'Playlist')
$source = @($playlists | Where-Object { $_.GetAttribute('title') -ceq $script:PlaylistCfg.sourcePlaylist })
if ($source.Count -ne 1) { throw 'Configured source playlist must exist exactly once.' }
$original = @(Get-PlaylistPlexItems ("/playlists/{0}/items?includeGuids=1" -f $source[0].GetAttribute('ratingKey')) | ForEach-Object { Convert-PlaylistMedia $_ })
$standbyNames = @($script:PlaylistCfg.replacements | ForEach-Object { $_.to })
$activeShows = @($shows | Where-Object { $_.Title -notin $standbyNames } | Sort-Object SortTitle,Identity)

'Active roster:'
$activeShows | ForEach-Object { "  $($_.Title)" }
''
'Standby shows with downloaded, unwatched episodes:'
foreach ($show in @($shows | Where-Object { $_.Title -in $standbyNames } | Sort-Object SortTitle,Identity)) {
    $seed = @($original | Where-Object ShowKey -eq $show.Key | Sort-Object Season,Episode | Select-Object -First 1)
    $anchor = if ($seed.Count) { [long]$seed[0].Season * 10000 + $seed[0].Episode } else { 1 }
    $available = @($episodes | Where-Object {
        $_.Type -eq 'episode' -and $_.ShowKey -eq $show.Key -and $_.Season -gt 0 -and -not $_.Watched -and
        ([long]$_.Season * 10000 + $_.Episode) -ge $anchor
    } | Sort-Object Season,Episode)
    if ($available.Count) { "  $($show.Title): $($available.Count) episode(s), next S$($available[0].Season)E$($available[0].Episode)" }
    else { "  $($show.Title): no downloaded unwatched episodes" }
}
