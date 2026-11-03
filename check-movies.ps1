$state = [IO.File]::ReadAllText('playlist-data\state.json') | ConvertFrom-Json
Write-Host "applied=$($state.Applied) count=$(@($state.Queue).Count) movies=$(@($state.Movies).Count)"
for ($i = 0; $i -lt @($state.Movies).Count; $i++) {
  $m = $state.Movies[$i]
  "{0}: {1} watched={2} id={3}" -f ($i+1), $m.Title, $m.Watched, $m.Identity
}
