# The failing-drive gate: can the balancer tell which physical disk a drive
# letter sits on, in a system whose event log is not in English?
#
# The gate exists because of 2026-10-03, when one drive logged tens of thousands
# of paging errors and thousands of hardware I/O failures and another logged a
# hundred-odd retried reads. A failing
# disk retries rather than failing, so Get-ChildItem -Recurse blocks forever
# instead of erroring out.
#
# The wording is the trap. This machine logs in Portuguese, so events 153/154 say
# "Disco 4" where an English system says "Disk 4". The first version of the
# pattern only matched the English form, so the gate silently found nothing. The
# patterns are read out of balance.ps1 below rather than copied here, so this
# suite cannot drift away from what actually ships.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

$byWord = Lift-Pattern -Script 'balance.ps1' -Anchor 'Dis[ck]o?' -Occurrence 1
$byDevice = Lift-Pattern -Script 'balance.ps1' -Anchor 'Harddisk(' -Occurrence 1
"pattern read from balance.ps1:"
"  event 153/154 wording : $byWord"
"  event 51 device path  : $byDevice"
''

function Get-DiskNumber {
    param([string]$Message)
    if ($Message -match $byWord) { return [int]$Matches[1] }
    if ($Message -match $byDevice) { return [int]$Matches[1] }
    return $null
}

# ---- 1. both locales resolve to the same disk number ------------------------
# Real wording, so a reworded pattern fails here rather than on a live drive.
$cases = @(
    @{ n = 'Portuguese 153 (Disco)'; msg = 'O sistema detectou um problema ao tentar corrigir erros em uma unidade de disco. O estado de corrupcao pode corromper seus dados. Verifique o Disco 4 para erros de hardware.'; want = 4 }
    @{ n = 'Portuguese 154 (Disco)'; msg = 'Um erro de E/S ocorreu no Disco 4 durante uma operacao de hardware. O estado de corrupcao pode corromper seus dados.'; want = 4 }
    @{ n = 'English 153 (Disk)'; msg = 'Windows recovered from a hardware error on disk 4 while reading a file.'; want = 4 }
    @{ n = 'English 154 (Disk)'; msg = 'An I/O operation on Disk 3 encountered a hardware error.'; want = 3 }
    @{ n = 'event 51 device path'; msg = 'An error was detected on device \Device\Harddisk3\DR3 during a paging operation.'; want = 3 }
    @{ n = 'device path, higher number'; msg = 'An error was detected on device \Device\Harddisk10\DR0 during a paging operation.'; want = 10 }
    @{ n = 'two-digit in wording'; msg = 'The paging file on Disco 12 could not be read.'; want = 12 }
)
foreach ($c in $cases) {
    Assert-Equal $c.n (Get-DiskNumber $c.msg) $c.want
}

# ---- 2. messages with no disk must not produce a number ----------------------
# A false positive here would mark a healthy drive as failing, which is worse
# than missing one: it silently takes a drive out of the cascade.
Assert-Equal 'no disk named -> no number' `
    (Get-DiskNumber 'The volume on drive C: was created directly with a volume label of "System".') $null
Assert-Equal 'an unrelated "disco" in prose -> no number' `
    (Get-DiskNumber 'O usuario leu um disco removivel.') $null
# "HarddiskVolume3" is a volume, not a disk, and must not be read as disk 3.
Assert-Equal 'HarddiskVolume3 is not disk 3' `
    (Get-DiskNumber 'The paging file on \Device\HarddiskVolume3 was not enough.') $null

# ---- 4. Get-DriveDiskNumber against the real machine ------------------------
. (Lift-Functions -Script 'balance.ps1' -Names @('Get-DriveDiskNumber'))
# balance.ps1 initialises this cache at script level, which lifting a single
# function does not bring with it. Without it the first call hits a method on
# $null and the test fails for a reason that has nothing to do with the drive.
$script:diskOfDrive = @{}

$sys = $env:SystemDrive
$num = Get-DriveDiskNumber -Letter $sys
Assert-True ("{0}: resolves to a disk number" -f $sys) ($null -ne $num -and $num -ge 0)
Assert-Equal ("{0}: same answer when asked twice (cached)" -f $sys) `
    (Get-DriveDiskNumber -Letter $sys) $num
Assert-Equal "a letter with no volume -> null" (Get-DriveDiskNumber -Letter 'ZZ') $null
# A missing partition must be reported as unknown, never as disk 0: [int]$null
# is 0, and disk 0 is a real disk number, so an unguarded cast would name the
# wrong physical disk instead of admitting ignorance.
Assert-Equal "an empty letter -> null, never disk 0" (Get-DriveDiskNumber -Letter '') $null

# ---- 5. the cache is keyed by letter, colon and case aside -------------------
$lower = Get-DriveDiskNumber -Letter $sys.TrimEnd(':').ToLowerInvariant()
Assert-Equal "lowercase, no colon -> same cache entry" $lower $num

Write-TestResult -Suite 'drive-health'
