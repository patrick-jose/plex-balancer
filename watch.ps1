<#
.SYNOPSIS
    Watches drive free space and runs the balancer when slack appears.

.DESCRIPTION
    Sleeps for a poll interval, checks whether any sink drive has grown past
    its target, and only then shells out to balance.ps1. When every sink is at
    its target it does nothing at all, so an idle system costs one cheap
    DriveInfo read per drive per interval instead of a full library scan.

    It is safe to leave running unattended:
      * balance.ps1 takes a named mutex, so a manual run started while the
        watcher is mid-run simply reports "already in progress" and exits
      * USB drives that are unplugged are skipped, not treated as full
      * every trigger and every balancer result is appended to watcher log

    It also prunes audit logs older than logRetentionDays, since that is the
    one piece of housekeeping that has to happen on every cycle.

.PARAMETER IntervalMinutes
    How long to sleep between checks.

.PARAMETER Once
    Check a single time and exit. Used by the scheduled task, which fires on a
    repeat trigger, and useful for testing.

.EXAMPLE
    .\watch.ps1                 # poll every 15 min until stopped
    .\watch.ps1 -Once           # single check, then exit
    .\watch.ps1 -IntervalMinutes 5 -Once
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$IntervalMinutes = 60,
    [switch]$Once,
    [switch]$DryRun,
    [int]$StartupDelaySeconds = 90,
    [double]$MinSlackGB = 1.0,
    [int]$BalanceTimeoutSeconds = 1800,
    [int]$ReconcileTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.json'
    # See balance.ps1: config.json is not committed, so say so plainly.
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $example = Join-Path $PSScriptRoot 'config.example.json'
        if (Test-Path -LiteralPath $example) {
            throw ("config.json not found. Copy config.example.json to config.json and edit it:  Copy-Item '$example' '$ConfigPath'")
        }
        throw ("config.json not found at {0}, and there is no config.example.json to copy from." -f $ConfigPath)
    }
}
$balancer = Join-Path $PSScriptRoot 'balance.ps1'
$reconciler = Join-Path $PSScriptRoot 'reconcile.ps1'
$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$watchLog = Join-Path $logDir ("watch-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$GB = 1GB

function Write-WatchLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $watchLog -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# Free space a sink should keep once it is full: absolute or percentage.
#
# Tested against $null, not truthiness - the same reasoning and the same fix as
# Get-SinkTargetFree in balance.ps1. "if ($abs)" is false for 0, so a target of
# exactly 0 (which is what D:, F:, G:, H: and J: are set to, to fill completely)
# fell through both branches and reached "return 0.0" by accident. The number was
# right and nothing checked that it was reached on purpose, which is exactly how
# "fill to the brim" turns into "fall back to a default" unnoticed.
function Get-TargetFree {
    param($Cfg, [double]$Total)
    $abs = Get-Prop $Cfg 'targetFreeGB'
    if ($null -ne $abs) { return [double]$abs * $GB }
    $pct = Get-Prop $Cfg 'targetFreePct'
    if ($null -ne $pct) { return $Total * [double]$pct / 100 }
    return 0.0
}

function Test-ShouldRun {
    <#
      Returns the letters of sink drives that have grown above their target.
      A drive that is absent or not ready is reported but never counts as
      slack: an unplugged USB stick must not look like a full disk.
    #>
    param($Cfg, [double]$MinSlackBytes)

    $ready = @()
    $absent = @()
    foreach ($letter in ($Cfg.drives.PSObject.Properties.Name | Sort-Object)) {
        $dc = $Cfg.drives.$letter
        # mirrors balance.ps1: a drive that is both source and sink (K:) still
        # counts as a destination, otherwise the watcher would never notice
        # room appearing there
        if ((Get-Prop $dc 'sources') -and -not (Get-Prop $dc 'alsoSink')) { continue }
        try {
            $d = [System.IO.DriveInfo]::new($letter)
            if (-not $d.IsReady) { $absent += $letter; continue }
            $free = [double]$d.AvailableFreeSpace
            $target = Get-TargetFree -Cfg $dc -Total ([double]$d.TotalSize)
            # Ignore room that rounds to nothing. A drive sitting a few
            # megabytes above its target would otherwise trigger a full run
            # every single cycle for no possible move.
            if (($free - $target) -ge $MinSlackBytes) {
                $ready += [pscustomobject]@{
                    Letter = $letter
                    RoomGB = [math]::Round(($free - $target) / $GB, 1)
                }
            }
        }
        catch { $absent += $letter }
    }
    return [pscustomobject]@{ Slack = $ready; Absent = $absent }
}

# Run a child script under a hard timeout.
#
# This exists because of what happened on 2026-10-03. Calling a child with
# & powershell is synchronous and unbounded: when balance.ps1 blocked on a
# failing disk the watcher never reached its next log line, Task Scheduler kept
# reporting the task as Running, and the next hourly trigger started a second
# watcher that did exactly the same thing. Nothing was left to notice.
#
# Stop-Process rather than a polite stop, because a thread blocked in a disk's
# I/O cannot be asked to stop - it has to be killed.
function Invoke-Child {
    param(
        [string]$Script,
        [string[]]$ScriptArgs = @(),
        [int]$TimeoutSeconds = 1800
    )

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ScriptArgs
    $timedOut = $false
    $exitCode = $null
    $output = @()
    try {
        $p = Start-Process -FilePath 'powershell' -ArgumentList $argList `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
            -NoNewWindow -PassThru
        # Touch .Handle so the Process object keeps a live handle to the child.
        # Start-Process -PassThru otherwise hands back a Process whose handle was
        # never cached, and .ExitCode then stays null for every run - so the one
        # number that says whether the child died was never actually readable, and
        # the "it may have died early" warning could only ever print an empty code.
        [void]$p.Handle
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            Write-WatchLog ("{0} did not finish within {1}s - killing PID {2}" -f (Split-Path $Script -Leaf), $TimeoutSeconds, $p.Id) 'ERROR'
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
            try { [void]$p.WaitForExit(15000) } catch { }
        }
        else { $exitCode = $p.ExitCode }
        $output = @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue)
        $errs = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue)
        if ($errs.Count) { $output += $errs | ForEach-Object { "stderr: $_" } }
    }
    catch { $output += "failed to launch: $($_.Exception.Message)" }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Output = $output; TimedOut = $timedOut; ExitCode = $exitCode }
}

# Is a balancer run already going? balance.ps1 holds this mutex for the whole
# run, so failing to take it means one is in flight. The task fires hourly AND
# at logon, so a second watcher can start while the first is still inside a
# scan - which is exactly what happened at 23:45 on 2026-10-03, 40 minutes after
# the previous run had started and never finished.
$script:MutexHeldHere = $false
function Test-RunInFlight {
    # A Windows mutex is recursive: a thread that already owns it re-acquires it
    # successfully and WaitOne reports success even though a run IS in flight.
    # Nothing here takes the mutex today, but the guard keeps the answer honest
    # if that ever changes, instead of silently reporting "nothing running".
    if ($script:MutexHeldHere) { return $true }

    $m = $null
    try {
        $m = New-Object System.Threading.Mutex($false, 'Global\PlexBalancer')
        $free = $m.WaitOne(0)
        if ($free) { try { $m.ReleaseMutex() } catch { } }
        return (-not $free)
    }
    catch { return $false }
    finally { if ($m) { try { $m.Dispose() } catch { } } }
}

function Invoke-Reconcile {
    if (-not (Test-Path -LiteralPath $reconciler)) { return }
    Write-WatchLog 'checking for interrupted copies from a previous run'
    $r = Invoke-Child -Script $reconciler -ScriptArgs @('-ConfigPath', $ConfigPath, '-Apply') -TimeoutSeconds $ReconcileTimeoutSeconds
    if ($r.TimedOut) { return }
    $line = @($r.Output | Where-Object { "$_" -match 'partials:|Nothing to repair|already in progress' })
    foreach ($l in $line) { Write-WatchLog ("  {0}" -f $l) }
    if (-not $line.Count) { Write-WatchLog '  reconcile produced no summary line - see above' 'WARN' }
}

# Audit logs are append-only and were originally kept forever, so logs\ grew
# without bound. Retention is policy, so the number of days comes from config;
# set it to 0 to keep everything.
#
# Age is read from the date in the filename, not LastWriteTime. A day whose
# watcher stopped running has an old LastWriteTime that nothing refreshes, and
# LastWriteTime would quietly extend a file's life any time something else
# touched it. The name says which day the log belongs to, and that is the day
# the user cares about.
#
# Only the three dated patterns are ever considered. state.json is deliberately
# not one of them: it is live, rewritten by whatever run is in progress, and
# deleting it would strand status.ps1.
# Snapshots and working copies in backup\, on the same clock as the logs.
#
# Age comes from LastWriteTime here rather than from the filename, which is the
# opposite of the rule the logs use. A log is named for the day it belongs to, so
# the name is the truth and a stale mtime is not to be trusted. A backup is named
# whatever the edit that produced it was called - qbt-manager.ps1.bak-queuewin,
# test-dedup.ps1.bak-before-settag - so there is nothing to parse and the mtime is
# the only evidence there is. Using the wrong one of these two rules silently
# keeps everything or deletes everything.
#
# Deliberately recursive and deliberately indiscriminate about the name: everything
# in backup\ is a snapshot by definition. It is not matched against any pattern,
# because the one thing a backup folder must never do is decide some of its
# contents are too important to expire.
function Invoke-BackupPrune {
    # $Path defaults to the project's own backup\ and exists only so the retention
    # suite can point this at a scratch directory. A test that aged files inside
    # the real backup\ would be deleting the user's snapshots as a side effect of
    # checking that it can delete the user's snapshots.
    param($Cfg, [switch]$DryRun, [string]$Path)

    $days = Get-Prop $Cfg 'logRetentionDays'
    if ($null -eq $days -or [int]$days -le 0) { return }

    # $PSScriptRoot is the empty string when this function is lifted out of the file
    # for a test, so with no -Path and no script root there is nothing to prune.
    # Returning quietly is right: a prune that cannot find its folder has not been
    # asked to do anything.
    if (-not $Path -and -not $PSScriptRoot) { return }
    $backupDir = if ($Path) { $Path } else { Join-Path $PSScriptRoot 'backup' }
    if (-not (Test-Path -LiteralPath $backupDir)) { return }

    # Whole days, not instants. The cutoff is truncated to midnight because
    # LastWriteTime carries a time of day: a snapshot written at 09:00 six days ago
    # has to be judged as six days old, and comparing that against "now minus six
    # days" at, say, 14:00 puts it on the wrong side. The log prune never hit this
    # because it compares dates that are already midnight-aligned by construction.
    # Truncating here is what makes "kept for N days" mean the same thing at any
    # hour of the day.
    $cutoff = (Get-Date).Date.AddDays(1 - [int]$days)
    $today = (Get-Date).Date

    # Only files. A subfolder is left alone - recursing into one would delete
    # snapshots of a snapshot set, and nothing puts a folder here on purpose.
    $stale = @(
        foreach ($f in Get-ChildItem -LiteralPath $backupDir -File -Recurse -ErrorAction SilentlyContinue) {
            $age = ($today - $f.LastWriteTime.Date).Days
            if ($age -lt [int]$days) { continue }
            [pscustomobject]@{ File = $f; Days = $age }
        }
    )

    if (-not $stale.Count) { return }

    foreach ($item in $stale) {
        $kb = [math]::Round($item.File.Length / 1KB, 1)
        $name = $item.File.FullName.Substring($backupDir.Length + 1)
        if ($DryRun) {
            Write-WatchLog ("would delete backup {0} ({1} days old, {2} KB)" -f $name, $item.Days, $kb)
            continue
        }
        try {
            Remove-Item -LiteralPath $item.File.FullName -Force -ErrorAction Stop
            Write-WatchLog ("deleted backup {0} ({1} days old, {2} KB)" -f $name, $item.Days, $kb)
        }
        catch { Write-WatchLog ("could not delete backup {0}: {1}" -f $name, $_.Exception.Message) 'ERROR' }
    }
}

function Invoke-LogPrune {
    # $DryRun is declared here rather than left to resolve out of the caller's
    # scope. Read-but-undeclared meant a caller writing -DryRun got no error and
    # no dry run either: PowerShell put the name in $args, $DryRun came back $null,
    # and the function deleted for real. It worked in the watcher only because the
    # script's own -DryRun happened to be in scope at the call site. Declaring it
    # makes the switch mean what it says, and makes a dry run impossible to
    # mistake for the real thing.
    param($Cfg, [switch]$DryRun)

    Invoke-BackupPrune -Cfg $Cfg -DryRun:$DryRun

    $days = Get-Prop $Cfg 'logRetentionDays'
    if ($null -eq $days -or [int]$days -le 0) { return }

    $pattern = '^(moves|watch|reconcile)-(\d{8})\.(jsonl|log)$'
    # AddDays(1 - $days), not AddDays(-$days): a log dated today is kept, so the
    # retention window has to start one day after the oldest day still wanted.
    # With a plain -$days the setting named N actually kept N+1 days' logs - at
    # logRetentionDays 4 a five-day-old log was still on disk, which is one day
    # more than anyone reading the config would expect.
    $cutoff = (Get-Date).Date.AddDays(1 - [int]$days)
    $today = (Get-Date).Date

    # The age has to travel with the file: a bare list of files would lose the
    # date once the pipeline finished, leaving every file reported with the age
    # of whichever one happened to sort last.
    $stale = @(
        foreach ($f in Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue) {
            if ($f.Name -notmatch $pattern) { continue }
            # TryParseExact, not ParseExact: a file named moves-20261301.jsonl has
            # 8 digits but not a real date, and ParseExact would throw and take the
            # whole watcher cycle down over a stray file. The exact format also
            # matters on its own - plain TryParse reads yyyyMMdd culture-ably, so
            # the same file could mean a different day depending on locale. An
            # unparseable name is kept: pruning must never be the thing that breaks.
            $stamp = [datetime]::MinValue
            $styles = [System.Globalization.DateTimeStyles]::None
            if (-not [datetime]::TryParseExact($Matches[2], 'yyyyMMdd', $null, $styles, [ref]$stamp)) { continue }
            if ($stamp -ge $cutoff) { continue }
            [pscustomobject]@{ File = $f; Days = ($today - $stamp).Days }
        }
    )

    if (-not $stale.Count) { return }

    foreach ($item in $stale) {
        $kb = [math]::Round($item.File.Length / 1KB, 1)
        if ($DryRun) {
            Write-WatchLog ("would delete {0} ({1} days old, {2} KB)" -f $item.File.Name, $item.Days, $kb)
            continue
        }
        try {
            Remove-Item -LiteralPath $item.File.FullName -Force -ErrorAction Stop
            Write-WatchLog ("deleted {0} ({1} days old, {2} KB)" -f $item.File.Name, $item.Days, $kb)
        }
        catch { Write-WatchLog ("could not delete {0}: {1}" -f $item.File.Name, $_.Exception.Message) 'ERROR' }
    }
}

function Invoke-Balance {
    param([switch]$WhatIfOnly)

    if (-not (Test-Path -LiteralPath $balancer)) {
        Write-WatchLog "balancer not found at $balancer" 'ERROR'
        return
    }
    $childArgs = @('-ConfigPath', $ConfigPath)
    if (-not $WhatIfOnly) { $childArgs += '-Apply' }

    Write-WatchLog ("running balancer ({0}, timeout {1}s)" -f $(if ($WhatIfOnly) { 'dry run' } else { 'apply' }), $BalanceTimeoutSeconds)
    $r = Invoke-Child -Script $balancer -ScriptArgs $childArgs -TimeoutSeconds $BalanceTimeoutSeconds
    if ($r.TimedOut) {
        Write-WatchLog 'balancer was killed. The run did not finish; anything it had copied is left for reconcile to repair next cycle.' 'ERROR'
        return
    }
    $tail = @($r.Output | Where-Object { $_ -and "$_" -match 'planned:|ALL SINKS|moved:|Warning|Error|not reading' })
    foreach ($l in $tail) { Write-WatchLog ("  {0}" -f $l) }
    if (-not $tail.Count) {
        Write-WatchLog ("  balancer produced no summary line (exit code {0}) - it may have died early" -f $r.ExitCode) 'WARN'
    }
}

# ------------------------------------------------------------------ startup --

# At boot the USB drives are often still settling, and Plex has not finished
# its own start. Waiting avoids reacting to a half-mounted volume.
if ($StartupDelaySeconds -gt 0 -and -not $Once) {
    Write-WatchLog "waiting ${StartupDelaySeconds}s for drives and Plex to settle"
    Start-Sleep -Seconds $StartupDelaySeconds
}

Write-WatchLog ("watcher starting (interval {0} min, mode {1})" -f $IntervalMinutes, $(if ($DryRun) { 'dry run' } else { 'apply' }))

while ($true) {
    try {
        $cfg = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $state = Test-ShouldRun -Cfg $cfg -MinSlackBytes ($MinSlackGB * $GB)

        foreach ($a in $state.Absent) { Write-WatchLog "$a is not ready - ignored this cycle" }
        $slackText = if ($state.Slack.Count) {
            ($state.Slack | ForEach-Object { "$($_.Letter) +$($_.RoomGB)GB" }) -join ', '
        } else { 'none' }
        Write-WatchLog "slack above target: $slackText"

        # Housekeeping runs every cycle, slack or not, so expired logs are
        # cleared on days when the balancer happens to have nothing to do.
        Invoke-LogPrune -Cfg $cfg -DryRun:$DryRun

        # Never stack runs. A run still in progress means the previous cycle did
        # not finish, and starting another alongside it is what turned one hung
        # scan into a pile of them.
        if (Test-RunInFlight) {
            Write-WatchLog 'a balancer run is still in progress - skipping reconcile and balance this cycle' 'WARN'
        }
        else {
            # Always repair first, even when every sink is full: a partial left
            # by a killed run wastes space that a full balancer will not touch.
            Invoke-Reconcile

            if ($state.Slack.Count) { Invoke-Balance -WhatIfOnly:$DryRun }
            else { Write-WatchLog 'every sink is at its target - nothing to do' }
        }
    }
    catch {
        Write-WatchLog "cycle failed: $($_.Exception.Message)" 'ERROR'
    }

    if ($Once) { break }
    Write-WatchLog "sleeping $IntervalMinutes min"
    Start-Sleep -Minutes $IntervalMinutes
}

Write-WatchLog 'watcher exiting'
