$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')
. (Join-Path $script:TestRoot 'playlist-lib.ps1')

function Media {
    param([string]$Id, [string]$Type = 'movie', [int]$Episode = 0, [string]$ShowKey = '')
    [pscustomobject]@{ Identity = $Id; Ids = @('plex://' + $Id); Key = $Id; Type = $Type; Title = $Id
        Watched = $false; Season = 1; Episode = $Episode; ShowKey = $ShowKey; SortTitle = $Id
        Show = $ShowKey; ReleaseDate = ('2000-01-{0:00}' -f ([math]::Max(1,$Episode))); Paths = @(); Collections = @(); PlaylistItemId = 'p-' + $Id }
}
$savedToken=$env:TMDB_READ_TOKEN; $savedKey=$env:TMDB_API_KEY
try {
    $env:TMDB_READ_TOKEN='stale-environment-token'; $env:TMDB_API_KEY='stale-environment-key'
    $auth=Get-PlaylistTmdbCredential ([pscustomobject]@{tmdbReadToken='  Bearer local-test-token  ';tmdbApiKey=''})
    Assert-Equal 'local token overrides stale environment and removes Bearer prefix' $auth.Token 'local-test-token'
    $auth=Get-PlaylistTmdbCredential ([pscustomobject]@{tmdbReadToken='';tmdbApiKey='local-test-key'})
    Assert-Equal 'local API key overrides stale environment token' $auth.ApiKey 'local-test-key'
    Assert-Equal 'local key prevents fallback to invalid environment token' $auth.Token ''
    $auth=Get-PlaylistTmdbCredential ([pscustomobject]@{})
    Assert-Equal 'environment remains a fallback when local fields are empty' $auth.Token 'stale-environment-token'
}
finally { $env:TMDB_READ_TOKEN=$savedToken; $env:TMDB_API_KEY=$savedKey }
$shows = @(1..25 | ForEach-Object { $s = Media ('show{0:00}' -f $_) 'show'; $s })
$episodes = @(foreach ($s in $shows) { foreach ($n in 3,1,2) { Media ($s.Key + '-' + $n) 'episode' $n $s.Key } })
$plan = Get-PlaylistRounds -Shows $shows -Episodes $episodes -Original @() -Replacements @() -TvStatus @{}
Assert-Equal 'exactly 25 shows form three complete rounds' @($plan.Rounds).Count 3
Assert-Equal 'round shows are alphabetical' $plan.Rounds[0].Episodes[0].ShowKey 'show01'
Assert-Equal 'numeric episode ordering' $plan.Rounds[0].Episodes[0].Episode 1
Assert-Equal 'next round advances each show' $plan.Rounds[1].Episodes[0].Episode 2
Assert-Equal 'round has 25 distinct shows' @($plan.Rounds[0].Episodes.ShowKey|Select-Object -Unique).Count 25
$only24 = Get-PlaylistRounds -Shows @($shows | Select-Object -First 24) -Episodes $episodes -Original @() -Replacements @() -TvStatus @{}
Assert-Equal '24 active shows stop the cycle instead of creating a short round' @($only24.Rounds).Count 0
Assert-True '24-show stop is explained in the planner result' ($only24.Stop[0] -match 'only 24 active shows')

$standby = Media 'show26' 'show'
$short = @($episodes | Where-Object { $_.ShowKey -ne 'show01' -or $_.Episode -eq 1 })
$short += @(1..3 | ForEach-Object { Media ('new-' + $_) 'episode' $_ $standby.Key })
$pairs = @([pscustomobject]@{ from = 'show01'; to = 'show26' })
$swapped = Get-PlaylistRounds -Shows ($shows + $standby) -Episodes $short -Original @() -Replacements $pairs -TvStatus @{}
Assert-Equal '26 library shows still produce 25-show rounds' @($swapped.Rounds).Count 3
Assert-True 'replacement does not enter before the old show finishes' ('show26' -notin $swapped.Rounds[0].Episodes.ShowKey)
Assert-True 'replacement enters the following round' ('show26' -in $swapped.Rounds[1].Episodes.ShowKey)
Assert-Equal 'replacement starts at its first episode' (@($swapped.Rounds[1].Episodes|Where-Object ShowKey -eq 'show26')[0].Episode) 1
Assert-Equal 'new round is alphabetized after replacement' $swapped.Rounds[1].Episodes[-1].ShowKey 'show26'
Assert-Equal 'manual override is recorded' $swapped.Replacements[0].ManualOverride $true
$blocked = Get-PlaylistRounds -Shows $shows -Episodes $short -Original @() -Replacements @() -TvStatus @{}
Assert-Equal 'one exhausted show stops further complete rounds' @($blocked.Rounds).Count 1
Assert-True 'exhausted continuing/unknown show is not silently retired' ($blocked.Stop[0] -match 'show01')
$knownEnd = @{}
$knownEnd[$shows[0].Identity] = [pscustomobject]@{ Known=$true; Ended=$true; Final=10001; Missing=@(); NextAirDate='' }
$noDownloadedStandby = Get-PlaylistRounds -Shows ($shows + $standby) -Episodes @($short | Where-Object ShowKey -ne $standby.Key) -Original @() -Replacements @() -TvStatus $knownEnd -ActiveIds @($shows.Identity)
Assert-Equal 'downloadable but not locally downloaded standby cannot replace an exhausted show' @($noDownloadedStandby.Replacements).Count 0
Assert-True 'cycle remains stopped without a downloaded replacement episode' ($noDownloadedStandby.Stop -match 'show01')
$auto = Get-PlaylistRounds -Shows ($shows + $standby) -Episodes $short -Original @() -Replacements @() -TvStatus $knownEnd -ActiveIds @($shows.Identity)
Assert-Equal 'confirmed exhaustion uses an available downloaded standby' $auto.Replacements[0].To 'show26'
Assert-False 'metadata-driven replacement is not labeled a manual override' $auto.Replacements[0].ManualOverride
Assert-True 'replacement joins the rotation in alphabetical order' ($auto.Rounds[1].Episodes[-1].ShowKey -eq 'show26')

$slotQueue = @((Media 'slot-episode-1' 'episode' 1 'show01'), (Media 'slot-missing-a'), (Media 'slot-episode-2' 'episode' 2 'show02'), (Media 'slot-missing-b'))
$slotMovies = @($slotQueue | Where-Object Type -eq 'movie')
$slotRepair = Replace-PlaylistMissingMovieSlots -Queue $slotQueue -MovieOrder $slotMovies -MissingIdentities @('slot-missing-a','slot-missing-b') -Replacements @((Media 'slot-replacement-a'),(Media 'slot-replacement-b'))
Assert-Equal 'deleted filler replacement keeps the first queue position' $slotRepair.Queue[1].Identity 'slot-replacement-a'
Assert-Equal 'deleted filler replacement keeps later queue position' $slotRepair.Queue[3].Identity 'slot-replacement-b'
Assert-Equal 'movie order receives replacements in the matching slots' ($slotRepair.Movies.Identity -join ',') 'slot-replacement-a,slot-replacement-b'
$slotBad = $false
try { Replace-PlaylistMissingMovieSlots -Queue $slotQueue -MovieOrder $slotMovies -MissingIdentities @('slot-missing-a','slot-missing-b') -Replacements @((Media 'slot-replacement-a'),(Media 'slot-replacement-a')) } catch { $slotBad = $true }
Assert-True 'replacement refuses duplicate random selections' $slotBad

$resumeQueue = @($episodes | Where-Object { $_.ShowKey -notin @($shows[0..13].Key) })
$resumeQueue += @(1..2 | ForEach-Object { Media ('new-resume-' + $_) 'episode' $_ $standby.Key })
$resumeConsumed = @($shows | Sort-Object SortTitle,Identity | Select-Object -First 13 | ForEach-Object Identity)
$resumeStatus = @{}; $resumeStatus[$shows[13].Identity] = [pscustomobject]@{ Known=$true; Ended=$false; Final=0; Missing=@(); Future=@(); NextAirDate='' }
$resumePlan = Get-PlaylistRounds -Shows ($shows + $standby) -Episodes $resumeQueue -Original @() -Replacements @() -TvStatus $resumeStatus -ActiveIds @($shows.Identity) -CycleConsumed $resumeConsumed
Assert-Equal 'downloaded standby resumes after already-consumed cycle prefix' $resumePlan.Rounds[0].Episodes[0].ShowKey 'show15'
Assert-Equal 'downloaded standby is sorted into its correct rotation position' $resumePlan.Rounds[0].Episodes[-1].ShowKey 'show26'

$rotationNames = @('The Bear','Castle Rock','Curb Your Enthusiasm','Doctor Who','Euphoria','From','Hacks','House of the Dragon','Impuros',"It's Always Sunny in Philadelphia",'Jury Duty','Lanterns','Louis Theroux: Life on the Edge','Modern Family','New Bandits','Parks and Recreation','Penn & Teller: Fool Us','The Simpsons','The Sopranos','South Park','Spider-Noir','Star Wars: The Clone Wars','Ted Lasso',"Widow's Bay",'X-Men')
$repairShows = @($rotationNames | ForEach-Object { $s=Media $_ 'show'; if($s.Title -eq 'The Bear'){$s.SortTitle='Bear'}; $s })
$repairQueue = @(); $repairTv = 0; $repairMovie = 0
for($cycle=1;$cycle -le 2;$cycle++) {
    foreach($s in $repairShows) {
        $epNo = if($s.Title -eq 'Penn & Teller: Fool Us' -and $cycle -eq 1){5} elseif($s.Title -eq 'Penn & Teller: Fool Us'){4} else {$cycle}
        $repairQueue += (Media ('repair-' + $s.Key + '-' + $cycle) 'episode' $epNo $s.Key)
        $repairQueue[-1].Show=$s.Title
        $repairTv++
        if($repairTv % 5 -eq 0){$repairQueue += (Media ('repair-movie-' + (++$repairMovie))) }
    }
}
foreach($s in $repairShows | Select-Object -First 16) {
    $thirdEpisode = if($s.Title -eq 'New Bandits'){7}else{3}
    $repairQueue += (Media ('repair-' + $s.Key + '-3') 'episode' $thirdEpisode $s.Key)
    $repairQueue[-1].Show=$s.Title
    $repairTv++
    if($repairTv % 5 -eq 0){$repairQueue += (Media ('repair-movie-' + (++$repairMovie))) }
}
$repair = Repair-PlaylistQueueBeforeBlockedShow -Queue $repairQueue -Shows $repairShows -ActiveIds @($repairShows.Identity) -StopShow 'New Bandits'
Assert-Equal 'cycle repair stops before the blocked show rather than wrapping to Bear' $repair.Queue[-1].Show 'Modern Family'
Assert-True 'cycle repair excludes blocked New Bandits from the current cycle' (@($repair.Queue|Where-Object { $_.Show -eq 'New Bandits' -and $_.Season -eq 1 -and $_.Episode -eq 3 }).Count -eq 0)
Assert-Equal 'cycle repair retains the two complete prior cycles and only the valid preceding shows' @($repair.Queue|Where-Object Type -eq 'episode').Count 64
$pennRepair=@($repair.Queue|Where-Object Show -eq 'Penn & Teller: Fool Us')
Assert-Equal 'Penn & Teller remains queued and episode-sorted' ($pennRepair.Season -join ',') '1,1'
Assert-Equal 'Penn & Teller earlier cycle contains E04 before E05' ($pennRepair.Episode -join ',') '4,5'
Assert-Equal 'repaired current partial cycle is recorded as consumed through its predecessor' @($repair.CycleConsumed).Count 14

$seed = @($episodes|Where-Object Episode -eq 2)
$anchored = Get-PlaylistRounds -Shows $shows -Episodes $episodes -Original $seed -Replacements @() -TvStatus @{}
Assert-Equal 'manual queue anchor prevents older episode reintroduction' $anchored.Rounds[0].Episodes[0].Episode 2
$missingStatus = @{}
$missingStatus[$shows[0].Identity] = [pscustomobject]@{ Known = $true; Ended = $false; Final = 10003; Missing = @([pscustomobject]@{Number=10002}); NextAirDate = '' }
$gap = Get-PlaylistRounds -Shows $shows -Episodes $episodes -Original @() -Replacements @() -TvStatus $missingStatus
Assert-Equal 'known missing episode prevents jumping to later episodes' @($gap.Rounds).Count 1
$more = Get-PlaylistRounds -Shows $shows -Episodes $episodes -Original @() -Replacements @() -TvStatus @{} -Cursors $plan.Cursors -ActiveIds $plan.ActiveIds -StartRound 4
Assert-Equal 'rerun after all planned episodes adds no duplicate rounds' @($more.Rounds).Count 0

$movies = @(1..40 | ForEach-Object { Media ('movie{0:00}' -f $_) })
$empty = Get-PlaylistMovies -Movies $movies -Groups @() -Slots 0 -Seed 42
Assert-Equal 'no complete round means no random movie dump' @($empty.Movies).Count 0
$mp = Get-PlaylistMovies -Movies $movies -Groups @() -Slots 10 -Seed 42
Assert-Equal 'explicit null existing queue initializes as an array' @( (Get-PlaylistMovies -Movies $movies -Groups @() -Slots 5 -Seed 42 -Existing $null).Movies ).Count 5
Assert-Equal 'two TV rounds create exactly ten ordinary movies' @($mp.Movies).Count 10
Assert-Equal 'movie draw has no duplicates' @($mp.Movies.Identity|Select-Object -Unique).Count 10
$repeat = Get-PlaylistMovies -Movies $movies -Groups @() -Slots 10 -Seed 42
Assert-Equal 'same seed produces repeatable preview' ($mp.Movies.Identity -join ',') ($repeat.Movies.Identity -join ',')
$extended = Get-PlaylistMovies -Movies $movies -Groups @() -Slots 15 -Seed 42 -Existing $mp.Movies
Assert-Equal 'extension preserves prior random selections' ($extended.Movies[0..9].Identity -join ',') ($mp.Movies.Identity -join ',')
Assert-Equal 'extension adds only newly required slots' @($extended.Movies).Count 15
$preferred = Get-PlaylistMovies -Movies $movies -Groups @() -Slots 5 -Seed 42 -Preferred $movies[20..39]
Assert-Equal 'initial import preserves existing random movie choices' $preferred.Movies[0].Identity $movies[20].Identity
Assert-Equal 'preferences do not dump the whole copied tail' @($preferred.Movies).Count 5
$gMovies = @(1..3|ForEach-Object { Media ('group-' + $_) 'movie' $_ })
$group = [pscustomobject]@{ Id = 'g'; Name = 'story'; Kind = 'franchise'; Members = $gMovies }
# Seed an already-selected first installment with two preceding random films.
$prior = @($movies[0], $movies[1], $gMovies[0])
$gp = Get-PlaylistMovies -Movies ($movies + $gMovies) -Groups @($group) -Slots 3 -Seed 8 -Existing $prior
$positions = @(for($i=0;$i -lt $gp.Movies.Count;$i++){if($gp.Movies[$i].Identity -in $gMovies.Identity){$i}})
Assert-Equal 'group expansion reaches its final installment' $gp.Movies[-1].Identity 'group-3'
Assert-Equal 'exactly two unrelated movies separate installments' ($positions[1] - $positions[0]) 3
Assert-Equal 'spacing persists for the third installment' ($positions[2] - $positions[1]) 3
Assert-Equal 'no random tail beyond the last installment' @($gp.Movies).Count 9
Assert-Equal 'group entries stay in installment order' ((@($gp.Movies | Where-Object { $_.Identity -in $gMovies.Identity }).Identity) -join ',') 'group-1,group-2,group-3'
$scarce = Get-PlaylistMovies -Movies @($movies[0],$movies[1],$gMovies[0],$gMovies[1],$gMovies[2]) -Groups @($group) -Slots 3 -Seed 1 -Existing $prior
Assert-True 'insufficient fillers is an explicit shortage' ($scarce.Stop -match 'Not enough unrelated')
$watched = Media 'watched'; $watched.Watched = $true
$filtered = Get-PlaylistMovies -Movies ($movies + $watched) -Groups @() -Slots 40 -Seed 2
Assert-True 'watched films do not enter random selection' ('watched' -notin $filtered.Movies.Identity)
$queue = @(Merge-PlaylistQueue -Rounds $plan.Rounds[0..1] -Movies $mp.Movies)
Assert-Equal 'two merged rounds contain 60 items' $queue.Count 60
Assert-Equal 'movie after five TV episodes' $queue[5].Type 'movie'
Assert-Equal 'TV resumes immediately after a movie' $queue[6].Type 'episode'
Assert-Equal 'last entry of a round is a movie' $queue[29].Type 'movie'
$partialQueue = @(Merge-PlaylistQueue -Rounds @([pscustomobject]@{ Episodes = $episodes[0..3] }) -Movies @())
Assert-Equal 'available partial cycle is kept without inventing a fifth slot' $partialQueue.Count 4

$middleShort = @($episodes | Where-Object { $_.ShowKey -ne 'show14' -or $_.Episode -eq 1 })
$untilGap = Get-PlaylistRounds -Shows $shows -Episodes $middleShort -Original @() -Replacements @() -TvStatus @{}
Assert-Equal 'missing show fourteen retains the preceding thirteen episodes' @($untilGap.Rounds[1].Episodes).Count 13
Assert-Equal 'queue stops immediately before the missing show' $untilGap.Rounds[1].Episodes[-1].ShowKey 'show13'
Assert-Equal 'partial cycle records thirteen consumed show positions' @($untilGap.CycleConsumed).Count 13
Assert-Equal 'partial cycle is resumed with the same cycle number' $untilGap.NextCycleNumber 2
$blockedAgain = Get-PlaylistRounds -Shows $shows -Episodes $middleShort -Original @() -Replacements @() -TvStatus @{} -Cursors $untilGap.Cursors -ActiveIds $untilGap.ActiveIds -CycleConsumed $untilGap.CycleConsumed -StartRound $untilGap.NextCycleNumber
Assert-Equal 'retry cannot skip the missing show to start another cycle' @($blockedAgain.Rounds).Count 0
$updated = $middleShort + (Media 'new-show14-2' 'episode' 2 'show14')
$resume = Get-PlaylistRounds -Shows $shows -Episodes $updated -Original @() -Replacements @() -TvStatus @{} -Cursors $untilGap.Cursors -ActiveIds $untilGap.ActiveIds -CycleConsumed $untilGap.CycleConsumed -StartRound $untilGap.NextCycleNumber
Assert-Equal 'downloaded content resumes exactly at the blocked show' $resume.Rounds[0].Episodes[0].ShowKey 'show14'
Assert-Equal 'resume completes only the twelve remaining cycle positions' @($resume.Rounds[0].Episodes).Count 12
$gapMovies = (Get-PlaylistMovies -Movies $movies -Groups @() -Slots 7 -Seed 42).Movies
$gapQueue = @(Merge-PlaylistQueue -Rounds $untilGap.Rounds -Movies $gapMovies)
Assert-Equal '38 queued episodes get seven movies, not ten' @($gapQueue|Where-Object Type -eq 'movie').Count 7
Assert-Equal 'three trailing episodes carry cadence across retry' (Get-PlaylistEpisodeOffset $gapQueue) 3
$resumeMovies = @($gapMovies) + @($movies | Where-Object { $_.Identity -notin $gapMovies.Identity } | Select-Object -First 3)
$resumedQueue = @(Merge-PlaylistContinuation -BaseQueue $gapQueue -Rounds @($resume.Rounds[0]) -Movies $resumeMovies)
Assert-Equal 'next movie follows two resumed episodes, completing the old five' $resumedQueue[$gapQueue.Count+2].Type 'movie'

# The existing queue is the viewing continuation point, NOT a request to rebuild
# a round from alphabetic position one. Even watched/partial historical entries
# remain until an explicitly approved removal policy says otherwise.
$spider = Media 'already-queued-spider' 'episode' 4 $shows[23].Key
$spider.Watched = $true
$partial = Media 'already-queued-partial' 'episode' 6 $shows[23].Key
$base = @($spider, (Media 'already-queued-star' 'episode' 6 $shows[24].Key), $movies[4], $partial, $movies[2], $movies[0])
$continuation = New-PlaylistContinuationState -Queue $base -Shows $shows -Replacements @() -Server 'fake' -SourceId '1' -TargetId '2'
Assert-Equal 'continuation imports existing order exactly, not alphabetically' ($continuation.Queue.Identity -join ',') ($base.Identity -join ',')
Assert-Equal 'viewing head stays Spider-Noir-like, even if now watched' $continuation.Queue[0].Identity $spider.Identity
Assert-Equal 'import cursor includes the incomplete last round' $continuation.Cursors[$shows[23].Identity] 10006
Assert-Equal 'historical entries are not falsely recorded as new full rounds' @($continuation.Rounds).Count 0
$unchanged = @(Merge-PlaylistContinuation -BaseQueue $base -Rounds @() -Movies @($base|Where-Object Type -eq 'movie'))
Assert-Equal 'shortage preserves already-queued partial-round entries' ($unchanged.Identity -join ',') ($base.Identity -join ',')
$suffixMovies = @($base|Where-Object Type -eq 'movie') + $movies[10..14]
$appended = @(Merge-PlaylistContinuation -BaseQueue $base -Rounds @($plan.Rounds[0]) -Movies $suffixMovies)
Assert-Equal 'new episodes preserve relative order of every existing item' ((@($appended | Where-Object { $_.Identity -in $base.Identity }).Identity) -join ',') ($base.Identity -join ',')
Assert-Equal 'only a complete extension is appended' $appended.Count ($base.Count+30)
$bad=$false
try { Merge-PlaylistContinuation -BaseQueue $base -Rounds @() -Movies @($base|Where-Object Type -eq 'movie'|Sort-Object Identity) } catch { $bad=$true }
Assert-True 'existing movie tail cannot be silently reordered' $bad

# Continue after the next earned movie, not after the entire movie reserve.
$reserveBase = @($plan.Rounds[0].Episodes[0..4]) + $movies[0..10]
$newSegment = [pscustomobject]@{Number=2;Episodes=@($plan.Rounds[1].Episodes[0..12])}
$woven = @(Merge-PlaylistContinuation -BaseQueue $reserveBase -Rounds @($newSegment) -Movies $movies[0..10])
Assert-Equal 'TV continuation starts immediately after Next Goal Wins-like anchor' $woven[6].Identity $newSegment.Episodes[0].Identity
Assert-Equal 'five new episodes consume the next already queued movie' $woven[11].Identity $movies[1].Identity
Assert-Equal 'next five new episodes consume the following queued movie' $woven[17].Identity $movies[2].Identity
Assert-Equal 'existing movie reserve supplies slots without extra movies' @($woven|Where-Object Type -eq 'movie').Count 11
Assert-Equal 'every old movie retains its original relative order' ((@($woven|Where-Object Type -eq 'movie').Identity)-join ',') ($movies[0..10].Identity-join ',')
Assert-Equal 'original queue head is not moved' $woven[0].Identity $reserveBase[0].Identity
$weaveContext = Get-PlaylistContinuationContext $woven
Assert-Equal 'three episodes before gap resume before unearned next movie' $weaveContext.Offset 3
$resumedSegment = [pscustomobject]@{Number=2;Episodes=@($plan.Rounds[1].Episodes[13..24])}
$wovenMore = @(Merge-PlaylistContinuation -BaseQueue $woven -Rounds @($resumedSegment) -Movies $movies[0..10])
Assert-Equal 'resume at missing show precedes the unused movie reserve' $wovenMore[$weaveContext.Prefix.Count].Identity $resumedSegment.Episodes[0].Identity
Assert-Equal 'two resumed episodes finish the old five before the movie' $wovenMore[$weaveContext.Prefix.Count+2].Identity $weaveContext.Tail[0].Identity
Assert-Equal 'retry without new episodes changes no order' ((@(Merge-PlaylistContinuation -BaseQueue $woven -Rounds @() -Movies $movies[0..10]).Identity)-join ',') ($woven.Identity-join ',')

$wanted = Media 'old'; $found = Media 'new'; $found.Ids = $wanted.Ids
Assert-Equal 'stable identity resolves a changed ratingKey' (Resolve-PlaylistMedia $wanted @($found)).Key 'new'
Assert-Equal 'missing library media stays unresolved' (Resolve-PlaylistMedia $wanted @()) $null
Assert-Equal 'ambiguous identity does not pick an arbitrary edition' (Resolve-PlaylistMedia $wanted @($found,$wanted)) $null
$ops = @(Get-PlaylistSyncOperations -Desired $movies[0..2] -Current @($movies[0],$movies[3]))
Assert-Equal 'sync adds only missing items' @($ops|Where-Object Kind -eq 'add').Count 2
Assert-Equal 'sync removes unwanted references, not files' @($ops|Where-Object Kind -eq 'remove').Count 1
$same = @(Get-PlaylistSyncOperations -Desired $movies[0..2] -Current $movies[0..2])
Assert-Equal 'already synchronized playlist is idempotent' $same.Count 0
$bad = $false
try { Get-PlaylistSyncOperations -Desired @($movies[0],$movies[0]) -Current @() } catch { $bad = $true }
Assert-True 'duplicate desired entries are refused' $bad

$script:PlaylistBase = 'http://127.0.0.1:1'
$script:SourcePlaylistId = '1'; $script:ManagedPlaylistId = '2'; $script:PlaylistApply = $true
$bad = $false
try { Invoke-PlaylistPlex '/playlists/1/items/5' 'Delete' } catch { $bad = $_.Exception.Message -match 'outside the managed' }
Assert-True 'API guard refuses mutation of the original' $bad
$bad = $false
try { Invoke-PlaylistPlex '/library/metadata/8' 'Delete' } catch { $bad = $_.Exception.Message -match 'restricted' }
Assert-True 'API guard refuses library/media deletion' $bad
$script:PlaylistApply = $false
$bad = $false
try { Invoke-PlaylistPlex '/playlists/2/items/5' 'Delete' } catch { $bad = $_.Exception.Message -match 'require -Apply' }
Assert-True 'preview cannot perform playlist writes' $bad

# Provider behavior is tested with a deterministic metadata fake, not a real key.
function Get-PlaylistMetadata {
    param([string]$Path)
    if ($script:MetadataFails) { throw 'provider unavailable' }
    if ($Path -eq 'tv/99') { return [pscustomobject]@{ status='Ended'; seasons=@([pscustomobject]@{season_number=1}) } }
    if ($Path -eq 'tv/99/season/1') {
        return [pscustomobject]@{ episodes=@(
            [pscustomobject]@{season_number=1;episode_number=1;air_date='2000-01-01'},
            [pscustomobject]@{season_number=1;episode_number=2;air_date='2000-01-02'},
            [pscustomobject]@{season_number=1;episode_number=3;air_date='2099-01-03'}
        ) }
    }
    throw 'Unexpected fake metadata request.'
}
$providerShow = Media 'provider-show' 'show'; $providerShow.Ids += 'tmdb://99'
$localEpisode = Media 'provider-episode' 'episode' 1 $providerShow.Key
$script:MetadataFails = $false
$tv = Get-PlaylistTvStatus $providerShow @($localEpisode) 10001
Assert-True 'TMDb status is accepted only after successful metadata read' $tv.Known
Assert-True 'TMDb ended status is represented' $tv.Ended
Assert-Equal 'released missing episode is identified' $tv.Missing[0].Episode 2
Assert-Equal 'unaired future episode is not a missing-download notice' @($tv.Missing).Count 1
Assert-Equal 'next release date is available for notification' $tv.NextAirDate '2099-01-03'
Assert-Equal 'final episode includes future scheduled finale' $tv.Final 10003
$script:MetadataFails = $true
$tv = Get-PlaylistTvStatus $providerShow @($localEpisode) 10001
Assert-False 'provider failure never fabricates an ended decision' $tv.Ended
Assert-False 'provider failure is explicitly unknown' $tv.Known
$script:MetadataFails = $false

# Execute the real synchronization algorithm against a fake Plex backend. No
# HTTP request, real playlist, token, playback state or media is touched.
$script:PlaylistApply = $true
$script:FakeItems = @($movies[2], $movies[0], $movies[3])
$script:FakeLibrary = $movies
$script:FakeWrites = @()
$script:IgnoreAdds = $false
$script:IgnoreMoves = $false
function Read-ManagedItems { param($Id) return $script:FakeItems }
function Invoke-PlaylistPlex {
    param([string]$Path, [string]$Method='Get')
    if ($Path -eq '/identity') { return ([xml]'<MediaContainer machineIdentifier="fake"/>').DocumentElement }
    $script:FakeWrites += "$Method $Path"
    if ($Path -notmatch '^/playlists/2/') { throw 'Fake backend detected a write outside managed copy.' }
    if ($Method -eq 'Delete') {
        if ($Path -eq '/playlists/2/items') { $script:FakeItems = @(); return }
        $id = ($Path -split '/')[-1]
        $script:FakeItems = @($script:FakeItems | Where-Object { $_.PlaylistItemId -ne $id })
    }
    elseif ($Path -match '/items\?uri=(.+)$') {
        $key = ([uri]::UnescapeDataString($Matches[1]) -split '/')[-1]
        if (-not $script:IgnoreAdds) { foreach($part in $key.Split(',')){ $script:FakeItems += @($script:FakeLibrary | Where-Object Key -eq $part)[0] } }
    }
    elseif ($Path -match '/items/([^/]+)/move(?:\?after=(.+))?$') {
        if ($script:IgnoreMoves) { return }
        $id = $Matches[1]; $after = $Matches[2]
        $moving = @($script:FakeItems | Where-Object PlaylistItemId -eq $id)[0]
        $list = [Collections.Generic.List[object]]::new()
        foreach ($x in $script:FakeItems) { if($x.PlaylistItemId -ne $id){ $list.Add($x) } }
        $index = 0
        if ($after) { for($i=0;$i -lt $list.Count;$i++){if($list[$i].PlaylistItemId -eq $after){$index=$i+1;break}} }
        $list.Insert($index,$moving); $script:FakeItems = @($list.ToArray())
    }
    else { throw 'Unexpected fake request.' }
}
$ok = Set-PlaylistIntendedItems -Desired $movies[0..2] -Current $script:FakeItems
Assert-True 'real sync algorithm verifies fake server order' $ok
Assert-Equal 'fake backend receives all desired items in order' ($script:FakeItems.Identity -join ',') ($movies[0..2].Identity -join ',')
Assert-True 'all mutations target only the managed playlist' (@($script:FakeWrites|Where-Object {$_ -notmatch '^\w+ /playlists/2/'}).Count -eq 0)
$script:FakeWrites = @()
[void](Set-PlaylistIntendedItems -Desired $movies[0..2] -Current $script:FakeItems)
Assert-Equal 'second sync sends no mutation when already correct' $script:FakeWrites.Count 0
$script:FakeItems = @($movies[0],$movies[2])
[void](Set-PlaylistIntendedItems -Desired $movies[0..2] -Current $script:FakeItems)
Assert-Equal 'recovery restores missing middle item at its exact position' ($script:FakeItems.Identity -join ',') ($movies[0..2].Identity -join ',')
$script:FakeItems = @($movies[2],$movies[0],$movies[1]); $script:IgnoreMoves = $true
[void](Set-PlaylistIntendedItems -Desired $movies[0..2] -Current $script:FakeItems)
Assert-Equal 'ineffective Plex move falls back to verified ordered references' ($script:FakeItems.Identity -join ',') ($movies[0..2].Identity -join ',')
$script:IgnoreMoves = $false
$script:FakeItems = @($movies[0]); $script:IgnoreAdds = $true
$bad = $false
try { Set-PlaylistIntendedItems -Desired $movies[0..2] -Current $script:FakeItems } catch { $bad = $_.Exception.Message -match 'absent|Verification' }
Assert-True 'server silently ignoring additions is a failure, not success' $bad
$script:IgnoreAdds = $false

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('playlist-test-' + [guid]::NewGuid().ToString('N'))
try {
    $path = Join-Path $tmp 'state.json'
    Write-PlaylistJson $path ([pscustomobject]@{ Count = 1 })
    Write-PlaylistJson $path ([pscustomobject]@{ Count = 2 })
    Assert-Equal 'atomic state replace saves current intent' ([IO.File]::ReadAllText($path)|ConvertFrom-Json).Count 2
    Assert-Equal 'atomic state replace keeps previous intent as backup' ([IO.File]::ReadAllText($path+'.bak')|ConvertFrom-Json).Count 1
    Assert-Equal 'state writer leaves no temporary files' @(Get-ChildItem $tmp -Filter '*.tmp').Count 0
}
finally { if(Test-Path $tmp){ Remove-Item -LiteralPath $tmp -Recurse -Force } }
Write-TestResult -Suite 'playlist-manager'
