# The give-back ledger: does it do its job, and does it fail safe?
#
# The parking lot may hand content back one step so the space stays in
# circulation. Nothing recorded that, so the next run saw the same unit one step
# upstream with room in front of it and returned it: F: -> G: -> F: on a single
# file, six times, an hour apart, every copy paid for in full and undone an hour
# later.
#
# The most important property is not the happy path, it is the failure path. A
# missing, corrupt or unwritable ledger must degrade to an empty one - which is
# exactly the old behaviour - and must never be able to stop a move.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

. (Lift-Functions -Script 'balance.ps1' -Names @('Test-Forward', 'Test-Shed', 'Read-GivenBackLedger', 'Save-GivenBackLedger'))
''

$tmp = Join-Path $env:TEMP ('gbledger-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# drive objects mirroring the configured cascade
$D = @{}
foreach ($p in @(@('C:', 1), @('K:', 2), @('D:', 3), @('G:', 4), @('F:', 5), @('H:', $null), @('J:', $null))) {
    $D[$p[0]] = [pscustomobject]@{
        Letter = $p[0]
        Priority = if ($null -ne $p[1]) { [int]$p[1] } else { 99 }
        InCascade = ($null -ne $p[1])
        IsLast = ($p[1] -eq 5)
    }
}

$fresh = (Get-Date).ToUniversalTime().ToString('o')
$stale = (Get-Date).ToUniversalTime().AddDays(-30).ToString('o')
$key = 'Filmes|Some Movie (2016) 720p HDTV HEVC x265.mkv'
$demand = @{ 'G:' = 3 }
$script:GivenBack = @{}

# ---- 1. fail-safe: unusable ledgers read as empty ----------------------------
$l = Read-GivenBackLedger -Path (Join-Path $tmp 'does-not-exist.json') -MaxAgeDays 7
Assert-Equal 'missing ledger reads as empty' $l.Count 0

$corrupt = Join-Path $tmp 'corrupt.json'
[System.IO.File]::WriteAllText($corrupt, '{ this is not json at all', [System.Text.Encoding]::UTF8)
Assert-Equal 'corrupt ledger reads as empty' (Read-GivenBackLedger -Path $corrupt -MaxAgeDays 7).Count 0

$blank = Join-Path $tmp 'blank.json'
[System.IO.File]::WriteAllText($blank, '', [System.Text.Encoding]::UTF8)
Assert-Equal 'blank ledger reads as empty' (Read-GivenBackLedger -Path $blank -MaxAgeDays 7).Count 0

# ---- 2. round trip ----------------------------------------------------------
$save = Join-Path $tmp 'ledger.json'
Save-GivenBackLedger -Path $save -Ledger @{ 'Filmes|A.mkv' = $fresh; 'Series|B.mkv' = $fresh }
$l = Read-GivenBackLedger -Path $save -MaxAgeDays 7
Assert-Equal 'round trip keeps both entries'  $l.Count 2
Assert-True  'round trip keeps the key'       $l.ContainsKey('Filmes|A.mkv')
Assert-Equal 'round trip keeps the timestamp' $l['Filmes|A.mkv'] $fresh
Assert-False 'no .tmp left behind'           (Test-Path "$save.tmp")

# ---- 3. self-pruning --------------------------------------------------------
# Timestamps are UTC round-trip, which sorts correctly as text, so ageing out
# needs no date parsing and is immune to locale.
Save-GivenBackLedger -Path $save -Ledger @{ 'Filmes|Fresh.mkv' = $fresh; 'Filmes|Stale.mkv' = $stale }
$l = Read-GivenBackLedger -Path $save -MaxAgeDays 7
Assert-True  'fresh entry survives'         $l.ContainsKey('Filmes|Fresh.mkv')
Assert-False '30-day-old entry is dropped'  $l.ContainsKey('Filmes|Stale.mkv')
Assert-Equal 'only the fresh one remains'   $l.Count 1

# ---- 4. the parking lot refuses a recorded unit -----------------------------
$script:GivenBack = @{ $key = $fresh }
Assert-False 'recorded unit refused by the parking lot' `
    (Test-Shed -From $D['G:'] -To $D['F:'] -Demand $demand -UnitKey $key)
Assert-True  'unrecorded unit still allowed by it' `
    (Test-Shed -From $D['G:'] -To $D['F:'] -Demand $demand -UnitKey 'Filmes|Another file.mkv')

# ---- 5. the ledger must not leak into unrelated decisions -------------------
Assert-True 'recorded unit still reaches non-parking-lot sinks' `
    (Test-Shed -From $D['G:'] -To $D['J:'] -Demand @{} -UnitKey $key)
Assert-True 'no UnitKey behaves exactly as before' `
    (Test-Shed -From $D['G:'] -To $D['F:'] -Demand $demand)
$script:GivenBack = @{}
Assert-True 'an empty ledger blocks nothing' `
    (Test-Shed -From $D['G:'] -To $D['F:'] -Demand $demand -UnitKey $key)

# ---- 6. the give-back itself is untouched -----------------------------------
Assert-True 'F: can still give back to G:' `
    (Test-Shed -From $D['F:'] -To $D['G:'] -Demand @{} -UnitKey $key)

# ---- 7. a bad destination path must not throw -------------------------------
$rooted = Join-Path (Join-Path $tmp 'no-such-dir') 'ledger.json'
Save-GivenBackLedger -Path $rooted -Ledger @{ 'Filmes|A.mkv' = $fresh }
Assert-False 'unwritable ledger leaves no .tmp behind' (Test-Path "$rooted.tmp")

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-TestResult -Suite 'giveback-ledger'
