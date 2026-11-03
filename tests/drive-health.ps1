$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

$balance = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\balance.ps1'))
$status = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\status.ps1'))
$config = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\config.example.json')) | ConvertFrom-Json

Assert-False 'balancer has no hardware/paging-error event gate' ($balance -match 'Get-WinEvent|Resolve-FailingDrives|Get-FailingDisks|unreadableDriveReason|not reading')
Assert-False 'status has no hardware/paging-error reporting' ($status -match 'Get-WinEvent|Get-FailingDrive|Get-DriveAlert|driveErrorWindowHours|paging errors')
Assert-False 'published config has no drive-error exclusion setting' ($null -ne $config.PSObject.Properties['driveErrorWindowHours'])
Assert-True 'normal source enumeration remains in place' ($balance -match 'foreach \(\$u in Get-Units -Library \$lib -Root \$root -Cutoff \$cutoff\)')
Assert-True 'unrelated readiness checks remain in place' ($balance -match '\.IsReady')
Assert-True 'unrelated active-file protections remain in place' ($balance -match 'skip_in_use')

Write-TestResult -Suite 'drive-health'
