# A stand-in qBittorrent, for download-guard.ps1 to talk to.
#
# It answers /api/v2/torrents/info with whatever JSON is currently in the body file,
# and 404s everything else. Run as its own process by the suite, on a loopback port
# given on the command line, and killed by the suite when it is finished.
#
# Two details are deliberate, because reproducing the real client's mistakes is the
# whole point:
#
#   * The reply is "application/json" with NO charset, which is exactly what
#     qBittorrent sends. PowerShell then decodes it as Latin-1 and an accented path
#     arrives mangled - the bug the suite exists to prove cannot happen.
#   * It is a child process rather than an in-process listener, because a
#     BeginGetContext callback inside a `powershell -File` script makes the host
#     exit 2 whatever exit code the script asked for, which would turn every other
#     suite's result into a lie.
#
# The body comes from a file, re-read on every request, so a test can change the
# torrent list between cases without restarting anything.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$BodyFile,
    [Parameter(Mandatory = $true)][string]$FilesFile,
    [Parameter(Mandatory = $true)][string]$ReadyFile
)

$ErrorActionPreference = 'Stop'

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

# Tell the parent we are listening by creating a file it can poll for. Not by
# writing to stdout: Start-Process -RedirectStandardOutput holds its output file
# open exclusively, so the parent cannot read it and a readiness check based on it
# either throws on every poll or hangs. A file this server opens and closes is the
# only handshake that works from both sides.
[System.IO.File]::WriteAllText($ReadyFile, "READY $Port")

try {
    while ($true) {
        $ctx = $listener.GetContext()
        try {
            $path = $ctx.Request.Url.AbsolutePath
            $json = $null
            if ($path -like '*/torrents/info') {
                $json = [System.IO.File]::ReadAllText($BodyFile, [System.Text.Encoding]::UTF8)
            }
            elseif ($path -like '*/torrents/files*') {
                # Keyed by hash, the way the real endpoint is. A hash with no entry
                # answers 404, which is how a torrent's file list "cannot be read".
                $hash = $ctx.Request.QueryString['hash']
                $map = [System.IO.File]::ReadAllText($FilesFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                $prop = $map.PSObject.Properties[$hash]
                if ($prop) { $json = ConvertTo-Json -InputObject @($prop.Value) -Depth 4 -Compress }
                else { $ctx.Response.StatusCode = 404 }
            }
            if ($json) {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $ctx.Response.ContentType = 'application/json'
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            $ctx.Response.Close()
        }
        catch { }
    }
}
finally {
    try { $listener.Stop(); $listener.Close() } catch { }
}