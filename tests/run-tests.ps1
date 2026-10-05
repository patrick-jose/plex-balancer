# Run every suite in this folder and summarise.
#
# Each suite is a separate process on purpose: they lift functions by defining them
# in their own scope, and the watchdog suite deliberately takes and releases the
# balancer's real mutex. Isolating them keeps one suite's state out of another's
# and lets a suite call exit with its own status.
#
#   powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
#   powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1 -Suite watchdog
#
# Exit code is 0 only when every suite passes, so this can gate a commit.

[CmdletBinding()]
param([string]$Suite = '')

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

$all = @(Get-ChildItem $here -Filter '*.ps1' -File |
        Where-Object { $_.Name -notin @('_helpers.ps1', 'run-tests.ps1') } |
        Sort-Object Name)

$chosen = if ($Suite) { @($all | Where-Object { $_.BaseName -eq $Suite }) } else { $all }
if ($Suite -and -not $chosen.Count) {
    "no suite named '{0}'. available: {1}" -f $Suite, (($all.BaseName) -join ', ')
    exit 2
}

$results = @()
foreach ($f in $chosen) {
    ''
    '=' * 72
    "  {0}" -f $f.Name
    '=' * 72
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # -NoProfile, and a child powershell: a profile could change the answer.
    $p = Start-Process -FilePath 'powershell' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $f.FullName) `
        -NoNewWindow -Wait -PassThru
    $sw.Stop()
    $results += [pscustomobject]@{
        Suite = $f.BaseName
        Code = $p.ExitCode
        Secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

''
'=' * 72
'  summary'
'=' * 72
$bad = 0
foreach ($r in $results) {
    if ($r.Code -ne 0) { $bad++ }
    "  {0} {1,-20} {2,6}s" -f $(if ($r.Code -eq 0) { 'PASS' } else { 'FAIL' }), $r.Suite, $r.Secs
}
''
if ($bad) { "  {0} of {1} suite(s) FAILED" -f $bad, $results.Count; exit 1 }
"  all $($results.Count) suite(s) pass"
exit 0
