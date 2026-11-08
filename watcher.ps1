# Background loop: every few seconds, looks at the session states written by hook.ps1 and shows a
# Windows notification for sessions that have been waiting on you / idle longer than the configured time.
param([string]$HomeDir, [switch]$Once)

if ($HomeDir) { $env:CLAUDE_IDLE_NOTIFIER_HOME = $HomeDir }
. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $Once) {
    $mutexName = 'Local\ClaudeCodeIdleNotifier-' + $NotifierHome.ToLower().GetHashCode()
    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    if (-not $mutex.WaitOne(0)) { exit 0 }   # already running
}

$script:Track = @{}   # session id -> @{ Key; Last; Count }

function Invoke-WatcherTick {
    $cfg = Get-NotifierConfig
    $now = [DateTime]::UtcNow
    $first = [TimeSpan]::FromMinutes([double]$cfg.first_reminder_after_minutes)
    $every = [TimeSpan]::FromMinutes([double]$cfg.remind_every_minutes) - [TimeSpan]::FromSeconds([double]$cfg.check_every_seconds / 2)
    $maxAge = if ([double]$cfg.stop_after_hours -gt 0) { [TimeSpan]::FromHours([double]$cfg.stop_after_hours) } else { [TimeSpan]::MaxValue }
    $wantWaiting = $cfg.notify_when -contains 'waiting'
    $wantIdle = $cfg.notify_when -contains 'idle'

    $eligible = New-Object System.Collections.Generic.List[object]
    $due = $false
    $seen = @{}
    foreach ($v in (Get-SessionViews -Config $cfg -PruneDead)) {
        $seen[$v.SessionId] = $true
        if ($v.ExcludedBy) { continue }
        $kind = switch ($v.Status) { 'waiting' { 'waiting' } 'tool-pending' { 'waiting' } 'idle' { 'idle' } default { $null } }
        if (-not $kind) { continue }
        if ($kind -eq 'waiting' -and -not $wantWaiting) { continue }
        if ($kind -eq 'idle' -and -not $wantIdle) { continue }
        if ($v.Age -lt $first -or $v.Age -gt $maxAge) { continue }

        $key = '{0}|{1}' -f $v.Status, $v.Since.Ticks
        $t = $script:Track[$v.SessionId]
        if (-not $t -or $t.Key -ne $key) { $t = @{ Key = $key; Last = $null; Count = 0 }; $script:Track[$v.SessionId] = $t }
        $eligible.Add($v)
        if (-not $t.Last -or ($now - $t.Last) -ge $every) { $due = $true }
    }
    foreach ($id in @($script:Track.Keys)) { if (-not $seen[$id]) { $script:Track.Remove($id) } }

    if ($due -and $eligible.Count -gt 0) {
        try {
            Send-SessionToast -Views $eligible -Sound ([bool]$cfg.sound)
            Write-NotifierLog ('reminder sent: ' + (($eligible | ForEach-Object { '{0} [{1}, {2}]' -f $_.Name, $_.Status, (Format-Age $_.Age) }) -join '; '))
        } catch {
            Write-NotifierLog "could not show notification: $($_.Exception.Message)"
        }
        foreach ($v in $eligible) { $t = $script:Track[$v.SessionId]; $t.Last = $now; $t.Count++ }
    }
}

if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
if ($Once) { Invoke-WatcherTick; exit 0 }

Write-NotifierLog "watcher started (home: $NotifierHome)"
try { Register-ToastApp } catch { }
while ($true) {
    $sleep = 30
    try {
        Invoke-WatcherTick
        $sleep = [Math]::Max(5, [int](Get-NotifierConfig).check_every_seconds)
    } catch {
        Write-NotifierLog "watcher error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $sleep
}
