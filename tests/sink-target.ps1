# The fill target: how much free space a sink keeps, and what happens at both
# ends of the range.
#
# "How much room does this drive have" is `free - target - copyMarginGB`. The
# target is a floor, not a quota: it is the space that stays free. Getting it
# wrong does not move files somewhere odd, it takes a drive out of the cascade
# silently - a drive below its own target has negative headroom and is never
# offered as a destination.
#
# That is exactly what happened on 2026-10-06. H: was set to targetFreePct 1.0,
# which on its 1863 GB is 18.63 GB reserved, while the drive had 4.45 GB free. It
# refused everything, and the run looked idle with room on the screen.
#
# The zero case is the other end, and it is why this suite exists. PowerShell
# treats 0 as falsy, so "if ($pct)" was false for a target of 0 and the value fell
# through both branches to "return 0" by accident. The answer happened to be
# right - 0 is the intended meaning, "fill to the brim" - but nothing recorded
# that, so a later edit could have turned an explicit 0 into a silent fallback.
# H: and J: both use 0 now.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

. (Lift-Functions -Script 'balance.ps1' -Names @('Get-Prop', 'Get-SinkTargetFree'))

# balance.ps1 defines $GB at script level. A lifted function does not bring it
# with it, so an absolute target multiplies by $null and every GB figure reads as
# 0 - a failure that looks like a broken function rather than a missing variable.
$GB = 1GB

# H: as it is today: 1863 GB, 4,45 GB free. Total is the figure DriveInfo reports
# for the volume, 2000387309568 bytes - not 1863 * 1GB, which is a different
# number and gives the wrong answer to a percentage question.
$hStat = [pscustomobject]@{ Total = 2000387309568; Free = 4777570048 }
# J: the 116 GB stick, effectively full.
$jStat = [pscustomobject]@{ Total = 125000000000; Free = 40000000 }

# Bytes to GB, rounded for comparison.
#
# Written as a helper rather than [math]::Round(x / $GB, 2) inline because an
# unparenthesised static call sitting in a command's argument position is parsed
# in ARGUMENT mode, where the comma builds an array: Round($val / @($GB, 2)),
# i.e. a division by Object[], which throws "op_Division". It reads as though
# the function under test is broken. Parentheses fix it; a helper removes the
# chance of the trap being reintroduced.
function ToGB {
    param([double]$Bytes)
    return [math]::Round($Bytes / $GB, 2)
}

# ---- 1. a percentage target, at both ends of the range ----------------------
Assert-Equal 'pct 0.1 on 1863 GB -> 1,86 GB floor' `
    (ToGB (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{ targetFreePct = 0.1 }) -Stat $hStat)) 1.86
Assert-Equal 'pct 1.0 on 1863 GB -> 18,63 GB, the value that blocked H:' `
    (ToGB (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{ targetFreePct = 1.0 }) -Stat $hStat)) 18.63

# ---- 2. zero is a real setting, not an absent one ---------------------------
# These all return 0. Only the first is intentional: the others are the falsy-0
# bug reappearing, which is why they are asserted separately rather than lumped
# into one "0 comes back" check.
Assert-Equal 'pct 0 -> no floor, fill to the brim' `
    (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{ targetFreePct = 0 }) -Stat $hStat) 0
Assert-Equal 'gb 0 -> no floor either' `
    (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{ targetFreeGB = 0 }) -Stat $jStat) 0
Assert-Equal 'no target at all -> 0, the same fallback' `
    (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{}) -Stat $hStat) 0

# A zero target and a missing one are indistinguishable from the return value
# alone, so the source is what pins the intent: a truthiness test would let 0
# fall through, and only reading the code catches that.
# Comments are stripped before matching: the comment in this very function quotes
# the old "if ($abs)" it replaced, so a search over the raw text matches its own
# explanation of the bug and the assertion passes either way.
$src = (Get-SourceBetween -Script 'balance.ps1' -Start 'function Get-SinkTargetFree' -End 'function Get-LiveFree')
$code = (($src -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Assert-True 'the absolute target is compared against $null' ($code -match '\$null\s+-ne\s+\$abs')
Assert-True 'the percentage target too' ($code -match '\$null\s+-ne\s+\$pct')
Assert-False 'no truthiness test survives on either target' ($code -match 'if\s*\(\s*\$(abs|pct)\s*\)')

# ---- 3. absolute targets ----------------------------------------------------
Assert-Equal 'gb 0.5 -> 0,5 GB floor' `
    (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{ targetFreeGB = 0.5 }) -Stat $jStat) (0.5 * $GB)
Assert-Equal 'gb 2 -> 2 GB floor' `
    (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{ targetFreeGB = 2 }) -Stat $jStat) (2 * $GB)
# targetFreeGB is checked first, so a drive carrying both keys is governed by the
# absolute one. Otherwise a config that sets both would depend on object order.
Assert-Equal 'gb wins when both are set' `
    (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{ targetFreeGB = 0.5; targetFreePct = 10 }) -Stat $hStat) (0.5 * $GB)

# ---- 4. an explicit null is not a value ------------------------------------
Assert-Equal 'null targetFreePct -> no floor' `
    (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{ targetFreePct = $null }) -Stat $hStat) 0
Assert-Equal 'both null -> no floor' `
    (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{ targetFreePct = $null; targetFreeGB = $null }) -Stat $hStat) 0
Assert-Equal 'a null DriveCfg -> no floor' `
    (Get-SinkTargetFree -DriveCfg $null -Stat $hStat) 0

# ---- 5. what the target does to real drives --------------------------------
# The regression that matters: a target above the free space on the drive removes
# it from the cascade while the screen still shows room.
function Get-Headroom {
    param($Cfg, $Stat)
    return $Stat.Free - (Get-SinkTargetFree -DriveCfg $Cfg -Stat $Stat) - (0.2 * $GB)
}

Assert-True 'pct 1.0 -> H: refuses despite 4,45 GB free' `
    ((Get-Headroom -Cfg ([pscustomobject]@{ targetFreePct = 1.0 }) -Stat $hStat) -lt 0)
Assert-True 'pct 0.1 -> H: accepts' `
    ((Get-Headroom -Cfg ([pscustomobject]@{ targetFreePct = 0.1 }) -Stat $hStat) -gt 0)
Assert-True 'pct 0 gives H: the most room of the three' `
    ((Get-Headroom -Cfg ([pscustomobject]@{ targetFreePct = 0 }) -Stat $hStat) -gt
    (Get-Headroom -Cfg ([pscustomobject]@{ targetFreePct = 0.1 }) -Stat $hStat))
# J: at 40 MB free cannot be rescued by any target, which is a physical limit and
# not a setting. Asserted so the distinction stays visible if the numbers change.
Assert-True 'no target makes J: a sink while it is full' `
    ((Get-Headroom -Cfg ([pscustomobject]@{ targetFreeGB = 0 }) -Stat $jStat) -lt 0)

# ---- 6. the watcher's copy of the same rule ---------------------------------
# watch.ps1 decides whether to start a run by asking the same question through a
# second implementation, Get-TargetFree. It carried the identical falsy-zero bug
# and was fixed the same way. Two copies of one rule is the hazard: a fix applied
# to one and not the other leaves the watcher starting runs the balancer then
# refuses, which looks like an idle machine with room on screen.
. (Lift-Functions -Script 'watch.ps1' -Names @('Get-Prop', 'Get-TargetFree'))

Assert-Equal 'watch: pct 0 -> no floor' `
    (Get-TargetFree -Cfg ([pscustomobject]@{ targetFreePct = 0 }) -Total $hStat.Total) 0
Assert-Equal 'watch: gb 0 -> no floor' `
    (Get-TargetFree -Cfg ([pscustomobject]@{ targetFreeGB = 0 }) -Total $jStat.Total) 0
Assert-Equal 'watch: no target -> 0' `
    (Get-TargetFree -Cfg ([pscustomobject]@{}) -Total $hStat.Total) 0.0
Assert-Equal 'watch: pct 0.1 agrees with the balancer' `
    (Get-TargetFree -Cfg ([pscustomobject]@{ targetFreePct = 0.1 }) -Total $hStat.Total) `
    (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{ targetFreePct = 0.1 }) -Stat $hStat)
Assert-Equal 'watch: gb 2 agrees with the balancer' `
    (Get-TargetFree -Cfg ([pscustomobject]@{ targetFreeGB = 2 }) -Total $jStat.Total) `
    (Get-SinkTargetFree -DriveCfg ([pscustomobject]@{ targetFreeGB = 2 }) -Stat $jStat)

$wSrc = Get-SourceBetween -Script 'watch.ps1' -Start 'function Get-TargetFree' -End 'function Test-ShouldRun'
$wCode = (($wSrc -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Assert-True 'watch: compared against $null, not truthiness' ($wCode -match '\$null\s+-ne\s+\$abs')
Assert-False 'watch: no truthiness test survives' ($wCode -match 'if\s*\(\s*\$(abs|pct)\s*\)')

# ---- 7. the rule the config is supposed to encode ---------------------------
# "Keep as little free space as possible" applies to every drive except C: and K:.
# C: is the landing zone and never a sink, so its target is inert by design; K: is
# a real sink and keeps 0.5% on purpose. Asserted against the shipped config
# rather than trusted to a comment that can drift.
$cfgRaw = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'config.json'), [System.Text.Encoding]::UTF8)
$cfg = $cfgRaw | ConvertFrom-Json

foreach ($L in 'D:', 'F:', 'G:', 'H:') {
    Assert-Equal ("{0} fills completely (targetFreePct 0)" -f $L) `
        (Get-Prop $cfg.drives.$L 'targetFreePct') 0
}
Assert-Equal 'J: fills completely (targetFreeGB 0)' `
    (Get-Prop $cfg.drives.'J:' 'targetFreeGB') 0
Assert-Equal 'K: keeps 0.5%, the one sink that holds space back' `
    (Get-Prop $cfg.drives.'K:' 'targetFreePct') 0.5
# C: is the other exception, expressed by ROLE rather than by target: sources
# without alsoSink is skipped by both the balancer and the watcher, so C: can
# never be a destination and its free space is never spent. A target on C: would be
# dead config that reads as though it were doing something.
Assert-True 'C: is not a sink, so it keeps its space by role' `
    (((Get-Prop $cfg.drives.'C:' 'sources')) -and -not ((Get-Prop $cfg.drives.'C:' 'alsoSink')))

Write-TestResult -Suite 'sink-target'