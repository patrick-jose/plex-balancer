# Test-Shed: the demand gate on the last drive in the chain.
#
# This suite replaces tests\giveback-ledger.ps1, which tested a feature that no
# longer exists. There used to be a "give-back": the last drive in the chain could
# hand a file one step back upstream, on the reasoning that a full parking lot
# should return space rather than freeze it. A ledger recorded every give-back so
# the same file would not be handed straight back in on the next run.
#
# Both halves are gone. Backwards moves are now refused outright (Test-Forward),
# so there is no give-back to record and the ledger had no writer left - it was
# read every run, pruned every run, and documented as a protection that no longer
# existed. On 2026-10-06 the give-back had already done the opposite of its
# purpose: F: and G: traded the same three files back and forth across runs, each
# copy paid for in full and undone an hour later, and the last leg left three files
# stranded on a full F: that could reach neither G: (refused) nor H:/J: (full).
#
# What survives is the demand gate, and it is a genuinely different rule: the end
# of the chain accepts from its neighbour only when that neighbour has something
# actually waiting for room. It restricts receiving; it can never grant a move
# that Test-Forward refused. That distinction is the point of this suite - a gate
# that can add permissions is not a gate.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

. (Lift-Functions -Script 'balance.ps1' -Names @('Test-Forward', 'Test-Shed'))

# Drive objects mirroring config.json: C:1 K:2 D:3 F:4 G:5, and H:/J: with no
# priority at all, which is what puts them outside the chain.
function New-D {
    param([string]$Letter, $Priority)
    $inChain = ($null -ne $Priority)
    [pscustomobject]@{
        Letter    = $Letter
        Priority  = if ($inChain) { [int]$Priority } else { 99 }
        InCascade = $inChain
        IsLast    = ($inChain -and [int]$Priority -eq 5)
    }
}

$D = @{}
foreach ($p in @(@('C:', 1), @('K:', 2), @('D:', 3), @('F:', 4), @('G:', 5), @('H:', $null), @('J:', $null))) {
    $D[$p[0]] = New-D -Letter $p[0] -Priority $p[1]
}

# ---- 1. the ledger parameter is gone -----------------------------------------
# Test-Shed used to take -UnitKey and consult the give-back ledger. Read out of the
# source rather than called, because calling it with a parameter the function no
# longer declares would fail for the wrong reason and could pass a -ErrorAction
# that swallowed it.
$src = Get-SourceBetween -Script 'balance.ps1' -Start 'function Test-Shed' -End 'ZZZ-NOT-THERE'
Assert-True 'Test-Shed was found to read at all' ($src -match 'function Test-Shed')
Assert-True 'Test-Shed no longer takes a UnitKey' ($src -notmatch '\$UnitKey')
Assert-True 'Test-Shed no longer reads the give-back ledger' ($src -notmatch 'GivenBack')

# The ledger functions are gone from the file, not merely unused. Read straight
# from the source rather than through Get-SourceBetween: that helper returns the
# whole file when its Start anchor is absent, which would make this pass for the
# wrong reason - it would find no match only because it had read everything.
$balanceSrc = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'balance.ps1'), [System.Text.Encoding]::UTF8)
Assert-False 'Save-GivenBackLedger is gone from balance.ps1' ($balanceSrc -match 'function\s+Save-GivenBackLedger')
Assert-False 'Read-GivenBackLedger is gone from balance.ps1' ($balanceSrc -match 'function\s+Read-GivenBackLedger')
Assert-False 'nothing writes a give-back entry any more' ($balanceSrc -match '\$script:GivenBack')

# ---- 2. the gate blocks the last drive when nothing is waiting ----------------
$candidates = @('D:', 'F:', 'K:', 'H:', 'J:', 'G:')
$noDemand = @($candidates | Where-Object { Test-Shed -From $D['F:'] -To $D[$_] -Demand @{} })
Assert-True 'F: -> G: blocked while nothing waits on F:' ('G:' -notin $noDemand)

# Every other destination from F: stays open, so the gate narrows one route rather
# than shutting F: down.
foreach ($open in @('H:', 'J:')) {
    Assert-True ("F: -> {0} is unaffected by the gate" -f $open) ($open -in $noDemand)
}

# ---- 3. the gate opens when the neighbour has real demand --------------------
$withDemand = @($candidates | Where-Object { Test-Shed -From $D['F:'] -To $D[$_] -Demand @{ 'F:' = 3 } })
Assert-True 'F: -> G: allowed when F: is waiting for room' ('G:' -in $withDemand)

# One unit of demand is enough - the gate asks whether anything is waiting, not
# for a threshold. A count of zero must behave exactly like an absent key.
Assert-True 'a demand count of zero does not open the gate' `
    (-not (Test-Shed -From $D['F:'] -To $D['G:'] -Demand @{ 'F:' = 0 }))
Assert-True 'demand on a different drive does not open the gate' `
    (-not (Test-Shed -From $D['F:'] -To $D['G:'] -Demand @{ 'D:' = 5 }))
# $Demand is read through -and -not ContainsKey, so a null set has to behave like
# an empty one rather than throwing under StrictMode.
Assert-False 'a null demand set does not throw and keeps the gate shut' `
    (Test-Shed -From $D['F:'] -To $D['G:'] -Demand $null)

# ---- 4. the gate cannot grant a move the direction check refused -------------
# The regression that matters most. This is the exact ping-pong: G: is the last
# drive, F: is one step behind it, and no amount of waiting may put that route
# back. Asserted with demand set absurdly high so a gate that added permissions
# rather than removing them would pass it.
$big = @{ 'G:' = 9999 }
Assert-False 'G: -> F: refused even with huge demand on G:' (Test-Shed -From $D['G:'] -To $D['F:'] -Demand $big)
Assert-False 'G: -> D: refused even with huge demand on G:' (Test-Shed -From $D['G:'] -To $D['D:'] -Demand $big)
Assert-False 'G: -> K: refused even with huge demand on G:' (Test-Shed -From $D['G:'] -To $D['K:'] -Demand $big)
Assert-False 'F: -> D: refused even with huge demand on F:' (Test-Shed -From $D['F:'] -To $D['D:'] -Demand @{ 'F:' = 9999 })

# And the routes G: legitimately has stay open under the same pressure.
Assert-True 'G: -> H: still open under pressure' (Test-Shed -From $D['G:'] -To $D['H:'] -Demand $big)
Assert-True 'G: -> J: still open under pressure' (Test-Shed -From $D['G:'] -To $D['J:'] -Demand $big)

# ---- 5. drives outside the chain are never gated ------------------------------
# H: and J: declare no priority. They are not links in the chain, so the gate has
# nothing to say about them and no demand figure should change that.
foreach ($out in @('H:', 'J:')) {
    Assert-True ("{0} accepts from G: with no demand at all" -f $out) (Test-Shed -From $D['G:'] -To $D[$out] -Demand @{})
}

# ---- 6. a source outside the chain is unrestricted ---------------------------
# A drive with no position of its own has nothing to compare against, so every
# direction is permitted. This is also why H: can reach F: and G:, which is the
# one place the implemented chain differs from the stated rule "H: -> J:".
$loose = New-D -Letter 'Z:' -Priority $null
Assert-True 'no priority on the source -> unrestricted towards the chain end' (Test-Shed -From $loose -To $D['G:'] -Demand @{})
Assert-True 'no priority on the source -> unrestricted towards a mid drive' (Test-Shed -From $loose -To $D['D:'] -Demand @{})

Write-TestResult -Suite 'shed-gate'