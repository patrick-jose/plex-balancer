# Which directions the cascade allows. This is the rule that decides where a file
# lands, and getting it wrong is silent: files just move to the wrong drive and
# nothing reports an error.
#
# The bug this suite exists for: the end of the chain used to be derived from
# whichever drives happened to be sources or sinks on a given run. When F: was
# in neither list the maximum collapsed to G:'s priority, G: was crowned parking
# lot, and G: content was moved BACKWARDS to D: - four files in one apply run on
# 2026-10-04, planned on every run since 2026-10-03 16:05.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

# The real config is not committed - it names drive letters and library paths that
# are specific to one machine. So this prefers the local one when it exists, which
# is what actually runs here, and falls back to the committed example so a fresh
# clone can still run the suite instead of failing on a missing file. The cascade
# rules are read out of the config, so this has to have a config either way.
$cfgPath = Join-Path $script:TestRoot 'config.json'
if (-not (Test-Path -LiteralPath $cfgPath)) {
    $cfgPath = Join-Path $script:TestRoot 'config.example.json'
    Write-Host 'config.json not found - testing against config.example.json'
}
$cfg = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json

. (Lift-Functions -Script 'balance.ps1' -Names @('Get-Prop', 'Test-Forward', 'Test-Shed'))
''
$script:GivenBack = @{}

# Rebuild the drive objects exactly as balance.ps1 does, then apply the IsLast
# marking from the NEW config-derived chainMax. Priority 99 / InCascade false is
# what a drive with no declared priority looks like.
function New-Drive($letter) {
    $dc = $cfg.drives.$letter
    $prio = Get-Prop $dc 'priority'
    [pscustomobject]@{
        Letter    = $letter
        Priority  = if ($null -ne $prio) { [int]$prio } else { 99 }
        InCascade = ($null -ne $prio)
    }
}

function Set-IsLast($list) {
    $chainMax = 0
    $found = $false
    foreach ($dp in $cfg.drives.PSObject.Properties) {
        $dprio = Get-Prop $dp.Value 'priority'
        if ($null -eq $dprio) { continue }
        $found = $true
        if ([int]$dprio -gt $chainMax) { $chainMax = [int]$dprio }
    }
    foreach ($x in $list) {
        $x | Add-Member -NotePropertyName IsLast `
            -NotePropertyValue ($found -and $x.InCascade -and $x.Priority -eq $chainMax) -Force
    }
    return $chainMax
}

$all = @('C:', 'K:', 'D:', 'G:', 'F:', 'H:', 'J:') | ForEach-Object { New-Drive $_ }

# ---- 1. the parking lot must not slide when F: is absent ---------------------
# The failure state: F: had no headroom and sources:false, so the old code saw
# only C: K: D: G: and crowned G: as the chain end.
$withoutF = @($all | Where-Object { $_.Letter -ne 'F:' } | ForEach-Object { $_ | Select-Object * })
$gAbsent = @($withoutF | Where-Object { $_.Letter -eq 'G:' })[0]
$maxAbsent = Set-IsLast $withoutF
Assert-False "F: absent -> G: is not the parking lot" $gAbsent.IsLast
Assert-Equal  "F: absent -> chainMax still 5 (was 4)" $maxAbsent 5

# ---- 2. when F: is present it owns the role ---------------------------------
Set-IsLast $all | Out-Null
$byLetter = @{}
foreach ($d in $all) { $byLetter[$d.Letter] = $d }
Assert-True  "F: present -> F: is the parking lot" $byLetter['F:'].IsLast
Assert-False "F: present -> G: is not" $byLetter['G:'].IsLast

# ---- 3. the direction matrix -----------------------------------------------
# Read off the cascade diagram in COMMANDS.md: C:1 -> K:2 -> D:3 -> G:4 -> F:5,
# and F: may give back exactly one step. H: and J: declare no priority, so they
# sit outside the chain and every source may reach them.
$cases = @(
    @{ f = 'C:'; t = 'D:'; want = $true;  why = 'forward' }
    @{ f = 'C:'; t = 'K:'; want = $true;  why = 'forward' }
    @{ f = 'C:'; t = 'F:'; want = $true;  why = 'forward' }
    @{ f = 'K:'; t = 'D:'; want = $true;  why = 'forward' }
    @{ f = 'D:'; t = 'G:'; want = $true;  why = 'forward' }
    @{ f = 'D:'; t = 'F:'; want = $true;  why = 'forward' }
    @{ f = 'G:'; t = 'F:'; want = $true;  why = 'forward' }
    @{ f = 'G:'; t = 'D:'; want = $false; why = 'BACKWARDS - the bug' }
    @{ f = 'G:'; t = 'K:'; want = $false; why = 'backwards' }
    @{ f = 'D:'; t = 'K:'; want = $false; why = 'backwards' }
    @{ f = 'K:'; t = 'C:'; want = $false; why = 'backwards' }
    @{ f = 'K:'; t = 'G:'; want = $true;  why = 'forward' }
    @{ f = 'F:'; t = 'D:'; want = $false; why = 'give back only ONE step' }
    @{ f = 'F:'; t = 'C:'; want = $false; why = 'two steps back' }
    @{ f = 'C:'; t = 'H:'; want = $true;  why = 'no priority, outside the chain' }
    @{ f = 'G:'; t = 'J:'; want = $true;  why = 'no priority, outside the chain' }
)
foreach ($c in $cases) {
    Assert-Equal ("{0} -> {1}  ({2})" -f $c.f, $c.t, $c.why) `
        (Test-Forward -From $byLetter[$c.f] -To $byLetter[$c.t]) $c.want
}

# ---- 4. the parking-lot gates ----------------------------------------------
# The demand gate guards the parking lot as a RECEIVER, not as a sender: F: only
# accepts from G: when something is actually waiting for room on G:. Without it G:
# would spend every run relocating its own library into a drive that gives
# nothing back. F: -> G: (giving back) is allowed by Test-Forward alone.
$candidates = @('D:', 'G:', 'K:', 'H:', 'J:', 'F:')

$noDemand = @($candidates | Where-Object { Test-Shed -From $byLetter['G:'] -To $byLetter[$_] -Demand @{} })
Assert-True  "G: -> F: blocked while nothing waits on G:" ('F:' -notin $noDemand)

$withDemand = @($candidates | Where-Object { Test-Shed -From $byLetter['G:'] -To $byLetter[$_] -Demand @{ 'G:' = 3 } })
Assert-True  "G: -> F: allowed when G: is waiting for room" ('F:' -in $withDemand)

$giveBack = @($candidates | Where-Object { Test-Shed -From $byLetter['F:'] -To $byLetter[$_] -Demand @{} })
Assert-True  "F: -> G: give-back permitted" ('G:' -in $giveBack)
Assert-True  "F: -> D: give-back cannot skip a step" ('D:' -notin $giveBack)

# ---- 5. a drive with no priority stays unrestricted -------------------------
$loose = New-Drive 'Z:'
Assert-True "no priority on the source -> unrestricted" (Test-Forward -From $loose -To $byLetter['C:'])

Write-TestResult -Suite 'cascade-direction'
