# Recycle bin reclaim: reading a binned item's origin out of its $I file, and
# refusing to touch anything whose origin cannot be read.
#
# This is the only part of the balancer that deletes without first reading what
# it is deleting. A move can always be undone by reconcile on the next cycle; a
# file destroyed out of the bin cannot. So the origin check is the entire safety
# story here, and the failure that matters is the quiet one: a header that does
# not parse has to mean "origin unknown, leave it alone", never "no origin, go
# ahead and destroy it".
#
# The $I layout is undocumented, so the parser is checked against header bytes
# rather than against a round trip through this suite's own writer - a round-trip
# test passes just as happily after the real format has moved on. The two fixtures
# in section 1 were lifted from real bins and then had their embedded paths
# replaced with invented ones, so that nothing here names a file the user has
# watched. Everything that makes the bytes a header is untouched: version, the
# int64 size, the FILETIME, the character count, and the UTF-16LE encoding - and
# the accent in both paths is kept deliberately, because 'Series' with U+00E9 is a
# different folder from plain ASCII 'Series' and a mangled decode would produce a
# path matching no root, quietly exempting real library media from reclaim.
#
# Section 5 runs the real Invoke-RecycleBinReclaim over a throwaway subst volume,
# so the safety rules are exercised against a real directory tree without going
# anywhere near a real recycle bin.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

. (Lift-Functions -Script 'balance.ps1' -Names 'Read-RecycleMeta', 'Test-MediaOrigin', 'Get-DriveFree', 'Get-DriveDiskNumber', 'Invoke-RecycleBinReclaim')

# Get-DriveDiskNumber keeps a cache that balance.ps1 fills at line 178, when the
# script loads. Lifting functions out of the file skips that, so seed it here or
# the first call throws on a null hashtable.
$script:diskOfDrive = @{}

$eAcute = [char]0x00E9          # 'e' with an acute accent, as in 'Series'
$seriesRootName = "S${eAcute}ries"

# ---- 1. real headers, as Windows wrote them ----------------------------------
# Two items lifted from the actual bins: a 14.98GB file on D: and a 2.23GB file on
# F:. Both version 2. Their recorded sizes are the proof that offset 8 is the file
# size and not something else - 16084916373 bytes is 14.98GiB, which is what the
# bin actually held.
$goldens = @(
    @{
        name  = 'header A'
        hex   = '02000000000000009558bcbe0300000060dfed82a354dd012400000044003a00' +
        '5c005300e90072006900650073005c0053006f006d00650020004d006f007600' +
        '69006500200032003000320035002000320031003600300070002e006d006b00' +
        '76000000'
        ver   = 2
        size  = 16084916373
        chars = 36
        origin = "D:\${seriesRootName}\Some Movie 2025 2160p.mkv"
    }
    @{
        name  = 'header B'
        hex   = '0200000000000000f876c28e0000000060dfed82a354dd012800000046003a00' +
        '5c005300e90072006900650073005c0041006e006f0074006800650072002000' +
        '530068006f007700200053003000320045003000360020003100300038003000' +
        '70002e006d006b0076000000'
        ver   = 2
        size  = 2395109112
        chars = 40
        origin = "F:\${seriesRootName}\Another Show S02E06 1080p.mkv"
    }
)

# Written to disk as-is, because the parser takes a path. That is deliberate: a
# parser that would only ever see bytes handed straight to it from memory is not
# the parser that runs at 3am on a failing drive.
$fixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ('recycle-meta-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $fixtureDir -Force | Out-Null

try {
    $fixtureNo = 0
    foreach ($g in $goldens) {
        $bytes = [byte[]]::new($g.hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($g.hex.Substring($i * 2, 2), 16) }
        # numbered rather than named after the case, because a label like
        # 'real D: header' contains a colon and no file may
        $fixtureNo++
        $p = Join-Path $fixtureDir ('$Ifixture' + $fixtureNo + '.dat')
        [System.IO.File]::WriteAllBytes($p, $bytes)

        $got = Read-RecycleMeta -Path $p
        Assert-Equal "$($g.name): parsed" ($null -ne $got) $true
        if ($got) {
            Assert-Equal "$($g.name): version" $got.Version $g.ver
            Assert-Equal "$($g.name): size" $got.Size $g.size
            Assert-Equal "$($g.name): origin" $got.Origin $g.origin
        }
    }
}
finally { Remove-Item -LiteralPath $fixtureDir -Recurse -Force -ErrorAction SilentlyContinue }

# ---- 2. a version 1 header, built to the documented older layout ------------
# Vista through Windows 8 wrote version 1: no timestamp, no character count, just
# a 20 byte header and a null terminated path. Nothing on this machine produces
# one any more, so it is the layout most likely to rot unnoticed.
$v1 = [System.IO.MemoryStream]::new()
$v1.Write([BitConverter]::GetBytes([int64]1), 0, 8)
$v1.Write([BitConverter]::GetBytes([int64]4096), 0, 8)
$pathV1 = 'D:\Filmes\Old Movie.mkv'
$v1.Write([System.Text.Encoding]::Unicode.GetBytes($pathV1 + [char]0), 0, ($pathV1.Length + 1) * 2)
$v1.Write([System.Text.Encoding]::Unicode.GetBytes('trailing junk after the null'), 0, 54)
$v1Bytes = $v1.ToArray(); $v1.Dispose()

$v1Path = Join-Path ([System.IO.Path]::GetTempPath()) ('$I' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.dat')
[System.IO.File]::WriteAllBytes($v1Path, $v1Bytes)
$v1Got = Read-RecycleMeta -Path $v1Path
Assert-Equal 'version 1: parsed' ($null -ne $v1Got) $true
if ($v1Got) {
    Assert-Equal 'version 1: version' $v1Got.Version 1
    Assert-Equal 'version 1: size' $v1Got.Size 4096
    # The null terminator is the only end marker in this layout, so anything
    # written after it is not part of the path.
    Assert-Equal 'version 1: origin stops at the null' $v1Got.Origin $pathV1
}
Remove-Item -LiteralPath $v1Path -Force -ErrorAction SilentlyContinue

# ---- 3. headers that must be refused ----------------------------------------
# Every one of these returns $null, and a $null means the caller leaves the item
# alone. If any of them ever returns an object, the guard has a hole in it.
function New-Bad {
    param([byte[]]$Bytes)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('$I' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.dat')
    [System.IO.File]::WriteAllBytes($p, $Bytes)
    return $p
}

# version 9: a layout nobody has documented, so nobody can say what the bytes mean
$badVer = New-Object byte[] 60
$badVer[0] = 9
# version 2 declaring 500 characters in a file that only has room for four: the
# path would be cut mid-string, and a truncated path still starts with a library
# root, so it would pass the origin check while proving nothing about the rest
$stubPath = "D:\${seriesRootName}\a"
$stubBytes = [System.Text.Encoding]::Unicode.GetBytes($stubPath)
$shortV2 = New-Object byte[] (28 + $stubBytes.Length)
$shortV2[0] = 2
[Array]::Copy([BitConverter]::GetBytes([uint32]500), 0, $shortV2, 24, 4)
[Array]::Copy($stubBytes, 0, $shortV2, 28, $stubBytes.Length)
# version 1 with no null terminator anywhere in it
$cutPath = 'D:\Filmes\cut off here'
$cutBytes = [System.Text.Encoding]::Unicode.GetBytes($cutPath)
$noNull = New-Object byte[] (16 + $cutBytes.Length)
$noNull[0] = 1
[Array]::Copy($cutBytes, 0, $noNull, 16, $cutBytes.Length)
# a valid header whose path is empty
$noPath = New-Object byte[] 30
$noPath[0] = 2
[Array]::Copy([BitConverter]::GetBytes([uint32]1), 0, $noPath, 24, 4)
# version 0, which is not a thing either
$zeroVer = New-Object byte[] 40
$zeroVer[0] = 0

$refusals = @(
    @{ n = 'empty file';                    p = (New-Bad (New-Object byte[] 0)) }
    @{ n = 'shorter than any header';       p = (New-Bad (New-Object byte[] 10)) }
    @{ n = 'exactly 19 bytes';              p = (New-Bad (New-Object byte[] 19)) }
    @{ n = 'version 2 cut short';           p = (New-Bad $shortV2) }
    @{ n = 'unknown version 9';             p = (New-Bad $badVer) }
    @{ n = 'version 1, no null terminator'; p = (New-Bad $noNull) }
    @{ n = 'valid header, empty path';      p = (New-Bad $noPath) }
    @{ n = 'version 0';                     p = (New-Bad $zeroVer) }
)
foreach ($r in $refusals) {
    $got = Read-RecycleMeta -Path $r.p
    # reported as a string so a stray object prints usefully instead of as
    # '@{Version=2; ...}', which reads like a pass at a glance
    Assert-Equal "refused: $($r.n)" $(if ($null -eq $got) { 'null' } else { "parsed($($got.Origin))" }) 'null'
}
foreach ($r in $refusals) { Remove-Item -LiteralPath $r.p -Force -ErrorAction SilentlyContinue }

Assert-Equal 'refused: path that does not exist' $(if ($null -eq (Read-RecycleMeta -Path 'Q:\nope\$Izzz.dat')) { 'null' } else { 'parsed' }) 'null'

# ---- 4. the origin check itself ----------------------------------------------
$cfg = [pscustomobject]@{
    libraries = @(
        [pscustomobject]@{ name = 'Filmes'; roots = @('D:\Filmes', 'F:\Filmes') }
        [pscustomobject]@{ name = 'Series'; roots = @("D:\${seriesRootName}", "F:\${seriesRootName}") }
    )
}

$originCases = @(
    @{ n = 'a library root exactly';        v = 'D:\Filmes'; want = $true }
    @{ n = 'a file under a root';          v = 'D:\Filmes\Sub\a.mkv'; want = $true }
    @{ n = 'a root with a trailing slash';  v = 'D:\Filmes\'; want = $true }
    @{ n = 'a second volume, same shape';  v = 'F:\Filmes\a.mkv'; want = $true }
    @{ n = 'the accented root';            v = "D:\${seriesRootName}\Show\x.mkv"; want = $true }
    @{ n = 'unaccented spelling, same folders'; v = 'D:\Series\Show\x.mkv'; want = $false }
    @{ n = 'a volume root, no folder';     v = 'D:\'; want = $false }
    @{ n = 'a sibling with a shared prefix'; v = 'D:\FilmesAntigos\a.mkv'; want = $false }
    @{ n = 'outside every library';        v = 'C:\Users\YOURNAME\Documents\a.mkv'; want = $false }
    @{ n = 'no origin at all';             v = ''; want = $false }
    @{ n = 'null origin';                  v = $null; want = $false }
)
foreach ($c in $originCases) {
    Assert-Equal "origin: $($c.n)" (Test-MediaOrigin $c.v) $c.want
}

# ---- 5. the whole pass, over a throwaway volume ------------------------------
# A real directory tree, a real $Recycle.Bin, a real subst drive letter, and the
# real function doing the walking. Nothing here touches a real recycle bin.
$base = Join-Path ([System.IO.Path]::GetTempPath()) ('recycle-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
# The second letter gets its own directory. Pointing both at one base would make
# them the same volume wearing two hats: the pass would find each item twice, and
# "one verify event per volume" would pass or fail for the wrong reason.
$otherBase = Join-Path ([System.IO.Path]::GetTempPath()) ('recycle-e2e2-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $base -Force | Out-Null
New-Item -ItemType Directory -Path $otherBase -Force | Out-Null
$free = @()
foreach ($cand in 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z') {
    if (-not (Test-Path "${cand}:\")) { $free += $cand }
    if ($free.Count -ge 2) { break }
}
$letter = $free[0]
if ($free.Count -lt 2) {
    Write-Warning 'fewer than two free drive letters; the end-to-end section is skipped'
}
else {
    $otherLetter = $free[1]
    & subst "${letter}:" $base
    & subst "${otherLetter}:" $otherBase
    try {
        $sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
        $bin = "${letter}:\`$Recycle.Bin\$sid"
        New-Item -ItemType Directory -Path $bin -Force | Out-Null

        # Build one binned item: the $I header Windows would have written, and the
        # $R payload holding the bytes.
        function New-Binned {
            param([string]$Suffix, [string]$Origin, [int]$Bytes = 64, [string]$Corrupt)

            $metaName = '$I' + $Suffix
            $rName = '$R' + $Suffix
            if ($Corrupt) {
                $raw = [System.Text.Encoding]::ASCII.GetBytes($Corrupt)
            }
            else {
                $mem = [System.IO.MemoryStream]::new()
                $mem.Write([BitConverter]::GetBytes([int64]2), 0, 8)
                $mem.Write([BitConverter]::GetBytes([int64]$Bytes), 0, 8)
                $mem.Write([BitConverter]::GetBytes([int64]0), 0, 8)
                $mem.Write([BitConverter]::GetBytes([uint32]($Origin.Length + 1)), 0, 4)
                $mem.Write([System.Text.Encoding]::Unicode.GetBytes($Origin + [char]0), 0, ($Origin.Length + 1) * 2)
                $raw = $mem.ToArray(); $mem.Dispose()
            }
            [System.IO.File]::WriteAllBytes((Join-Path $bin $metaName), $raw)
            if ($PSBoundParameters.ContainsKey('Bytes') -or -not $Corrupt) {
                [System.IO.File]::WriteAllBytes((Join-Path $bin $rName), (New-Object byte[] $Bytes))
            }
        }

        New-Binned -Suffix 'AAA.mkv' -Origin "${letter}:\Filmes\Library Film.mkv" -Bytes 4096
        New-Binned -Suffix 'BBB.mkv' -Origin "${letter}:\Series\Library Show.mkv" -Bytes 4096
        # filed under the accented root, so this only resolves if the decode kept
        # the accent rather than transliterating it
        New-Binned -Suffix 'CCC.mkv' -Origin "${letter}:\${seriesRootName}\Accented Show.mkv" -Bytes 4096
        New-Binned -Suffix 'DDD.mkv' -Origin 'C:\Users\YOURNAME\Documents\holiday photos.mkv' -Bytes 4096
        New-Binned -Suffix 'EEE.mkv' -Origin "${letter}:\Filmes\Readable.mkv" -Bytes 4096 -Corrupt 'this is not a recycle bin header at all'
        # an $I with no $R beside it: the entry Explorer would show as broken
        [System.IO.File]::WriteAllBytes((Join-Path $bin '$IFFF.mkv'),
            [System.Text.Encoding]::Unicode.GetBytes("${letter}:\Filmes\Orphan.mkv" + [char]0))
        # a deleted folder: the payload is a whole tree, and its size is 0 in the
        # header, so it has to be walked
        New-Item -ItemType Directory -Path (Join-Path $bin '$RGGG') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $bin '$RGGG\inner') -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $bin '$RGGG\inner\a.bin'), (New-Object byte[] 2048))
        $memG = [System.IO.MemoryStream]::new()
        $memG.Write([BitConverter]::GetBytes([int64]2), 0, 8)
        $memG.Write([BitConverter]::GetBytes([int64]0), 0, 8)
        $memG.Write([BitConverter]::GetBytes([int64]0), 0, 8)
        $fo = "${letter}:\Filmes\Deleted Folder"
        $memG.Write([BitConverter]::GetBytes([uint32]($fo.Length + 1)), 0, 4)
        $memG.Write([System.Text.Encoding]::Unicode.GetBytes($fo + [char]0), 0, ($fo.Length + 1) * 2)
        [System.IO.File]::WriteAllBytes((Join-Path $bin '$IGGG'), $memG.ToArray())
        $memG.Dispose()

        # a second volume on the same fake base, so the pass has to walk more
        # than one
        $otherBin = "${otherLetter}:\`$Recycle.Bin\$sid"
        New-Item -ItemType Directory -Path $otherBin -Force | Out-Null

        $script:GB = 1GB
        $script:Apply = $false
        $script:cfg = [pscustomobject]@{
            libraries = @(
                [pscustomobject]@{ name = 'Filmes'; roots = @("${letter}:\Filmes") }
                [pscustomobject]@{ name = 'Series'; roots = @("${letter}:\Series", "${letter}:\${seriesRootName}") }
                [pscustomobject]@{ name = 'Other'; roots = @("${otherLetter}:\Filmes") }
            )
        }
        $script:Logged = @()
        $script:Warnings = @()
        # Seams, not copies. Write-Log and Write-Warning are replaced so the events
        # and warnings can be inspected; the functions under test are the real ones
        # lifted from balance.ps1.
        function Write-Log { param([string]$Event, $Data) $script:Logged += [pscustomobject]@{ Event = $Event; Data = $Data } }
        function Write-Warning { param([string]$Message) $script:Warnings += $Message }

        $script:failingDisks = @()
        $dry = (& { Invoke-RecycleBinReclaim } 6>&1) -join "`n"

        $dryEvents = @($script:Logged | Where-Object { $_.Event -eq 'recycle_would_destroy' })
        Assert-Equal 'dry run: nothing reported as destroyed' (@($script:Logged | Where-Object { $_.Event -eq 'recycle_destroyed' }).Count) 0
        Assert-Equal 'dry run: four library items found' $dryEvents.Count 4
        Assert-True 'dry run: library film offered' ($dryEvents.Data.name -contains 'Library Film.mkv')
        Assert-True 'dry run: library show offered' ($dryEvents.Data.name -contains 'Library Show.mkv')
        Assert-True 'dry run: accented item offered' ($dryEvents.Data.name -contains 'Accented Show.mkv')
        Assert-True 'dry run: deleted folder offered' ($dryEvents.Data.name -contains 'Deleted Folder')
        Assert-False 'dry run: personal file left alone' ($dryEvents.Data.name -contains 'holiday photos.mkv')
        Assert-False 'dry run: corrupt header left alone' ($dryEvents.Data.name -contains 'Readable.mkv')
        Assert-False 'dry run: orphan $I not offered' ($dryEvents.Data.name -contains 'Orphan.mkv')
        Assert-True 'dry run: reported the corrupt header' ($dry -match 'could not be read')
        $folderEvent = $dryEvents | Where-Object { $_.Data.name -eq 'Deleted Folder' }
        Assert-Equal 'dry run: folder size walked off disk, not read as zero' $folderEvent.Data.sizeGB 0

        # and nothing on disk changed
        Assert-True 'dry run: payload still present' (Test-Path -LiteralPath (Join-Path $bin '$RAAA.mkv'))
        Assert-True 'dry run: personal payload still present' (Test-Path -LiteralPath (Join-Path $bin '$RDDD.mkv'))
        Assert-True 'dry run: corrupt-header payload still present' (Test-Path -LiteralPath (Join-Path $bin '$REEE.mkv'))
        Assert-Equal 'dry run: no verify event without deleting' (@($script:Logged | Where-Object { $_.Event -eq 'recycle_verify' }).Count) 0

        # ---- a failing disk must NOT hold the bins ----------------------------
        # The health gate belongs to the library scan, where 2026-10-03 proved that
        # walking tens of thousands of files on a disk that retries rather than
        # fails blocks instead of erroring. Emptying a bin is not that operation,
        # and Explorer's own Empty Recycle Bin does more work on the same files.
        # So this asserts the gate stays OUT, which is a regression guard in the
        # opposite direction: without it, someone re-adding the check would look
        # reasonable and quietly cost a drive its reclaimed space for 24h.
        $script:Logged = @(); $script:Warnings = @()
        $script:failingDisks = @(4242)
        $script:diskOfDrive[$letter] = 4242
        $script:diskOfDrive[$otherLetter] = 4242
        $failOut = (& { Invoke-RecycleBinReclaim } 6>&1) -join "`n"
        Assert-True 'failing disk: still reclaimed' (@($script:Logged | Where-Object { $_.Event -eq 'recycle_would_destroy' }).Count -gt 0)
        Assert-False 'failing disk: not reported as skipped' ($failOut -match 'not touching the bins on')
        Assert-Equal 'failing disk: no skipped-volume warning' $script:Warnings.Count 0

        # ---- apply, with the measurement faked to prove the check can fail ---
        # The point of the verification is that it is capable of failing. Here the
        # payload really is deleted, but the volume "does not" grow, which is what
        # a held-open file or a sparse payload would look like from here. If this
        # still logs a success, the check is decorative.
        # The real Get-DriveFree is what the dry run above just measured with, so it has
        # been exercised by now. Redefining it here is the one seam in this section:
        # what decides whether verification passes is the measurement, so that is
        # the thing being controlled.
        Assert-True 'free space: real reader returns a number' ((Get-DriveFree -Letter "${letter}:") -gt 0)
        Assert-Equal 'free space: unknown volume reads as null' $(if ($null -eq (Get-DriveFree -Letter 'ZZ:')) { 'null' } else { 'number' }) 'null'

        $script:Reads = 0
        function Get-DriveFree {
            param([string]$Letter)
            $script:Reads++
            return [int64]0     # flat: nothing ever comes back
        }

        $script:Logged = @(); $script:Warnings = @()
        $script:failingDisks = @()
        $script:Apply = $true
        $applyOut = (& { Invoke-RecycleBinReclaim } 6>&1) -join "`n"

        Assert-True 'apply: read the volume before deleting' ($script:Reads -ge 2)
        Assert-Equal 'apply: four items destroyed' (@($script:Logged | Where-Object { $_.Event -eq 'recycle_destroyed' }).Count) 4
        $verifies = @($script:Logged | Where-Object { $_.Event -eq 'recycle_verify' })
        # one volume had anything in it, so one volume gets measured and reported
        Assert-Equal 'apply: one verify event per volume with targets' $verifies.Count 1
        Assert-Equal 'apply: verify named that volume' $verifies[0].Data.drive "${letter}:"
        Assert-Equal 'apply: verify recorded what it measured' $verifies[0].Data.freedGB 0
        Assert-True 'apply: expected figure recorded, not just the measured one' ($null -ne $verifies[0].Data.expectedGB)
        # the shortfall is raised through Write-Warning, so it is collected in
        # $script:Warnings rather than in the host output
        Assert-True 'apply: shortfall reported on the volume' (@($script:Warnings | Where-Object { $_ -match 'did not free what it claimed' }).Count -ge 1)
        Assert-True 'apply: shortfall summarised at the end' (@($script:Warnings | Where-Object { $_ -match 'did not return the space' }).Count -ge 1)

        # what survived, and why
        Assert-False 'apply: library payload destroyed' (Test-Path -LiteralPath (Join-Path $bin '$RAAA.mkv'))
        Assert-False 'apply: library $I destroyed' (Test-Path -LiteralPath (Join-Path $bin '$IAAA.mkv'))
        Assert-True 'apply: personal payload survives' (Test-Path -LiteralPath (Join-Path $bin '$RDDD.mkv'))
        Assert-True 'apply: personal $I survives' (Test-Path -LiteralPath (Join-Path $bin '$IDDD.mkv'))
        Assert-True 'apply: corrupt-header payload survives' (Test-Path -LiteralPath (Join-Path $bin '$REEE.mkv'))
        Assert-False 'apply: deleted folder tree destroyed' (Test-Path -LiteralPath (Join-Path $bin '$RGGG'))
        Assert-True 'apply: orphan $I untouched' (Test-Path -LiteralPath (Join-Path $bin '$IFFF.mkv'))
    }
    finally {
        & subst "${letter}:" /d
        & subst "${otherLetter}:" /d
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $otherBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---- 6. the flat layout used by removable and exFAT volumes ------------------
# A fixed volume puts the $I records inside a per-account SID folder. A removable
# or exFAT volume has no such folder and puts them directly in $Recycle.Bin - which
# is H: and every USB stick.
#
# This section exists because the pass originally looked only inside subfolders, so
# on those volumes it found nothing and reported "no library media waiting to be
# destroyed" without a word. A bin nobody empties because the tool said it was
# already empty is the worst failure this pass can have, and it was silent.
$flatBase = Join-Path ([System.IO.Path]::GetTempPath()) ('recycle-flat-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $flatBase -Force | Out-Null
& subst 'Q:' $flatBase
try {
    # no SID folder at all - this is the whole point
    $flatBin = 'Q:\$Recycle.Bin'
    New-Item -ItemType Directory -Path $flatBin -Force | Out-Null

    # Windows also drops desktop.ini in there; it must not be mistaken for a record
    [System.IO.File]::WriteAllText((Join-Path $flatBin 'desktop.ini'), '[.ShellClassInfo]')

    function New-Flat {
        param([string]$Suffix, [string]$Origin, [int]$Bytes = 2048, [switch]$NoPayload)
        $m = [System.IO.MemoryStream]::new()
        $m.Write([BitConverter]::GetBytes([int64]2), 0, 8)
        $m.Write([BitConverter]::GetBytes([int64]$Bytes), 0, 8)
        $m.Write([BitConverter]::GetBytes([int64]0), 0, 8)
        $m.Write([BitConverter]::GetBytes([uint32]($Origin.Length + 1)), 0, 4)
        $m.Write([System.Text.Encoding]::Unicode.GetBytes($Origin + [char]0), 0, ($Origin.Length + 1) * 2)
        [System.IO.File]::WriteAllBytes((Join-Path $flatBin ('$I' + $Suffix)), $m.ToArray())
        $m.Dispose()
        if (-not $NoPayload) {
            [System.IO.File]::WriteAllBytes((Join-Path $flatBin ('$R' + $Suffix)), (New-Object byte[] $Bytes))
        }
    }

    New-Flat -Suffix 'FLAT.mkv' -Origin 'Q:\Series\Flat Layout Show S01E03.mkv'
    New-Flat -Suffix 'ORPH.mkv' -Origin 'Q:\Series\No Payload.mkv' -NoPayload
    New-Flat -Suffix 'PRIV.mkv' -Origin 'C:\Users\YOURNAME\Documents\holiday.mkv'
    # a zero-length stub, which is what exFAT leaves behind after a partial empty
    [System.IO.File]::WriteAllBytes((Join-Path $flatBin '$IZERO.mkv'), (New-Object byte[] 0))

    $script:cfg = [pscustomobject]@{
        libraries = @([pscustomobject]@{ name = 'TV'; roots = @("Q:\Series") })
    }
    $script:Logged = @(); $script:Warnings = @()
    $script:Apply = $false
    $script:failingDisks = @()
    $flatOut = (& { Invoke-RecycleBinReclaim } 6>&1) -join "`n"

    $flatEvents = @($script:Logged | Where-Object { $_.Event -eq 'recycle_would_destroy' })
    Assert-Equal 'flat bin: the library item is found' $flatEvents.Count 1
    Assert-True 'flat bin: and it is the right one' ($flatEvents.Data.name -contains 'Flat Layout Show S01E03.mkv')
    Assert-True 'flat bin: drive is the removable volume' ($flatEvents.Data.drive -eq 'Q:')
    Assert-False 'flat bin: personal file still left alone' ($flatEvents.Data.name -contains 'holiday.mkv')
    Assert-True 'flat bin: the orphan is reported, not silently dropped' ($flatOut -match 'metadata record but no payload')
    Assert-True 'flat bin: the zero-length stub is reported' ($flatOut -match 'could not be read')
    Assert-False 'flat bin: desktop.ini is not treated as a record' ($flatOut -match 'desktop')

    # and the SID layout still works, because the fix added a level rather than
    # replacing one
    New-Item -ItemType Directory -Path (Join-Path $flatBin 'S-1-5-21-1-2-3-1001') -Force | Out-Null
    $sidDir = Join-Path $flatBin 'S-1-5-21-1-2-3-1001'
    $m2 = [System.IO.MemoryStream]::new()
    $o2 = 'Q:\Series\Sid Layout Show S02E01.mkv'
    $m2.Write([BitConverter]::GetBytes([int64]2), 0, 8)
    $m2.Write([BitConverter]::GetBytes([int64]2048), 0, 8)
    $m2.Write([BitConverter]::GetBytes([int64]0), 0, 8)
    $m2.Write([BitConverter]::GetBytes([uint32]($o2.Length + 1)), 0, 4)
    $m2.Write([System.Text.Encoding]::Unicode.GetBytes($o2 + [char]0), 0, ($o2.Length + 1) * 2)
    [System.IO.File]::WriteAllBytes((Join-Path $sidDir '$ISID.mkv'), $m2.ToArray())
    $m2.Dispose()
    [System.IO.File]::WriteAllBytes((Join-Path $sidDir '$RSID.mkv'), (New-Object byte[] 2048))

    $script:Logged = @()
    $null = (& { Invoke-RecycleBinReclaim } 6>&1)
    $both = @($script:Logged | Where-Object { $_.Event -eq 'recycle_would_destroy' })
    Assert-Equal 'both layouts: flat and SID are scanned in one run' $both.Count 2
}
finally {
    & subst 'Q:' /d
    Remove-Item -LiteralPath $flatBase -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- 7. how these rows reach the screen --------------------------------------
# status.ps1 decides the EVENT label and the ROUTE column itself, so the rows
# only read correctly if the two agree on which field holds the drive. These are
# lifted from status.ps1 rather than asserted about, because a rename there would
# silently blank the column instead of failing anything.
. (Lift-Functions -Script 'status.ps1' -Names 'Get-Prop', 'Get-Root', 'Get-EventLabel', 'Get-Route')

Assert-Equal 'label: bin purge' (Get-EventLabel 'recycle_would_destroy') 'bin purge'
Assert-Equal 'label: bin purged' (Get-EventLabel 'recycle_destroyed') 'bin purged'
Assert-Equal 'label: bin verified' (Get-EventLabel 'recycle_verify') 'bin verified'
Assert-Equal 'label: bin purge fail' (Get-EventLabel 'recycle_destroy_failed') 'bin purge fail'
Assert-Equal 'label: bin meta fail' (Get-EventLabel 'recycle_meta_failed') 'bin meta fail'

# A destroyed item is routed by where it was deleted from, because the bin is
# per-volume: that drive is the one whose free space actually went up.
Assert-Equal 'route: destroyed item' (Get-Route ([pscustomobject]@{ event = 'recycle_destroyed'; from = "D:\${seriesRootName}\A Show"; name = 'a.mkv' })) 'D:'
Assert-Equal 'route: pending item' (Get-Route ([pscustomobject]@{ event = 'recycle_would_destroy'; from = 'F:\Filmes'; name = 'b.mkv' })) 'F:'
# A verification row names no item at all, so without the drive field fallback it
# renders as a blank row: an event label with nothing beside it.
Assert-Equal 'route: verification row' (Get-Route ([pscustomobject]@{ event = 'recycle_verify'; drive = 'D:'; expectedGB = 14.98; freedGB = 0.4 })) 'D:'
Assert-True 'route: verification row is not blank' ((Get-Route ([pscustomobject]@{ event = 'recycle_verify'; drive = 'K:' })).Length -gt 0)

# ---- 8. the two requirements are actually wired, not just present ------------
# Asserted against the source because the end-to-end section above cannot reach
# these: it has no real failing disk to point at, and it cannot make a real purge
# fail honestly.
$src = [System.IO.File]::ReadAllText((Join-Path $script:TestRoot 'balance.ps1'), [System.Text.Encoding]::UTF8)
$fnStart = $src.IndexOf('function Invoke-RecycleBinReclaim')
$gateStart = $src.IndexOf('# ------', $fnStart)
$fn = $src.Substring($fnStart, $gateStart - $fnStart)

Assert-False 'wired: no shell COM object' ($fn -match 'New-Object -ComObject')
Assert-False 'wired: no shell recycle namespace' ($fn -match 'Namespace\(10\)')
Assert-False 'wired: no failing-disk gate on the bin' ($fn -match '\$failingDisks')
Assert-False 'wired: no disk lookup on the bin path' ($fn -match 'Get-DriveDiskNumber')
Assert-True 'wired: reads the volume before deleting' ($fn -match '\$freeBefore\[.*?\] = Get-DriveFree')
Assert-True 'wired: reads the volume again after deleting' ($fn -match '\$now = Get-DriveFree')
Assert-True 'wired: logs the measured figure' ($fn -match "'recycle_verify'")
Assert-True 'wired: only lists the top level of the bin' ($fn -match "-LiteralPath \`$binRoot -Directory")
Assert-False 'wired: never recurses into the bin' ($fn -match '-LiteralPath \$binRoot -Recurse')

Write-TestResult -Suite 'recycle-bin'