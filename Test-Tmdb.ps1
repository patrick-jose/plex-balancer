# Validate configured TMDb authentication without printing credentials or using
# cached metadata. No Plex or playlist calls and no media changes.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'playlist-lib.ps1')
$script:PlaylistCfg=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'playlist.config.json'))|ConvertFrom-Json
$script:PlaylistData=Join-Path $PSScriptRoot 'playlist-data'
try {
    $result=Get-PlaylistMetadata -Path 'authentication' -Fresh
    if(-not $result.success){throw 'Authentication rejected.'}
    Write-Host 'TMDb authentication successful.'
}
catch { Write-Host 'TMDb authentication failed. Check tmdbReadToken or tmdbApiKey in playlist.config.json. Credential not displayed.'; exit 1 }
