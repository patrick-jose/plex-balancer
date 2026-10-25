# Round planning uses synthetic metadata; no Plex login or network needed.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')
. (Lift-Functions -Script 'playlist-preview.ps1' -Names 'Get-PreviewRounds')
$shows = @(1..25 | ForEach-Object { [pscustomobject]@{ Key = "$_"; Title = ('Show {0:00}' -f $_); SortTitle = ('Show {0:00}' -f $_) } })
$episodes = @(foreach ($show in $shows) {
    foreach ($number in 3, 1, 2) {
        [pscustomobject]@{ Key = "$($show.Key)-$number"; ShowKey = $show.Key
            Show = $show.Title; Season = 1; Episode = $number; Watched = $false }
    }
})
$plan = Get-PreviewRounds -Shows @($shows | Sort-Object Title -Descending) -Episodes $episodes
Assert-Equal '25 shows with three episodes produce three rounds' @($plan.Rounds).Count 3
Assert-Equal 'each complete round creates five movie slots' $plan.MovieSlots 15
Assert-Equal 'show order is alphabetical, not input order' $plan.Rounds[0].Episodes[0].Show 'Show 01'
Assert-Equal 'episode order is numeric, not input order' $plan.Rounds[0].Episodes[0].Episode 1
Assert-Equal 'the next round advances each show' $plan.Rounds[1].Episodes[0].Episode 2
Assert-Equal 'each round contains 25 distinct shows' @($plan.Rounds[0].Episodes.ShowKey | Select-Object -Unique).Count 25

$short = @($episodes | Where-Object { $_.ShowKey -ne '25' -or $_.Episode -eq 1 })
$plan = Get-PreviewRounds -Shows $shows -Episodes $short
Assert-Equal 'episodes before the exhausted show form a retained partial cycle' @($plan.Rounds).Count 2
Assert-Equal '49 available episodes before the gap create nine movie slots' $plan.MovieSlots 9
Assert-True 'shortage names the exhausted show' ('Show 25' -in $plan.Missing)
$none = Get-PreviewRounds -Shows $shows -Episodes @()
Assert-Equal 'no available episodes produces no round' @($none.Rounds).Count 0
$fewer = Get-PreviewRounds -Shows $shows[0..23] -Episodes $episodes
Assert-Equal '24 selected shows cannot form a round' $fewer.MovieSlots 0
$extra = [pscustomobject]@{ Key = '26'; Title = 'Show 26'; SortTitle = 'Show 26' }
$more = Get-PreviewRounds -Shows ($shows + $extra) -Episodes $episodes
Assert-Equal '26 shows require a roster choice, not silent dropping' $more.MovieSlots 0
$threw = $false
try { Get-PreviewRounds -Shows ($shows[0..23] + $shows[0]) -Episodes $episodes | Out-Null } catch { $threw = $true }
Assert-True 'one show cannot occupy two rotation positions' $threw
$watched = @($episodes | ForEach-Object { $_ | Select-Object * })
$watched | Where-Object { $_.Episode -eq 1 } | ForEach-Object { $_.Watched = $true }
$plan = Get-PreviewRounds -Shows $shows -Episodes $watched
Assert-Equal 'watched episodes are not requeued' $plan.Rounds[0].Episodes[0].Episode 2
$special = @($episodes | ForEach-Object { $_ | Select-Object * })
$special | Where-Object { $_.Episode -eq 1 } | ForEach-Object { $_.Season = 0 }
$plan = Get-PreviewRounds -Shows $shows -Episodes $special
Assert-Equal 'specials are excluded pending a specials policy' $plan.Rounds[0].Episodes[0].Episode 2
$duplicate = $episodes + $episodes[0]
$plan = Get-PreviewRounds -Shows $shows -Episodes $duplicate
Assert-Equal 'duplicate media versions do not become extra episodes' @($plan.Rounds).Count 3
Write-TestResult -Suite 'playlist-preview'
