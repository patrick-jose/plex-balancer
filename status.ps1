<#
.SYNOPSIS
    Live view of what the balancer is doing right now.

.DESCRIPTION
    Reads the state file that balance.ps1 rewrites on every move, so you can
    see progress from a second window without attaching to the console that is
    doing the work. Also shows the scheduled task, drive status, and the tail
    of the audit log.

    The RECENT ACTIVITY table shows which drive each file came from and which
    drive it went to, e.g. "C: -> D:". Rows that name only one side show half
    an arrow: "K:" for a source-only problem, "-> D:" for a destination-only
    one. SIZE is what the row actually moved; a "-" means the row never
    recorded one, which is the case for every failure and skip. NEXT RUN is when
    the balancer will next pick that work up, read from the scheduled task
    rather than guessed, and it appears only on rows still waiting to happen. A
    "-" means the work is not scheduled - either it already happened, or it was
    a skip that will be skipped again, or no future run is registered.

    Refreshes itself until you close it or press Ctrl+C.

.PARAMETER Watch
    Keep refreshing every few seconds. Without it, prints one snapshot.

.EXAMPLE
    .\status.ps1           # one snapshot
    .\status.ps1 -Watch    # live, refreshing
    .\status.ps1 -Tail 30  # more log history
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Watch,
    [int]$Tail = 12,
    [int]$RefreshSeconds = 30
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
$cfg = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$GB = 1GB
$logDir = if ($cfg.logDir) { Join-Path $PSScriptRoot $cfg.logDir } else { $PSScriptRoot }
$stateFile = Join-Path $logDir 'state.json'
$taskName = 'PlexStorageBalancer'

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# ---- failing disks, reported only when they are actually costing something ---
#
# balance.ps1 refuses to read a drive whose disk is logging hardware errors, and
# narrates that in the run log every hour. Both halves of that sentence matter. In
# the log it is correct and it is exactly what you want when reading an incident
# back. In a status display it is noise: a sink drive whose reads are skipped has
# lost nothing, because the balancer still writes to it and nothing on it was ever
# going to move. Repeating that hourly teaches you to scroll past it, which is the
# worst outcome available - it is also what a genuinely broken drive looks like.
#
# So the three questions below are separated. What is failing is Get-FailingDrive.
# Whether that costs anything is Get-DriveAlert. Only the second one is displayed.

# Disk number out of a Windows storage error message, or $null if it names no disk.
# 153/154 say "Disco 4" on a Portuguese system and "Disk 4" on an English one; 51
# names the device, "\Device\Harddisk3\DR3", which reads the same in any locale.
# Event ID 153 is also used by unrelated subsystems - VBS status, the display
# driver - so a message that names no disk is ignored rather than guessed at.
function Get-DiskFromMessage {
    param([string]$Message)
    if (-not $Message) { return $null }
    if ($Message -match 'Dis[ck]o?\s+(\d+)') { return [int]$Matches[1] }
    if ($Message -match 'Harddisk(\d+)\\DR') { return [int]$Matches[1] }
    return $null
}

# Physical disk number -> how many errors it logged. Takes the events as an
# argument rather than reading the log itself, so the parsing can be tested
# against real wording on a machine where nothing is actually failing.
function Get-FailingDiskMap {
    param($Events)
    $byDisk = @{}
    foreach ($e in @($Events)) {
        if ($null -eq $e) { continue }
        $num = Get-DiskFromMessage (Get-Prop $e 'Message')
        if ($null -eq $num) { continue }
        if ($byDisk.ContainsKey($num)) { $byDisk[$num]++ } else { $byDisk[$num] = 1 }
    }
    return $byDisk
}

# Drive letter -> the failing disk it sits on, for balancer drives only. Errors
# on a disk that holds none of the configured drives are not the balancer's
# business and are not reported.
function Get-FailingDrive {
    param($Cfg)
    $drives = Get-Prop $Cfg 'drives'
    if ($null -eq $drives) { return @{} }

    $window = Get-Prop $Cfg 'driveErrorWindowHours'
    if (-not $window) { $window = 24 }
    $since = (Get-Date).AddHours(-[int]$window)
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 51, 153, 154, 157
                StartTime = $since } -MaxEvents 200 -ErrorAction SilentlyContinue)
    $byDisk = Get-FailingDiskMap -Events $events
    if (-not $byDisk.Count) { return @{} }

    # Looked up by disk number rather than per drive letter: two calls when two
    # disks are failing, instead of one for every drive in the config.
    $out = @{}
    foreach ($diskNo in @($byDisk.Keys)) {
        $parts = @(Get-Partition -DiskNumber $diskNo -ErrorAction SilentlyContinue |
                Where-Object { $_ -and $_.DriveLetter })
        foreach ($part in $parts) {
            $letter = "$($part.DriveLetter):"
            if ($null -eq (Get-Prop $drives $letter)) { continue }
            $out[$letter] = [pscustomobject]@{ Disk = $diskNo; Errors = $byDisk[$diskNo] }
        }
    }
    return $out
}

# What a failing disk is actually costing on this drive, or $null when it is
# costing nothing. Two things count, and both are moves:
#   - the drive is a source, so nothing on it can move while its reads are blocked
#   - a move touching it failed, which is the drive making the decision for us
# A drive that is only ever a destination is silent: skipping its reads changes
# nothing about where files end up.
function Get-DriveAlert {
    param([string]$Letter, $Cfg, $Failing, $Failures)
    $info = Get-Prop $Failing $Letter
    if ($null -eq $info) { return $null }

    $bits = @()
    if (Get-Prop (Get-Prop (Get-Prop $Cfg 'drives') $Letter) 'sources') {
        $bits += 'reads blocked, content cannot move off'
    }

    $here = @(@($Failures) | Where-Object {
            $route = Get-Route $_
            $route -and ($route -match [regex]::Escape($Letter))
        })
    if ($here.Count) { $bits += ('{0} move(s) failed here today' -f $here.Count) }

    if (-not $bits.Count) { return $null }
    return ('disk {0} failing, {1} I/O error(s) in {2}h - {3}' -f
        $info.Disk, $info.Errors, (Get-Prop $Cfg 'driveErrorWindowHours'), ($bits -join '; '))
}

# A run that overran its deadline or died before it could say anything. The
# watchdog kills a child that runs too long; a child that exits without a summary
# line is the same failure seen from the far side. Neither shows up in
# LastTaskResult, because the watcher carries on afterwards and exits 0 either way,
# which is why this has to be read out of the watcher log.
function Get-WatcherTrouble {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $hit = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue |
            Where-Object { $_ -match 'did not finish within|produced no summary line' } |
            Select-Object -Last 1)
    if (-not $hit.Count) { return $null }
    return $hit[0]
}

# The activity table carries a filename and a drive route, which needs more room
# than the 74 columns the other sections were laid out for. Follow the console
# when it reports one, but never drop below what those sections need.
function Get-Width {
    $cw = 0
    try { $cw = [Console]::WindowWidth } catch { $cw = 0 }
    # redirected or headless: assume a normal modern console
    if ($cw -lt 40) { $cw = 100 }
    return [Math]::Min(120, [Math]::Max(74, $cw - 1))
}

# Drive letter off the front of a full path: "D:\Filmes\x.mkv" -> "D:"
function Get-Root {
    param([string]$Path)
    if (-not $Path) { return $null }
    try { $r = [System.IO.Path]::GetPathRoot($Path) } catch { return $null }
    if (-not $r) { return $null }
    return $r.TrimEnd('\')
}

# Which drives this event touched, and in which direction, as "C: -> D:".
# Log rows do not agree on how to spell the source: successful moves log
# "source", failures log "path". Both are full paths, so the drive comes off the
# front either way. Rows that name only one side render half an arrow.
function Get-Route {
    param($Row)
    $from = Get-Root (Get-Prop $Row 'source')
    if (-not $from) { $from = Get-Root (Get-Prop $Row 'path') }
    # Bin reclaim rows have neither source nor path, only the location the item
    # was deleted from. That drive is also the drive holding its $Recycle.Bin
    # payload, because the bin is per-volume, so it names the drive that was
    # actually freed.
    if (-not $from) { $from = Get-Root (Get-Prop $Row 'from') }
    # recycle_verify rows describe no item at all, only a volume that was measured
    # before and after a purge, so the drive is the whole of the row's subject.
    if (-not $from) { $from = Get-Prop $Row 'drive' }
    $to = Get-Root (Get-Prop $Row 'dest')
    # partial_* rows point at the leftover file, which sits on the destination
    if ($Row.event -match '^partial_') { $to = $from; $from = $null }
    if (-not $from) { return $(if ($to) { "-> $to" } else { '' }) }
    if (-not $to) { return $from }
    return "$from -> $to"
}

# Long event names would break the column, so show short labels. The log keeps
# the full names; this is display only.
function Get-EventLabel {
    param([string]$Event)
    $label = switch ($Event) {
        'moved' { 'moved' }
        'planned' { 'planned' }
        'move_failed' { 'MOVE FAILED' }
        'verify_failed' { 'VERIFY FAIL' }
        'source_delete_failed' { 'DELETE FAIL' }
        'dest_dir_failed' { 'MKDIR FAIL' }
        'partial_removed' { 'PARTIAL RM' }
        'partial_remove_failed' { 'PARTIAL RM FAIL' }
        'skip_no_live_space' { 'no live space' }
        'skip_in_use' { 'in use' }
        'recycle_destroyed' { 'bin purged' }
        'recycle_would_destroy' { 'bin purge' }
        'recycle_verify' { 'bin verified' }
        'recycle_destroy_failed' { 'bin purge fail' }
        'recycle_meta_failed' { 'bin meta fail' }
        default { $Event }
    }
    # the default branch passes through an event name of unknown length, so cap
    # it here rather than let one row shove the filename column sideways
    if ($label.Length -gt 15) { $label = $label.Substring(0, 15) }
    return $label
}

# Is the process that wrote the state file still alive? A state file left in
# the "moving" phase with a dead pid means the run was killed.
function Get-LiveRun {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try { $s = [System.IO.File]::ReadAllText($stateFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return $null }
    $alive = $false
    try {
        $p = Get-Process -Id $s.pid -ErrorAction Stop
        $alive = $true
        $procName = $p.ProcessName
    } catch { $procName = $null }

    $age = [int]((Get-Date) - [datetime]$s.updated).TotalSeconds
    $running = $alive -and ($s.phase -eq 'moving' -or $s.phase -eq 'planning' -or $s.phase -eq 'scanning') -and $age -lt 300
    $stale = (-not $alive) -and ($s.phase -ne 'done' -and $s.phase -ne 'idle')
    return [pscustomobject]@{
        State = $s; Alive = $alive; ProcName = $procName; AgeSeconds = $age
        Running = $running; Stale = $stale
    }
}

function Show-Snapshot {
    $W = Get-Width
    Clear-Host
    Write-Host ("Plex Balancer status   {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Cyan
    Write-Host ('=' * $W)

    # ---- current run -------------------------------------------------------
    Write-Host ''
    Write-Host 'CURRENT RUN' -ForegroundColor Cyan
    Write-Host ('-' * $W)
    $live = Get-LiveRun
    if ($null -eq $live) {
        Write-Host '  no run recorded yet' -ForegroundColor DarkGray
    }
    elseif ($live.Running) {
        $s = $live.State
        Write-Host ("  RUNNING  pid {0} ({1})  mode {2}" -f $s.pid, $live.ProcName, $s.mode) -ForegroundColor Green
        Write-Host ("  phase   {0}" -f $s.phase) -ForegroundColor White
        if ($s.current) { Write-Host ("  copying {0}" -f $s.current) -ForegroundColor White }
        Write-Host ("  moved {0}   planned {1}   skipped {2}" -f $s.moved, $s.planned, $s.skipped)
        $el = [int]((Get-Date) - [datetime]$s.started).TotalMinutes
        Write-Host ("  running for {0} min, last update {1}s ago" -f $el, $live.AgeSeconds) -ForegroundColor DarkGray
    }
    elseif ($live.Stale) {
        $s = $live.State
        Write-Host ("  INTERRUPTED  pid {0} is gone, state stuck at '{1}'" -f $s.pid, $s.phase) -ForegroundColor Red
        Write-Host ("  it was: {0}" -f $(if ($s.current) { $s.current } else { 'no file recorded' })) -ForegroundColor DarkGray
        Write-Host '  run reconcile.ps1 to clean up whatever it left behind' -ForegroundColor Yellow
    }
    else {
        $s = $live.State
        $when = ([datetime]$s.updated).ToString('HH:mm:ss')
        Write-Host ("  idle - last run finished at {0}" -f $when) -ForegroundColor DarkGray
        Write-Host ("  mode {0}, moved {1}, planned {2}, skipped {3}" -f $s.mode, $s.moved, $s.planned, $s.skipped) -ForegroundColor DarkGray
    }

    # ---- scheduled task ----------------------------------------------------
    Write-Host ''
    Write-Host 'SCHEDULED TASK' -ForegroundColor Cyan
    Write-Host ('-' * $W)
    # Seeded before the try: StrictMode throws on an unset variable, and the
    # RECENT ACTIVITY table below reads this even when the task is missing.
    $nextRun = $null
    try {
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $info = $t | Get-ScheduledTaskInfo
        $nextRun = $info.NextRunTime
        Write-Host ("  {0}   state: {1}" -f $taskName, $t.State)
        Write-Host ("  runs as {0} ({1})" -f $t.Principal.UserId, $t.Principal.LogonType)
        Write-Host ("  last run  {0}   result: {1}" -f $info.LastRunTime, $info.LastTaskResult) -ForegroundColor DarkGray
        Write-Host ("  next run  {0}" -f $info.NextRunTime) -ForegroundColor DarkGray
        if ($info.LastTaskResult -ne 0) {
            Write-Host ("  last exit code {0} - check logs\watch-*.log" -f $info.LastTaskResult) -ForegroundColor Red
        }
    }
    catch {
        Write-Host "  task '$taskName' is not registered" -ForegroundColor Yellow
    }

    # ---- drives ------------------------------------------------------------
    Write-Host ''
    Write-Host 'DRIVES' -ForegroundColor Cyan
    Write-Host ('-' * $W)
    # Row order comes from statusDisplayOrder in config.json, falling back to
    # priority order (chain drives first, then the unprioritised ones) when the
    # key is absent. Cosmetic only: balance.ps1 never reads it, so it cannot
    # change what gets moved where.
    $rank = @{}
    $listed = @(Get-Prop $cfg 'statusDisplayOrder')
    for ($i = 0; $i -lt $listed.Count; $i++) { $rank[[string]$listed[$i]] = $i }

    $driveRows = @($cfg.drives.PSObject.Properties | ForEach-Object {
            [pscustomobject]@{
                Letter   = $_.Name
                Cfg      = $_.Value
                Priority = Get-Prop $_.Value 'priority'
            }
        })
    $ordered = @($driveRows | Sort-Object -Property `
            @{e = { if ($rank.ContainsKey($_.Letter)) { 0 } else { 1 } } }, `
            @{e = { if ($rank.ContainsKey($_.Letter)) { $rank[$_.Letter] } else { 0 } } }, `
            @{e = { if ($null -eq $_.Priority) { 1 } else { 0 } } }, `
            @{e = { if ($null -eq $_.Priority) { 0 } else { $_.Priority } } }, `
            Letter)

    '{0,-5} {1,-9} {2,10} {3,10} {4,7}  {5}' -f 'DRIVE', 'FORMAT', 'TOTAL', 'FREE', 'FREE%', 'ROLE'
    foreach ($row in $ordered) {
        $letter = $row.Letter
        $dc = $row.Cfg
        try {
            $d = [System.IO.DriveInfo]::new($letter)
            if (-not $d.IsReady) {
                Write-Host ("{0,-5} {1,-9} {2}" -f $letter, '-', 'not ready - skipped') -ForegroundColor DarkGray
                continue
            }
            $free = $d.AvailableFreeSpace
            $pct = if ($d.TotalSize) { [math]::Round(100 * $free / $d.TotalSize, 1) } else { 0 }
            $role = if ((Get-Prop $dc 'sources') -and (Get-Prop $dc 'alsoSink')) { 'source + sink' }
                    elseif (Get-Prop $dc 'sources') { 'source' }
                    else { 'sink' }
            $color = if ($pct -lt 2) { 'Red' } elseif ($pct -lt 10) { 'Yellow' } else { 'Green' }
            Write-Host ('{0,-5} {1,-9} {2,8:N1}GB {3,8:N1}GB {4,6}%  {5}' -f $letter, $d.DriveFormat,
                ($d.TotalSize / $GB), ($free / $GB), $pct, $role) -ForegroundColor $color
        }
        catch {
            Write-Host ("{0,-5} unavailable" -f $letter) -ForegroundColor DarkGray
        }
    }

    # ---- recent log --------------------------------------------------------
    Write-Host ''
    Write-Host 'RECENT ACTIVITY' -ForegroundColor Cyan
    Write-Host ('-' * $W)
    $log = Join-Path $logDir ("moves-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
    if (Test-Path -LiteralPath $log) {
        $rows = @(Get-Content -LiteralPath $log -Tail ($Tail * 3) -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } |
            Where-Object { $_ })
        Write-Host ("  {0}   ({1} events in today's log)" -f (Split-Path $log -Leaf), $rows.Count) -ForegroundColor DarkGray
        Write-Host ('  {0,-8}  {1,-15} {2,-10} {3,8}  {4,8}  {5}' -f 'TIME', 'EVENT', 'ROUTE', 'SIZE', 'NEXT RUN', 'FILE') -ForegroundColor DarkGray

        # When the next scheduled run will pick up work that has NOT happened yet.
        # Restricted to rows that describe work still to be performed. A skip -
        # in use, no live space, nowhere downstream - is not pending: the file
        # stays where it is and the next run skips it again, so showing a time
        # there would promise a move that is never going to happen. A row whose
        # move already happened gets a dash too, because its real time is the one
        # in the TIME column. A dash therefore means "not scheduled work", or
        # nothing is scheduled at all - task disabled, or not registered.
        $pendingEvents = @('planned', 'recycle_would_destroy')
        $nextClock = '-'
        if ($nextRun -and $nextRun -gt (Get-Date)) {
            $nextClock = if ($nextRun.Date -eq (Get-Date).Date) { $nextRun.ToString('HH:mm') }
            else { $nextRun.ToString('dd/MM HH:mm') }
        }

        # 2 indent + 8 time + 2 + 15 event + 1 + 10 route + 1 + 8 size + 2 + 8 next + 2
        $nameW = $W - 59
        foreach ($r in ($rows | Select-Object -Last $Tail)) {
            $color = switch ($r.event) {
                'moved' { 'Green' }
                'move_failed' { 'Red' }
                'verify_failed' { 'Red' }
                'source_delete_failed' { 'Red' }
                'dest_dir_failed' { 'Red' }
                'partial_removed' { 'Yellow' }
                'partial_remove_failed' { 'Yellow' }
                'recycle_destroyed' { 'Yellow' }
                'recycle_verify' { 'DarkGray' }
                'recycle_destroy_failed' { 'Red' }
                'recycle_meta_failed' { 'Red' }
                'planned' { 'DarkGray' }
                default { 'DarkGray' }
            }
            # a single malformed row must not kill a -Watch display, so the
            # filename is taken defensively rather than assumed to be splittable
            $what = Get-Prop $r 'dest'
            if (-not $what) { $what = Get-Prop $r 'path' }
            # bin reclaim rows carry no dest or path, only the name of the item
            if (-not $what) { $what = Get-Prop $r 'name' }
            # The two failure rows carry both, and the path is the payload file as
            # Windows named it - "$RLOCKED.mkv" - which says nothing about which
            # item it was. The name is the item, so it wins.
            if ($r.event -match '^recycle_.*failed$') {
                $nm = Get-Prop $r 'name'
                if ($nm) { $what = $nm }
            }
            if ($what) { try { $what = Split-Path $what -Leaf } catch { } }
            if ($what -and $what.Length -gt $nameW) { $what = $what.Substring(0, $nameW - 3) + '...' }
            # Only the move-shaped rows record a size. A failure or a skip has no size to
            # report, and a dash says so rather than implying the file was empty.
            $sizeGB = Get-Prop $r 'sizeGB'
            # A verification row measures the volume rather than a file, so its size
            # is what came back rather than what was asked for. Shown as freed vs
            # expected, because the gap between the two is the entire point - a row
            # where they match is a purge that worked and needs no attention.
            if ($r.event -eq 'recycle_verify') {
                $freedGB = Get-Prop $r 'freedGB'
                $wantGB = Get-Prop $r 'expectedGB'
                $verdict = Get-Prop $r 'verdict'
                # A dash, as everywhere else in this column, when the run could not
                # read the volume back. The FILE column says why.
                $sizeTxt = if ($null -eq $freedGB) { '-' } else { ('{0:N2}GB' -f [double]$freedGB) }
                if ($verdict -eq 'unmeasurable') {
                    $what = 'could not measure'
                }
                elseif ($null -ne $wantGB) {
                    $what = 'expected {0:N2}GB' -f [double]$wantGB
                    if ($null -ne $freedGB -and $wantGB -gt 0) {
                        $what = '{0} ({1:P0})' -f $what, ([double]$freedGB / [double]$wantGB)
                    }
                }
                else { $what = '' }
            }
            else {
                $sizeTxt = if ($null -eq $sizeGB) { '-' } else { ('{0:N2}GB' -f [double]$sizeGB) }
            }
            $ts = ([datetime]$r.at).ToString('HH:mm:ss')
            $nextTxt = if ($pendingEvents -contains $r.event) { $nextClock } else { '-' }
            Write-Host ("  {0}  {1,-15} {2,-10} {3,8}  {4,8}  {5}" -f $ts, (Get-EventLabel $r.event), (Get-Route $r), $sizeTxt, $nextTxt, $what) -ForegroundColor $color
        }
    }
    else {
        Write-Host '  no moves log yet for today' -ForegroundColor DarkGray
    }

    # ---- watcher log -------------------------------------------------------
    $wlog = Join-Path $logDir ("watch-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    if (Test-Path -LiteralPath $wlog) {
        Write-Host ''
        Write-Host 'WATCHER' -ForegroundColor Cyan
        Write-Host ('-' * $W)
        Get-Content -LiteralPath $wlog -Tail 4 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }

    if ($Watch) {
        Write-Host ''
        Write-Host ('refreshing every {0}s - Ctrl+C to stop' -f $RefreshSeconds) -ForegroundColor DarkGray
    }
}

if ($Watch) {
    try {
        while ($true) { Show-Snapshot; Start-Sleep -Seconds $RefreshSeconds }
    }
    finally { Clear-Host }
}
else {
    Show-Snapshot
}
