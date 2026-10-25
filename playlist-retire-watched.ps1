# Explicitly retire ONE user-confirmed watched episode at the managed queue head.
# No automatic sweeping of library watch flags. Preview unless -Apply is passed.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Show,
    [Parameter(Mandatory=$true)][int]$Season,
    [Parameter(Mandatory=$true)][int]$Episode,
    [switch]$ConfirmedPlaylistViewing,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'playlist-lib.ps1')
if (-not $ConfirmedPlaylistViewing) { throw 'This command requires user confirmation that this episode was watched from this playlist.' }
$cfg = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'config.json')) | ConvertFrom-Json
$pc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'playlist.config.json')) | ConvertFrom-Json
$script:PlaylistBase = $pc.serverUrl.TrimEnd('/')
$token = $env:PLEX_TOKEN
if (-not $token) { $token = (Get-ItemProperty 'HKCU:\Software\Plex, Inc.\Plex Media Server').PlexOnlineToken }
$script:PlaylistHeaders = @{ 'X-Plex-Token'=$token; Accept='application/xml' }
$script:PlaylistApply = [bool]$Apply
$data = Join-Path $PSScriptRoot 'playlist-data'
$statePath = Join-Path $data 'state.json'
$mutex = [Threading.Mutex]::new($false, 'Global\PlexBalancer')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
    if (-not $held) { throw 'Another balancer/playlist operation is active.' }
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    if ($state.Version -ne 2 -or -not $state.Applied) { throw 'Verified continuation state required.' }
    $script:SourcePlaylistId = [string]$state.SourceId
    $script:ManagedPlaylistId = [string]$state.TargetId
    function Read-ManagedItems {
        param([string]$Id)
        @(Get-PlaylistPlexItems "/playlists/$Id/items?includeGuids=1" | ForEach-Object { Convert-PlaylistMedia $_ })
    }
    $current = @(Read-ManagedItems $script:ManagedPlaylistId)
    $item = Get-PlaylistRetirementCandidate -Current $current -State $state -Show $Show -Season $Season -Episode $Episode -Confirmed ([bool]$ConfirmedPlaylistViewing)
    $path = [IO.Path]::GetFullPath($item.Paths[0])
    $rootMatches = @($cfg.libraries.roots | ForEach-Object { $_ } | Where-Object { $path.StartsWith($_.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) })
    if (-not $rootMatches.Count -or -not [IO.File]::Exists($path)) { throw 'Media file absent or outside configured library roots.' }
    if (([IO.FileInfo]::new($path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing to delete a reparse-point media file.' }
    function Assert-NotPlaying {
        $sessions = Invoke-PlaylistPlex '/status/sessions'
        foreach ($video in $sessions.SelectNodes('Video')) {
            if ($video.GetAttribute('ratingKey') -eq $item.Key -or $video.GetAttribute('guid') -in $item.Ids) { throw 'Episode is still in an active Plex session.' }
            foreach ($part in $video.SelectNodes('Media/Part')) {
                if ($part.GetAttribute('file') -eq $path) { throw 'Media file is in an active Plex session.' }
            }
        }
    }
    Assert-NotPlaying
    $bytes = ([IO.FileInfo]::new($path)).Length
    "Selected watched head: $Show S${Season}E$Episode - $($item.Title)"
    "Single file: $path ($([math]::Round($bytes/1GB,2)) GB); apply=$Apply"
    if (-not $Apply) { return }

    # User policy: explicitly confirmed watched-playlist retirement does not
    # consult or start qBittorrent. Storage balancing/recycle guards are separate.
    Assert-NotPlaying
    $fresh = @(Read-ManagedItems $script:ManagedPlaylistId)
    if (($fresh.Identity -join '|') -cne ($current.Identity -join '|')) { throw 'Playlist changed during safety checks; no deletion performed.' }

    $transactionPath = Join-Path $data ('retirement-' + $item.Key + '.json')
    if (Test-Path -LiteralPath $transactionPath) { throw 'A retirement transaction already exists; inspect it before retrying.' }
    $transaction = [pscustomobject]@{ At=(Get-Date).ToString('o'); Item=$item; Path=$path; Bytes=$bytes
        Reason='User-confirmed watched from managed playlist; Plex watched; no active session; torrent check omitted by user policy'
        Status='Pending'; Deleted=$false; QueueUpdated=$false }
    Write-PlaylistJson (Join-Path $data ('before-retirement-'+$item.Key+'.json')) $state
    Write-PlaylistJson $transactionPath $transaction
    # Exclusive handle + DeleteOnClose avoids closing an exclusive test handle
    # and then racing a new Plex reader before deleting. No folder recursion.
    $handle = [IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None,4096,[IO.FileOptions]::DeleteOnClose)
    $handle.Dispose()
    if ([IO.File]::Exists($path)) { throw 'File still exists; transaction retained for inspection.' }
    $transaction.Deleted=$true; $transaction.Status='FileDeleted'
    Write-PlaylistJson $transactionPath $transaction
    # Durable removal before playlist edits: recovery must never resurrect this
    # explicitly retired media, even if the Plex update is interrupted.
    $state.Queue = @($state.Queue | Where-Object Identity -ne $item.Identity)
    $state.BaseQueue = @($state.BaseQueue | Where-Object Identity -ne $item.Identity)
    $state | Add-Member -NotePropertyName Retired -NotePropertyValue (@(Get-PlaylistProp $state 'Retired' @()) + $transaction) -Force
    $state.At=(Get-Date).ToString('o'); $state.Applied=$false
    Write-PlaylistJson $statePath $state
    $remaining = @(Read-ManagedItems $script:ManagedPlaylistId)
    [void](Set-PlaylistIntendedItems -Desired @($state.Queue) -Current $remaining)
    $state.Applied=$true
    Write-PlaylistJson $statePath $state
    $transaction.QueueUpdated=$true; $transaction.Status='Complete'
    Write-PlaylistJson $transactionPath $transaction
    "Deleted the one confirmed watched file; managed queue now $(@($state.Queue).Count) entries, original remaining order preserved."
    "No other episode, watch flag, or original-playlist API entry was edited."
}
finally { if ($held) { try {$mutex.ReleaseMutex()}catch{} }; $mutex.Dispose() }
