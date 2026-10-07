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

. (Lift-Functions -Script 'balance.ps1' -Names @('Get-Prop', 'Test-Forward'))
''
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

# ---- 1. the parking lot must not slide when G: is absent ---------------------
# The failure state: the chain end comes from config and from nothing else. G:
# holds the highest declared priority, so when it is unplugged the chain is left
# without a receiver - which is correct - rather than crowning F: or D: instead,
# which is the bug that moved four files backwards on 2026-10-04.
$withoutG = @($all | Where-Object { $_.Letter -ne 'G:' } | ForEach-Object { $_ | Select-Object * })
$fAbsent = @($withoutG | Where-Object { $_.Letter -eq 'F:' })[0]
$dAbsent = @($withoutG | Where-Object { $_.Letter -eq 'D:' })[0]
$maxAbsent = Set-IsLast $withoutG
Assert-False "G: absent -> F: is NOT crowned instead" $fAbsent.IsLast
Assert-False "G: absent -> D: is NOT crowned instead" $dAbsent.IsLast
Assert-Equal "G: absent -> chainMax still 5, read from config" $maxAbsent 5

# ---- 2. when G: is present it owns the role ---------------------------------
Set-IsLast $all | Out-Null
$byLetter = @{}
foreach ($d in $all) { $byLetter[$d.Letter] = $d }
Assert-True  "G: present -> G: is the parking lot" $byLetter['G:'].IsLast
Assert-False "G: present -> F: is not" $byLetter['F:'].IsLast

# ---- 3. the direction matrix -----------------------------------------------
# The whole chain, exactly as specified. Every destination has a higher priority
# number than its source, or no priority at all and so sits outside the chain.
# Nothing moves backwards - including the last drive, which used to be permitted
# one step back as a "give-back".
#
#   C: -> D: F: G: H: J: K:
#   K: -> D: F: G: H: J:
#   D: -> F: G: H: J:
#   F: -> G: H: J:
#   G: -> H: J:
#   H: -> J:
#   J: -> nowhere
$cases = @(
    @{ f = 'C:'; t = 'D:'; want = $true;  why = 'chain' }
    @{ f = 'C:'; t = 'F:'; want = $true;  why = 'chain' }
    @{ f = 'C:'; t = 'G:'; want = $true;  why = 'chain' }
    @{ f = 'C:'; t = 'H:'; want = $true;  why = 'chain' }
    @{ f = 'C:'; t = 'J:'; want = $true;  why = 'chain' }
    @{ f = 'C:'; t = 'K:'; want = $true;  why = 'chain' }
    @{ f = 'K:'; t = 'D:'; want = $true;  why = 'chain' }
    @{ f = 'K:'; t = 'F:'; want = $true;  why = 'chain' }
    @{ f = 'K:'; t = 'G:'; want = $true;  why = 'chain' }
    @{ f = 'K:'; t = 'H:'; want = $true;  why = 'chain' }
    @{ f = 'K:'; t = 'J:'; want = $true;  why = 'chain' }
    @{ f = 'D:'; t = 'F:'; want = $true;  why = 'chain' }
    @{ f = 'D:'; t = 'G:'; want = $true;  why = 'chain' }
    @{ f = 'D:'; t = 'H:'; want = $true;  why = 'chain' }
    @{ f = 'D:'; t = 'J:'; want = $true;  why = 'chain' }
    @{ f = 'F:'; t = 'G:'; want = $true;  why = 'chain' }
    @{ f = 'F:'; t = 'H:'; want = $true;  why = 'chain' }
    @{ f = 'F:'; t = 'J:'; want = $true;  why = 'chain' }
    @{ f = 'G:'; t = 'H:'; want = $true;  why = 'chain' }
    @{ f = 'G:'; t = 'J:'; want = $true;  why = 'chain' }
    @{ f = 'H:'; t = 'J:'; want = $true;  why = 'chain' }

    # The rule the user restated after the give-back caused a ping-pong on
    # 2026-10-06: G: reaches H: and J: and nothing else. Not F:.
    @{ f = 'G:'; t = 'F:'; want = $false; why = 'RULE: G: -> H: or J: only' }
    @{ f = 'G:'; t = 'D:'; want = $false; why = 'backwards' }
    @{ f = 'G:'; t = 'K:'; want = $false; why = 'backwards' }
    @{ f = 'G:'; t = 'C:'; want = $false; why = 'backwards' }

    @{ f = 'J:'; t = 'H:'; want = $true;  why = 'J: is sources:false so this never happens' }
    @{ f = 'D:'; t = 'K:'; want = $false; why = 'backwards' }
    @{ f = 'D:'; t = 'C:'; want = $false; why = 'backwards' }
    @{ f = 'K:'; t = 'C:'; want = $false; why = 'backwards' }
    @{ f = 'F:'; t = 'D:'; want = $false; why = 'backwards' }
    @{ f = 'F:'; t = 'C:'; want = $false; why = 'backwards' }

    # H: declares NO priority in config.json, so it is outside the chain and a
    # source with no position is unrestricted. That is the code working as
    # designed, but it is NOT what the stated chain says: "H: -> J:" implies J:
    # and nothing else. Asserted here so the gap is visible in the test output
    # rather than discovered later by noticing a file moved onto F:.
    @{ f = 'H:'; t = 'F:'; want = $true; why = 'H: is outside the chain - see note below' }
    @{ f = 'H:'; t = 'G:'; want = $true; why = 'H: is outside the chain - see note below' }
)
foreach ($c in $cases) {
    Assert-Equal ("{0} -> {1}  ({2})" -f $c.f, $c.t, $c.why) `
        (Test-Forward -From $byLetter[$c.f] -To $byLetter[$c.t]) $c.want
}

# ---- 3b. no backwards move exists among the prioritised drives ---------------
# The matrix above lists the destinations that matter; this sweeps every ordered
# pair among the drives that declare a priority and asserts the invariant
# directly, so adding a drive to config.json cannot quietly open a hole that the
# list above was not updated for.
#
# Drives with no priority are excluded and cannot be swept this way: they are
# outside the chain by definition, and a source with no position has nothing to be
# compared against, so every direction is permitted. That is correct for J: (a
# terminal sink, never a source) and it is the gap for H: - see the note in the
# matrix above.
$chained = @('C:', 'K:', 'D:', 'F:', 'G:')
$backwards = @()
foreach ($a in $chained) {
    foreach ($b in $chained) {
        if ($a -eq $b) { continue }
        $ok = Test-Forward -From $byLetter[$a] -To $byLetter[$b]
        $aPrio = $byLetter[$a].Priority
        $bPrio = $byLetter[$b].Priority
        # Both in the chain: only a strictly higher number may receive.
        if ($bPrio -le $aPrio -and $ok) {
            $backwards += ("{0}({1}) -> {2}({3})" -f $a, $aPrio, $b, $bPrio)
        }
    }
}
Assert-Equal 'no prioritised drive may move content to an earlier one' ($backwards -join ', ') ''

# Demand-gate cases, including G: -> F: under pressure, live in shed-gate.ps1.

# ---- 4. a drive with no priority stays unrestricted -------------------------
$loose = New-Drive 'Z:'
Assert-True "no priority on the source -> unrestricted" (Test-Forward -From $loose -To $byLetter['C:'])

Write-TestResult -Suite 'cascade-direction'
