# Per-file storage history.
#
# The balancer's moves-*.jsonl is an audit log with a retention window: after
# logRetentionDays it is pruned. That is fine for "what moved today" and useless
# for "where was this episode last week, and who removed it" - which is exactly
# the question every time a library file goes missing. This script keeps a
# durable, append-only ledger of every media path it has seen, independent of
# log pruning and independent of the balance run that touched it.
#
# It is read-only on the library: it never moves, renames or deletes media. It
# writes only under storage-history\:
#   index.json          current snapshot: path -> size, mtime, first/last seen,
#                       Present or Missing, plus per-root health
#   events-YYYYMM.jsonl append-only events: appeared, moved, vanished, changed,
#                       reappeared, retired, move_failed, root-offline/online
#   ingest.json         how far each moves-*.jsonl and retirement record was read
#
# A disappearance is inferred, not witnessed: the file was present at the last
# scan and is absent at this one, with its root reachable and scanned cleanly.
# An offline or partially scanned root never marks its files missing, so an
# unplugged USB disk cannot fake a loss. A path that vanishes while a same-name,
# same-size path appears within 48 hours is recorded as a move, not a loss.
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$DataDirectory,
    [switch]$IngestOnly,
    [switch]$NoIngest,
    [switch]$DryRun,
    [string]$Report,
    [int]$Limit = 200,
    [int]$MinIntervalMinutes = 0
)

function New-StorageEntry {
    param(
        [string]$Path, [long]$Size, [string]$LastWrite,
        [string]$FirstSeen, [string]$LastSeen, [string]$State,
        $MissingSince, [string]$Library, [string]$Root
    )
    [pscustomobject]@{
        Path = $Path; Size = $Size; LastWrite = $LastWrite
        FirstSeen = $FirstSeen; LastSeen = $LastSeen
        State = $State; MissingSince = $MissingSince
        Library = $Library; Root = $Root
    }
}

function Get-StorageIndex {
    param([string]$Path)

    $index = [pscustomobject]@{ Version = 1; At = ''; Files = @{}; RootHealth = @{} }
    if (-not (Test-Path -LiteralPath $Path)) { return $index }

    $raw = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ([int]$raw.Version -ne 1) { throw "Unsupported storage-history index version '$($raw.Version)'. Refusing to overwrite it." }
    $index.At = [string]$raw.At

    if ($raw.Files) {
        foreach ($p in $raw.Files.PSObject.Properties) {
            $e = $p.Value
            $index.Files[$p.Name] = New-StorageEntry -Path $e.Path -Size ([long]$e.Size) -LastWrite ([string]$e.LastWrite) `
                -FirstSeen ([string]$e.FirstSeen) -LastSeen ([string]$e.LastSeen) `
                -State $(if ($e.State) { [string]$e.State } else { 'Present' }) `
                -MissingSince $e.MissingSince -Library ([string]$e.Library) -Root ([string]$e.Root)
        }
    }
    if ($raw.RootHealth) {
        foreach ($p in $raw.RootHealth.PSObject.Properties) { $index.RootHealth[$p.Name] = $p.Value }
    }
    return $index
}

function Save-StorageIndex {
    param([string]$Path, $Index)

    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Index -Depth 12), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, $Path + '.bak') }
    else { [IO.File]::Move($tmp, $Path) }
}

function Add-StorageEvent {
    param([string]$DataDirectory, $Event)

    $at = Get-Date
    if ($Event.at) {
        try {
            $at = [datetime]::Parse([string]$Event.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        }
        catch { $at = Get-Date }
    }
    [void][IO.Directory]::CreateDirectory($DataDirectory)
    $file = Join-Path $DataDirectory ('events-' + $at.ToString('yyyyMM') + '.jsonl')
    $line = ConvertTo-Json -InputObject $Event -Depth 8 -Compress
    [IO.File]::AppendAllText($file, $line + "`n", [Text.UTF8Encoding]::new($false))
}

function Test-StorageScanDue {
    param([string]$IndexPath, [int]$MinIntervalMinutes)

    # A full walk of every library root is cheap here (a few thousand files) but
    # not free, and the watcher calls this hourly. The index carries the time of
    # its own scan, so the script can decide for itself whether it is due and a
    # caller never has to remember when it last ran. An unreadable index is
    # treated as due: a scan that always runs costs time, one that never runs
    # loses history.
    if ($MinIntervalMinutes -le 0) { return $true }
    if (-not (Test-Path -LiteralPath $IndexPath)) { return $true }
    try { $index = [IO.File]::ReadAllText($IndexPath) | ConvertFrom-Json } catch { return $true }
    if (-not $index.At) { return $true }
    try {
        $last = [datetime]::Parse([string]$index.At, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch { return $true }
    return ((Get-Date) - $last).TotalMinutes -ge $MinIntervalMinutes
}

function Get-StorageScan {
    param($Config)

    $files = @{}
    $health = @{}
    $roots = @{}
    foreach ($library in @($Config.libraries)) {
        $exts = @($library.mediaExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $name = [string]$library.name
        foreach ($root in @($library.roots)) {
            $rootText = [string]$root
            $rootKey = $rootText.TrimEnd('\').ToLowerInvariant()
            $roots[$rootKey] = $rootText
            if (-not (Test-Path -LiteralPath $rootText)) { $health[$rootKey] = 'offline'; continue }

            $rootErrors = @()
            $items = @(Get-ChildItem -LiteralPath $rootText -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable rootErrors)
            # An unreadable subfolder skips its files silently. Judging those
            # files "missing" on the strength of a partial walk is worse than
            # waiting for the next clean scan.
            $health[$rootKey] = $(if (@($rootErrors).Count) { 'partial' } else { 'ok' })

            foreach ($file in $items) {
                if ($exts -notcontains $file.Extension.ToLowerInvariant()) { continue }
                $files[$file.FullName.ToLowerInvariant()] = [pscustomobject]@{
                    Path = $file.FullName; Size = [long]$file.Length
                    LastWrite = $file.LastWriteTimeUtc.ToString('o')
                    Library = $name; Root = $rootText
                }
            }
        }
    }
    return [pscustomobject]@{ Files = $files; Health = $health; Roots = $roots }
}

function Compare-StorageHistory {
    param($Index, $Scan, [datetime]$At)

    $atText = $At.ToString('o')
    $events = New-Object System.Collections.ArrayList
    $files = @{}
    foreach ($key in @($Index.Files.Keys)) {
        $e = $Index.Files[$key]
        $files[$key] = New-StorageEntry -Path $e.Path -Size ([long]$e.Size) -LastWrite ([string]$e.LastWrite) `
            -FirstSeen ([string]$e.FirstSeen) -LastSeen ([string]$e.LastSeen) `
            -State $(if ($e.State) { [string]$e.State } else { 'Present' }) `
            -MissingSince $e.MissingSince -Library ([string]$e.Library) -Root ([string]$e.Root)
    }

    # Root health first: it decides which absences are evidence and which are
    # just an unreachable disk.
    $oldHealth = $Index.RootHealth
    $newHealth = @{}
    $firstRun = -not [string]$Index.At
    foreach ($rootKey in @($Scan.Health.Keys)) {
        $state = [string]$Scan.Health[$rootKey]
        $rootText = [string]$Scan.Roots[$rootKey]
        $previous = $null
        if ($oldHealth -and $oldHealth.ContainsKey($rootKey)) { $previous = [string]$oldHealth[$rootKey].State }
        $newHealth[$rootKey] = [pscustomobject]@{ Root = $rootText; State = $state; At = $atText }
        if (-not $firstRun -and $previous -ne $state -and ($previous -or $state -ne 'ok')) {
            $kind = switch ($state) {
                'offline' { 'root-offline' }
                'partial' { 'root-partial' }
                default { 'root-online' }
            }
            [void]$events.Add([ordered]@{
                    at = $atText; event = $kind; path = $rootText
                    detail = $(switch ($state) {
                            'offline' { 'Root not reachable; its files are not judged missing.' }
                            'partial' { 'Root walked with errors; its unread files are not judged missing.' }
                            default { 'Root reachable again; absence checks resumed for its files.' }
                        })
                })
        }
    }

    # New paths, indexed by file name and size, so a balancer move can be told
    # apart from a plain appearance and a disappearance.
    $newPaths = @{}
    foreach ($key in @($Scan.Files.Keys)) {
        if (-not $files.ContainsKey($key)) { $newPaths[$key] = $Scan.Files[$key] }
    }
    $byNameSize = @{}
    foreach ($key in @($newPaths.Keys)) {
        $f = $newPaths[$key]
        $matchKey = [IO.Path]::GetFileName($f.Path).ToLowerInvariant() + '|' + $f.Size
        if (-not $byNameSize.ContainsKey($matchKey)) { $byNameSize[$matchKey] = New-Object System.Collections.Queue }
        $byNameSize[$matchKey].Enqueue($key)
    }
    $claimed = @{}

    foreach ($key in @($files.Keys | Sort-Object)) {
        $e = $files[$key]
        if ($Scan.Files.ContainsKey($key)) { continue }
        if ($e.State -eq 'Missing') { continue }

        $rootKey = ([string]$e.Root).TrimEnd('\').ToLowerInvariant()
        if (-not $Scan.Health.ContainsKey($rootKey) -or [string]$Scan.Health[$rootKey] -ne 'ok') { continue }

        $lastSeen = $At
        if ($e.LastSeen) {
            try { $lastSeen = [datetime]::Parse([string]$e.LastSeen, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
            catch { $lastSeen = $At }
        }

        $matchKey = [IO.Path]::GetFileName($e.Path).ToLowerInvariant() + '|' + $e.Size
        $movedTo = $null
        if (($At - $lastSeen).TotalHours -le 48 -and $byNameSize.ContainsKey($matchKey) -and $byNameSize[$matchKey].Count) {
            $movedTo = [string]$byNameSize[$matchKey].Dequeue()
        }

        if ($movedTo) {
            $claimed[$movedTo] = $true
            $destination = $Scan.Files[$movedTo]
            [void]$files.Remove($key)
            $files[$movedTo] = New-StorageEntry -Path $destination.Path -Size ([long]$destination.Size) -LastWrite ([string]$destination.LastWrite) `
                -FirstSeen ([string]$e.FirstSeen) -LastSeen $atText -State 'Present' -MissingSince $null `
                -Library ([string]$destination.Library) -Root ([string]$destination.Root)
            [void]$events.Add([ordered]@{
                    at = $atText; event = 'moved'; path = $e.Path; dest = $destination.Path; size = [long]$destination.Size
                    library = [string]$destination.Library; detail = 'matched by file name and size'
                })
        }
        else {
            $e.State = 'Missing'; $e.MissingSince = $atText
            [void]$events.Add([ordered]@{
                    at = $atText; event = 'vanished'; path = $e.Path; size = [long]$e.Size
                    library = [string]$e.Library; lastSeen = [string]$e.LastSeen
                    detail = 'root scanned cleanly; no file with this name and size appeared within the move window'
                })
        }
    }

    foreach ($key in @($Scan.Files.Keys | Sort-Object)) {
        if ($claimed.ContainsKey($key)) { continue }
        $f = $Scan.Files[$key]
        if ($files.ContainsKey($key)) {
            $e = $files[$key]
            $wasMissing = $e.State -eq 'Missing'
            $sizeChanged = [long]$e.Size -ne [long]$f.Size
            $mtimeChanged = [string]$e.LastWrite -cne [string]$f.LastWrite
            if ($wasMissing) {
                $e.State = 'Present'
                $missingSince = $e.MissingSince
                $e.MissingSince = $null
                $e.LastSeen = $atText
                $e.Size = [long]$f.Size
                $e.LastWrite = [string]$f.LastWrite
                [void]$events.Add([ordered]@{
                        at = $atText; event = 'reappeared'; path = $f.Path; size = [long]$f.Size
                        library = [string]$f.Library; missingSince = [string]$missingSince
                        detail = 'same path is present again'
                    })
            }
            else {
                $oldSize = [long]$e.Size
                $e.LastSeen = $atText
                $e.Size = [long]$f.Size
                $e.LastWrite = [string]$f.LastWrite
                if ($sizeChanged -or $mtimeChanged) {
                    [void]$events.Add([ordered]@{
                            at = $atText; event = 'changed'; path = $f.Path; size = [long]$f.Size
                            oldSize = $oldSize; library = [string]$f.Library
                            detail = $(if ($sizeChanged) { 'file size changed' } else { 'file modification time changed' })
                        })
                }
            }
        }
        else {
            $files[$key] = New-StorageEntry -Path $f.Path -Size ([long]$f.Size) -LastWrite ([string]$f.LastWrite) `
                -FirstSeen $atText -LastSeen $atText -State 'Present' -MissingSince $null `
                -Library ([string]$f.Library) -Root ([string]$f.Root)
            [void]$events.Add([ordered]@{
                    at = $atText; event = 'appeared'; path = $f.Path; size = [long]$f.Size
                    library = [string]$f.Library; detail = 'first seen by the storage scanner'
                })
        }
    }

    return [pscustomobject]@{
        Index = [pscustomobject]@{ Version = 1; At = $atText; Files = $files; RootHealth = $newHealth }
        Events = @($events)
    }
}

function Invoke-StorageIngest {
    param([string]$ProjectRoot, [string]$DataDirectory, [switch]$DryRun)

    $statePath = Join-Path $DataDirectory 'ingest.json'
    $state = @{ Files = @{}; Retirements = @{} }
    if (Test-Path -LiteralPath $statePath) {
        $raw = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        if ($raw.Files) { foreach ($p in $raw.Files.PSObject.Properties) { $state.Files[$p.Name] = [long]$p.Value } }
        if ($raw.Retirements) { foreach ($p in $raw.Retirements.PSObject.Properties) { $state.Retirements[$p.Name] = $true } }
    }

    $events = New-Object System.Collections.ArrayList
    $logs = @(Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'logs') -Filter 'moves-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($log in $logs) {
        $offset = 0
        if ($state.Files.ContainsKey($log.Name)) { $offset = [long]$state.Files[$log.Name] }
        if ($log.Length -lt $offset) { $offset = 0 }
        if ($log.Length -eq $offset) { continue }

        $bytes = New-Object byte[] ($log.Length - $offset)
        $read = 0
        $stream = [IO.File]::Open($log.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            [void]$stream.Seek($offset, 'Begin')
            while ($read -lt $bytes.Length) {
                $n = $stream.Read($bytes, $read, $bytes.Length - $read)
                if ($n -le 0) { break }
                $read += $n
            }
        }
        finally { $stream.Dispose() }

        $text = [Text.Encoding]::UTF8.GetString($bytes, 0, $read)
        $lastNewline = $text.LastIndexOf("`n")
        if ($lastNewline -lt 0) { continue }
        $complete = $text.Substring(0, $lastNewline + 1)
        $consumed = [Text.Encoding]::UTF8.GetByteCount($complete)

        foreach ($line in ($complete -split "`n")) {
            $lineText = $line.Trim()
            if (-not $lineText) { continue }
            try { $ev = $lineText | ConvertFrom-Json } catch { continue }
            if ([string]$ev.event -notin @('move_failed', 'partial_removed', 'partial_remove_failed')) { continue }
            [void]$events.Add([ordered]@{
                    at = [string]$ev.at; event = [string]$ev.event
                    path = [string]$ev.path; dest = [string]$ev.dest
                    sizeGB = $ev.sizeGB; error = [string]$ev.error
                    origin = 'balance'; source = $log.Name
                })
        }
        $state.Files[$log.Name] = $offset + $consumed
    }

    $retirementDir = Join-Path $ProjectRoot 'playlist-data'
    if (Test-Path -LiteralPath $retirementDir) {
        foreach ($record in @(Get-ChildItem -LiteralPath $retirementDir -Filter 'retirement-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($state.Retirements.ContainsKey($record.Name)) { continue }
            try { $r = [IO.File]::ReadAllText($record.FullName) | ConvertFrom-Json } catch { continue }
            if ($r.Deleted -ne $true) { continue }
            [void]$events.Add([ordered]@{
                    at = [string]$r.At; event = 'retired'; path = [string]$r.Path
                    title = [string]$r.Item.Title; show = [string]$r.Item.Show
                    season = $r.Item.Season; episode = $r.Item.Episode
                    origin = 'playlist-retirement'; source = $record.Name
                })
            $state.Retirements[$record.Name] = $true
        }
    }

    if (-not $DryRun) {
        foreach ($event in $events) { Add-StorageEvent -DataDirectory $DataDirectory -Event $event }
        [void][IO.Directory]::CreateDirectory($DataDirectory)
        $tmp = $statePath + '.tmp'
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $state -Depth 6), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($statePath)) { [IO.File]::Replace($tmp, $statePath, $statePath + '.bak') }
        else { [IO.File]::Move($tmp, $statePath) }
    }
    return [pscustomobject]@{ Events = @($events) }
}

function Get-StorageEvents {
    param([string]$DataDirectory)

    $files = @(Get-ChildItem -LiteralPath $DataDirectory -Filter 'events-*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $events = New-Object System.Collections.ArrayList
    foreach ($file in $files) {
        foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
            if (-not $line.Trim()) { continue }
            try { [void]$events.Add(($line | ConvertFrom-Json)) } catch { }
        }
    }
    return @($events)
}

function Get-StorageHistoryReport {
    param([string]$DataDirectory, [string]$Pattern, [int]$Limit = 200)

    $needle = $Pattern.ToLowerInvariant()
    $files = @()
    $indexPath = Join-Path $DataDirectory 'index.json'
    if (Test-Path -LiteralPath $indexPath) {
        $index = Get-StorageIndex -Path $indexPath
        $files = @($index.Files.Values | Where-Object { $_.Path.ToLowerInvariant().Contains($needle) } | Sort-Object Path)
    }
    $events = @(Get-StorageEvents -DataDirectory $DataDirectory | Where-Object {
            (([string]$_.path) + ' ' + ([string]$_.dest) + ' ' + ([string]$_.detail) + ' ' + ([string]$_.show) + ' ' + ([string]$_.title)).ToLowerInvariant().Contains($needle)
        } | Sort-Object { [string]$_.at })
    if ($Limit -gt 0 -and $events.Count -gt $Limit) { $events = @($events | Select-Object -Last $Limit) }
    return [pscustomobject]@{ Files = $files; Events = $events }
}

function Format-StorageHistoryReport {
    param($Report, [string]$Pattern)

    $out = New-Object System.Collections.ArrayList
    if (-not $Report.Files.Count -and -not $Report.Events.Count) {
        [void]$out.Add("No storage history matches '$Pattern'.")
        return @($out)
    }
    if ($Report.Files.Count) {
        [void]$out.Add('--- current locations ---')
        foreach ($f in $Report.Files) {
            $first = ''
            if ($f.FirstSeen) { try { $first = ([datetime]$f.FirstSeen).ToString('yyyy-MM-dd') } catch { } }
            $last = ''
            if ($f.LastSeen) { try { $last = ([datetime]$f.LastSeen).ToString('yyyy-MM-dd HH:mm') } catch { } }
            [void]$out.Add(('{0,-8} {1}  ({2} GB, first {3}, last {4})' -f $f.State, $f.Path, [math]::Round($f.Size / 1GB, 2), $first, $last))
        }
    }
    if ($Report.Events.Count) {
        [void]$out.Add('--- events (oldest first) ---')
        foreach ($e in $Report.Events) {
            $when = ''
            if ($e.at) { try { $when = ([datetime]$e.at).ToString('yyyy-MM-dd HH:mm') } catch { $when = [string]$e.at } }
            $extra = ''
            if ($e.event -eq 'moved') { $extra = '-> ' + [string]$e.dest }
            elseif ($e.event -eq 'vanished') {
                $seen = [string]$e.lastSeen
                if ($seen) { try { $seen = ([datetime]$seen).ToString('yyyy-MM-dd HH:mm') } catch { } }
                $extra = "(last seen $seen)"
            }
            elseif ($e.event -eq 'move_failed') { $extra = [string]$e.error }
            elseif ($e.event -eq 'retired') { $extra = ('watched retirement: {0} {1} S{2:00}E{3:00}' -f $e.show, $e.title, [int]$e.season, [int]$e.episode) }
            elseif ($e.detail) { $extra = [string]$e.detail }
            [void]$out.Add(('{0}  {1,-13} {2} {3}' -f $when, $e.event, $e.path, $extra))
        }
    }
    return @($out)
}

if ($MyInvocation.InvocationName -ne '.') {
    $projectRoot = $PSScriptRoot
    if (-not $ConfigPath) { $ConfigPath = Join-Path $projectRoot 'config.json' }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw 'config.json not found. Pass -ConfigPath.' }
    if (-not $DataDirectory) { $DataDirectory = Join-Path $projectRoot 'storage-history' }

    if ($Report) {
        $result = Get-StorageHistoryReport -DataDirectory $DataDirectory -Pattern $Report -Limit $Limit
        foreach ($line in (Format-StorageHistoryReport -Report $result -Pattern $Report)) { $line }
        return
    }

    $cfg = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
    if (-not $NoIngest) {
        $ingested = Invoke-StorageIngest -ProjectRoot $projectRoot -DataDirectory $DataDirectory -DryRun:$DryRun
        foreach ($e in $ingested.Events) {
            $label = if ($e.event -eq 'move_failed') { 'MOVE FAILED' } else { 'retired' }
            "ingested: $label $($e.path) $(if ($e.error) { '- ' + $e.error } else { '' })"
        }
    }
    if (-not $IngestOnly) {
        $indexPath = Join-Path $DataDirectory 'index.json'
        if (-not (Test-StorageScanDue -IndexPath $indexPath -MinIntervalMinutes $MinIntervalMinutes)) {
            $lastText = ''
            try { $lastText = [string](([IO.File]::ReadAllText($indexPath) | ConvertFrom-Json).At) } catch { }
            "storage history: skipped, last scan was $lastText (interval ${MinIntervalMinutes}m)"
            return
        }
        $index = Get-StorageIndex -Path $indexPath
        $scan = Get-StorageScan -Config $cfg
        $compared = Compare-StorageHistory -Index $index -Scan $scan -At (Get-Date)

        if (-not $DryRun) {
            foreach ($event in $compared.Events) { Add-StorageEvent -DataDirectory $DataDirectory -Event $event }
            Save-StorageIndex -Path $indexPath -Index $compared.Index
        }

        $kinds = @{}
        foreach ($event in $compared.Events) { $kinds[[string]$event.event] = 1 + [int]$kinds[[string]$event.event] }
        $present = @($compared.Index.Files.Values | Where-Object { $_.State -eq 'Present' }).Count
        $missing = @($compared.Index.Files.Values | Where-Object { $_.State -eq 'Missing' }).Count
        "storage history: tracked $present present, $missing missing; appeared $([int]$kinds['appeared']), moved $([int]$kinds['moved']), vanished $([int]$kinds['vanished']), changed $([int]$kinds['changed']), reappeared $([int]$kinds['reappeared'])"
        if ($DryRun) { 'dry run: index and events were not written' }
        else { "events: $(Join-Path $DataDirectory ('events-' + (Get-Date).ToString('yyyyMM') + '.jsonl'))" }
        foreach ($event in @($compared.Events | Where-Object { $_.event -eq 'vanished' })) {
            "  VANISHED: $($event.path) ($([math]::Round($event.size / 1GB, 2)) GB, last seen $($event.lastSeen))"
        }
    }
}
