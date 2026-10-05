# Shared helpers for the test scripts in this folder. Dot-source, do not run.
#
# Tests never copy the code they check. They lift the real function definitions
# out of the shipping scripts with the parser, so a test cannot drift away from
# the thing it is supposed to be testing - if a function is renamed or deleted,
# the test fails loudly instead of quietly passing against a stale copy.

$script:TestRoot = Split-Path -Parent $PSScriptRoot
$script:TestPassed = 0
$script:TestFailed = 0

# Return the source text of real function definitions from a script, by name.
#
# Callers dot-source the result:  . (Lift-Functions -Script 'balance.ps1' -Names ...)
#
# It returns text rather than defining them itself on purpose. Dot-sourcing
# inside this function would define the functions in *this* function's scope, and
# they would vanish the moment it returned - which looks exactly like the
# functions were never found.
function Lift-Functions {
    param([string]$Script, [string[]]$Names)

    $path = if ([System.IO.Path]::IsPathRooted($Script)) { $Script } else { Join-Path $script:TestRoot $Script }
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors) { throw ("{0} does not parse: {1}" -f (Split-Path $path -Leaf), $errors[0].Message) }

    $found = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Names -contains $n.Name
        }, $true)

    $missing = @($Names | Where-Object { $_ -notin $found.Name })
    if ($missing.Count) {
        throw ("could not lift from {0}: {1} (renamed or deleted?)" -f (Split-Path $path -Leaf), ($missing -join ', '))
    }

    Write-Host ("lifted from {0}: {1}" -f (Split-Path $path -Leaf), (($found.Name | Sort-Object) -join ', '))
    # Returned as a scriptblock, not a string: the dot operator treats a string as
    # the *name of a command to run*, so `. "function Get-Prop {...}"` tries to
    # launch a program with that name and fails.
    return [scriptblock]::Create(($found.Extent.Text -join "`r`n`r`n"))
}

# Pull a regex literal out of a script's source text, so a pattern can be tested
# without the function that uses it having to be run against a real event log.
function Lift-Pattern {
    param([string]$Script, [string]$Anchor, [int]$Occurrence = 1)

    $path = if ([System.IO.Path]::IsPathRooted($Script)) { $Script } else { Join-Path $script:TestRoot $Script }
    $src = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $rx = [regex]::new("-match\s+'(?<pat>[^']*" + [regex]::Escape($Anchor) + "[^']*)'")
    $seen = 0
    foreach ($m in $rx.Matches($src)) {
        $seen++
        if ($seen -eq $Occurrence) { return $m.Groups['pat'].Value }
    }
    throw ("pattern containing '{0}' not found in {1} - the source changed shape" -f $Anchor, (Split-Path $path -Leaf))
}

function Assert-Equal {
    param([string]$Name, $Got, $Want)

    $ok = $Got -eq $Want
    if ($ok) { $script:TestPassed++ } else { $script:TestFailed++ }
    $g = if ($null -eq $Got) { '(null)' } else { "$Got" }
    $w = if ($null -eq $Want) { '(null)' } else { "$Want" }
    "  {0} {1,-52} got={2,-10} want={3}" -f $(if ($ok) { 'ok  ' } else { 'FAIL' }), $Name, $g, $w
}

function Assert-True {
    param([string]$Name, $Condition)
    Assert-Equal -Name $Name -Got ([bool]$Condition) -Want $true
}

function Assert-False {
    param([string]$Name, $Condition)
    Assert-Equal -Name $Name -Got ([bool]$Condition) -Want $false
}

function Write-TestResult {
    param([string]$Suite)

    ''
    if ($script:TestFailed) {
        "RESULT {0}: {1} FAILED, {2} passed" -f $Suite, $script:TestFailed, $script:TestPassed
        exit 1
    }
    "RESULT {0}: all {1} checks pass" -f $Suite, $script:TestPassed
    exit 0
}
