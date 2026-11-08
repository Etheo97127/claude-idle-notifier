# Claude Idle Notifier - shared helpers (Windows PowerShell 5.1+, no extra modules).
# Dot-sourced by hook.ps1, watcher.ps1 and claude-idle.ps1.

$NotifierHome = if ($env:CLAUDE_IDLE_NOTIFIER_HOME) { $env:CLAUDE_IDLE_NOTIFIER_HOME } else { Join-Path $env:USERPROFILE '.claude\idle-notifier' }
$StateDir     = Join-Path $NotifierHome 'state'
$ConfigPath   = Join-Path $NotifierHome 'config.json'
$LogPath      = Join-Path $NotifierHome 'notifier.log'
$ToastAppId   = 'ClaudeCode.IdleNotifier'
$Utf8NoBom    = New-Object System.Text.UTF8Encoding($false)

$DefaultConfig = [ordered]@{
    remind_every_minutes         = 10                          # gap between reminders for the same session
    first_reminder_after_minutes = 10                          # how long a session must sit before the first reminder
    notify_when                  = @('waiting', 'idle')        # 'waiting' = needs your input/approval, 'idle' = finished its turn
    stop_after_hours             = 8                           # stop reminding after a session has sat this long (0 = never)
    detect_pending_tools         = $true                       # treat a tool call stuck without a result as "waiting"
    pending_tool_ignore          = @('Agent', 'Task', 'Workflow')  # long-running tools that are not waiting on you
    check_every_seconds          = 30
    sound                        = $true
    exclude_folders              = @()                         # folders (and their subfolders) that are never monitored
}

# ---------------------------------------------------------------- logging / json

function Write-NotifierLog([string]$Message) {
    try {
        if (-not (Test-Path -LiteralPath $NotifierHome)) { return }
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
        }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $Message
        [IO.File]::AppendAllText($LogPath, $line + "`r`n", $Utf8NoBom)
    } catch { }
}

# Re-indents compact JSON with 2 spaces (Windows PowerShell's ConvertTo-Json output is hard to read).
function Format-Json([string]$Json) {
    $sb = New-Object System.Text.StringBuilder
    $indent = 0; $inStr = $false; $esc = $false
    for ($i = 0; $i -lt $Json.Length; $i++) {
        $ch = $Json[$i]
        if ($inStr) {
            [void]$sb.Append($ch)
            if ($esc) { $esc = $false } elseif ($ch -eq [char]'\') { $esc = $true } elseif ($ch -eq [char]'"') { $inStr = $false }
            continue
        }
        if ($ch -eq [char]'"') { $inStr = $true; [void]$sb.Append($ch); continue }
        if ($ch -eq [char]'{' -or $ch -eq [char]'[') {
            $j = $i + 1
            while ($j -lt $Json.Length -and [char]::IsWhiteSpace($Json[$j])) { $j++ }
            if ($j -lt $Json.Length -and ($Json[$j] -eq [char]'}' -or $Json[$j] -eq [char]']')) {
                [void]$sb.Append($ch).Append($Json[$j]); $i = $j; continue
            }
            $indent++
            [void]$sb.Append($ch).Append("`n").Append('  ' * $indent); continue
        }
        if ($ch -eq [char]'}' -or $ch -eq [char]']') { $indent--; [void]$sb.Append("`n").Append('  ' * $indent).Append($ch); continue }
        if ($ch -eq [char]',') { [void]$sb.Append(",`n").Append('  ' * $indent); continue }
        if ($ch -eq [char]':') { [void]$sb.Append(': '); continue }
        if (-not [char]::IsWhiteSpace($ch)) { [void]$sb.Append($ch) }
    }
    $out = $sb.ToString()
    # Windows PowerShell escapes these needlessly; undo it (only where the backslash is not itself escaped).
    foreach ($pair in @(@('0026', '&'), @('003c', '<'), @('003e', '>'), @('0027', "'"))) {
        $out = [regex]::Replace($out, '(?<!\\)((?:\\\\)*)\\u' + $pair[0], '${1}' + $pair[1])
    }
    return $out
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Write-JsonFile([string]$Path, $Object) {
    $json = Format-Json ($Object | ConvertTo-Json -Depth 30 -Compress)
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $json + "`n", $Utf8NoBom)
    for ($try = 0; $try -lt 5; $try++) {
        try { Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 100 }
    }
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    throw "Could not write $Path"
}

function ConvertTo-UtcDate($Value) {
    if (-not $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    try { return ([DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime } catch { return $null }
}

# ---------------------------------------------------------------- config

function Get-NotifierConfig {
    $cfg = [ordered]@{}
    foreach ($k in $DefaultConfig.Keys) { $cfg[$k] = $DefaultConfig[$k] }
    try {
        $j = Read-JsonFile $ConfigPath
        if ($j) { foreach ($p in $j.PSObject.Properties) { if (-not $p.Name.StartsWith('_')) { $cfg[$p.Name] = $p.Value } } }
    } catch { Write-NotifierLog "config.json could not be parsed, using defaults: $($_.Exception.Message)" }
    $cfg.exclude_folders     = [object[]]@($cfg.exclude_folders | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $cfg.notify_when         = [object[]]@($cfg.notify_when | ForEach-Object { ([string]$_).ToLower() })
    $cfg.pending_tool_ignore = [object[]]@($cfg.pending_tool_ignore | ForEach-Object { [string]$_ })
    return $cfg
}

function Save-NotifierConfig($Config) {
    if (-not (Test-Path -LiteralPath $NotifierHome)) { New-Item -ItemType Directory -Force -Path $NotifierHome | Out-Null }
    Write-JsonFile $ConfigPath $Config
}

# ---------------------------------------------------------------- folder exclusion

# Normalises a folder path or pattern: expands %VARS% and ~, accepts / and /c/... forms, drops trailing slash.
function Resolve-FolderPattern([string]$Path) {
    if (-not $Path) { return '' }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ($p -eq '~') { $p = $env:USERPROFILE }
    elseif ($p.StartsWith('~/') -or $p.StartsWith('~\')) { $p = Join-Path $env:USERPROFILE $p.Substring(2) }
    $p = $p -replace '/', '\'
    if ($p -match '^\\([a-zA-Z])(\\.*)?$') { $p = $Matches[1] + ':' + $(if ($Matches[2]) { $Matches[2] } else { '\' }) }
    if ($p -notmatch '[\*\?]') { try { $p = [IO.Path]::GetFullPath($p) } catch { } }
    return $p.TrimEnd('\')
}

# Returns the exclusion entry that matches $Path (the folder itself or anything under it), else $null.
function Get-MatchingExclusion([string]$Path, $Patterns) {
    if (-not $Path) { return $null }
    $n = Resolve-FolderPattern $Path
    foreach ($raw in @($Patterns)) {
        $pat = Resolve-FolderPattern ([string]$raw)
        if (-not $pat) { continue }
        if ($pat -match '[\*\?]') {
            $like = $pat -replace '\[', '`[' -replace '\]', '`]'
            if ($n -like $like -or $n -like "$like\*") { return $raw }
        } elseif ($n -ieq $pat -or $n.StartsWith($pat + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $raw
        }
    }
    return $null
}

# ---------------------------------------------------------------- Claude process tracking

# Walks up from this process to the Claude Code process that ran the hook.
function Find-ClaudeProcess {
    try {
        $procId = $PID
        for ($i = 0; $i -lt 10 -and $procId; $i++) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop
            if (-not $p) { break }
            if ($i -gt 0) {
                $name = ([string]$p.Name).ToLower()
                if ($name -eq 'claude.exe' -or ($name -eq 'node.exe' -and [string]$p.CommandLine -match 'claude')) {
                    $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
                    $start = $null
                    if ($gp) { try { $start = $gp.StartTime.ToUniversalTime().ToString('o') } catch { } }
                    return [pscustomobject]@{ Pid = [int]$p.ProcessId; Start = $start }
                }
            }
            $procId = [int]$p.ParentProcessId
        }
    } catch { }
    return $null
}

function Test-ProcessAlive($ProcessId, $StartIso) {
    if (-not $ProcessId) { return $true }   # unknown -> assume alive
    $p = Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    $recorded = ConvertTo-UtcDate $StartIso
    if ($recorded) {
        try {
            if ([math]::Abs(($p.StartTime.ToUniversalTime() - $recorded).TotalSeconds) -gt 2) { return $false }   # pid was reused
        } catch { }
    }
    return $true
}

# ---------------------------------------------------------------- transcript inspection

$script:TranscriptCache = @{}

# Reads the tail of a session transcript (.jsonl) and returns the session title and any tool call still waiting for its result.
function Get-TranscriptInfo([string]$Path) {
    $result = [pscustomobject]@{ Readable = $false; Title = $null; PendingTool = $null; LastEntryTime = $null }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $result }
    $fi = Get-Item -LiteralPath $Path
    $cacheKey = '{0}|{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks
    $cached = $script:TranscriptCache[$Path]
    if ($cached -and $cached.Key -eq $cacheKey) { return $cached.Value }

    $maxBytes = 2MB
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
        try {
            $len = $fs.Length
            $start = [Math]::Max([long]0, $len - $maxBytes)
            [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] ($len - $start)
            $read = 0
            while ($read -lt $buf.Length) { $n = $fs.Read($buf, $read, $buf.Length - $read); if ($n -le 0) { break }; $read += $n }
            $text = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        } finally { $fs.Dispose() }
    } catch { return $result }

    $lines = $text -split "`n"
    $firstUsable = if ($start -gt 0) { 1 } else { 0 }   # first line may be cut in half
    $foundConversation = $false
    for ($i = $lines.Count - 1; $i -ge $firstUsable; $i--) {
        $line = $lines[$i].Trim()
        if (-not $line.StartsWith('{')) { continue }
        if (-not $result.Title -and $line -match '^\{"type":"(custom-title|agent-name|summary)"') {
            try {
                $o = $line | ConvertFrom-Json
                $t = @($o.customTitle, $o.agentName, $o.summary) | Where-Object { $_ } | Select-Object -First 1
                if ($t) { $result.Title = [string]$t }
            } catch { }
            continue
        }
        if ($foundConversation) { if ($result.Title) { break } else { continue } }
        if ($line.StartsWith('{"type":"')) { continue }   # metadata entries (api-request, mode, last-prompt, ...)
        if ($line -notmatch '"type":"(assistant|user)"') { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.type -ne 'assistant' -and $o.type -ne 'user') { continue }
        if ($o.isSidechain) { continue }
        $foundConversation = $true
        $result.LastEntryTime = ConvertTo-UtcDate $o.timestamp
        if ($o.type -eq 'assistant') {
            $blocks = @($o.message.content)
            if ($blocks.Count -gt 0 -and $blocks[-1].type -eq 'tool_use') {
                $result.PendingTool = [pscustomobject]@{ Name = [string]$blocks[-1].name; Time = $result.LastEntryTime }
            }
        }
    }
    $result.Readable = $foundConversation
    $script:TranscriptCache[$Path] = @{ Key = $cacheKey; Value = $result }
    return $result
}

# ---------------------------------------------------------------- session views

function Format-Age([TimeSpan]$Span) {
    if ($Span.TotalMinutes -lt 1) { return '<1 min' }
    if ($Span.TotalHours -lt 1) { return ('{0} min' -f [int][math]::Floor($Span.TotalMinutes)) }
    return ('{0} h {1:00} min' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes)
}

# Effective state of every tracked session. Status is one of:
#   active | waiting (hook says Claude needs input) | tool-pending (a tool call has no result yet) | idle
function Get-SessionViews($Config, [switch]$PruneDead) {
    $views = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $StateDir)) { return $views }
    $now = [DateTime]::UtcNow
    foreach ($f in Get-ChildItem -LiteralPath $StateDir -Filter '*.json' -File) {
        $s = $null
        try { $s = Read-JsonFile $f.FullName } catch { continue }
        if (-not $s -or -not $s.session_id) { continue }

        $alive = Test-ProcessAlive $s.pid $s.pid_start
        $updated = ConvertTo-UtcDate $s.updated
        $stale = $updated -and ($now - $updated).TotalDays -gt 7
        if ($PruneDead -and (-not $alive -or $stale)) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            Write-NotifierLog ("forgot session {0}: {1}" -f $s.session_id, $(if (-not $alive) { 'Claude process exited' } else { 'no activity for 7 days' }))
            continue
        }

        $status = [string]$s.status
        $since = ConvertTo-UtcDate $s.since
        if (-not $since) { $since = $now }
        $detail = [string]$s.detail
        $info = $null
        if ($status -ne 'idle' -or -not $s.title) { $info = Get-TranscriptInfo ([string]$s.transcript_path) }

        if ($status -eq 'waiting' -and $info -and $info.Readable) {
            # Claude has moved on since the prompt (tool ran / was denied / new turn) -> no longer waiting.
            if (-not $info.PendingTool -or $info.PendingTool.Time -gt $since.AddSeconds(5)) { $status = 'active'; $detail = $null }
        }
        if ($status -eq 'active' -and $Config.detect_pending_tools -and $info -and $info.PendingTool -and
            ($Config.pending_tool_ignore -notcontains $info.PendingTool.Name) -and $info.PendingTool.Time) {
            $status = 'tool-pending'
            $since = $info.PendingTool.Time
            $detail = "Tool '$($info.PendingTool.Name)' has no result yet - it may need your approval or answer"
        }

        $folder = if ($s.project_dir) { [string]$s.project_dir } else { [string]$s.cwd }
        $title = if ($info -and $info.Title) { $info.Title } elseif ($s.title) { [string]$s.title } else { $null }
        $name = if ($title) { $title } elseif ($folder) { Split-Path -Leaf $folder } else { $s.session_id.Substring(0, 8) }
        $excludedBy = Get-MatchingExclusion ([string]$s.cwd) $Config.exclude_folders
        if (-not $excludedBy -and $s.project_dir) { $excludedBy = Get-MatchingExclusion ([string]$s.project_dir) $Config.exclude_folders }

        $views.Add([pscustomobject]@{
            SessionId  = [string]$s.session_id
            Name       = $name
            Folder     = $folder
            Status     = $status
            Since      = $since
            Age        = $now - $since
            Detail     = $detail
            Source     = [string]$s.entrypoint
            Alive      = $alive
            ExcludedBy = $excludedBy
        })
    }
    return $views
}

# ---------------------------------------------------------------- toasts

function Register-ToastApp {
    $key = "HKCU:\Software\Classes\AppUserModelId\$ToastAppId"
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name DisplayName -Value 'Claude Code idle reminders'
    Set-ItemProperty -Path $key -Name ShowInSettings -Value 1 -Type DWord
    $icon = Join-Path $NotifierHome 'icon.png'
    if (Test-Path -LiteralPath $icon) { Set-ItemProperty -Path $key -Name IconUri -Value $icon }
}

function Show-Toast([string]$Title, [string[]]$Lines, [string]$Attribution, [bool]$Sound = $true) {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $e = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $body = (@($Lines | Where-Object { $_ } | Select-Object -First 2) | ForEach-Object { '<text>' + (& $e $_) + '</text>' }) -join ''
    $attr = if ($Attribution) { '<text placement="attribution">' + (& $e $Attribution) + '</text>' } else { '' }
    $audio = if ($Sound) { '<audio src="ms-winsoundevent:Notification.Reminder"/>' } else { '<audio silent="true"/>' }
    $xml = '<toast><visual><binding template="ToastGeneric"><text>' + (& $e $Title) + '</text>' + $body + $attr + '</binding></visual>' + $audio + '</toast>'
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
    $toast.Tag = 'idle-sessions'      # each reminder replaces the previous one in Action Center
    $toast.Group = 'claude-idle-notifier'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId).Show($toast)
}

function Send-SessionToast($Views, [bool]$Sound = $true) {
    $hourglass = [char]0x23F3
    $sleeping = [char]::ConvertFromUtf32(0x1F4A4)
    $sorted = @($Views | Sort-Object @{ Expression = { if ($_.Status -eq 'idle') { 1 } else { 0 } } }, @{ Expression = { $_.Since } })
    $label = {
        param($v)
        switch ($v.Status) { 'waiting' { 'needs your input' } 'tool-pending' { 'may need your input' } default { 'is idle' } }
    }
    if ($sorted.Count -eq 1) {
        $v = $sorted[0]
        $icon = if ($v.Status -eq 'idle') { $sleeping } else { $hourglass }
        $title = '{0} {1} {2}' -f $icon, $v.Name, (& $label $v)
        $line1 = '{0} for {1}' -f $(if ($v.Status -eq 'idle') { 'Idle' } else { 'Waiting' }), (Format-Age $v.Age)
        $line2 = if ($v.Detail) { $v.Detail } else { $null }
        Show-Toast -Title $title -Lines @($line1, $line2) -Attribution $v.Folder -Sound $Sound
    } else {
        $waiting = @($sorted | Where-Object { $_.Status -ne 'idle' }).Count
        $title = '{0} {1} Claude Code sessions need you' -f $hourglass, $sorted.Count
        if ($waiting) { $title = '{0} {1} Claude Code sessions need you ({2} waiting on input)' -f $hourglass, $sorted.Count, $waiting }
        $shown = @($sorted | Select-Object -First 4 | ForEach-Object {
            $icon = if ($_.Status -eq 'idle') { $sleeping } else { $hourglass }
            '{0} {1} - {2} {3}' -f $icon, $_.Name, $(if ($_.Status -eq 'idle') { 'idle' } else { 'waiting' }), (Format-Age $_.Age)
        })
        if ($sorted.Count -gt 4) { $shown += ('...and {0} more' -f ($sorted.Count - 4)) }
        Show-Toast -Title $title -Lines @(($shown -join "`n")) -Attribution 'Claude Code idle reminders' -Sound $Sound
    }
}
