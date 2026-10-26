$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')
. (Join-Path $script:TestRoot 'playlist-lib.ps1')
$head=[pscustomobject]@{Identity='head';Type='episode';Show='Spider-Noir';Season=1;Episode=4;Watched=$true;Paths=@('D:\TV\one.mkv')}
$next=[pscustomobject]@{Identity='next';Type='episode';Show='Clone Wars';Season=2;Episode=6;Watched=$false;Paths=@('D:\TV\two.mkv')}
$state=[pscustomobject]@{Queue=@($head,$next);BaseQueue=@($head,$next)}
$automaticHead=Get-PlaylistWatchedQueueHead @($head,$next)
Assert-Equal 'automatic retirement selects only the watched queue head' $automaticHead.Identity 'head'
$automaticHead=Get-PlaylistWatchedQueueHead @($next,$head)
Assert-Equal 'automatic retirement never skips an unwatched head' $automaticHead $null
$movie=[pscustomobject]@{Identity='movie';Type='movie';Watched=$true}
Assert-Equal 'automatic retirement never removes a movie head' (Get-PlaylistWatchedQueueHead @($movie,$head)) $null
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
