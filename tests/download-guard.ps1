# The qBittorrent download guard: a file is held while a torrent still owns it.
#
# This replaces a rule that was purely time-based - anything modified in the last
# 24 hours was left alone - which held back a whole library because a file inside it
# was touched that morning, and knew nothing about what was actually downloading.
#
# Five ways this can be quietly wrong, each of which looks like it is working:
#
#   1. Blocking the folder instead of the file. save_path is whatever folder the
#      user picked when adding a torrent, and it is very often a whole library.
#      Blocking on it held 48 files when only 6 torrents existed, every one of them
#      under Downloads\Filmes and Downloads\S\u00e9ries - including finished movies
#      belonging to no torrent at all. The per-torrent file list is the only precise
#      answer, and it is what is used.
#   2. Encoding. qBittorrent replies "application/json" with no charset, so
#      PowerShell decodes it as Latin-1 and an accented root arrives mangled. Every
#      path comparison then fails and the guard never blocks anything.
#   3. Array parsing. On PowerShell 5.1, @($json | ConvertFrom-Json) wraps a
#      top-level JSON array into ONE element, so foreach walks once over the whole
#      list and collects nothing.
#   4. Empty list. "[]" parses to an empty array, and return of an empty array
#      assigns $null - which reads as "the client did not answer" and silently
#      falls back to the time rule on a machine with no torrents.
#   5. A finished torrent treated as finished rather than as still owned.
#      qBittorrent lists seeded torrents indefinitely.
#
# The client is faked by tests\_fake-qbittorrent.ps1 in a child process. The real
# qBittorrent binary is deliberately never started or stopped by a test.
#
# Note on ASCII: this file must stay pure ASCII, because powershell -File reads a
# script as ANSI. The accented folder name is built with [char]0x00E9.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

. (Lift-Functions -Script 'balance.ps1' -Names 'Get-Prop', 'Read-QbtTorrents', 'Read-QbtFiles', 'Get-DownloadGuard', 'Test-Downloading')

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('dlguard-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $root -Force | Out-Null

$bodyFile = Join-Path $root 'body.json'
$filesFile = Join-Path $root 'files.json'
[System.IO.File]::WriteAllText($bodyFile, '[]', [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($filesFile, '{}', [System.Text.UTF8Encoding]::new($false))

# ---- bring up the fake client ---------------------------------------------------
$server = $null
$port = 0
foreach ($candidate in 47311, 47312, 47313, 47314, 47315, 47316) {
    $readyFile = Join-Path $root "ready-$candidate.txt"
    $errFile = Join-Path $root "err-$candidate.txt"
    $p = Start-Process -FilePath 'powershell' -PassThru -NoNewWindow `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $PSScriptRoot '_fake-qbittorrent.ps1'),
            '-Port', $candidate, '-BodyFile', $bodyFile,
            '-FilesFile', $filesFile, '-ReadyFile', $readyFile) `
        -RedirectStandardError $errFile
    $deadline = (Get-Date).AddSeconds(30)
    $ready = $false
    while ((Get-Date) -lt $deadline -and -not $p.HasExited) {
        Start-Sleep -Milliseconds 200
        if (Test-Path -LiteralPath $readyFile) { $ready = $true; break }
    }
    if ($ready) { $server = $p; $port = $candidate; break }
    $why = if (Test-Path -LiteralPath $errFile) { [System.IO.File]::ReadAllText($errFile) } else { '(no stderr)' }
    Write-Host ("  port {0} would not start: {1}" -f $candidate, ($why -replace "`r?`n", ' '))
    try { if (-not $p.HasExited) { $p.Kill() } } catch { }
}
if (-not $server) {
    Write-Host 'could not start the fake qBittorrent; the suite cannot run' -ForegroundColor Red
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

$base = "http://127.0.0.1:$port/api/v2"

function Make-Cfg {
    param([hashtable]$Extra = @{})
    $h = @{ enabled = $true; url = $base; timeoutSeconds = 5; blockSeeded = $true
        startIfStopped = $false; stopAfterCheck = $false
        exePath = 'C:\does\not\exist.exe'; startTimeoutSeconds = 5 }
    foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }
    return [pscustomobject]@{
        downloadGuard = [pscustomobject]$h
        libraries     = @([pscustomobject]@{ name = 'Movies'; roots = @('C:\Movies') })
    }
}

$script:Cfg = Make-Cfg

# The guard caches for the life of the process, so every case clears it the way a
# fresh run would.
function Reset-Guard {
    $script:DownloadGuard = $null
    $script:cfg = $script:Cfg
}

function Torrent {
    param([string]$Hash, [string]$SavePath, $Progress = 0.5, [string]$State = 'stalledDL', [string]$Name = 'T')
    [pscustomobject]@{ name = $Name; hash = $Hash; progress = $Progress
        state = $State; save_path = $SavePath; content_path = $null }
}

function FileList {
    param([string[]]$Names)
    , @($Names | ForEach-Object { [pscustomobject]@{ name = $_; size = 100; progress = 0.5 } })
}

# Publishes both files. The fake re-reads them per request, so changing the
# torrent list needs no restart - just a cache clear.
function With-Torrents {
    param([object[]]$Torrents, [hashtable]$Files = @{})
    $json = ConvertTo-Json -InputObject @($Torrents) -Depth 4 -Compress
    [System.IO.File]::WriteAllText($bodyFile, $json, [System.Text.UTF8Encoding]::new($false))
    $map = [ordered]@{}
    foreach ($k in $Files.Keys) { $map[$k] = @($Files[$k]) }
    $filesJson = if ($map.Count) { ConvertTo-Json -InputObject $map -Depth 6 -Compress } else { '{}' }
    [System.IO.File]::WriteAllText($filesFile, $filesJson, [System.Text.UTF8Encoding]::new($false))
    Reset-Guard
}

try {
    # ---- 1. only files the torrent owns are held, not the whole folder -----
    # This is the bug the guard shipped with. save_path here is a library root, and
    # the torrent owns one file inside it.
    With-Torrents @(Torrent -Hash 'aaa' -SavePath 'C:\Movies' -Progress 1 -State 'stoppedUP' -Name 'Seeded') `
    @{ 'aaa' = (FileList @('Finished Movie (1999).mkv')) }
    $g = Get-DownloadGuard
    Assert-True 'guard reached the fake client' $g.Known
    Assert-Equal 'one file is held' $g.Files.Count 1
    Assert-Equal 'and no folder is held loosely' $g.Folders.Count 0
    Assert-True 'the file the torrent owns is held' (Test-Downloading 'C:\Movies\Finished Movie (1999).mkv')
    Assert-False 'a DIFFERENT file in the same folder is free' (Test-Downloading 'C:\Movies\Something Else.mkv')
    Assert-False 'a subfolder of it is free' (Test-Downloading 'C:\Movies\Sub\a.mkv')

    # ---- 2. a FINISHED torrent still blocks --------------------------------
    # The rule asked for is presence on the list, not progress.
    With-Torrents @(
        Torrent -Hash 'aaa' -SavePath 'C:\Movies\Seeded' -Progress 1 -State 'stoppedUP' -Name 'Seeded'
        Torrent -Hash 'bbb' -SavePath 'C:\Movies\Half' -Progress 0.5 -Name 'Half'
    ) @{
        'aaa' = (FileList @('Seeded.mkv'))
        'bbb' = (FileList @('Half.mkv'))
    }
    $g = Get-DownloadGuard
    Assert-Equal 'both torrents contribute a file' $g.Files.Count 2
    Assert-True 'a FINISHED torrent still blocks' (Test-Downloading 'C:\Movies\Seeded\Seeded.mkv')
    Assert-True 'an unfinished torrent blocks' (Test-Downloading 'C:\Movies\Half\Half.mkv')
    Assert-False 'a path outside every torrent is free' (Test-Downloading 'C:\Movies\Nothing\x.mkv')

    # ---- 3. blockSeeded false is the documented escape hatch ---------------
    $script:Cfg = Make-Cfg @{ blockSeeded = $false }
    Reset-Guard
    $g = Get-DownloadGuard
    Assert-Equal 'blockSeeded false: only the unfinished torrent is held' $g.Files.Count 1
    Assert-False 'blockSeeded false: the finished one is free' (Test-Downloading 'C:\Movies\Seeded\Seeded.mkv')
    Assert-True 'blockSeeded false: the unfinished one is still held' (Test-Downloading 'C:\Movies\Half\Half.mkv')
    $script:Cfg = Make-Cfg
    Reset-Guard

    # ---- 4. a torrent whose file list cannot be read falls back to the folder -
    # Never to nothing: guessing open here would let a half-written file move.
    With-Torrents @(Torrent -Hash 'aaa' -SavePath 'C:\Movies\Unlisted') @{}
    $g = Get-DownloadGuard
    Assert-True 'an unreadable file list is counted' ($g.Unreadable -eq 1)
    Assert-Equal 'and falls back to the folder' $g.Folders.Count 1
    Assert-Equal 'but holds no exact files' $g.Files.Count 0
    Assert-True 'so the whole folder is held' (Test-Downloading 'C:\Movies\Unlisted\anything.mkv')
    # and the fallback is still on a separator boundary
    Assert-False 'the fallback does not cover a shared prefix' (Test-Downloading 'C:\Movies\Unlisted-old\a.mkv')

    # ---- 5. nested paths, and the accented root must survive the round trip --
    # Decoded as Latin-1 the accented root arrives mangled, matches nothing, and the
    # guard is inert while appearing to be on.
    $accented = "C:\Users\YOURNAME\Downloads\S$([char]0x00E9)ries\Ted Lasso\Season 4"
    With-Torrents @(Torrent -Hash 'aaa' -SavePath $accented -Progress 0.3) `
    @{ 'aaa' = (FileList @('release folder\Ted Lasso S04E09.mkv', 'release folder\poster.png')) }
    $g = Get-DownloadGuard
    Assert-True 'the accented save_path was read correctly' ($g.Files -contains "$accented\release folder\Ted Lasso S04E09.mkv")
    Assert-True 'a file under it is held' (Test-Downloading "$accented\release folder\Ted Lasso S04E09.mkv")
    Assert-False 'a file beside it is free' (Test-Downloading "$accented\Something Else.mkv")
    Assert-False 'the unaccented spelling is a different folder' (Test-Downloading 'C:\Users\YOURNAME\Downloads\Series\Ted Lasso\Season 4\x.mkv')

    # ---- 6. array parsing: six torrents must yield six files ---------------
    # @($json | ConvertFrom-Json) produces ONE element here, which looks exactly
    # like a working guard with nothing to hold.
    $t6 = @(1..6 | ForEach-Object { Torrent -Hash "h$_" -SavePath "C:\T$_" -Progress 0.1 -Name "T$_" })
    $f6 = [ordered]@{}
    foreach ($i in 1..6) { $f6["h$i"] = FileList @("file$i.mkv") }
    With-Torrents $t6 $f6
    $g = Get-DownloadGuard
    Assert-Equal 'six torrents are six files, not one' $g.Files.Count 6
    Assert-True 'the sixth is really there' (Test-Downloading 'C:\T6\file6.mkv')

    # ---- 7. an empty torrent list holds nothing, and is still a real answer --
    With-Torrents @()
    $g = Get-DownloadGuard
    Assert-True 'an empty list is still a known answer' $g.Known
    Assert-Equal 'an empty list holds nothing' $g.Files.Count 0
    Assert-False 'nothing is held' (Test-Downloading 'C:\Movies\a.mkv')

    # ---- 8. an unreachable client falls back, it does not fail open --------
    $script:Cfg = Make-Cfg @{ url = 'http://127.0.0.1:1/api/v2'; startIfStopped = $false }
    Reset-Guard
    $g = Get-DownloadGuard
    Assert-False 'an unreachable client is not Known' $g.Known
    Assert-True 'and it says why' ($g.Reason -match 'not reachable')
    Assert-False 'and it holds nothing rather than guessing' (Test-Downloading 'C:\Movies\a.mkv')

    # ---- 9. an unreachable client with startIfStopped is reported ----------
    # The wording depends on whether qBittorrent happens to be running on the
    # machine running the suite, which a test must not depend on.
    $script:Cfg = Make-Cfg @{ url = 'http://127.0.0.1:1/api/v2'; startIfStopped = $true; exePath = 'C:\does\not\exist.exe'; startTimeoutSeconds = 5 }
    Reset-Guard
    $g = Get-DownloadGuard
    Assert-False 'unreachable plus startIfStopped leaves the guard Unknown' $g.Known
    Assert-True 'and it explains itself' ($g.Reason.Length -gt 10)
    Assert-False 'and it holds nothing rather than guessing' (Test-Downloading 'C:\Movies\a.mkv')

    # ---- 10. the wiring, so none of the above can be bypassed ----------------
    $src = [System.IO.File]::ReadAllText((Join-Path $script:TestRoot 'balance.ps1'), [System.Text.Encoding]::UTF8)
    Assert-True 'Get-Units consults the guard' ($src -match 'Test-Downloading \$f\.FullName')
    Assert-True 'a downloading file is skipped by name' ($src -match "'still downloading'")
    Assert-True 'the time rule is gated on the guard being unknown' ($src -match '\$useTimeFallback -and \$f\.LastWriteTime -gt \$Cutoff')
    Assert-True 'blockSeeded defaults to true' ($src -match "Get-Prop \`$settings 'blockSeeded' \`$true")
    Assert-True 'the JSON is decoded as UTF-8' ($src -match '\[System\.Text\.Encoding\]::UTF8\.GetString\(\$resp\.RawContentStream\.ToArray\(\)\)')
    Assert-True 'ConvertFrom-Json is not wrapped in @()' ($src -match 'ConvertFrom-Json -InputObject \$json')
    Assert-True 'an empty list survives the return' ($src -match 'return , \$list')
    Assert-True 'the per-torrent file list is asked for' ($src -match 'torrents/files\?hash=')
    Assert-True 'and its result is what is held' ($src -match '\$guard\.Files \+= \(Join-Path \$savePath \$rel\)')
    Assert-True 'startIfStopped is honoured' ($src -match "Get-Prop \`$settings 'startIfStopped'")
    Assert-True 'a client it started is closed again' ($src -match 'app/shutdown')
    Assert-True 'the close is in a finally, so a failure cannot leak it' ($src -match '(?s)finally\s*\{[^}]*app/shutdown')

    # ---- 11. who started a client, and who may close it ----------------------
    # On 2026-10-07 this guard closed a torrent client the user had running.
    # Windows launches qBittorrent from the Run key, its tray icon appears before
    # the WebUI binds port 8080, and the guard used to ask "is a qbittorrent
    # process running?" at exactly that gap. The answer was no, so it started a
    # second instance, set the flag that says "I started it", and then shut the
    # whole thing down one second after the API came up. The client's own log:
    #   01:05:35 WebUI: Now listening on port 8080
    #   01:05:36 qBittorrent termination initiated
    #
    # Ownership is now a recorded pid rather than a flag, and these check that the
    # close is gated on it. Read from the source, because the failure mode is the
    # absence of a guard and calling the function cannot prove one is absent.
    Assert-True 'the started instance is recorded by pid' ($src -match '\$ourPid = \$started\.Id')
    Assert-True 'the close requires that pid to be set' ($src -match 'if \(\$null -ne \$ourPid -and \$stopAfterCheck\)')
    # Both conditions, not either: the flag alone was the bug.
    Assert-True 'the close also requires that pid to still be the only one running' `
        ($src -match '\$live\.Count -eq 1 -and \$live\[0\]\.Id -eq \$ourPid')
    Assert-True 'a client it did not start is never shut down' `
        ($src -match 'left qBittorrent running: it is not the instance this guard started')
    # The flag that could be set by a race must be gone entirely.
    Assert-False 'the old boolean ownership flag is gone' ($src -match 'weStartedIt')

    # ---- 12. waiting for Windows rather than racing it -----------------------
    # The same gap, before starting anything: a freshly booted machine may still
    # be launching the client, and only time actually spent since boot is counted
    # so an established machine does not wait at all.
    Assert-True 'the boot grace period is configurable' ($src -match "Get-Prop \`$settings 'bootGraceSeconds' 300")
    Assert-True 'and it measures uptime rather than waiting blindly' `
        ($src -match 'LastBootUpTime')
    Assert-True 'a client that is running but not yet answering is waited for' `
        ($src -match 'A process exists but the API is not up yet')
    # Starting a second instance is only allowed when nothing is running at all.
    Assert-True 'a second instance is started only when none exists' `
        ($src -match [regex]::Escape('if ($null -eq $torrents -and -not (Get-Process qbittorrent'))

    Write-TestResult -Suite 'download-guard'
}
finally {
    try { if ($server -and -not $server.HasExited) { $server.Kill() } } catch { }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}