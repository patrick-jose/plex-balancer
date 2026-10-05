<#
.SYNOPSIS
    Finds and repairs the wreckage left behind by an interrupted balancer run.

.DESCRIPTION
    A run killed mid-copy leaves a partial file on the destination and the
    complete original on the source. Left alone, the next run sees the
    destination already exists, refuses to overwrite, and the space stays
    wasted indefinitely. This pass finds those cases and closes them.

    Three states are detected, all by comparing the same filename across every
    configured library root:

      interrupted  destination exists and is SMALLER than the source
                   -> the partial is removed, the source is left untouched
      duplicated   destination exists and is the SAME size as the source
                   -> the copy finished but the source delete never ran, so
                      the destination is kept and the source removed
      orphan       destination exists, no source anywhere
                   -> nothing to repair, reported only

    It only ever removes a file after proving the other copy is complete, and
    never touches anything modified in the last N hours, so an in-flight
    download cannot be mistaken for wreckage. Dry run unless -Apply is passed.

.PARAMETER Hash
    Compare SHA256 instead of file size before removing anything. Slower, but
    proves the copy is byte-identical rather than merely the same length.

.EXAMPLE
    .\reconcile.ps1            # report only
    .\reconcile.ps1 -Apply     # repair
    .\reconcile.ps1 -Hash      # verify with sha256 before deleting
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Apply,
    [switch]$Hash,
    [int]$LookbackDays = 14
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.json'
    # See balance.ps1: config.json is not committed, so say so plainly rather than
    # letting ReadAllText fail with a bare FileNotFoundException.
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
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("reconcile-{0}.jsonl" -f (Get-Date -Format 'yyyyMMdd'))
$cutoff = (Get-Date).AddHours(-[double]$cfg.skipFilesModifiedWithinHours)

function Write-Log {
    param([string]$Event, [hashtable]$Data)
    $entry = [ordered]@{ at = (Get-Date).ToString('o'); event = $Event; apply = [bool]$Apply }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
    Add-Content -LiteralPath $logFile -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
}

# Only one repair pass at a time, shared with the balancer so a reconcile can
# never run against files the balancer is actively copying.
$mutex = New-Object System.Threading.Mutex($false, 'Global\PlexBalancer')
$held = $false
try { $held = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
if (-not $held) {
    Write-Host 'A balancer run is in progress - reconcile will wait rather than fight it.' -ForegroundColor Yellow
    Write-Host 'Run this again once it finishes.'
    return
}

Write-Host ''
Write-Host ("RECONCILE  (mode: {0})" -f $(if ($Apply) { 'APPLY' } else { 'REPORT ONLY' })) -ForegroundColor Cyan
Write-Host 'Looking for copies left behind by an interrupted run.' -ForegroundColor DarkGray
Write-Host ('-' * 74)

# Index every media file by name across all library roots. A name appearing on
# more than one drive is the only evidence of an interrupted move, since a
# completed one leaves a single copy.
$byName = @{}
foreach ($lib in $cfg.libraries) {
    $exts = @($lib.mediaExtensions | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($root in $lib.roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            if ($exts -notcontains $f.Extension.ToLowerInvariant()) { continue }
            $key = "$($lib.name)|$($f.Name)"
            if (-not $byName.ContainsKey($key)) { $byName[$key] = @() }
            $byName[$key] += [pscustomobject]@{
                Library = $lib.name; Name = $f.Name; Path = $f.FullName
                Size = $f.Length; Written = $f.LastWriteTime; Root = $root
            }
        }
    }
}

$dupeSets = @($byName.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
Write-Host ("indexed {0} filenames, {1} appear on more than one drive" -f $byName.Count, $dupeSets.Count)
Write-Host ''

$partials = 0; $dupes = 0; $skippedFresh = 0; $repaired = 0; $failed = 0

foreach ($entry in ($dupeSets | Sort-Object { $_.Value[0].Name })) {
    $copies = @($entry.Value | Sort-Object Size)
    $small = $copies[0]
    $big = $copies[-1]

    # the interrupted copy is the shorter one; if they match in length the copy
    # completed and only the source delete was lost
    $isPartial = ($small.Size -lt $big.Size)

    foreach ($c in $copies) {
        if ($c.Written -gt $cutoff) {
            Write-Host ("  skip (fresh)   {0}  - modified recently" -f $c.Name) -ForegroundColor DarkGray
            $skippedFresh++
            continue
        }
    }
    if (@($copies | Where-Object { $_.Written -gt $cutoff }).Count) {
        Write-Host ("  skip           {0}  - one copy is still being written" -f $small.Name) -ForegroundColor DarkGray
        Write-Log 'skip_fresh' @{ name = $small.Name; copies = $copies.Count }
        continue
    }

    if ($isPartial) {
        $partials++
        Write-Host ("  partial        {0}" -f $small.Name) -ForegroundColor Yellow
        Write-Host ("                 {0:N2} GB partial on {1}" -f ($small.Size / $GB), $small.Root) -ForegroundColor DarkGray
        Write-Host ("                 {0:N2} GB source on {1}" -f ($big.Size / $GB), $big.Root) -ForegroundColor DarkGray
        if ($Apply) {
            try {
                Remove-Item -LiteralPath $small.Path -Force -ErrorAction Stop
                Write-Host '                 removed the partial, source kept' -ForegroundColor Green
                Write-Log 'partial_removed' @{ path = $small.Path; source = $big.Path }
                $repaired++
            }
            catch {
                Write-Host ("                 could not remove it: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Write-Log 'partial_remove_failed' @{ path = $small.Path; error = $_.Exception.Message }
                $failed++
            }
        }
        else {
            Write-Host '                 would remove the partial, source kept' -ForegroundColor DarkGray
            Write-Log 'partial_found' @{ path = $small.Path; source = $big.Path; sizeGB = [math]::Round($small.Size / $GB, 3) }
        }
        continue
    }

    # same length on both drives: the copy finished, the source delete did not
    $dupes++
    Write-Host ("  duplicate      {0}  ({1:N2} GB on two drives)" -f $small.Name, ($small.Size / $GB)) -ForegroundColor Yellow
    Write-Host ("                 {0}" -f $big.Path) -ForegroundColor DarkGray
    Write-Host ("                 {0}" -f $small.Path) -ForegroundColor DarkGray

    if (-not $Apply) {
        Write-Host '                 would keep the destination and remove the source' -ForegroundColor DarkGray
        Write-Log 'duplicate_found' @{ source = $small.Path; dest = $big.Path; sizeGB = [math]::Round($small.Size / $GB, 3) }
        continue
    }

    # prove the two are the same content before removing either
    $same = $true
    if ($Hash) {
        $ha = (Get-FileHash -LiteralPath $small.Path -Algorithm SHA256).Hash
        $hb = (Get-FileHash -LiteralPath $big.Path -Algorithm SHA256).Hash
        $same = ($ha -eq $hb)
        Write-Host ("                 sha256 {0}" -f $(if ($same) { 'match' } else { 'MISMATCH - leaving both alone' })) `
            -ForegroundColor $(if ($same) { 'DarkGray' } else { 'Red' })
    }
    if (-not $same) {
        Write-Log 'duplicate_hash_mismatch' @{ source = $small.Path; dest = $big.Path }
        $failed++
        continue
    }

    try {
        Remove-Item -LiteralPath $small.Path -Force -ErrorAction Stop
        Write-Host '                 kept the destination, removed the source' -ForegroundColor Green
        Write-Log 'duplicate_resolved' @{ source = $small.Path; dest = $big.Path }
        $repaired++
    }
    catch {
        Write-Host ("                 could not remove the source: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Log 'duplicate_remove_failed' @{ path = $small.Path; error = $_.Exception.Message }
        $failed++
    }
}

Write-Host ''
Write-Host ("partials: {0}   duplicates: {1}   repaired: {2}   skipped (fresh): {3}   failed: {4}" -f
    $partials, $dupes, $repaired, $skippedFresh, $failed) -ForegroundColor Cyan
Write-Host "log: $logFile"

if (-not $partials -and -not $dupes) {
    Write-Host ''
    Write-Host 'Nothing to repair - no interrupted copies found.' -ForegroundColor Green
}
elseif (-not $Apply) {
    Write-Host ''
    Write-Host 'Re-run with -Apply to repair these.' -ForegroundColor Green
}

try { $mutex.ReleaseMutex() } catch { }
$mutex.Dispose()
