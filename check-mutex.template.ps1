try {
    $mutex = [Threading.Mutex]::new($false, 'Global\PlexBalancer')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true; Write-Host 'abandoned mutex; acquired for inspection' }

        if ($acquired) {
            Write-Host 'free'
            $mutex.ReleaseMutex()
        }
        else {
            Write-Host 'held'
        }
    }
    finally {
        $mutex.Dispose()
    }
}
catch {
    Write-Error $_
    exit 1
}
