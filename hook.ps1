# Claude Code hook: records each session's state so watcher.ps1 can send reminders.
# Registered for UserPromptSubmit, Stop, StopFailure, Notification, PermissionRequest and SessionEnd.
# Reads the hook JSON from stdin, writes state\<session_id>.json, never blocks or fails the session.

try {
    . (Join-Path $PSScriptRoot 'common.ps1')

    $stdin = [Console]::OpenStandardInput()
    $ms = New-Object System.IO.MemoryStream
    $stdin.CopyTo($ms)
    $raw = [Text.Encoding]::UTF8.GetString($ms.ToArray())
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $evt = $raw | ConvertFrom-Json

    $sid = [string]$evt.session_id
    if ($sid -notmatch '^[A-Za-z0-9_\-]+$') { exit 0 }
    $hookName = [string]$evt.hook_event_name
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
    $path = Join-Path $StateDir "$sid.json"

    if ($hookName -eq 'SessionEnd') {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Write-NotifierLog "$sid SessionEnd ($($evt.reason))"
        exit 0
    }

    $new = $null; $detail = $null
    switch ($hookName) {
        'UserPromptSubmit'  { $new = 'active' }
        'Stop'              { $new = 'idle'; if ($evt.last_assistant_message) { $detail = [string]$evt.last_assistant_message } }
        'StopFailure'       { $new = 'idle'; $detail = 'The turn ended with an error' }
        'PermissionRequest' { $new = 'waiting'; $detail = "Claude wants to use $($evt.tool_name)" }
        'Notification' {
            $type = [string]$evt.notification_type
            if ($type -eq 'permission_prompt' -or $type -eq 'elicitation_dialog') { $new = 'waiting'; $detail = [string]$evt.message }
            elseif ($type -eq 'idle_prompt') { $new = 'idle-hint' }
        }
    }
    if (-not $new) { exit 0 }

    $old = $null
    try { $old = Read-JsonFile $path } catch { }

    if ($new -eq 'idle-hint') {
        # "waiting for your input" after 60s: only meaningful if we missed the Stop (e.g. the turn was interrupted).
        if ($old -and $old.status -ne 'active') { exit 0 }
        $new = 'idle'
    }

    $now = [DateTime]::UtcNow.ToString('o')
    $since = $now
    if ($old -and $old.status -eq $new -and $new -eq 'idle' -and $old.since) { $since = [string]$old.since }
    if ($detail) {
        $detail = ($detail -replace '\s+', ' ').Trim()
        if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 157) + '...' }
    } elseif ($old -and $old.status -eq $new) { $detail = $old.detail }

    # Remember which Claude process owns the session, so closed terminals stop getting reminders.
    $procId = $null; $procStart = $null
    if ($old -and $old.pid -and (Test-ProcessAlive $old.pid $old.pid_start)) { $procId = $old.pid; $procStart = $old.pid_start }
    else { $p = Find-ClaudeProcess; if ($p) { $procId = $p.Pid; $procStart = $p.Start } }

    $projectDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } elseif ($old -and $old.project_dir) { $old.project_dir } else { [string]$evt.cwd }

    $state = [ordered]@{
        session_id      = $sid
        status          = $new
        since           = $since
        updated         = $now
        last_event      = $hookName
        detail          = $detail
        cwd             = [string]$evt.cwd
        project_dir     = [string]$projectDir
        transcript_path = [string]$evt.transcript_path
        entrypoint      = [string]$env:CLAUDE_CODE_ENTRYPOINT
        pid             = $procId
        pid_start       = $procStart
    }
    Write-JsonFile $path $state
    if (-not $old -or $old.status -ne $new) { Write-NotifierLog "$sid $hookName -> $new ($($evt.cwd))" }
} catch {
    try { Write-NotifierLog "hook error: $($_.Exception.Message)" } catch { }
}
exit 0
