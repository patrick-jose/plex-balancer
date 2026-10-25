# Correct the manager's initial rebuild using its first untouched-copy snapshot.
# Refuses concurrent/manual queue edits. Never changes source, watch flags or files.
[CmdletBinding()]
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'playlist-lib.ps1')
$script:PlaylistData = Join-Path $PSScriptRoot 'playlist-data'
$config = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'playlist.config.json')) | ConvertFrom-Json
if ($config.maintenanceEnabled) { throw 'Disable playlist maintenance before restoring order.' }
$script:PlaylistBase = $config.serverUrl.TrimEnd('/')
$token = $env:PLEX_TOKEN
if (-not $token) { $token = (Get-ItemProperty 'HKCU:\Software\Plex, Inc.\Plex Media Server').PlexOnlineToken }
$script:PlaylistHeaders = @{ 'X-Plex-Token' = $token; Accept = 'application/xml' }
$script:PlaylistApply = [bool]$Apply
$mutex = [Threading.Mutex]::new($false, 'Global\PlexBalancer')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another balancer/playlist operation is running; retry after it finishes.' }
    $backup = [IO.File]::ReadAllText((Join-Path $script:PlaylistData 'before-first-apply.json')) | ConvertFrom-Json
    $old = [IO.File]::ReadAllText((Join-Path $script:PlaylistData 'state.json')) | ConvertFrom-Json
    if (@(Get-PlaylistProp $old 'Retired' @()).Count) { throw 'Watched retirements exist; do not restore an older snapshot over intentional removals.' }
    $script:SourcePlaylistId = [string]$backup.SourceId
    $script:ManagedPlaylistId = [string]$backup.TargetId
    if ($script:SourcePlaylistId -eq $script:ManagedPlaylistId) { throw 'Invalid restore source/target.' }
    $playlists = @(Get-PlaylistPlexItems '/playlists' 'Playlist')
    $target = @($playlists | Where-Object { $_.GetAttribute('ratingKey') -eq $script:ManagedPlaylistId -and $_.GetAttribute('title') -ceq $config.managedPlaylist })
    if ($target.Count -ne 1) { throw 'Managed playlist identity changed; restoration requires review.' }
    function Read-ManagedItems {
        param([string]$Id)
        @(Get-PlaylistPlexItems "/playlists/$Id/items?includeGuids=1" | ForEach-Object { Convert-PlaylistMedia $_ })
    }
    $current = @(Read-ManagedItems $script:ManagedPlaylistId)
    $source = @(Read-ManagedItems $script:SourcePlaylistId)
    if (($source.Identity -join '|') -cne ($backup.Target.Identity -join '|')) { throw 'The manual original has changed since the first snapshot; refusing to assume the restoration target.' }
    if (($current.Identity -join '|') -cne ($old.Queue.Identity -join '|')) { throw 'Managed queue changed since the saved state; preserve user edits and review before restoration.' }
    $desired = @($source)
    foreach ($item in $desired) { if (-not (Test-PlaylistMediaPresent $item)) { throw "File unavailable for $($item.Title); no restoration writes made." } }
    $shows = @()
    foreach ($section in (Invoke-PlaylistPlex '/library/sections').SelectNodes('Directory')) {
        if ($section.GetAttribute('type') -ne 'show') { continue }
        $id = $section.GetAttribute('key')
        foreach ($node in @(Get-PlaylistPlexItems "/library/sections/$id/all?type=2&includeGuids=1" 'Directory')) { $shows += Convert-PlaylistMedia $node $id }
    }
    $new = New-PlaylistContinuationState -Queue $desired -Shows $shows -Replacements @($config.replacements) -Server $script:PlaylistBase -SourceId $script:SourcePlaylistId -TargetId $script:ManagedPlaylistId
    if ($Apply) {
        $archive = Join-Path $script:PlaylistData ('correction-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
        Write-PlaylistJson $archive ([pscustomobject]@{ PreviousState = $old; BeforeCorrection = $current; RestoredOrder = $desired })
        Write-PlaylistJson (Join-Path $script:PlaylistData 'state.json') $new
        [void](Set-PlaylistIntendedItems -Desired $desired -Current $current)
        $sourceNow = @(Read-ManagedItems $script:SourcePlaylistId)
        if (($sourceNow.Identity -join '|') -cne ($source.Identity -join '|')) { throw 'Manual original changed concurrently; inspect before claiming restoration.' }
        $new.Applied = $true
        Write-PlaylistJson (Join-Path $script:PlaylistData 'state.json') $new
    }
    "Restore apply=$Apply; intended=$($desired.Count); original ordering preserved; maintenance remains disabled."
    "Head: $($desired[0].Show) S$($desired[0].Season)E$($desired[0].Episode) - $($desired[0].Title)"
    "Watched flags and media files are not modified."
}
finally { if ($held) { try { $mutex.ReleaseMutex() } catch { } }; $mutex.Dispose() }
