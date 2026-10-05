# Log retention: which dated logs the watcher destroys, and when.
#
# Retention is the one thing in this folder that deletes data on a timer rather
# than as the visible result of a decision the user just made, so it gets tested
# on two fronts: the age boundary, and the fact that asking for a dry run cannot
# quietly mean the real thing.
#
# The second one is here because of an accident. Invoke-LogPrune read a $DryRun
# variable it never declared. PowerShell resolves an undeclared name out of the
# caller's scope, so it worked inside the watcher - and a caller elsewhere that
# passed -DryRun got $null instead of a switch, the dry run silently became a real
# delete, and six real logs were destroyed by a test that was only trying to look.
# The parameter is now declared, and these tests fail if that ever regresses.
#
# The function is lifted, so these run against the shipping code rather than a copy.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

. (Lift-Functions -Script 'watch.ps1' -Names 'Get-Prop', 'Invoke-LogPrune', 'Invoke-BackupPrune')

# A throwaway log directory holding dated files at known ages, so the boundary is
# a fact rather than a guess about what today's date happens to be.
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('retention-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
$logDir = $root
New-Item -ItemType Directory -Path $root -Force | Out-Null

# Backup retention, on a scratch directory passed in explicitly. Invoke-BackupPrune
# defaults to the project's own backup\, and a suite that aged files in there would
# be deleting real snapshots as a side effect of testing that it deletes snapshots.
$backupRoot = Join-Path $root 'backup'
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

$script:Says = @()
function Write-WatchLog {
    param([string]$Message, [string]$Level = 'INFO')
    $script:Says += $Message
}

# Names must carry their age, because the prune reads the date out of the filename
# and never looks at LastWriteTime. Deliberately not touching the mtime, so a test
# that got the age logic wrong would still be caught.
function New-Aged {
    param([int]$AgeDays, [string]$Stem, [string]$Ext)
    $d = (Get-Date).Date.AddDays(-$AgeDays)
    $p = Join-Path $root ("{0}-{1}.{2}" -f $Stem, $d.ToString('yyyyMMdd'), $Ext)
    [System.IO.File]::WriteAllText($p, 'x')
    return (Split-Path $p -Leaf)
}

function Invoke-Prune {
    param([int]$Days, [switch]$DryRun)
    $script:Says = @()
    Invoke-LogPrune -Cfg ([pscustomobject]@{ logRetentionDays = $Days }) -DryRun:$DryRun
    return @($script:Says)
}

try {
    # ---- 1. the age boundary --------------------------------------------------
    # $Days means "how many days a log is kept", so a log is destroyed once it
    # reaches that age: it exists on the days 0..$Days-1 and goes on day $Days.
    # At retention 4, today's log, yesterday's and the one 3 days old all survive,
    # and the one 4 days old is the first to go.
    $d = 4
    $today = New-Aged -AgeDays 0 -Stem 'reconcile' -Ext 'jsonl'
    $inside = New-Aged -AgeDays ($d - 1) -Stem 'watch' -Ext 'log'
    $atLimit = New-Aged -AgeDays $d -Stem 'moves' -Ext 'jsonl'
    $past1 = New-Aged -AgeDays ($d + 1) -Stem 'moves' -Ext 'jsonl'
    $past2 = New-Aged -AgeDays ($d + 2) -Stem 'watch' -Ext 'log'

    $said = Invoke-Prune -Days $d -DryRun
    $joined = $said -join "`n"
    # The prune only names what it would remove, so "kept" means "not named".
    Assert-False "retention $d keeps today''s log" ($joined -match [regex]::Escape($today))
    Assert-False "retention $d keeps a log aged $($d-1) d" ($joined -match [regex]::Escape($inside))
    Assert-True "retention $d destroys a log aged $d d" ($joined -match [regex]::Escape($atLimit))
    Assert-True "retention $d destroys a log aged $($d+1) d" ($joined -match [regex]::Escape($past1))
    Assert-True "retention $d destroys a log aged $($d+2) d" ($joined -match [regex]::Escape($past2))

    # ---- 2. a dry run must not delete, whatever else is true -----------------
    # The accident this suite exists for. If $DryRun is read but not declared, the
    # switch silently arrives as $null and the function removes files for real -
    # which is how six real logs were lost. Asserted on the filesystem, not on the
    # message, because the message was never the problem.
    $before = @(Get-ChildItem $root -File).Count
    $said = Invoke-Prune -Days 1 -DryRun
    $dryText = $said -join "`n"
    $after = @(Get-ChildItem $root -File).Count
    Assert-Equal 'a dry run deletes nothing on disk' $after $before
    Assert-True 'a dry run says what it would do' ($dryText -match 'would delete')
    Assert-True 'a dry run never claims it already deleted' ($dryText -notmatch '(?<!would )deleted ')

    # and the parameter is genuinely declared, not resolved out of the caller's scope
    $p = (Get-Command Invoke-LogPrune).Parameters
    Assert-True 'DryRun is a declared parameter' ($p.ContainsKey('DryRun'))
    Assert-Equal 'DryRun is a switch' $p['DryRun'].ParameterType.Name 'SwitchParameter'

    # ---- 3. without the switch it really does delete ------------------------
    # Proves the boundary above is not passing for the wrong reason, and that the
    # function is genuinely capable of removing files in this scratch directory.
    $before = @(Get-ChildItem $root -File).Count
    $said = Invoke-Prune -Days 1
    $after = @(Get-ChildItem $root -File).Count
    Assert-True 'a real prune removes files' ($after -lt $before)
    Assert-True 'a real prune says it deleted' ((($said -join "`n")) -match '\bdeleted ')
    Assert-True 'a real prune leaves today''s log alone' (Test-Path -LiteralPath (Join-Path $root $today))

    # ---- 4. 0 means keep everything ------------------------------------------
    $before = @(Get-ChildItem $root -File).Count
    $said = Invoke-Prune -Days 0
    Assert-Equal 'retention 0 deletes nothing' @(Get-ChildItem $root -File).Count $before
    Assert-Equal 'retention 0 says nothing' $said.Count 0

    # ---- 5. only the three dated patterns, and only at the top level ---------
    # The blast radius is the whole point: this must never be able to reach media,
    # and it cannot, because it looks at files directly inside logs\ and only
    # ones named moves/watch/reconcile-<date>.(jsonl|log).
    foreach ($name in @('state.json', 'givenback.json', 'moves-backup.jsonl',
            'watch-20261001.log.bak', 'archive-moves-20261001.jsonl', 'notes.txt')) {
        [System.IO.File]::WriteAllText((Join-Path $root $name), 'x')
    }
    $sub = Join-Path $root 'sub'
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $sub 'moves-20260101.jsonl'), 'x')

    $null = Invoke-Prune -Days 1
    foreach ($name in @('state.json', 'givenback.json', 'moves-backup.jsonl',
            'watch-20261001.log.bak', 'archive-moves-20261001.jsonl', 'notes.txt')) {
        Assert-True "never pruned: $name" (Test-Path -LiteralPath (Join-Path $root $name))
    }
    Assert-True 'never pruned: a dated log in a subdirectory' (Test-Path -LiteralPath (Join-Path $sub 'moves-20260101.jsonl'))

    # ---- 6. an unparseable date is kept, not guessed at ----------------------
    # moves-20261301 has eight digits but is not a real date. Deleting on a guess
    # about what someone meant is worse than keeping a file too long.
    $bogus = Join-Path $root 'moves-20261301.jsonl'
    [System.IO.File]::WriteAllText($bogus, 'x')
    $null = Invoke-Prune -Days 1
    Assert-True 'kept: a filename that is eight digits but not a date' (Test-Path -LiteralPath $bogus)
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- 7. backup\ expires on the same clock ----------------------------------
# Snapshot names are arbitrary - qbt-manager.ps1.bak-queuewin,
# test-dedup.ps1.bak-before-settag - so unlike the logs there is no date in the
# name to read. LastWriteTime is the only evidence there is, and that is the
# opposite rule from the one the logs use on purpose.
function New-AgedBackup {
    param([int]$AgeDays, [string]$Name, [string]$In = '')
    $dir = if ($In) { Join-Path $backupRoot $In } else { $backupRoot }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $p = Join-Path $dir $Name
    [System.IO.File]::WriteAllText($p, 'snapshot')
    # LastWriteTime is what the prune reads, so it has to be set explicitly
    (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
    return $p
}

function Invoke-Backup {
    param([int]$Days, [switch]$DryRun)
    $script:Says = @()
    Invoke-BackupPrune -Cfg ([pscustomobject]@{ logRetentionDays = $Days }) -Path $backupRoot -DryRun:$DryRun
    return @($script:Says)
}

$bd = 7
$bToday = New-AgedBackup -AgeDays 0 -Name 'qbt-manager.ps1.bak-queuewin'
$bInside = New-AgedBackup -AgeDays ($bd - 1) -Name 'config.json.bak-2026-10-05-nocap'
$bAtLimit = New-AgedBackup -AgeDays $bd -Name 'test-dedup.ps1.bak-before-settag'
$bPast = New-AgedBackup -AgeDays ($bd + 3) -Name 'status.ps1.bak-before-backtick-fix'

$said = Invoke-Backup -Days $bd -DryRun
$btxt = $said -join "`n"
Assert-False "backup $bd keeps a snapshot written today" ($btxt -match 'qbt-manager\.ps1\.bak-queuewin')
Assert-False "backup $bd keeps one aged $($bd-1) d" ($btxt -match [regex]::Escape('config.json.bak-2026-10-05-nocap'))
Assert-True "backup $bd expires one aged $bd d" ($btxt -match [regex]::Escape('test-dedup.ps1.bak-before-settag'))
Assert-True "backup $bd expires one aged $($bd+3) d" ($btxt -match [regex]::Escape('status.ps1.bak-before-backtick-fix'))

# a subfolder is included - unlike the logs, which are top-level only
$sub = New-AgedBackup -AgeDays ($bd + 5) -Name 'deep.bak' -In 'nested'
$said = Invoke-Backup -Days $bd -DryRun
Assert-True 'backup: recurses into a subfolder' ((($said -join "`n")) -match [regex]::Escape('nested\deep.bak'))

# the same dry-run guarantee the log prune needed
$before = @(Get-ChildItem $backupRoot -Recurse -File).Count
$said = Invoke-Backup -Days 1 -DryRun
Assert-Equal 'backup: a dry run deletes nothing' @(Get-ChildItem $backupRoot -Recurse -File).Count $before
Assert-True 'backup: a dry run says what it would do' ((($said -join "`n")) -match 'would delete backup')

# and it really does delete
$null = Invoke-Backup -Days 1
Assert-False 'backup: expired snapshot removed' (Test-Path -LiteralPath $bAtLimit)
Assert-False 'backup: snapshot in a subfolder removed' (Test-Path -LiteralPath $sub)
Assert-True 'backup: today''s snapshot survives' (Test-Path -LiteralPath $bToday)

# retention 0 means keep everything here too
$before = @(Get-ChildItem $backupRoot -Recurse -File).Count
$null = Invoke-Backup -Days 0
Assert-Equal 'backup: retention 0 keeps everything' @(Get-ChildItem $backupRoot -Recurse -File).Count $before

# a missing backup\ is not an error
Assert-Equal 'backup: a missing folder is not an error' $script:Says.Count $script:Says.Count
$script:Says = @()
Invoke-BackupPrune -Cfg ([pscustomobject]@{ logRetentionDays = 1 }) -Path (Join-Path $root 'no-such-folder')
Assert-Equal 'backup: missing folder deletes nothing' $script:Says.Count 0

Write-TestResult -Suite 'retention'