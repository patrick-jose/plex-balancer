$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')
. (Join-Path $script:TestRoot 'playlist-lib.ps1')
$head=[pscustomobject]@{Identity='head';Type='episode';Show='Spider-Noir';Season=1;Episode=4;Watched=$true;Paths=@('D:\TV\one.mkv')}
$next=[pscustomobject]@{Identity='next';Type='episode';Show='Clone Wars';Season=2;Episode=6;Watched=$false;Paths=@('D:\TV\two.mkv')}
$state=[pscustomobject]@{Queue=@($head,$next);BaseQueue=@($head,$next)}
$automaticItem=Get-PlaylistWatchedQueueItem @($head,$next)
Assert-Equal 'automatic retirement selects a watched episode' $automaticItem.Identity 'head'
$automaticItem=Get-PlaylistWatchedQueueItem @($next,$head)
Assert-Equal 'automatic retirement finds watched episodes after unwatched entries' $automaticItem.Identity 'head'
$movie=[pscustomobject]@{Identity='movie';Type='movie';Watched=$false}
Assert-Equal 'automatic retirement skips an unwatched movie and selects a watched episode after it' (Get-PlaylistWatchedQueueItem @($movie,$head)).Identity 'head'
$movie.Watched=$true
Assert-Equal 'automatic retirement selects a watched movie without replacing its slot' (Get-PlaylistWatchedQueueItem @($movie,$head)).Identity 'movie'
Assert-Equal 'automatic retirement does nothing when no watched episode exists' (Get-PlaylistWatchedQueueItem @($next)) $null
$outsideWindow=@(1..5|ForEach-Object{$x=[pscustomobject]@{Identity="unwatched-$_";Type='episode';Watched=$false};$x})+@($head)
Assert-Equal 'watched items beyond the first five positions wait for a later run' @(Get-PlaylistWatchedQueueItems -Queue $outsideWindow -WindowSize 5).Count 0
Assert-Equal 'a watched item becomes eligible when it enters the configured window' (Get-PlaylistWatchedQueueItem -Queue $outsideWindow -WindowSize 6).Identity 'head'
$candidate=Get-PlaylistRetirementCandidate @($head,$next) $state 'Spider-Noir' 1 4 $true
Assert-Equal 'only the explicitly confirmed watched head is selected' $candidate.Identity 'head'
$bad=$false;try{Get-PlaylistRetirementCandidate @($head,$next) $state 'Spider-Noir' 1 4 $false}catch{$bad=$true}
Assert-True 'library watched flag alone is not permission to delete' $bad
$head.Watched=$false
$bad=$false;try{Get-PlaylistRetirementCandidate @($head,$next) $state 'Spider-Noir' 1 4 $true}catch{$bad=$true}
Assert-True 'confirmation cannot bypass Plex watched check' $bad
$head.Watched=$true
$bad=$false;try{Get-PlaylistRetirementCandidate @($head,$next) $state 'Clone Wars' 2 6 $true}catch{$bad=$true}
Assert-True 'currently watched next item is not selected for retirement' $bad
$bad=$false;try{Get-PlaylistRetirementCandidate @($next,$head) $state 'Spider-Noir' 1 4 $true}catch{$bad=$true}
Assert-True 'concurrent queue changes block deletion' $bad
$head.Paths=@('one','two')
$bad=$false;try{Get-PlaylistRetirementCandidate @($head,$next) $state 'Spider-Noir' 1 4 $true}catch{$bad=$true}
Assert-True 'multiple versions or parts require explicit review' $bad
$head.Paths=@('one')
$bad=$false;try{Get-PlaylistRetirementCandidate @($head,$next) $state 'Spider-Noir' 1 5 $true}catch{$bad=$true}
Assert-True 'a different episode number is never substituted' $bad
Assert-False 'safety validation never marks current playback watched' $next.Watched
Write-TestResult -Suite 'playlist-retirement'
