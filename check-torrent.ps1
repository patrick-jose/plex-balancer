$base = 'http://127.0.0.1:8080'
$torrents = @(Invoke-RestMethod -Uri "$base/api/v2/torrents/info" -Method Get)
foreach ($t in $torrents) {
    if ($t.name -match 'Dexter') {
        [pscustomobject]@{
            Name = $t.name
            Progress = $t.progress
            State = $t.state
            ContentPath = $t.content_path
        }
    }
}
