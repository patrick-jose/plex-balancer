# One-time repair of the mistaken append-after-movie-reserve generation.
# Restore the pre-extension sequence, weaving its already selected TV additions
# after the earned movie. Does not edit files, watch flags, or the original list.
[CmdletBinding()]
param([switch]$Apply)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'playlist-lib.ps1')
$data=Join-Path $PSScriptRoot 'playlist-data'
$pc=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'playlist.config.json'))|ConvertFrom-Json
if($pc.maintenanceEnabled){throw 'Pause automatic maintenance before correcting insertion.'}
$script:PlaylistBase=$pc.serverUrl.TrimEnd('/')
$token=$env:PLEX_TOKEN
if(-not $token){$token=(Get-ItemProperty 'HKCU:\Software\Plex, Inc.\Plex Media Server').PlexOnlineToken}
$script:PlaylistHeaders=@{'X-Plex-Token'=$token;Accept='application/xml'}
$script:PlaylistApply=[bool]$Apply
$mutex=[Threading.Mutex]::new($false,'Global\PlexBalancer');$held=$false
try{
    try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not $held){throw 'Another operation is active; retry later.'}
    $statePath=Join-Path $data 'state.json'
    $state=[IO.File]::ReadAllText($statePath)|ConvertFrom-Json
    $before=[IO.File]::ReadAllText((Join-Path $data 'before-latest-apply.json'))|ConvertFrom-Json
    $script:SourcePlaylistId=[string]$state.SourceId;$script:ManagedPlaylistId=[string]$state.TargetId
    function Read-ManagedItems {param([string]$Id) @(Get-PlaylistPlexItems "/playlists/$Id/items?includeGuids=1"|ForEach-Object{Convert-PlaylistMedia $_})}
    $current=@(Read-ManagedItems $script:ManagedPlaylistId)
    $source=@(Read-ManagedItems $script:SourcePlaylistId)
    if(($current.Identity-join '|') -cne ($state.Queue.Identity-join '|')){throw 'Live queue changed; inspect before correction.'}
    if(($state.BaseQueue.Identity-join '|') -cne ($before.Target.Identity-join '|')){throw 'Pre-extension snapshot no longer matches generation base.'}
    $base=@($before.Target)
    $context=Get-PlaylistContinuationContext $base
    if($context.Prefix[-1].Title -cne 'Next Goal Wins'){throw 'Expected Next Goal Wins continuation anchor; manual review needed.'}
    $added=@($state.Rounds|ForEach-Object{$_.Episodes}|ForEach-Object{$_})
    if(-not $added.Count -or $added[0].Show -cne 'The Bear' -or $added[0].Season -ne 4 -or $added[0].Episode -ne 10){throw 'Unexpected episode extension; refusing broad reorder.'}
    $baseMovies=@($base|Where-Object Type -eq 'movie')
    if($context.Tail.Count -lt [math]::Floor(($context.Offset+$added.Count)/5)){throw 'Movie reserve cannot supply the selected TV extension.'}
    $desired=@(Merge-PlaylistContinuation -BaseQueue $base -Rounds @($state.Rounds) -Movies $baseMovies)
    # Refresh metadata/playlist item IDs while preserving exact desired identities.
    $resolved=@()
    foreach($item in $desired){$found=@($current|Where-Object Identity -eq $item.Identity);if($found.Count -ne 1){throw 'An intended item is missing or duplicated.'};$resolved+=$found[0]}
    $desired=$resolved
    if(($base.Identity-join '|') -cne ((@($desired|Where-Object{$_.Identity -in $base.Identity}).Identity)-join '|')){throw 'Correction would disturb original relative order.'}
    if($Apply){
        Write-PlaylistJson (Join-Path $data ('before-insertion-correction-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json')) ([pscustomobject]@{State=$state;Queue=$current;Desired=$desired})
        $state.Queue=$desired;$state.BaseQueue=$desired;$state.Rounds=@();$state.Movies=@($desired|Where-Object Type -eq 'movie');$state.Applied=$false;$state.At=(Get-Date).ToString('o')
        Write-PlaylistJson $statePath $state
        [void](Set-PlaylistIntendedItems -Desired $desired -Current $current)
        $sourceNow=@(Read-ManagedItems $script:SourcePlaylistId)
        if(($sourceNow.Identity-join '|') -cne ($source.Identity-join '|')){throw 'Original changed concurrently; inspect.'}
        $state.Applied=$true;Write-PlaylistJson $statePath $state
    }
    "Insertion correction apply=$Apply; desired=$($desired.Count); movie reserve reused; no media files changed."
    $desired|Select-Object -Skip ($context.Prefix.Count-1) -First 18|Select-Object Type,Show,Season,Episode,Title|Format-Table -AutoSize
}
finally{if($held){try{$mutex.ReleaseMutex()}catch{}};$mutex.Dispose()}
