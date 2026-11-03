$files = Get-ChildItem -Path 'playlist-data' -Filter 'retirement-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 15
foreach ($f in $files) {
  $r = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
  [pscustomobject]@{
    File = $f.Name
    Item = $r.Item.Title
    Type = $r.Item.Type
    Status = $r.Status
    At = $r.At
  }
}
