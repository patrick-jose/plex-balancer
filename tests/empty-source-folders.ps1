# A verified move removes empty source Season/Show folders, but not the library
# root or any folder with other contents. Work only in a throwaway directory.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')
. (Lift-Functions -Script 'balance.ps1' -Names @('Get-Prop', 'Invoke-Move', 'Remove-EmptySourceParents'))

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pb-empty-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $tmp 'source'
$dest = Join-Path $tmp 'destination'
New-Item -ItemType Directory -Path $source, $dest -Force | Out-Null

$script:GB = 1GB
$script:cfg = [pscustomobject]@{ maxUnitPctOfFree = 50 }
$script:Hash = $false
$script:Apply = $true
$script:Events = @()
function Get-LiveFree { return [long](10GB) }
function Write-Log { param($Event, $Data) $script:Events += $Event }

function Move-TestFile {
    param([string]$Relative)
    $path = Join-Path $source $Relative
    $target = Join-Path $dest $Relative
    $unit = [pscustomobject]@{ Path = $path; Root = $source; Kind = 'episode'
        Files = @($path); Size = (Get-Item -LiteralPath $path).Length
        Name = [System.IO.Path]::GetFileName($path); Library = 'TV' }
    $stat = [pscustomobject]@{ Letter = 'Q:'; Free = [long](10GB); Total = [long](20GB); Used = [long](10GB); FreePct = 50 }
    Invoke-Move -Unit $unit -DestRoot $dest -DestPath $target -DriveStat $stat -DestCfg ([pscustomobject]@{})
}

try {
    $season = Join-Path $source 'Show\Season 1'
    New-Item -ItemType Directory -Path $season -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $season 'one.mkv'), 'one')
    [System.IO.File]::WriteAllText((Join-Path $season 'two.mkv'), 'two')

    $script:Apply = $false
    Assert-True 'dry run plans the file' (Move-TestFile 'Show\Season 1\one.mkv')
    Assert-True 'dry run leaves the source file' (Test-Path -LiteralPath (Join-Path $season 'one.mkv'))
    Assert-True 'dry run leaves the source folders' (Test-Path -LiteralPath $season)
    $script:Apply = $true

    Assert-True 'first episode moves' (Move-TestFile 'Show\Season 1\one.mkv')
    Assert-True 'first episode arrives at destination' (Test-Path -LiteralPath (Join-Path $dest 'Show\Season 1\one.mkv'))
    Assert-True 'season with a second episode remains' (Test-Path -LiteralPath $season)
    Assert-True 'second episode remains untouched' (Test-Path -LiteralPath (Join-Path $season 'two.mkv'))

    Assert-True 'last episode moves' (Move-TestFile 'Show\Season 1\two.mkv')
    Assert-False 'empty season is removed' (Test-Path -LiteralPath $season)
    Assert-False 'empty show is removed' (Test-Path -LiteralPath (Join-Path $source 'Show'))
    Assert-True 'configured library root remains' (Test-Path -LiteralPath $source)
    Assert-True 'both episodes arrived' (Test-Path -LiteralPath (Join-Path $dest 'Show\Season 1\two.mkv'))

    $hiddenSeason = Join-Path $source 'Hidden\Season 2'
    New-Item -ItemType Directory -Path $hiddenSeason -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $hiddenSeason 'episode.mkv'), 'episode')
    $hidden = Join-Path $hiddenSeason 'keep.txt'
    [System.IO.File]::WriteAllText($hidden, 'keep')
    (Get-Item -LiteralPath $hidden).Attributes = [System.IO.FileAttributes]::Hidden
    Assert-True 'episode beside a hidden file moves' (Move-TestFile 'Hidden\Season 2\episode.mkv')
    Assert-True 'hidden file prevents season removal' (Test-Path -LiteralPath $hiddenSeason)
    Assert-True 'hidden file survives' ($null -ne (Get-Item -LiteralPath $hidden -Force -ErrorAction SilentlyContinue))
    Assert-True 'nonempty show remains' (Test-Path -LiteralPath (Join-Path $source 'Hidden'))

    $other = Join-Path $tmp 'unrelated\Season'
    New-Item -ItemType Directory -Path $other -Force | Out-Null
    Remove-EmptySourceParents -SourcePath (Join-Path $other 'missing.mkv') -SourceRoot $source
    Assert-True 'folders outside the source root remain' (Test-Path -LiteralPath $other)
    $emptyRoot = Join-Path $tmp 'empty-root'
    New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
    Remove-EmptySourceParents -SourcePath (Join-Path $emptyRoot 'missing.mkv') -SourceRoot $emptyRoot
    Assert-True 'even an empty root is never removed' (Test-Path -LiteralPath $emptyRoot)

    Write-TestResult -Suite 'empty-source-folders'
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
