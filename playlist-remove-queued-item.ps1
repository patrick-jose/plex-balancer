# One-time repair: remove a single incorrectly queued item from the managed
# playlist and its durable intent, preserving every other item's order.
# Preview by default; -Apply edits only the named managed copy.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Key,
    [string]$Title,
    [switch]$Apply,
    [string]$DataDirectory
)
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
    $current = @(Read-ManagedItems $script:ManagedPlaylistId)
    $source = @(Read-ManagedItems $script:SourcePlaylistId)
    if (($current.Identity -join '|') -cne ($state.Queue.Identity -join '|')) {
        throw 'Managed live playlist differs from saved intent; preserve user edits and review before removal.'
    }

    $matches = @($current | Where-Object {
        [string]$_.Key -ceq $Key -and ((-not $Title) -or $_.Title -ceq $Title)
    })
    if ($matches.Count -ne 1) { throw "Expected exactly one queued item with key '$Key'; found $($matches.Count)." }
    $remove = $matches[0]
    $position = [array]::IndexOf($current, $remove) + 1
    $desired = @($current | Where-Object { $_.Identity -cne $remove.Identity })
    if ($desired.Count -ne ($current.Count - 1)) { throw 'Removal produced an unexpected queue length.' }

    Write-Host ("Remove apply=$Apply; position=$position; {0} '{1}' key=$Key; before={2}; after={3}" -f $remove.Type, $remove.Title, $current.Count, $desired.Count)
    Write-Host 'Proposed head of managed playlist:'
    for ($i = 0; $i -lt [math]::Min(8, $desired.Count); $i++) {
        $item = $desired[$i]
        $episode = if ($item.Show) { " [$($item.Show) S$($item.Season)E$($item.Episode)]" } else { '' }
        Write-Host ("  #{0} {1}:{2}{3} key={4}" -f ($i + 1), $item.Type, $item.Title, $episode, $item.Key)
    }
    Write-Host 'Original source playlist and media files are never changed.'

    if ($Apply) {
        $archive = Join-Path $script:PlaylistData ('before-item-removal-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        Write-PlaylistJson $archive ([pscustomobject]@{ PreviousState = $state; BeforeRemoval = $current; AfterRemoval = $desired })
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
        Write-Host 'Removal applied and verified; durable intent updated.'
    }
}
finally {
    if ($held) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
