# Runs every test suite and says plainly whether the project is healthy.
#
#   powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1
#   powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -Suite retention
#   powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -Quiet
#   powershell -ExecutionPolicy Bypass -File .\Run-Tests.ps1 -List
#
# Exit code is 0 only when everything passes, so this can gate a commit or a
# scheduled check:
#
#   git commit ; only after: powershell -File .\Run-Tests.ps1
#
# Exit codes:
#   0  every suite passed
#   1  preflight failed, or at least one suite failed
#   2  usage error - an unknown -Suite name. Distinguished from 1 so a typo can
#      never be mistaken for a real regression in a CI log.
#
# Each suite runs in its own powershell process. That is not tidiness: the suites
# lift functions out of the shipping scripts by defining them in their own scope,
# and the watchdog suite deliberately takes and releases the balancer's real mutex.
# Sharing one process would let a suite's leftovers decide the next suite's answer,
# and a suite calling exit would end the run at the first one instead of after the
# last. -NoProfile because a profile could change the answer.
#
# Three things are checked before any suite runs, because each has broken this
# project in a way the suites themselves could not report:
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
#
# A suite may exit 3 to say it SKIPPED: it cannot run right now for a reason that
# is not a defect. tests\watchdog.ps1 does this when the balancer is mid-run and
# holding the very mutex that suite asserts on. A skip is reported on its own line
# and never counted as a pass, so it cannot quietly turn a suite into a green tick
# that asserted nothing.

[CmdletBinding()]
param(
    # Run one suite by name instead of all of them.
    [string]$Suite = '',
    # Only the per-suite table and the verdict, for a quick go/no-go.
    [switch]$Quiet,
    # List the suites that would run, then exit without running them.
    [switch]$List,
    # Kill a suite that overruns this. 0 disables the guard.
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$testsDir = Join-Path $root 'tests'

$script:Results = @()
$script:Problems = @()

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * 74)
}

function Add-Problem {
    param([string]$Text)
    $script:Problems += $Text
    Write-Host "  $Text" -ForegroundColor Red
}

# Suites are every .ps1 in tests\ except the helpers, which are dot-sourced rather
# than run. The underscore prefix is what marks them: a helper with no underscore
# would be run as a suite, and it exits 0 having asserted nothing, which would look
# like a passing test.
function Get-SuiteFile {
    @(Get-ChildItem $testsDir -Filter '*.ps1' -File |
        Where-Object { $_.Name -notlike '_*' } |
        Sort-Object Name)
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
$testFiles = @(Get-ChildItem $testsDir -Filter '*.ps1' -File)
$nonAscii = @()
foreach ($f in $testFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if (@($bytes | Where-Object { $_ -gt 127 }).Count) { $nonAscii += $f.Name }
}
if ($nonAscii.Count) {
    foreach ($n in $nonAscii) {
        Add-Problem ("$n has non-ASCII bytes - powershell -File reads it as ANSI. Use [char]0x00E9 in the source instead.")
    }
}
else {
    Write-Host ("  ok   {0} test file(s) are pure ASCII" -f $testFiles.Count)
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

# The suites cannot report a missing tests\ folder usefully - they would fail on
# the file they are dot-sourcing - so it is a preflight problem, not a suite failure.
if (-not (Test-Path -LiteralPath $testsDir)) {
    Add-Problem ("tests\ not found at {0}" -f $testsDir)
}

if ($script:Problems.Count) {
    Write-Host ''
    Write-Host 'preflight failed - suites not run, because they would report a misleading result.' -ForegroundColor Red
    exit 1
}

# ---- 4. pick the suites --------------------------------------------------------
$suites = Get-SuiteFile

if ($List) {
    Write-Host ''
    foreach ($s in $suites) { Write-Host ("  {0}" -f $s.BaseName) }
    Write-Host ''
    Write-Host ("  {0} suite(s)" -f $suites.Count)
    exit 0
}

if (-not $suites.Count) {
    Write-Host ''
    Write-Host ("  no suites found in {0}" -f $testsDir) -ForegroundColor Red
    exit 1
}

if ($Suite) {
    $suites = @($suites | Where-Object { $_.BaseName -eq $Suite })
    if (-not $suites.Count) {
        Write-Host ''
        Write-Host ("  no suite named '{0}'." -f $Suite) -ForegroundColor Red
        Write-Host ('  available: ' + ((Get-SuiteFile).BaseName -join ', ')) -ForegroundColor Red
        exit 2
    }
}

# ---- 5. run them ---------------------------------------------------------------
# Output is captured per suite rather than streamed, for three reasons: the check
# count is read from the suites' own output so the number cannot drift from what
# was reported, a hung suite can be killed without losing the others' results, and
# a suite that dies mid-write cannot interleave into the table.
#
# The redirect files are per suite and deleted afterwards. RedirectStandardOutput
# holds its file exclusively for the life of the child, so they must be unique -
# two suites sharing one path would have the second write refused.
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("balancer-tests-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $scratch

try {
    foreach ($f in $suites) {
        $stdout = Join-Path $scratch ("{0}.out" -f $f.BaseName)
        $stderr = Join-Path $scratch ("{0}.err" -f $f.BaseName)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        $p = Start-Process -FilePath 'powershell' -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $f.FullName)

        # The handle is read BEFORE waiting. A Process object only keeps the exit
        # code it was polling for while it still holds an open handle; read it after
        # the child has gone and ExitCode comes back empty, which would mark every
        # suite as failed while printing its checks as passing. Verified: reading
        # Handle after WaitForExit gives '', reading it before gives the real code.
        [void]$p.Handle

        $timedOut = $false
        if ($TimeoutSeconds -gt 0) {
            if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
                $timedOut = $true
                # Kill the whole tree: a suite may have started a child of its own
                # (the watchdog suite does), and killing only the parent would leave
                # that child holding the mutex the next suite needs.
                try { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } catch { }
                try { $p.WaitForExit(10000) } catch { }
            }
        }
        else { $null = $p.WaitForExit() }

        $sw.Stop()
        $code = if ($timedOut) { 124 } else { $p.ExitCode }

        $text = if (Test-Path -LiteralPath $stdout) {
            [System.IO.File]::ReadAllText($stdout, [System.Text.Encoding]::UTF8)
        }
        else { '' }
        $errText = if (Test-Path -LiteralPath $stderr) {
            [System.IO.File]::ReadAllText($stderr, [System.Text.Encoding]::UTF8)
        }
        else { '' }

        $ok = ([regex]::Matches($text, '(?m)^\s+ok\s+')).Count
        $fail = ([regex]::Matches($text, '(?m)^\s+FAIL\s+')).Count
        # A skip is a suite saying it cannot run, not one that failed. It is kept
        # separate all the way to the summary so it cannot be mistaken for a pass.
        $skipped = ($code -eq 3)

        if (-not $Quiet) {
            Write-Host ''
            Write-Host ('=' * 72)
            Write-Host ("  {0}" -f $f.Name)
            Write-Host ('=' * 72)
            if ($text) { Write-Host ($text.TrimEnd()) }
            # A suite that writes to stderr without failing is still worth seeing:
            # the download guard and the watchdog both log there on the way past.
            if ($errText.Trim()) { Write-Host ($errText.TrimEnd()) -ForegroundColor DarkGray }
        }

        $note = ''
        if ($skipped) { $note = 'skipped - see the suite output' }
        elseif ($timedOut) { $note = "killed after ${TimeoutSeconds}s" }
        elseif ($ok + $fail -eq 0) { $note = 'reported no checks - it probably died before running' }
        elseif ($errText.Trim() -and $code -eq 0) { $note = 'wrote to stderr' }

        $script:Results += [pscustomobject]@{
            Suite   = $f.BaseName
            Code    = $code
            Ok      = $ok
            Fail    = $fail
            Secs    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            TimedOut = $timedOut
            Skipped = $skipped
            Note    = $note
        }
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- 6. verdict ----------------------------------------------------------------
$totalOk = ($script:Results | Measure-Object -Property Ok -Sum).Sum
$totalFail = ($script:Results | Measure-Object -Property Fail -Sum).Sum
# Skipped suites are excluded from the failure set explicitly. Left implicit, the
# exit-3 code would land them in $failed and fail the whole run for something the
# run itself called unavoidable.
$skippedResults = @($script:Results | Where-Object { $_.Skipped })
$failed = @($script:Results | Where-Object { $_.Code -ne 0 -and -not $_.Skipped })
$silent = @($script:Results | Where-Object { $_.Code -eq 0 -and ($_.Ok + $_.Fail) -eq 0 })

Write-Head 'SUMMARY'
foreach ($r in $script:Results) {
    if ($r.Skipped) {
        $mark = 'SKIP'; $colour = 'Yellow'
        $line = "  {0} {1,-20} {2,7}s" -f $mark, $r.Suite, $r.Secs
    }
    else {
        $mark = if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }
        $colour = if ($r.Code -eq 0) { 'Green' } else { 'Red' }
        $line = "  {0} {1,-20} {2,4} ok {3,4} failed {4,7}s" -f $mark, $r.Suite, $r.Ok, $r.Fail, $r.Secs
    }
    if ($r.Note) { $line += "  - $($r.Note)" }
    Write-Host $line -ForegroundColor $colour
}

$ranCount = $script:Results.Count - $skippedResults.Count
Write-Host ''
if ($skippedResults.Count) {
    Write-Host ("  {0} suite(s) run, {1} skipped, {2} checks reported ({3} ok, {4} failed)" -f
        $ranCount, $skippedResults.Count, ($totalOk + $totalFail), $totalOk, $totalFail) -ForegroundColor DarkGray
}
else {
    Write-Host ("  {0} suite(s) run, {1} checks reported ({2} ok, {3} failed)" -f
        $script:Results.Count, ($totalOk + $totalFail), $totalOk, $totalFail) -ForegroundColor DarkGray
}

if ($failed.Count) {
    foreach ($r in $failed) { Write-Host ("  FAILED: {0} (exit {1})" -f $r.Suite, $r.Code) -ForegroundColor Red }
    Write-Host ''
    Write-Host '  FAIL - see the suite output above' -ForegroundColor Red
    exit 1
}

# A suite that exits 0 without printing a check has asserted nothing. Counting it
# as a pass would let a suite silently stop running and still report green, which
# is the one failure mode a summary table cannot be trusted to catch on its own.
if ($silent.Count) {
    foreach ($r in $silent) { Write-Host ("  {0} exited 0 but printed no checks" -f $r.Suite) -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  FAIL - a suite reported success without asserting anything' -ForegroundColor Red
    exit 1
}

# A skip does not fail the run, but it is not a pass either, so it cannot be
# allowed to end in a bare green tick. It says so, and names itself.
if ($skippedResults.Count) {
    Write-Host ''
    foreach ($r in $skippedResults) {
        Write-Host ("  SKIPPED: {0} - it could not run, not that it passed" -f $r.Suite) -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  PASS with skips - every suite that ran reported success' -ForegroundColor Yellow
    exit 0
}

Write-Host '  PASS - every suite reported success' -ForegroundColor Green
exit 0