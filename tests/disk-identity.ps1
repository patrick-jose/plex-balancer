# Disk identity: attributing an event-log error to the drive that actually caused
# it, on a machine where Windows reassigns disk numbers.
#
# The bug this covers. Event 154 reads "Disco 3 (nome PDO: \Device\00000059)" and
# event 51 reads "\Device\Harddisk3\DR3". Both name a disk by its NUMBER and carry
# nothing else - no serial, no unique id, and the EventData is unnamed driver data.
# Disk numbers are reassigned across reboots and USB reconnects, so "disk 3" in
# September is not necessarily the drive that holds number 3 now.
#
# On 2026-10-06 that held H: out of a run. The drive that had really failed was K:,
# K: has since become disk 4, H: is disk 3, and every log line confidently blamed
# H: - while manual moves to H: worked perfectly the whole time.
#
# The fix cannot be retrospective - the events do not carry enough identity to tell
# two disks apart - so Resolve-FailingDrives records which unique id held each
# failing number while the errors were inside the window, and re-resolves the letter
# from that id. These checks drive it with an invented disk layout, so the exact
# situation that happened on this machine is tested without needing it to happen
# again.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

# Get-FailingDisks is lifted too so the call with -Numbers omitted really runs
# against the live event log rather than a stub. On a healthy machine it returns
# nothing at all, which is the exact shape that produced the $null.Count crash.
. (Lift-Functions -Script 'balance.ps1' -Names @(
        'Get-DiskIdentity', 'Read-DiskNumberMap', 'Write-DiskNumberMap',
        'Resolve-FailingDrives', 'Get-FailingDisks'))

# A stand-in for Get-Disk's output. Keys are unique ids; the value carries the disk
# number it holds now and the letters currently mounted from it.
function New-Layout {
    param([hashtable]$Pairs)
    $out = @{}
    foreach ($uid in $Pairs.Keys) {
        $v = $Pairs[$uid]
        $out[$uid] = [pscustomobject]@{
            UniqueId = $uid
            Number   = [int]$v.Number
            Letters  = @($v.Letters)
        }
    }
    return $out
}

# The layout as it was on 2026-10-03, when K: was the failing disk and held number 3.
$thenK = New-Layout @{
    '5001B484BBFA8282' = @{ Number = 0; Letters = @() }                     # C: nvme
    '5057440000000001' = @{ Number = 3; Letters = @('K:') }                 # the drive that failed
    '5000000000000001' = @{ Number = 4; Letters = @('H:') }                 # H:, before the shuffle
    '126FNE-1TB 2280'  = @{ Number = 2; Letters = @('D:') }
}
# The same physical disks today: K: has been replugged and is number 4, H: has
# inherited number 3. Identical disks, different numbers.
$now = New-Layout @{
    '5001B484BBFA8282' = @{ Number = 0; Letters = @('C:') }
    '126FNE-1TB 2280'  = @{ Number = 2; Letters = @('D:') }
    '5000000000000001' = @{ Number = 3; Letters = @('H:') }                 # was 4
    '5057440000000001' = @{ Number = 4; Letters = @('K:') }                 # was 3
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("diskid-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp
$map = Join-Path $tmp 'diskmap.json'
try {
    # ---- 1. nothing failing means nothing held out ---------------------------
    $none = Resolve-FailingDrives -Numbers @() -Identity $now -MapPath $map -NoWrite
    Assert-Equal 'no failing disks -> no drives held out' $none.Count 0

    # With -Numbers omitted the resolver calls Get-FailingDisks itself, and that
    # returns no objects at all when the event log is clean. Assigning an if whose
    # branch emits nothing yields $null, and $null.Count throws under
    # Set-StrictMode - so a run on a healthy machine died at this line. Passing
    # -Numbers @() above hides it, because that branch does emit an empty array.
    $live = Resolve-FailingDrives -Identity $now -MapPath $map -NoWrite
    Assert-True 'no -Numbers and a clean event log -> still a hashtable' ($live -is [hashtable])
    $src = Get-SourceBetween -Script 'balance.ps1' -Start '$numbers = @(' -End 'if ($numbers.Count -eq 0)'
    Assert-True 'the failing-disk list is wrapped before .Count is read' ($src -match '^\$numbers = @\(if')

    # ---- 2. the misattribution, exactly as it happened -----------------------
    # K: is failing as disk 3. Nothing has ever been recorded, so this run cannot
    # know the number changed hands.
    $first = Resolve-FailingDrives -Numbers @(3) -Identity $thenK -MapPath $map
    Assert-True  'first run: disk 3 is held out' ($first.ContainsKey('K:'))
    Assert-False 'first run: the letter is K:, the drive that failed' ($first.ContainsKey('H:'))
    Assert-Equal 'first run: recorded the id that held disk 3' (Read-DiskNumberMap -Path $map)['3'] '5057440000000001'

    # Same event, next run, after the replug. The errors still say "disk 3", disk 3
    # is H: now - and the recorded id resolves to K:, which is what actually failed.
    $second = Resolve-FailingDrives -Numbers @(3) -Identity $now -MapPath $map
    Assert-True  'after replug: K: still held out' ($second.ContainsKey('K:'))
    Assert-False 'after replug: H: is NOT blamed' ($second.ContainsKey('H:'))
    Assert-True  'the reason explains the reassignment' ($second['K:'] -match 'different physical disk')
    # The old code would have produced the opposite letter from the same inputs.
    Assert-True  'H: is not reachable from this evidence' ($now['5000000000000001'].Letters -contains 'H:')

    # ---- 3. the entry is rebuilt, not merged ---------------------------------
    # Stale entries would misattribute the next genuine failure, so the map only
    # ever holds the numbers that are failing right now.
    Assert-Equal 'map keeps only the failing number' (@(Read-DiskNumberMap -Path $map).Keys) @('3')
    $clear = Resolve-FailingDrives -Numbers @() -Identity $now -MapPath $map
    Assert-Equal 'no errors -> map emptied' (Read-DiskNumberMap -Path $map).Count 0

    # ---- 4. a genuinely failing drive is still held out ----------------------
    # G: is disk 5 and has never moved. Errors naming 5 belong to G: now and later.
    $now['9000000000000001'] = [pscustomobject]@{ UniqueId = '9000000000000001'; Number = 5; Letters = @('G:') }
    $g1 = Resolve-FailingDrives -Numbers @(5) -Identity $now -MapPath $map
    $g2 = Resolve-FailingDrives -Numbers @(5) -Identity $now -MapPath $map
    Assert-True 'new failure: held out on the first sighting' ($g1.ContainsKey('G:'))
    Assert-True 'new failure: still held out once the number is known' ($g2.ContainsKey('G:'))
    Assert-True 'a stable number says why' ($g2['G:'] -match 'disk 5')

    # ---- 5. a disk that is gone holds nothing out ----------------------------
    # Errors name a number nobody holds any more: no letter can be blamed.
    $gone = Resolve-FailingDrives -Numbers @(7) -Identity $now -MapPath $map
    Assert-Equal 'a failing number with no disk behind it -> nobody held out' $gone.Count 0

    # ---- 6. several letters on one disk --------------------------------------
    # ExFAT sticks often expose more than one volume, and the whole disk is the
    # thing that fails - so every letter from it must be held out.
    $now['9000000000000001'] = [pscustomobject]@{ UniqueId = '9000000000000001'; Number = 5; Letters = @('G:', 'X:') }
    $multi = Resolve-FailingDrives -Numbers @(5) -Identity $now -MapPath $map
    Assert-True 'second volume on the failing disk is held out too' ($multi.ContainsKey('X:'))

    # ---- 7. a corrupt or absent map must not throw --------------------------
    # Losing the file costs accuracy for one window; it must never stop the run,
    # because the whole point of the gate is to stop a hung scan from wedging.
    [System.IO.File]::WriteAllText($map, '{ this is not json', [System.Text.UTF8Encoding]::new($false))
    $corrupt = Resolve-FailingDrives -Numbers @(3) -Identity $now -MapPath $map -NoWrite
    Assert-True 'a corrupt map still yields an answer' ($corrupt.Count -ge 1)

    $never = Resolve-FailingDrives -Numbers @(3) -Identity $now -MapPath (Join-Path $tmp 'nope.json') -NoWrite
    Assert-True 'a missing map file still yields an answer' ($never.Count -ge 1)

    $noPath = Resolve-FailingDrives -Numbers @(3) -Identity $now -MapPath '' -NoWrite
    Assert-True 'no map path at all still yields an answer' ($noPath.Count -ge 1)

    # ---- 8. Read-DiskNumberMap always returns a hashtable --------------------
    # ConvertFrom-Json returns a PSCustomObject, the missing-file path used to
    # return a hashtable, and a caller indexing one with the other's syntax fails
    # on exactly the first run - the one where nothing has been recorded yet.
    Assert-True 'missing file -> hashtable' ((Read-DiskNumberMap -Path (Join-Path $tmp 'gone.json')) -is [hashtable])
    Write-DiskNumberMap -Path $map -Map @{ '3' = 'abc' }
    Assert-True 'written file -> hashtable' ((Read-DiskNumberMap -Path $map) -is [hashtable])
    Assert-Equal 'values come back as strings' (Read-DiskNumberMap -Path $map)['3'] 'abc'
    Write-DiskNumberMap -Path $map -Map @{}
    Assert-Equal 'an empty map round-trips' (Read-DiskNumberMap -Path $map).Count 0
    Assert-Equal 'an empty path -> empty map' (Read-DiskNumberMap -Path '').Count 0

    # ---- 9. the gate is not wired to the disk number any more ----------------
    # Read out of the source rather than asserted here, so this cannot pass while
    # the shipping code still resolves a letter to whatever number it has now.
    $scanBlock = Get-SourceBetween -Script 'balance.ps1' -Start 'foreach ($root in $lib.roots)' -End 'foreach ($u in Get-Units'
    Assert-True 'the scan asks the resolver, not the disk number' ($scanBlock -match 'unreadableDriveReason\.ContainsKey')
    # Comments are stripped first: the block explains why that helper is NOT used,
    # so a naive search would match its own justification and pass either way.
    $scanCode = (($scanBlock -split "`r?`n") |
            Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Assert-False 'the scan never maps a letter to a current disk number' ($scanCode -match 'Get-DriveDiskNumber')
    Assert-False 'the scan never compares a letter to a failing number' ($scanCode -match 'failingDisks\s+-contains')
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-TestResult -Suite 'disk-identity'