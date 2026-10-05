<#
.SYNOPSIS
    Plex storage balancer - moves already-optimized media between drives to hit
    per-drive free-space targets. Never deletes anything except the source copy
    of a file it just successfully moved and verified.

.DESCRIPTION
    Reads a policy from config.json, measures every drive, then moves media from
    "source" drives to "sink" drives until the targets are met or no sink has
    headroom left.

    Two unit types, because Plex libraries are laid out differently:
      file  - movies sit as loose files in the library root
      show  - series sit as one folder per show, with loose episode files inside

    Safety rules, all of them non-negotiable:
      * dry run unless -Apply is passed
      * never overwrites an existing file
      * verifies the copy before deleting the source (size by default, -Hash for sha256)
      * skips anything modified in the last N hours (in-flight downloads)
      * skips anything a Plex client currently has open (file lock check)
      * appends every decision to a JSONL audit log

.EXAMPLE
    .\balance.ps1                 # report + dry run, moves nothing
    .\balance.ps1 -Apply         # actually move
    .\balance.ps1 -Report        # status only, no planning
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Apply,
    [switch]$Report,
    [switch]$Hash,
    [int]$MaxMinutes = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# $PSScriptRoot is not populated while param defaults are evaluated in PS 5.1
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.json'
    # config.json is deliberately not committed: it names your drive letters and
    # library paths. A fresh clone therefore has no config at all, and the failure
    # would otherwise be a bare FileNotFoundException from ReadAllText.
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $example = Join-Path $PSScriptRoot 'config.example.json'
        if (Test-Path -LiteralPath $example) {
            throw ("config.json not found. Copy config.example.json to config.json and edit it:  Copy-Item '$example' '$ConfigPath'")
        }
        throw ("config.json not found at {0}, and there is no config.example.json to copy from." -f $ConfigPath)
    }
}

# Only one balancer may touch the library at a time. Without this, the watcher
# starting a run while you are running one by hand means two processes deciding
# against the same free space and copying the same file to the same place.
$mutex = New-Object System.Threading.Mutex($false, 'Global\PlexBalancer')
$held = $false
try { $held = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
if (-not $held) {
    Write-Host 'Another balancer run is already in progress - nothing to do.' -ForegroundColor Yellow
    Write-Host 'Wait for it to finish, or stop it before starting a new one.'
    return
}

# Must be read as UTF-8 explicitly. PS 5.1's default is ANSI, which turns the
# accent in "Séries" into garbage and makes every series root stop existing.
$cfg = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$GB = 1GB
$logDir = if ($cfg.logDir) { Join-Path $PSScriptRoot $cfg.logDir } else { $PSScriptRoot }
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("moves-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))

function Write-Log {
    param([string]$Event, [hashtable]$Data)
    $entry = [ordered]@{ at = (Get-Date).ToString('o'); event = $Event; apply = [bool]$Apply }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
    Add-Content -LiteralPath $logFile -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
}

# A live state file so status.ps1 can show what is happening right now without
# having to attach to the console. Rewritten on every move, and marked done on
# a clean exit, so a stale file means the process died mid-run.
$stateFile = Join-Path $logDir 'state.json'
function Write-State {
    param([string]$Phase, [string]$Current, [int]$Moved, [int]$Planned, [int]$Skipped)
    $s = [ordered]@{
        pid        = $PID
        phase      = $Phase
        current    = $Current
        moved      = $Moved
        planned    = $Planned
        skipped    = $Skipped
        mode       = $(if ($Apply) { 'apply' } else { 'dry run' })
        started    = $script:stateStarted
        updated    = (Get-Date).ToString('o')
        logFile    = $logFile
    }
    # write to a temp name then swap, so a reader never sees half a file
    $tmp = "$stateFile.tmp"
    Set-Content -LiteralPath $tmp -Value ($s | ConvertTo-Json) -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $stateFile -Force
}
$script:stateStarted = (Get-Date).ToString('o')

# StrictMode makes a missing property a hard error, and config entries are
# deliberately sparse (only J: has maxUnitGB, only H: and J: are exempt from
# the headroom rule, only K: is both source and sink).
function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# How much free space a sink should keep once it is "full". Either an absolute
# targetFreeGB or a percentage of the drive, whichever the config specifies.
# $DriveCfg, not $Cfg: PowerShell variable names are case-insensitive, so a
# parameter called $Cfg would shadow the script-wide $cfg and silently turn any
# "fall back to the global setting" line into a read of this same object.
function Get-SinkTargetFree {
    param($DriveCfg, $Stat)
    $abs = Get-Prop $DriveCfg 'targetFreeGB'
    if ($abs) { return [double]$abs * $GB }
    $pct = Get-Prop $DriveCfg 'targetFreePct'
    if ($pct) { return $Stat.Total * [double]$pct / 100 }
    return 0
}

# NTFS on a nearly-full volume over-reports free space: the figure it hands out
# can be roughly one file more than what is actually writable, and it only
# settles on a reboot. So the live number is re-read immediately before every
# copy rather than trusted from the start of the run.
function Get-LiveFree {
    param([string]$Letter)
    try { return [int64][System.IO.DriveInfo]::new($Letter).AvailableFreeSpace } catch { return [int64]0 }
}

function Get-DriveStat {
    param([string]$Letter)
    $d = [System.IO.DriveInfo]::new($Letter)
    [pscustomobject]@{
        Letter   = $Letter.ToUpperInvariant()
        Total    = $d.TotalSize
        Free     = $d.AvailableFreeSpace
        Used     = $d.TotalSize - $d.AvailableFreeSpace
        FreePct  = if ($d.TotalSize) { [math]::Round(100 * $d.AvailableFreeSpace / $d.TotalSize, 1) } else { 0 }
        Format   = $d.DriveFormat
        Ready    = $d.IsReady
    }
}

# A failing disk does not fail fast. Reads are retried, sometimes for minutes,
# and a recursive scan of one blocks the whole run with no way out - that is how
# two dying USB drives turned into an unusable machine on 2026-10-03: the watcher
# started a scan every hour, each scan hung, and the blocked processes piled up
# until nothing new could start.
#
# So before reading a drive, ask Windows which disks have reported hardware or
# paging errors recently and skip those. This is not a prediction of failure -
# it is the drive that already logged the errors.
function Get-FailingDisks {
    param([int]$WindowHours = 24)

    $bad = @{}
    $since = (Get-Date).AddHours(-$WindowHours)
    # 51 paging error, 153 I/O retried, 154 I/O failed with a hardware error,
    # 157 surprise removal. -MaxEvents keeps this cheap when a drive has been
    # logging thousands of retries an hour, and the newest events are returned
    # first, which are the ones describing how the drive behaves now.
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 51, 153, 154, 157; StartTime = $since } -MaxEvents 200 -ErrorAction SilentlyContinue)
    foreach ($e in $events) {
        $num = $null
        # 153/154 name the disk as "Disco 4" on a Portuguese system and "Disk 4"
        # on an English one, so the pattern must accept both. 51 names the device
        # instead - "\Device\Harddisk3\DR3" - which is the same string in every
        # locale, and is what the paging-error events actually use.
        if ($e.Message -match 'Dis[ck]o?\s+(\d+)') { $num = [int]$Matches[1] }
        elseif ($e.Message -match 'Harddisk(\d+)\\DR') { $num = [int]$Matches[1] }
        if ($null -ne $num) { $bad[$num] = $true }
    }
    return @($bad.Keys)
}

# Drive letter to physical disk number, cached because the scan loop asks for the
# same handful of letters once per library root.
$script:diskOfDrive = @{}
function Get-DriveDiskNumber {
    param([string]$Letter)
    $key = $Letter.TrimEnd(':').ToUpperInvariant()
    if ($script:diskOfDrive.ContainsKey($key)) { return $script:diskOfDrive[$key] }
    $num = $null
    try {
        $part = Get-Partition -DriveLetter $key -ErrorAction Stop
        # A null partition would cast to 0, and disk 0 is a real disk number - so
        # a missing partition would look like "this drive is on disk 0" instead of
        # "do not know". Better to admit ignorance than to name the wrong disk.
        $num = if ($part) { [int]$part.DiskNumber } else { $null }
    }
    catch { $num = $null }
    $script:diskOfDrive[$key] = $num
    return $num
}

# A "unit" is one movable thing: a single movie file, or a single episode.
# Episodes move individually rather than as whole show folders, so a show can
# spread across drives when only part of it fits. The show folder is recreated
# on the destination so Plex still sees Show/Season/Episode.
function Get-Units {
    param($Library, [string]$Root, [datetime]$Cutoff)

    $units = @()
    if (-not (Test-Path -LiteralPath $Root)) { return $units }
    $exts = @($Library.mediaExtensions | ForEach-Object { $_.ToLowerInvariant() })

    if ($Library.unit -eq 'file') {
        foreach ($f in Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue) {
            if ($exts -notcontains $f.Extension.ToLowerInvariant()) { continue }
            $skip = if ($f.LastWriteTime -gt $Cutoff) { 'modified recently' } else { $null }
            $units += [pscustomobject]@{ Path = $f.FullName; Name = $f.Name; Kind = 'file'
                SubPath = $f.Name; Show = ''
                Size = $f.Length; Files = @($f.FullName); Newest = $f.LastWriteTime; Skip = $skip }
        }
    }
    else {
        foreach ($d in Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue) {
            $files = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
            foreach ($f in $files) {
                if ($exts -notcontains $f.Extension.ToLowerInvariant()) { continue }
                $skip = if ($f.LastWriteTime -gt $Cutoff) { 'modified recently' } else { $null }
                # keep the show/season layout relative to the library root
                $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
                $units += [pscustomobject]@{ Path = $f.FullName; Name = $f.Name; Kind = 'episode'
                    SubPath = $rel; Show = $d.Name
                    Size = $f.Length; Files = @($f.FullName); Newest = $f.LastWriteTime; Skip = $skip }
            }
        }
    }
    return $units
}

# Plex streams hold the file open. If we cannot get exclusive read access, skip it.
function Test-UnitLocked {
    param($Unit)
    foreach ($f in $Unit.Files) {
        try {
            $s = [System.IO.File]::Open($f, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $s.Close()
        }
        catch [System.IO.IOException] { return $true }
        catch [System.UnauthorizedAccessException] { return $true }
    }
    return $false
}

function Test-DestinationFree {
    param([string]$DestPath, [long]$SizeBytes)
    if (Test-Path -LiteralPath $DestPath) { return 'destination exists' }
    return $null
}

function Invoke-Move {
    param($Unit, [string]$DestRoot, [string]$DestPath, $DriveStat, $DestCfg)

    if ($Apply) {
        # Copy-Item will not create a missing target directory for a single file
        try {
            $parent = [System.IO.Path]::GetDirectoryName($DestPath)
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
        }
        catch {
            Write-Log 'dest_dir_failed' @{ path = $Unit.Path; dest = $DestPath; sizeGB = [math]::Round($Unit.Size / $GB, 2); error = $_.Exception.Message }
            Write-Warning "could not create destination folder: $($_.Exception.Message)"
            return $false
        }

        # last chance to bail out before starting a copy we cannot finish
        $live = Get-LiveFree -Letter $DriveStat.Letter
        $need = [int64]$Unit.Size
        $pct = Get-Prop $DestCfg 'maxUnitPctOfFree'
        if (-not $pct) { $pct = Get-Prop $cfg 'maxUnitPctOfFree' }
        if ((Get-Prop $DestCfg 'exemptHeadroomRule')) { $pct = $null }
        $limit = if ($pct) { [int64]($live * [double]$pct / 100) } else { $live }
        if ($need -gt $limit) {
            Write-Log 'skip_no_live_space' @{
                path = $Unit.Path; dest = $DestPath; sizeGB = [math]::Round($Unit.Size / $GB, 2)
                liveFreeGB = [math]::Round($live / $GB, 2); limitGB = [math]::Round($limit / $GB, 2)
            }
            Write-Warning ("skipped: {0} - drive reports {1:N2} GB free, limit is {2:N2} GB" -f
                $Unit.Name, ($live / $GB), ($limit / $GB))
            return $false
        }

        try {
            if ($Unit.Kind -eq 'file') {
                Copy-Item -LiteralPath $Unit.Path -Destination $DestPath -Force -ErrorAction Stop
            }
            else {
                Copy-Item -LiteralPath $Unit.Path -Destination $DestPath -Recurse -Force -ErrorAction Stop
            }
        }
        catch {
            Write-Log 'move_failed' @{ path = $Unit.Path; dest = $DestPath; sizeGB = [math]::Round($Unit.Size / $GB, 2); error = $_.Exception.Message }
            Write-Warning "copy failed: $($Unit.Path) -> $($_.Exception.Message)"
            # a partial file may be sitting on the destination
            if (Test-Path -LiteralPath $DestPath) {
                try {
                    if ($Unit.Kind -eq 'file') { Remove-Item -LiteralPath $DestPath -Force -ErrorAction Stop }
                    else { Remove-Item -LiteralPath $DestPath -Recurse -Force -ErrorAction Stop }
                    Write-Log 'partial_removed' @{ path = $DestPath }
                }
                catch { Write-Log 'partial_remove_failed' @{ path = $DestPath; error = $_.Exception.Message } }
            }
            return $false
        }

        # verify before the source is removed
        $ok = $true
        if ($Hash) {
            foreach ($f in $Unit.Files) {
                $rel = $f.Substring($Unit.Path.Length).TrimStart('\')
                $copied = Join-Path $DestPath $rel
                if (-not (Test-Path -LiteralPath $copied)) { $ok = $false; break }
                $a = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
                $b = (Get-FileHash -LiteralPath $copied -Algorithm SHA256).Hash
                if ($a -ne $b) { $ok = $false; break }
            }
        }
        else {
            $copiedFiles = @(Get-ChildItem -LiteralPath $DestPath -Recurse -File -Force -ErrorAction SilentlyContinue)
            $copiedSize = ($copiedFiles | Measure-Object -Property Length -Sum).Sum
            if ($copiedSize -ne $Unit.Size -or $copiedFiles.Count -ne $Unit.Files.Count) { $ok = $false }
        }

        if (-not $ok) {
            Write-Log 'verify_failed' @{ path = $Unit.Path; dest = $DestPath; sizeGB = [math]::Round($Unit.Size / $GB, 2) }
            Write-Warning "verification failed, source kept: $($Unit.Path)"
            return $false
        }

        try {
            if ($Unit.Kind -eq 'file') { Remove-Item -LiteralPath $Unit.Path -Force -ErrorAction Stop }
            else { Remove-Item -LiteralPath $Unit.Path -Recurse -Force -ErrorAction Stop }
        }
        catch {
            Write-Log 'source_delete_failed' @{ path = $Unit.Path; sizeGB = [math]::Round($Unit.Size / $GB, 2); error = $_.Exception.Message }
            Write-Warning "copied but could not remove source: $($Unit.Path)"
            return $false
        }
    }

    $DeltaFree = [int64]($Unit.Size)
    $DriveStat.Free = $DriveStat.Free - $DeltaFree
    $DriveStat.Used = $DriveStat.Total - $DriveStat.Free
    $DriveStat.FreePct = if ($DriveStat.Total) { [math]::Round(100 * $DriveStat.Free / $DriveStat.Total, 1) } else { 0 }

    Write-Log $(if ($Apply) { 'moved' } else { 'planned' }) @{
        library = $Unit.Library; kind = $Unit.Kind; source = $Unit.Path
        dest = $DestPath; sizeGB = [math]::Round($Unit.Size / $GB, 2)
    }
    return $true
}

# --------------------------------------------------------------- reclaim ----
# Every delete in this codebase is Remove-Item -Force, which is permanent and
# never touches the Recycle Bin. So whatever is sitting in the bin got there
# from Explorer, and if it is library media then the space it holds is space the
# cascade is short of. It is destroyed before the move phase, not after.
#
# What qualifies is decided by where the file was deleted from, not by its name,
# so a renamed, truncated or unrecognisable filename cannot slip past. Anything
# whose original location is unknown is left alone.
function Test-MediaOrigin {
    param([string]$OriginalLocation)
    if (-not $OriginalLocation) { return $false }
    $norm = $OriginalLocation.TrimEnd('\')
    foreach ($lib in $cfg.libraries) {
        foreach ($root in $lib.roots) {
            $r = ([string]$root).TrimEnd('\')
            if ($norm.Equals($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            if ($norm.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

# Free space on a volume as the balancer's own user would see it, or $null.
# AvailableFreeSpace rather than TotalFreeSpace: the reclaim frees the user's own
# quota, so that is the number the freed bytes should show up in.
function Get-DriveFree {
    param([string]$Letter)
    try {
        $d = [System.IO.DriveInfo]::new($Letter)
        if (-not $d.IsReady) { return $null }
        return [int64]$d.AvailableFreeSpace
    }
    catch { return $null }
}

# Where a binned item came from, read out of the $I file that accompanies its
# payload. That origin is the only thing standing between "empty the bin" and
# deleting whatever else happens to be in there, so it has to come from the file
# itself rather than being assumed.
#
# The layout is not documented by Microsoft. Two versions are known:
#   v1   int64 version | int64 size |              UTF-16LE path
#   v2   int64 version | int64 size | FILETIME | uint32 chars | UTF-16LE path
# An unknown version, a truncated file or an undecodable path all return $null,
# and the caller then leaves the item alone. Skipping is the only safe direction:
# a wrong answer here is indistinguishable from no check at all.
function Read-RecycleMeta {
    param([string]$Path)

    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)

        $len = $fs.Length
        if ($len -lt 20) { return $null }

        $cap = [int][Math]::Min($len, 28)
        $head = New-Object byte[] $cap
        $fs.Position = 0
        if ($fs.Read($head, 0, $cap) -lt $cap) { return $null }

        $version = [int]$head[0]
        $size = [BitConverter]::ToInt64($head, 8)
        $pathAt = 20
        $chars = 0

        if ($version -eq 2) {
            if ($cap -lt 28) { return $null }
            $chars = [BitConverter]::ToUInt32($head, 24)
            $pathAt = 28
        }
        elseif ($version -eq 1) { $pathAt = 16 }
        else { return $null }

        $take = if ($chars -gt 0) { [int][Math]::Min([int64]$chars * 2, 65536) }
                else { [int][Math]::Min($len - $pathAt, 65536) }
        if ($take -le 0) { return $null }

        $fs.Position = $pathAt
        $buf = New-Object byte[] $take
        $read = 0
        while ($read -lt $take) {
            $n = $fs.Read($buf, $read, $take - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -le 0) { return $null }

        $origin = [System.Text.Encoding]::Unicode.GetString($buf, 0, $read)
        if ($chars -gt 0) {
            # The header declares how many characters the path holds. Getting
            # fewer than that means the file was cut short, and a path truncated
            # mid-string is not an origin: it can still begin with a library root
            # and so pass the check below while proving nothing about the rest of
            # the path. Refuse rather than reason about a partial answer.
            if ($read -lt $take) { return $null }
            $origin = $origin.TrimEnd([char]0)
        }
        else {
            # Version 1 has no length field, so the null terminator is the only
            # end-of-path marker there is. Without one, the path ran into the end
            # of what could be read.
            $z = $origin.IndexOf([char]0)
            if ($z -lt 0) { return $null }
            $origin = $origin.Substring(0, $z)
        }
        if (-not $origin) { return $null }

        return [pscustomobject]@{ Version = $version; Size = $size; Origin = $origin }
    }
    catch { return $null }
    finally { if ($fs) { $fs.Dispose() } }
}

function Invoke-RecycleBinReclaim {
    try {
        # Enumerated by path, one volume at a time, instead of through the shell's
        # Recycle Bin namespace. That is the fix for the reason this was switched
        # off: Shell.Application's namespace spans every mounted volume, so it
        # reads F: and K: even when nothing else does, and a COM enumeration
        # cannot be given a timeout. Walking the path touches only volumes that
        # can actually hold library media, and is bounded - only the top level of
        # each SID folder is listed, and the only file ever read is the small $I
        # header.
        #
        # No failing-disk gate here, on purpose. The gate belongs to the library
        # scan, where 2026-10-03 proved that walking tens of thousands of files on
        # a disk that retries rather than fails will block instead of erroring.
        # Emptying a bin is not that operation: a shallow listing, two ~300 byte
        # header reads, and a few directory-entry deletes. Explorer's own Empty
        # Recycle Bin does strictly more work on the same files - it removes
        # everything, where this touches only library media - so holding this back
        # bought nothing and cost a drive its reclaimed space for 24h for no
        # reason. A failed read or delete is caught and logged, not retried.
        $letters = @($cfg.libraries | ForEach-Object { $_.roots } | ForEach-Object {
                # A root is expected to look like 'D:\Filmes'. Anything that does
                # not even have two characters cannot name a volume, and letting
                # Substring throw here would cost the whole pass over one bad line
                # in config.json rather than just that root.
                $root = [string]$_
                if ($root.Length -ge 2) { $root.Substring(0, 2).ToUpperInvariant() }
            } | Sort-Object -Unique)

        $targets = @()
        $unreadable = 0

        foreach ($letter in $letters) {
            $binRoot = '{0}\$Recycle.Bin' -f $letter
            if (-not (Test-Path -LiteralPath $binRoot)) { continue }

            # One level down only. The payload of a deleted folder is an entire
            # directory tree, and descending into one on a disk that is starting
            # to fail is the hang this pass used to be able to cause.
            foreach ($sid in @(Get-ChildItem -LiteralPath $binRoot -Directory -Force -ErrorAction SilentlyContinue)) {
                $metas = @(Get-ChildItem -LiteralPath $sid.FullName -File -Filter '$I*' -Force -ErrorAction SilentlyContinue)
                foreach ($meta in $metas) {
                    $info = Read-RecycleMeta -Path $meta.FullName
                    if ($null -eq $info) { $unreadable++; continue }
                    if (-not (Test-MediaOrigin $info.Origin)) { continue }

                    # $R is the payload that actually occupies the bytes; $I is
                    # its metadata record, same suffix on both sides. Clearing
                    # only the payload leaves Explorer listing an entry with
                    # nothing behind it.
                    $payload = Join-Path -Path $sid.FullName -ChildPath ('$R' + $meta.Name.Substring(2))
                    if (-not (Test-Path -LiteralPath $payload)) { continue }

                    $bytes = [int64]$info.Size
                    $isFolder = $false
                    try {
                        $probe = Get-Item -LiteralPath $payload -Force -ErrorAction Stop
                        $isFolder = [bool]$probe.PSIsContainer
                        if (-not $isFolder) {
                            $bytes = [int64]$probe.Length
                        }
                        elseif ($bytes -le 0) {
                            # Neither the shell nor the $I header reports a size
                            # for a folder, so walk it rather than print a
                            # misleading zero. Accumulated by hand rather than
                            # with Measure-Object -Sum, because that returns an
                            # object with no Sum property at all on an empty
                            # folder, and StrictMode turns reading it into a
                            # terminating error.
                            $walked = [int64]0
                            Get-ChildItem -LiteralPath $payload -Recurse -File -Force -ErrorAction SilentlyContinue |
                                ForEach-Object { $walked += [int64]$_.Length }
                            $bytes = $walked
                        }
                    }
                    catch { }

                    $targets += [pscustomobject]@{
                        Name = [System.IO.Path]::GetFileName($info.Origin.TrimEnd('\')) -replace '\s+', ' '
                        From = $info.Origin; Drive = $letter
                        Payload = $payload; Meta = $meta.FullName
                        IsFolder = $isFolder; Bytes = $bytes
                    }
                }
            }
        }

        if ($unreadable) {
            Write-Host ('  left {0} item(s) alone: the $I record could not be read, so their origin is unknown' -f $unreadable) -ForegroundColor Yellow
        }
        if ($targets.Count -eq 0) {
            Write-Host 'recycle bin: no library media waiting to be destroyed' -ForegroundColor DarkGray
            return
        }

        $total = [int64](($targets | Measure-Object -Property Bytes -Sum).Sum)

        Write-Host ''
        Write-Host 'RECYCLE BIN' -ForegroundColor Cyan
        Write-Host ('-' * 74)
        foreach ($t in $targets) {
            Write-Host ('  {0,7:N2}GB  {1}  [{2}]' -f ($t.Bytes / $GB), $t.Name, $t.Drive) -ForegroundColor Yellow
        }

        # Free space per volume, read before anything is deleted. This is the
        # baseline the verification at the end measures against. Without it the
        # summary can only repeat the sizes we hoped to free, which is a claim
        # about what should happen rather than a record of what did.
        $freeBefore = @{}
        foreach ($t in $targets) {
            if (-not $freeBefore.ContainsKey($t.Drive)) { $freeBefore[$t.Drive] = Get-DriveFree -Letter $t.Drive }
        }

        $expected = @{}
        $destroyed = 0
        foreach ($t in $targets) {
            Write-Log $(if ($Apply) { 'recycle_destroyed' } else { 'recycle_would_destroy' }) @{
                name = $t.Name; from = $t.From; drive = $t.Drive; sizeGB = [math]::Round($t.Bytes / $GB, 2)
            }
            if (-not $Apply) { continue }
            try {
                if ($t.IsFolder) { Remove-Item -LiteralPath $t.Payload -Recurse -Force -ErrorAction Stop }
                else { Remove-Item -LiteralPath $t.Payload -Force -ErrorAction Stop }
            }
            catch {
                Write-Log 'recycle_destroy_failed' @{ name = $t.Name; path = $t.Payload; error = $_.Exception.Message }
                Write-Warning "could not destroy $($t.Name): $($_.Exception.Message)"
                continue
            }
            if ($t.Meta -and (Test-Path -LiteralPath $t.Meta)) {
                try { Remove-Item -LiteralPath $t.Meta -Force -ErrorAction Stop }
                catch { Write-Log 'recycle_meta_failed' @{ name = $t.Name; path = $t.Meta; error = $_.Exception.Message } }
            }
            $destroyed++
            if (-not $expected.ContainsKey($t.Drive)) { $expected[$t.Drive] = [int64]0 }
            $expected[$t.Drive] += $t.Bytes
        }

        Write-Host ''
        if ($Apply) {
            Write-Host ('  destroyed {0} item(s) across {1} volume(s) before the move phase' -f $destroyed, @($expected.Keys).Count) -ForegroundColor Yellow
        }
        else {
            Write-Host ('  {0} item(s) would be destroyed, about {1:N2}GB. -Apply does it.' -f $targets.Count, ($total / $GB)) -ForegroundColor DarkGray
            return
        }

        # ---- verification --------------------------------------------------
        # Measure, do not assume. A deleted file can be held open, sit behind a
        # reparse point, or turn out to be sparse; the only way to know the bytes
        # actually came back is to read the volume again and compare against
        # what was expected. Reporting the estimate alone, as this used to, is
        # how a failed purge gets logged as a successful one.
        $short = 0
        foreach ($letter in @($freeBefore.Keys | Sort-Object)) {
            $was = $freeBefore[$letter]
            $now = Get-DriveFree -Letter $letter
            $want = if ($expected.ContainsKey($letter)) { $expected[$letter] } else { [int64]0 }
            $got = if ($null -ne $was -and $null -ne $now) { [int64]$now - [int64]$was } else { $null }

            # The verdict is decided here and written into the event, rather than
            # left for status.ps1 to work out from the two numbers. Two readers
            # applying two slightly different tolerances is how a display ends up
            # disagreeing with the run that produced it.
            $verdict = 'ok'
            if ($null -eq $got) { $verdict = 'unmeasurable' }
            # Ten percent of slack for anything else touching the volume in the
            # meantime. Short of that, the purge did not do what it said it did.
            elseif ($want -gt 0 -and $got -lt ($want * 0.9)) { $verdict = 'short' }

            Write-Log 'recycle_verify' @{
                drive = $letter
                expectedGB = [math]::Round($want / $GB, 2)
                freedGB = $(if ($null -ne $got) { [math]::Round($got / $GB, 2) } else { $null })
                verdict = $verdict
            }

            if ($verdict -eq 'unmeasurable') {
                Write-Warning ("could not measure free space on {0} after the purge" -f $letter)
                $short++
            }
            elseif ($verdict -eq 'short') {
                Write-Warning ("{0}: expected about {1:N2}GB back, measured {2:N2}GB - the purge did not free what it claimed" -f
                    $letter, ($want / $GB), ($got / $GB))
                $short++
            }
            else {
                Write-Host ('  {0}  freed {1:N2}GB of an expected {2:N2}GB' -f $letter, ($got / $GB), ($want / $GB)) -ForegroundColor DarkGray
            }
        }
        if ($short) {
            Write-Warning ("{0} volume(s) did not return the space the purge claimed. The log holds the measured figure." -f $short)
        }
    }
    catch {
        # Reclaiming is an optimisation, not the job. Anything unexpected in it
        # is reported and stepped over, because aborting here would strand every
        # move that was about to happen.
        Write-Warning "recycle bin reclaim failed, continuing without it: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- status ----
# Which disks are currently reporting errors. Asked once per run, not per root:
# it reads the event log, and a drive that has logged 44,000 paging errors in a
# day makes that lookup expensive enough to be worth doing exactly once.
#
# Computed here, ahead of the reclaim pass, because the reclaim skips failing
# volumes too. It used to be computed later, where the recycle bin had already
# been walked.
$errorWindow = Get-Prop $cfg 'driveErrorWindowHours'
if ($null -eq $errorWindow) { $errorWindow = 24 }
$failingDisks = @(Get-FailingDisks -WindowHours ([int]$errorWindow))
if ($failingDisks.Count) {
    Write-Warning ("Windows logged hardware or paging errors on disk {0} in the last {1}h. Those drives will not be read this run." -f ($failingDisks -join ', '), $errorWindow)
}

# Reclaim runs first, so bytes freed here are visible to the planning phase in
# this same run instead of only the next one.
#
# It walks each library volume by path and skips the ones whose disk is logging
# errors, so the pass that made this the riskiest thing in the run on 2026-10-03
# no longer touches F: or K:. It then measures the volume again afterwards and
# compares against what it expected to free, so a purge that silently fails is
# reported as one instead of being logged as a success.
if (Get-Prop $cfg 'recycleReclaim') {
    Invoke-RecycleBinReclaim
}
else {
    Write-Host 'recycle bin reclaim is off (set recycleReclaim: true in config.json to enable)' -ForegroundColor DarkGray
}

$cutoff = (Get-Date).AddHours(-[double]$cfg.skipFilesModifiedWithinHours)
$stats = @{}
foreach ($letter in $cfg.drives.PSObject.Properties.Name) {
    try { $stats[$letter] = Get-DriveStat -Letter $letter } catch { Write-Warning "drive $letter unavailable: $($_.Exception.Message)" }
}

Write-Host ''
Write-Host 'DRIVE STATUS' -ForegroundColor Cyan
Write-Host ('-' * 74)
'{0,-5} {1,-9} {2,10} {3,10} {4,7}  {5}' -f 'DRIVE', 'FORMAT', 'TOTAL', 'FREE', 'FREE%', 'ROLE'
foreach ($letter in ($stats.Keys | Sort-Object)) {
    $s = $stats[$letter]
    $dc = $cfg.drives.$letter
    $role = @()
    if (Get-Prop $dc 'sources') { $role += 'source' }
    if ((Get-Prop $dc 'sources') -and (Get-Prop $dc 'alsoSink')) { $role += 'sink too' }
    elseif (-not (Get-Prop $dc 'sources')) { $role += 'sink' }
    $maxUnit = Get-Prop $dc 'maxUnitGB'
    if ($maxUnit) { $role += ("max {0} GB/unit" -f $maxUnit) }
    if (Get-Prop $dc 'exemptHeadroomRule') { $role += 'no 50% rule' }
    $color = if ($s.FreePct -lt 2) { 'Red' } elseif ($s.FreePct -lt 10) { 'Yellow' } else { 'Green' }
    Write-Host ('{0,-5} {1,-9} {2,8:N1}GB {3,8:N1}GB {4,6}%  {5}' -f $s.Letter, $s.Format,
        ($s.Total / $GB), ($s.Free / $GB), $s.FreePct, ($role -join ', ')) -ForegroundColor $color
}

# how full is each sink allowed to get?
Write-Host ''
Write-Host 'TARGETS' -ForegroundColor Cyan
Write-Host ('-' * 74)
'{0,-5} {1,10} {2,10}  {3}' -f 'DRIVE', 'FREE NOW', 'TARGET', 'NOTE'
foreach ($letter in ($stats.Keys | Sort-Object)) {
    $s = $stats[$letter]
    $dc = $cfg.drives.$letter
    if ((Get-Prop $dc 'sources') -and -not (Get-Prop $dc 'alsoSink')) { continue }
    $tgt = Get-SinkTargetFree -DriveCfg $dc -Stat $s
    $note = ''
    $maxUnit = Get-Prop $dc 'maxUnitGB'
    if ($maxUnit) { $note = ("small units only (<= {0} GB)" -f $maxUnit) }
    if (Get-Prop $dc 'exemptHeadroomRule') { $note = ($note + '  50% rule off').Trim() }
    $room = $s.Free - $tgt
    $fits = if ($room -gt 0) { ("{0:N1} GB of room" -f ($room / $GB)) } else { 'at target' }
    Write-Host ('{0,-5} {1,8:N1}GB {2,7:N1}GB  {3,-18} {4}' -f $s.Letter, ($s.Free / $GB), ($tgt / $GB), $fits, $note) `
        -ForegroundColor $(if (($s.Free - $tgt) -gt 0) { 'Yellow' } else { 'Green' })
}

# C: is the landing zone, so its free space is the download signal
$c = $stats['C:']
$signal = Get-Prop ($cfg.drives.'C:') 'downloadSignalGB'
if ($c -and $signal) {
    Write-Host ''
    if (($c.Free / $GB) -ge $signal) {
        Write-Host ("C: has {0:N1} GB free - time to download more content" -f ($c.Free / $GB)) -ForegroundColor Green
    }
    else {
        Write-Host ("C: has {0:N1} GB free - download more once it passes {1} GB" -f ($c.Free / $GB), $signal) -ForegroundColor DarkGray
    }
}

Write-State -Phase 'planning' -Current '' -Moved 0 -Planned 0 -Skipped 0

if ($Report) {
    Write-State -Phase 'done' -Current '' -Moved 0 -Planned 0 -Skipped 0
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
    return
}

# ---------------------------------------------------------------- planning --
$sources = @()
foreach ($letter in ($stats.Keys | Sort-Object)) {
    $dc = $cfg.drives.$letter
    if (-not (Get-Prop $dc 'sources')) { continue }
    $s = $stats[$letter]
    # drain "always" means C: gives up space whenever any sink can take it
    $need = ((Get-Prop $dc 'drain') -eq 'always')
    $maxFill = Get-Prop $dc 'maxFillPct'
    if ($maxFill -and $s.FreePct -lt (100 - $maxFill)) { $need = $true }
    if ($need) {
        # InCascade records whether this drive declared a place in the chain at
        # all. A source with no priority is not a link in the cascade, so the
        # direction check below leaves it unrestricted instead of freezing it -
        # with no position of its own there is nothing to compare against.
        $prio = Get-Prop $dc 'priority'
        $sources += [pscustomobject]@{
            Letter = $letter; Cfg = $dc; Stat = $s
            Priority = if ($null -ne $prio) { [int]$prio } else { 99 }
            InCascade = ($null -ne $prio)
        }
    }
}

$sinks = @()
foreach ($letter in ($stats.Keys | Sort-Object)) {
    $dc = $cfg.drives.$letter
    # A drive can be both. K: sheds what it cannot hold but still accepts
    # content from elsewhere when it has room, so "sources" alone no longer
    # disqualifies it: alsoSink opts it back in.
    if ((Get-Prop $dc 'sources') -and -not (Get-Prop $dc 'alsoSink')) { continue }
    $s = $stats[$letter]
    $reserve = Get-SinkTargetFree -DriveCfg $dc -Stat $s
    $headroom = $s.Free - $reserve - ([double]$cfg.copyMarginGB * $GB)
    if ($headroom -gt 0) {
        # Priority/InCascade mirror the source side so the chain can be checked in
        # both directions. H: and J: declare no priority and are extra
        # destinations rather than links in the cascade.
        $prio = Get-Prop $dc 'priority'
        $sinks += [pscustomobject]@{
            Letter = $letter; Cfg = $dc; Stat = $s; Headroom = $headroom; Reserve = $reserve
            Priority = if ($null -ne $prio) { [int]$prio } else { 99 }
            InCascade = ($null -ne $prio)
        }
    }
}

# The last drive in the chain is a parking lot: content that lands there is
# effectively stranded, because nothing downstream can move it again. Mark it on
# both lists so the rules below can recognise it by role rather than by hardcoding
# a letter. A chain with no priorities at all leaves IsLast false everywhere and
# every drive stays unrestricted.
#
# The parking lot is a DECLARED role, so it is resolved from the configured
# priorities of every drive in config.json - not from whichever drives happen to
# be sources or sinks on a given run.
#
# That distinction is the whole bug. Deriving the chain end from the live lists
# let the hat slide: when F: (priority 5) was neither a source nor had headroom
# to be a sink, the highest priority present collapsed to G: (4), G: was marked
# IsLast, and Test-Forward then correctly applied the parking-lot give-back rule
# to move G: content BACKWARDS to D: (3). Observed live on 2026-10-04:
# "G -> D:\Séries\..." on four files in one apply run, and planned on every run
# since 2026-10-03 16:05. A drive must never inherit the role because a different
# drive is absent, unplugged, or full - only because config says it is last.
$chainMax = 0
$chainMaxFound = $false
foreach ($dp in $cfg.drives.PSObject.Properties) {
    $dprio = Get-Prop $dp.Value 'priority'
    if ($null -eq $dprio) { continue }
    $chainMaxFound = $true
    if ([int]$dprio -gt $chainMax) { $chainMax = [int]$dprio }
}
foreach ($x in @($sources) + @($sinks)) {
    $x | Add-Member -NotePropertyName IsLast -NotePropertyValue ($chainMaxFound -and $x.InCascade -and $x.Priority -eq $chainMax) -Force
}

# True when $To is downstream of $From and may therefore receive from it.
# The cascade runs one way: C: -> K: -> D: -> G: -> F:. Content taken off a drive
# lands further along the chain, never back on an earlier one, otherwise a drive
# can be drained and refilled in the same run and the ordering means nothing.
# Picking purely by tightness ignored this and moved G: content onto D:.
#
# One step back is allowed, but only from the parking lot. F: is last, so its
# content has nowhere left to go; handing it back to G: keeps that space in
# circulation instead of freezing it on a drive that will never release it.
#
# A drive that declares no priority (H:, J:) is not a link in the chain, so it
# stays reachable from anywhere; likewise a source with no priority, which has no
# position to be compared against.
function Test-Forward {
    param($From, $To)
    if (-not $From -or -not $From.InCascade) { return $true }
    if (-not $To.InCascade) { return $true }
    if ($To.Priority -gt $From.Priority) { return $true }
    return ($From.IsLast -and $To.Priority -eq ($From.Priority - 1))
}

# Adds the reason the parking lot is special. F: accepts from the drive just
# upstream only to make room for something waiting for that room - otherwise G:
# would spend the run relocating its own library into a drive that gives nothing
# back, which is churn with no gain. $Demand counts the units that were turned
# away from each drive for lack of space earlier in this run.
function Test-Shed {
    param($From, $To, $Demand, $UnitKey)
    if (-not (Test-Forward -From $From -To $To)) { return $false }
    if (-not $From -or -not $From.InCascade) { return $true }
    if (-not $To.InCascade) { return $true }
    if (-not $To.IsLast) { return $true }
    # Content the parking lot handed back does not go straight back in. Without
    # this the give-back is pointless: the unit sits one step upstream with room
    # in front of it and is returned on the very next run.
    if ($UnitKey -and $script:GivenBack.ContainsKey($UnitKey)) { return $false }
    $waiting = 0
    if ($Demand -and $Demand.ContainsKey($From.Letter)) { $waiting = [int]$Demand[$From.Letter] }
    return ($waiting -gt 0)
}

# --- parking-lot give-back ledger --------------------------------------------
# The parking lot may hand content back one step so its space stays in
# circulation. Nothing recorded that, so the next run saw the same content one
# step upstream with room in front of it and sent it straight back: observed on
# 2026-10-03 as F: -> G: -> F: on a single file, six times, an hour apart, every
# copy paid for in full and undone an hour later.
#
# So a unit that has been given back is remembered here and the parking lot then
# refuses it until the record ages out. The key is the library plus the path
# relative to the library root, which survives the move because Invoke-Move
# preserves that layout.
#
# Every failure path degrades to an empty ledger, which is exactly the previous
# behaviour. A missing, corrupt or unwritable ledger must never be able to stop a
# move - this is a convenience against churn, not a correctness mechanism.
$script:GivenBack = @{}
$script:GivenBackMaxAgeDays = 7

function Read-GivenBackLedger {
    param([string]$Path, [int]$MaxAgeDays)
    $kept = @{}
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $kept }
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if (-not $raw) { return $kept }
        $loaded = $raw | ConvertFrom-Json
        if (-not $loaded) { return $kept }
        # Timestamps are written as UTC round-trip ("o"), which sorts correctly
        # as text - so ageing out needs no date parsing and no locale.
        $cut = (Get-Date).ToUniversalTime().AddDays(-$MaxAgeDays).ToString('o')
        foreach ($p in $loaded.PSObject.Properties) {
            $v = [string]$p.Value
            if ($v.Length -lt 20) { continue }
            if ($v -ge $cut) { $kept[$p.Name] = $v }
        }
    }
    catch { return @{} }
    return $kept
}

function Save-GivenBackLedger {
    param([string]$Path, $Ledger)
    try {
        $json = [ordered]@{}
        foreach ($k in ($Ledger.Keys | Sort-Object)) { $json[$k] = $Ledger[$k] }
        $tmp = "$Path.tmp"
        [System.IO.File]::WriteAllText($tmp, ($json | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
    }
    catch {
        # Losing the ledger only means the give-back loop can resume. Say so,
        # because carrying on silently would hide the write failure.
        Write-Host ("  note: could not update the give-back ledger ({0}) - churn protection is off for now" -f $_.Exception.Message) -ForegroundColor DarkYellow
    }
}

Write-Host ''
if (-not $sources.Count) {
    Write-Host 'No source drive is over its limit. Nothing to do.' -ForegroundColor Green
    Write-State -Phase 'idle' -Current '' -Moved 0 -Planned 0 -Skipped 0
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
    return
}
if (-not $sinks.Count) {
    Write-Host ''
    Write-Host 'ALL SINKS ARE FULL - the balancer is idle.' -ForegroundColor Yellow
    Write-Host 'Every destination has reached its target free space, so there is nowhere to move to.'
    Write-Host 'Free space (or add a drive) and the next run will move content again.'
    Write-Host "Planned moves: 0   (mode: $(if ($Apply) { 'APPLY' } else { 'dry run' }))"
    Write-State -Phase 'idle' -Current '' -Moved 0 -Planned 0 -Skipped 0
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
    return
}

# gather everything that could move, biggest first
$allUnits = @()
$rootMap = @{}

# $failingDisks was already resolved before the recycle bin pass, which needs it
# too. $unreadableDrives is built here, per root, as the roots are walked.
$unreadableDrives = @{}

foreach ($lib in $cfg.libraries) {
    foreach ($root in $lib.roots) {
        $letter = $root.Substring(0, 2).ToUpperInvariant()
        $rootMap["$($lib.name)|$letter"] = $root
        if (-not $stats.ContainsKey($letter)) { continue }

        # Refuse to enumerate a drive whose disk is logging I/O errors. Reading
        # it is what hangs, and a skipped scan costs one run; a hung scan costs
        # the machine.
        $diskNo = Get-DriveDiskNumber -Letter $letter
        if ($null -ne $diskNo -and $failingDisks -contains $diskNo) {
            if (-not $unreadableDrives.ContainsKey($letter)) {
                Write-Warning ("not reading {0} - disk {1} has logged hardware errors. Treat it as failed until it is replaced or the errors stop." -f $letter, $diskNo)
                $unreadableDrives[$letter] = $diskNo
            }
            continue
        }

        foreach ($u in Get-Units -Library $lib -Root $root -Cutoff $cutoff) {
            $u | Add-Member -NotePropertyName Library -NotePropertyValue $lib.name -Force
            $u | Add-Member -NotePropertyName Root -NotePropertyValue $root -Force
            $u | Add-Member -NotePropertyName Drive -NotePropertyValue $letter -Force
            $allUnits += $u
        }
    }
}

$planned = 0; $moved = 0; $skipped = 0; $cascadeBlocked = 0; $noDemand = 0
Write-Host ''
Write-Host ("MOVES  (mode: {0})" -f $(if ($Apply) { 'APPLY' } else { 'DRY RUN - nothing will be touched' })) -ForegroundColor Cyan
Write-Host ('-' * 74)

# One shared queue of candidates. Movies and episodes compete for the same
# room, so a 40 GB film that will not fit does not stop a 2 GB episode from
# moving, and a full D: does not stop J: from being used. Sources are still
# honoured in priority order (C: before K:), and within a source the smallest
# unit is offered first because it packs into whatever room is left over.
$order = Get-Prop $cfg 'unitOrder'
if (-not $order) { $order = 'smallestFirst' }
$rank = @{}
$i = 0
foreach ($src in ($sources | Sort-Object Priority)) { $rank[$src.Letter] = $i; $i++ }

# Each source's place in the cascade, keyed by letter because the pool carries
# Drive rather than the source object.
$chain = @{}
foreach ($src in $sources) { $chain[$src.Letter] = $src }

$pool = @()
foreach ($src in ($sources | Sort-Object Priority)) {
    Write-Host ("source {0}: {1:N1} GB free" -f $src.Letter, ($src.Stat.Free / $GB)) -ForegroundColor Cyan
    $here = @($allUnits | Where-Object { $_.Drive -eq $src.Letter })
    foreach ($u in ($here | Where-Object { $_.Skip })) {
        Write-Host ("  skip (fresh)    [{0}] {1}  - {2}" -f $u.Drive, $u.Name, $u.Skip) -ForegroundColor DarkGray
        $skipped++
    }
    $pool += @($here | Where-Object { -not $_.Skip })
}
$sizeKey = if ($order -eq 'largestFirst') { { -[double]$_.Size } } else { { [double]$_.Size } }
$pool = @($pool | Sort-Object @{e = { $rank[$_.Drive] } }, @{e = $sizeKey })

# Units turned away from a drive for want of space, per drive. The pool is walked
# in cascade order, so by the time a middle drive reaches its own content every
# upstream drive has already had its chance and the count of what is waiting on
# it is known. That is what lets G: tell "I must free up for D:" apart from "I
# would just be shuffling into F: for nothing".
$demand = @{}

# The give-back ledger, read once per run. It names the units the parking lot has
# already handed back, so the parking lot will not take them straight back in.
$givenBackFile = Join-Path $logDir 'givenback.json'
$script:GivenBack = Read-GivenBackLedger -Path $givenBackFile -MaxAgeDays $script:GivenBackMaxAgeDays
$givenBackDirty = $false
if ($script:GivenBack.Count) {
    Write-Host ("  {0} unit(s) were given back by the parking lot; it will not take them again for {1} day(s)." -f $script:GivenBack.Count, $script:GivenBackMaxAgeDays) -ForegroundColor DarkGray
}

foreach ($u in $pool) {
    if (Test-UnitLocked -Unit $u) {
            Write-Host ("  skip (in use)   [{0}] {1}" -f $u.Drive, $u.Name) -ForegroundColor DarkGray
            Write-Log 'skip_in_use' @{ path = $u.Path; sizeGB = [math]::Round($u.Size / $GB, 2) }; $skipped++; continue
        }
        $from = $chain[$u.Drive]
        # Library plus the path relative to the library root. Stable across
        # drives, because Invoke-Move preserves that layout under the
        # destination root - so the key still matches after the unit has moved.
        $unitKey = '{0}|{1}' -f $u.Library, $u.SubPath
        $target = $null
        # Downstream candidates only, then tightest-first within that set so a
        # small drive like J: actually gets used instead of everything piling
        # onto the roomiest one.
        #
        # Two exclusions happen here rather than inside the loop. Never the drive
        # the unit is already on: K: is both source and sink, so without it a
        # unit could be "moved" onto itself. And never a drive upstream in the
        # cascade, which is what used to send G: content to D:.
        $forward = @($sinks | Where-Object {
            $_.Letter -ne $u.Drive -and (Test-Shed -From $from -To $_ -Demand $demand -UnitKey $unitKey)
        })
        foreach ($snk in ($forward | Sort-Object -Property Headroom)) {
            $snkMaxUnit = Get-Prop $snk.Cfg 'maxUnitGB'
            if ($snkMaxUnit -and ($u.Size / $GB) -gt $snkMaxUnit) { continue }
            if ($u.Size -gt $snk.Headroom) { $demand[$snk.Letter] = 1 + [int]$demand[$snk.Letter]; continue }
            # A copy needs slack beyond the file size. On a nearly-full volume
            # NTFS cannot place a file that nominally "fits", so the run fails
            # with insufficient disk space partway through. Requiring the unit
            # to be at most maxUnitPctOfFree of what is actually free keeps a
            # clear margin: 22 GB free accepts an 11 GB file, not a 19 GB one.
            $snkPct = Get-Prop $snk.Cfg 'maxUnitPctOfFree'
            if (-not $snkPct) { $snkPct = Get-Prop $cfg 'maxUnitPctOfFree' }
            if ((Get-Prop $snk.Cfg 'exemptHeadroomRule')) { $snkPct = $null }
            if ($snkPct -and ($u.Size -gt ($snk.Stat.Free * [double]$snkPct / 100))) {
                $demand[$snk.Letter] = 1 + [int]$demand[$snk.Letter]; continue
            }
            # resolve the sink's own configured root for this library, never a
            # string-substituted path: C:\Users\YOURNAME\Downloads\Filmes would
            # otherwise become D:\Users\YOURNAME\Downloads\Filmes, which is not a
            # Plex library location at all.
            $destRoot = $rootMap["$($u.Library)|$($snk.Letter)"]
            if (-not $destRoot) { continue }
            # episodes keep their show/season folder on the destination
            $destPath = Join-Path $destRoot $u.SubPath
            $clash = Test-DestinationFree -DestPath $destPath -SizeBytes $u.Size
            if ($clash) { continue }
            $target = @{ Sink = $snk; DestPath = $destPath }
            break
        }
        if (-not $target) {
            # say why, so "no room" is distinguishable from "not worth the risk"
            # and from "the only drives with space are upstream"
            $biggest = ($sinks | ForEach-Object { $_.Stat.Free } | Measure-Object -Maximum).Maximum
            $why = 'no room'
            $upstream = @($sinks | Where-Object { $_.Letter -ne $u.Drive }).Count
            if (-not $forward.Count -and $upstream) {
                # Two different situations look identical from here, so tell them
                # apart: the parking lot was the only candidate and it is closed
                # for want of something waiting, or there is simply nothing
                # downstream in the chain with room left.
                $downstream = @($sinks | Where-Object {
                    $_.Letter -ne $u.Drive -and (Test-Forward -From $from -To $_)
                })
                if ($downstream.Count) { $why = 'no demand'; $noDemand++ }
                else { $why = 'cascade'; $cascadeBlocked++ }
            }
            elseif ($u.Size -gt $biggest) { $why = 'drive too small' }
            else {
                $pct = Get-Prop $cfg 'maxUnitPctOfFree'
                if ($pct -and ($u.Size -gt ($biggest * [double]$pct / 100))) {
                    $why = ("over {0}% free ({1:N1}>{2:N1}GB)" -f
                        $pct, ($u.Size / $GB), ($biggest * [double]$pct / 100 / $GB))
                }
            }
            $tag = if ($u.Kind -eq 'episode') { 'ep  ' } else { 'film' }
            Write-Host ("  {0}  skip ({1,-8}) [{2}] {3}  ({4:N1} GB)" -f $tag, $why, $u.Drive, $u.Name, ($u.Size / $GB)) -ForegroundColor DarkGray
            $skipped++; continue
        }

        $verb = if ($Apply) { 'moving  ' } else { 'would move' }
        $tag = if ($u.Kind -eq 'episode') { 'ep  ' } else { 'film' }
        Write-Host ("  {0} {1} [{2}] {3}  ({4:N1} GB)  ->  {5}" -f $verb, $tag, $u.Drive, $u.Name, ($u.Size / $GB), $target.DestPath) -ForegroundColor $(if ($Apply) { 'Yellow' } else { 'White' })
        Write-State -Phase 'moving' -Current $u.Name -Moved $moved -Planned $planned -Skipped $skipped
        if (Invoke-Move -Unit $u -DestRoot $target.Sink.Letter -DestPath $target.DestPath -DriveStat $target.Sink.Stat -DestCfg $target.Sink.Cfg) {
            $planned++; if ($Apply) { $moved++ }
            # Note a give-back so the parking lot will not take this unit straight
            # back in on the next run - that is the whole point of the give-back,
            # and without the note it undoes itself an hour later. Only in apply
            # mode: a dry run moves nothing, and recording there would refuse a
            # move that never actually happened.
            if ($Apply -and $from -and $from.IsLast -and $target.Sink.InCascade -and
                $target.Sink.Priority -eq ($from.Priority - 1)) {
                $script:GivenBack[$unitKey] = (Get-Date).ToUniversalTime().ToString('o')
                $givenBackDirty = $true
                Write-Host ("  noted in the give-back ledger - {0} will not be returned to {1} for {2} day(s)" -f $u.Name, $target.Sink.Letter, $script:GivenBackMaxAgeDays) -ForegroundColor DarkGray
            }
            # Re-read the live figure only when bytes actually moved: on a
            # nearly-full volume the reported number drifts and a live read is
            # the truth. A dry run writes nothing, so re-reading would hand back
            # the untouched free space and throw away the simulated decrement
            # Invoke-Move just applied - every file would then be measured
            # against the destination's full starting room, and the plan would
            # promise thousands of GB of moves into a drive holding a few GB.
            if ($Apply) {
                $target.Sink.Stat.Free = Get-LiveFree -Letter $target.Sink.Letter
                $target.Sink.Stat.FreePct = if ($target.Sink.Stat.Total) {
                    [math]::Round(100 * $target.Sink.Stat.Free / $target.Sink.Stat.Total, 1) } else { 0 }
            }
            $target.Sink.Headroom = $target.Sink.Stat.Free - $target.Sink.Reserve - ([double]$cfg.copyMarginGB * $GB)
        }
        else {
            $skipped++
            # this drive has just proven it cannot take a copy; stop offering it
            # for the rest of the run instead of failing repeatedly
            if ($Apply) {
                $target.Sink.Stat.Free = Get-LiveFree -Letter $target.Sink.Letter
                $target.Sink.Headroom = $target.Sink.Stat.Free - $target.Sink.Reserve - ([double]$cfg.copyMarginGB * $GB)
                if ($target.Sink.Headroom -le 0) {
                    $sinks = @($sinks | Where-Object { $_.Letter -ne $target.Sink.Letter })
                    Write-Host ("  {0} is out of usable space - removed from the sink list" -f $target.Sink.Letter) -ForegroundColor Yellow
                }
            }
        }
}

if ($givenBackDirty) { Save-GivenBackLedger -Path $givenBackFile -Ledger $script:GivenBack }

Write-Host ''
Write-Host ("planned: {0}   moved: {1}   skipped: {2}   log: {3}" -f $planned, $moved, $skipped, $logFile) -ForegroundColor Cyan
if ($cascadeBlocked) {
    Write-Host ("{0} unit(s) had nowhere downstream in the chain with room - left where they are." -f $cascadeBlocked) -ForegroundColor DarkGray
}
if ($noDemand) {
    Write-Host ("{0} unit(s) could only have gone to the parking lot, and nothing upstream is waiting for the room, so they were left put." -f $noDemand) -ForegroundColor DarkGray
}
if ($demand.Count) {
    $waiting = ($demand.Keys | Sort-Object | ForEach-Object { "$_=$($demand[$_])" }) -join '  '
    Write-Host ("waiting for room: {0}" -f $waiting) -ForegroundColor DarkGray
}
if (-not $Apply -and $planned) { Write-Host 'Re-run with -Apply to perform these moves.' -ForegroundColor Green }

Write-State -Phase 'done' -Current '' -Moved $moved -Planned $planned -Skipped $skipped

# give the mutex back, otherwise the next run is locked out until this
# process exits on its own
try { $mutex.ReleaseMutex() } catch { }
$mutex.Dispose()
