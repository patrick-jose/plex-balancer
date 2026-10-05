# Runs every test suite and says plainly whether the project is healthy.
#
#   powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1
#   powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -Suite retention
#   powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -Quiet
#
# Exit code is 0 only when everything passes, so this can gate a commit or a
# scheduled check:
#
#   git commit  ; only after: powershell -File .\Run-Tests.ps1
#
# Three things are checked before any suite runs, because each of them has broken
# this project in a way the suites themselves could not report:
#
#   - every script parses. A syntax error in balance.ps1 is not a test failure, it
#     is a suite that cannot even load the function it is lifting.
#   - every test file is pure ASCII. powershell -File reads a script as ANSI, so a
#     single non-ASCII byte silently becomes mojibake and a path comparison fails
#     for a reason that looks nothing like an encoding problem.
#   - config.example.json exists. config.json is deliberately not committed, so on
#     a fresh clone the cascade suite falls back to the example - and if that file
#     is missing too, the suite fails with a message about drives rather than
#     about the missing file.

[CmdletBinding()]
param(
    # Run one suite by name instead of all of them.
    [string]$Suite = '',
    # Only the last few lines of each suite, for a quick go/no-go.
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$testsDir = Join-Path $root 'tests'
$runner = Join-Path $testsDir 'run-tests.ps1'

$script:Failures = @()
$script:Checks = 0

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * 74)
}

function Add-Problem {
    param([string]$Text)
    $script:Failures += $Text
    Write-Host "  $Text" -ForegroundColor Red
}

# ---- 1. do the scripts even parse --------------------------------------------
Write-Head 'CHECK  preflight'

$scripts = @(Get-ChildItem $root -Filter '*.ps1' -File) +
           @(Get-ChildItem $testsDir -Filter '*.ps1' -File)
$badParse = 0
foreach ($f in $scripts) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    if ($errors) {
        $badParse++
        Add-Problem ("{0} does not parse: line {1}: {2}" -f $f.Name, $errors[0].Extent.StartLineNumber, $errors[0].Message)
    }
}
if (-not $badParse) {
    Write-Host ("  ok   {0} script(s) parse" -f $scripts.Count)
}

# ---- 2. test files must be ASCII ---------------------------------------------
# The rule, not a preference: -File reads as ANSI. COMMANDS.md says so too; this
# is the check that stops it being forgotten the day someone adds an accent to a
# fixture path.
$nonAscii = @()
foreach ($f in Get-ChildItem $testsDir -Filter '*.ps1' -File) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if (@($bytes | Where-Object { $_ -gt 127 }).Count) { $nonAscii += $f.Name }
}
if ($nonAscii.Count) {
    foreach ($n in $nonAscii) {
        Add-Problem ("$n has non-ASCII bytes - powershell -File reads it as ANSI. Use [char]0x00E9 in the source instead.")
    }
}
else {
    Write-Host ("  ok   {0} test file(s) are pure ASCII" -f @(Get-ChildItem $testsDir -Filter '*.ps1' -File).Count)
}

# ---- 3. the example config the fallback needs ---------------------------------
$example = Join-Path $root 'config.example.json'
$config = Join-Path $root 'config.json'
if (-not (Test-Path -LiteralPath $example)) {
    Add-Problem 'config.example.json is missing - a fresh clone could not create a config'
}
else {
    try {
        [void]([System.IO.File]::ReadAllText($example, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
        if (Test-Path -LiteralPath $config) { Write-Host '  ok   config.example.json parses; local config.json present' }
        else { Write-Host '  ok   config.example.json parses (no local config.json - suites will use the example)' -ForegroundColor Yellow }
    }
    catch {
        Add-Problem ("config.example.json is not valid JSON: {0}" -f $_.Exception.Message)
    }
}

if ($script:Failures.Count) {
    Write-Host ''
    Write-Host 'preflight failed - suites not run, because they would report a misleading result.' -ForegroundColor Red
    exit 1
}

# ---- 4. run the suites --------------------------------------------------------
if (-not (Test-Path -LiteralPath $runner)) {
    Write-Host "runner not found at $runner" -ForegroundColor Red
    exit 1
}

Write-Head 'CHECK  suites'
$suites = @(Get-ChildItem $testsDir -Filter '*.ps1' -File |
        Where-Object { $_.Name -notin @('_helpers.ps1', 'run-tests.ps1') } |
        Sort-Object Name)
if (-not $suites.Count) {
    Write-Host '  no suites found in tests\' -ForegroundColor Red
    exit 1
}

# A bad -Suite name is a usage error, not a test failure, and the runner says so
# with exit code 2 and a list of what exists. Counted here so the verdict below
# cannot describe a mistyped suite name as a failing test run.
if ($Suite) {
    $suites = @($suites | Where-Object { $_.BaseName -eq $Suite })
    if (-not $suites.Count) {
        Write-Host ("  no suite named '{0}'." -f $Suite) -ForegroundColor Red
        Write-Host ('  available: ' + ((Get-ChildItem $testsDir -Filter '*.ps1' -File |
                    Where-Object { $_.Name -notin @('_helpers.ps1', 'run-tests.ps1') } |
                    Sort-Object Name | ForEach-Object { $_.BaseName }) -join ', ')) -ForegroundColor Red
        exit 2
    }
}

# Captured rather than streamed so the count can be totalled at the end. The runner
# is a child process because it calls exit, which would otherwise end this script
# at the first suite instead of after the last one.
#
# $runner, not $runner.FullName: Join-Path returns a string, and a string has no
# FullName, so the child would be handed -File with nothing after it.
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner)
if ($Suite) { $argList += @('-Suite', $Suite) }

$out = (& powershell @argList 2>&1 | Out-String)
$code = $LASTEXITCODE

if ($Quiet) {
    # The summary block plus the verdict: enough to see what passed without
    # scrolling back through 200 lines of check output.
    @($out -split "`r?`n") | Select-Object -Last 14 | ForEach-Object { Write-Host $_ }
}
else {
    Write-Host $out
}

# The runner exits 2 only for a usage error, which is already reported above with
# a list of valid names. Anything else non-zero is a real failure.
if ($code -eq 2) { exit 2 }

# ---- 5. total the checks, which the runner's own summary does not --------------
# Counting "ok  " rows is reading the suites' own output rather than keeping a
# separate tally, so the number cannot drift from what was actually reported.
$okCount = ([regex]::Matches($out, '(?m)^\s+ok\s+')).Count
$failCount = ([regex]::Matches($out, '(?m)^\s+FAIL\s+')).Count
$script:Checks = $okCount + $failCount

# ---- 6. verdict ----------------------------------------------------------------
Write-Head 'RESULT'
$verdict = if ($code -eq 0) { 'Green' } else { 'Red' }
Write-Host ("  {0} suite(s) run, {1} checks reported ({2} passed, {3} failed)" -f
    $suites.Count, $script:Checks, $okCount, $failCount) -ForegroundColor $verdict

if ($code -eq 0) {
    Write-Host '  PASS' -ForegroundColor Green
    exit 0
}
Write-Host '  FAIL' -ForegroundColor Red
exit 1