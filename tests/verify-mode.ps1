# Which verification method a run uses, and who gets to decide.
#
# This exists because "verify" in config.json was documented as the verification
# method and was read by nothing. Setting "verify": "hash" and running without
# -Hash gave size verification - a silent downgrade of the check that decides
# whether it is safe to delete the source of a 50 GB move. A config key that looks
# like it works and does not is worse than an absent one, because the user stops
# checking.
#
# Two rules are being pinned down here:
#
#   1. The config key decides, by default. An unrecognised value is an error, not
#      a fallback - falling back would downgrade the check while appearing to
#      honour the config.
#   2. An explicitly bound -Hash wins, in both directions. -Hash forces hashing
#      against a config saying size; -Hash:$false forces size against a config
#      saying hash. The second one only works because an explicitly bound switch
#      is distinguishable from an unset one, which is the whole reason
#      Resolve-VerifyMode takes -HashBound rather than just -Hash.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_helpers.ps1')

. (Lift-Functions -Script 'balance.ps1' -Names 'Get-Prop', 'Resolve-VerifyMode')

function Mode {
    param($Cfg, [switch]$Hash, [bool]$Bound = $false)
    return [bool](Resolve-VerifyMode -Cfg $Cfg -Hash:$Hash -HashBound $Bound)
}

$size = [pscustomobject]@{ verify = 'size' }
$hash = [pscustomobject]@{ verify = 'hash' }
$none = [pscustomobject]@{}

# ---- 1. the config key decides when nothing is passed on the command line ------
Assert-False 'config size, nothing passed -> size' (Mode -Cfg $size)
Assert-True 'config hash, nothing passed -> hash' (Mode -Cfg $hash)
Assert-False 'key absent, nothing passed -> size' (Mode -Cfg $none)
Assert-False 'no config at all -> size' (Mode -Cfg $null)

# ---- 2. case and surrounding whitespace must not matter ------------------------
# config.json is hand-edited, and a trailing space in a JSON string is invisible.
Assert-True '"HASH" is accepted' (Mode -Cfg ([pscustomobject]@{ verify = 'HASH' }))
Assert-True '"Hash" is accepted' (Mode -Cfg ([pscustomobject]@{ verify = 'Hash' }))
Assert-True '" hash " is accepted' (Mode -Cfg ([pscustomobject]@{ verify = ' hash ' }))
Assert-False '" size " is accepted and means size' (Mode -Cfg ([pscustomobject]@{ verify = ' size ' }))

# ---- 3. an empty value is no value, not an error ------------------------------
Assert-False 'empty string falls back to size' (Mode -Cfg ([pscustomobject]@{ verify = '' }))
Assert-False 'whitespace falls back to size' (Mode -Cfg ([pscustomobject]@{ verify = '   ' }))

# ---- 4. an unrecognised value is refused, not guessed --------------------------
# The dangerous failure is a typo quietly meaning "size" while the user believes
# they asked for "hash". Refusing is the only safe answer.
foreach ($bad in 'hahs', 'sha256', 'size ', 'true', '1') {
    if ($bad -eq 'size ') { continue }   # trailing space is handled in section 2
    $threw = $false
    try { $null = Mode -Cfg ([pscustomobject]@{ verify = $bad }) }
    catch { $threw = $true }
    Assert-True "refused: '$bad'" $threw
}

# and the message says what the valid values are
try { $null = Mode -Cfg ([pscustomobject]@{ verify = 'hahs' }); $msg = '' }
catch { $msg = $_.Exception.Message }
Assert-True 'the error names the bad value' ($msg -match 'hahs')
Assert-True 'the error names the valid values' ($msg -match "'size'" -and $msg -match "'hash'")

# ---- 5. an explicitly bound -Hash wins, in both directions --------------------
Assert-True 'config size + -Hash -> hash' (Mode -Cfg $size -Hash -Bound $true)
Assert-True 'config hash + -Hash -> hash' (Mode -Cfg $hash -Hash -Bound $true)
Assert-False 'config hash + -Hash:$false -> size' (Mode -Cfg $hash -Bound $true)
Assert-False 'config size + -Hash:$false -> size' (Mode -Cfg $size -Bound $true)

# An unbound -Hash (the default $false) must behave as though nothing was passed,
# otherwise every run that forgot the flag would get size verification regardless
# of what the config asked for. The config still wins here.
Assert-True 'config hash + unbound -Hash -> hash, from config' (Mode -Cfg $hash -Hash -Bound $false)
Assert-False 'config size + unbound -Hash -> size' (Mode -Cfg $size -Hash -Bound $false)

# ---- 6. the invalid-value check still fires when -Hash is bound ---------------
# -Hash forces hashing regardless, but a config that says "hahs" is still a typo the
# user should hear about rather than have masked by a flag that happens to give the
# same answer.
$threw = $false
try { $null = Mode -Cfg ([pscustomobject]@{ verify = 'hahs' }) -Hash -Bound $true }
catch { $threw = $true }
Assert-True 'a bad value is still refused when -Hash is bound' $threw

# ---- 7. this is what the wiring is for: -Hash is really the only other input ---
# Guards against someone re-pointing $Hash at something else and leaving the
# resolver decorative.
$src = [System.IO.File]::ReadAllText((Join-Path $script:TestRoot 'balance.ps1'), [System.Text.Encoding]::UTF8)
$fnStart = $src.IndexOf('function Resolve-VerifyMode')
$fn = $src.Substring($fnStart, 1200)
# Single-quoted throughout. In a double-quoted PowerShell string \$Hash does not
# mean a literal dollar sign - the backslash is kept and $Hash is expanded, so the
# pattern silently becomes "\ = Resolve-VerifyMode" and matches nothing. That is
# exactly the shape of bug this suite is about: a check that looks like it is
# asserting something and is not.
Assert-True 'the gate reads PSBoundParameters' ($src -match '\$Hash = Resolve-VerifyMode .*PSBoundParameters\.ContainsKey')
Assert-True 'the invalid value is thrown, not warned' ($fn -match 'throw')
Assert-True 'the invalid value does not fall back silently' ($fn -notmatch 'Write-Warning')
# and the resolver must actually be called, or the key is inert again
Assert-True 'Resolve-VerifyMode is called at run time' ($src -match '(?m)^\$Hash = Resolve-VerifyMode')

Write-TestResult -Suite 'verify-mode'