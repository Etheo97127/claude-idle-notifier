<#
.SYNOPSIS
  Claude Code idle reminders: Windows notifications for Claude Code sessions that are waiting on you or idle.

.EXAMPLE
  claude-idle install              # copy files, add hooks to ~/.claude/settings.json, start at logon, start now
  claude-idle status               # watcher state + every tracked session
  claude-idle exclude add          # stop monitoring the current folder (and its subfolders)
  claude-idle exclude add "D:\scratch\*"
  claude-idle exclude remove C:\code\demo
  claude-idle exclude list
  claude-idle set remind_every_minutes 15
  claude-idle test                 # show a sample notification
  claude-idle start | stop | restart
  claude-idle uninstall [-Purge]   # remove hooks + autostart (-Purge also deletes config and logs)
#>
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$ClaudeSettings = if ($env:CLAUDE_IDLE_NOTIFIER_SETTINGS) { $env:CLAUDE_IDLE_NOTIFIER_SETTINGS } else { Join-Path $env:USERPROFILE '.claude\settings.json' }
$StartupLink    = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Code idle reminders.lnk'
$HookEvents     = @('UserPromptSubmit', 'Stop', 'StopFailure', 'Notification', 'PermissionRequest', 'SessionEnd')
$HookMarker     = 'idle-notifier/hook.ps1'
$ProgramFiles   = @('common.ps1', 'hook.ps1', 'watcher.ps1', 'claude-idle.ps1', 'claude-idle.cmd', 'README.md')

function Get-WatcherCommandLine {
    $watcher = Join-Path $NotifierHome 'watcher.ps1'
    $homeArg = if ($env:CLAUDE_IDLE_NOTIFIER_HOME) { " -HomeDir `"$NotifierHome`"" } else { '' }
    return "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcher`"$homeArg"
}

# Always call as @(Get-WatcherProcesses): a single CimInstance returned bare has no usable .Count.
function Get-WatcherProcesses {
    $needle = (Join-Path $NotifierHome 'watcher.ps1').ToLower()
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLower().Contains($needle) }
}

function Start-Watcher {
    $running = @(Get-WatcherProcesses)
    if ($running.Count) { Write-Host "Watcher already running (pid $($running[0].ProcessId))."; return }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    # conhost --headless keeps Windows Terminal from opening a window; Win32_Process.Create detaches it from this shell.
    $cmd = "`"$conhost`" --headless `"$ps`" " + (Get-WatcherCommandLine)
    $started = $false
    try {
        $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
        $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; CurrentDirectory = $NotifierHome; ProcessStartupInformation = $si }
        $started = ($r.ReturnValue -eq 0)
    } catch { }
    if (-not $started) { Start-Process -FilePath $conhost -ArgumentList ('--headless "' + $ps + '" ' + (Get-WatcherCommandLine)) -WindowStyle Hidden }
    $deadline = [DateTime]::UtcNow.AddSeconds(20)   # PowerShell can take several seconds to start on a busy machine
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $running = @(Get-WatcherProcesses)
        if ($running.Count) { Write-Host "Watcher started (pid $($running[0].ProcessId))."; return }
    }
    Write-Warning "Watcher did not start within 20 s - check 'claude-idle status' or $LogPath"
}

function Stop-Watcher([switch]$Quiet) {
    $running = @(Get-WatcherProcesses)
    if (-not $running.Count) { if (-not $Quiet) { Write-Host 'Watcher is not running.' }; return }
    foreach ($p in $running) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    if (-not $Quiet) { Write-Host 'Watcher stopped.' }
}

# ---------------------------------------------------------------- Claude settings.json hooks

function Get-HookCommand {
    $hook = (Join-Path $NotifierHome 'hook.ps1') -replace '\\', '/'
    return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$hook`""
}

function Test-OurHookGroup($Group) {
    foreach ($h in @($Group.hooks)) { if ([string]$h.command -like "*$HookMarker*") { return $true } }
    return $false
}

function Read-ClaudeSettings {
    if (Test-Path -LiteralPath $ClaudeSettings) {
        $s = Read-JsonFile $ClaudeSettings
        if ($s) { return $s }
    }
    return [pscustomobject]@{}
}

function Set-ClaudeHooks([switch]$Remove) {
    $settings = Read-ClaudeSettings
    if (Test-Path -LiteralPath $ClaudeSettings) {
        $backup = '{0}.bak-idle-notifier-{1}' -f $ClaudeSettings, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $ClaudeSettings -Destination $backup
    }
    if (-not $settings.PSObject.Properties['hooks']) {
        if ($Remove) { return }
        $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
    }
    $hooks = $settings.hooks
    foreach ($evt in $HookEvents) {
        $groups = @()
        if ($hooks.PSObject.Properties[$evt]) { $groups = @($hooks.$evt | Where-Object { -not (Test-OurHookGroup $_) }) }
        if (-not $Remove) {
            $entry = [ordered]@{ type = 'command'; command = (Get-HookCommand); timeout = 30 }
            if ($evt -ne 'SessionEnd') { $entry.async = $true }   # never slow Claude down; SessionEnd runs during shutdown
            $groups += [pscustomobject]@{ hooks = @([pscustomobject]$entry) }
        }
        if ($hooks.PSObject.Properties[$evt]) { $hooks.PSObject.Properties.Remove($evt) }
        if ($groups.Count) { $hooks | Add-Member -NotePropertyName $evt -NotePropertyValue ([object[]]$groups) }
    }
    if (-not @($hooks.PSObject.Properties).Count) { $settings.PSObject.Properties.Remove('hooks') }
    if (-not (Test-Path -LiteralPath (Split-Path $ClaudeSettings))) { New-Item -ItemType Directory -Force -Path (Split-Path $ClaudeSettings) | Out-Null }
    Write-JsonFile $ClaudeSettings $settings
}

function Test-HooksInstalled {
    try {
        $s = Read-ClaudeSettings
        if (-not $s.PSObject.Properties['hooks']) { return $false }
        foreach ($evt in $HookEvents) {
            if (-not $s.hooks.PSObject.Properties[$evt]) { return $false }
            if (-not (@($s.hooks.$evt) | Where-Object { Test-OurHookGroup $_ })) { return $false }
        }
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------- install / uninstall

function Save-ClaudeIcon {
    $target = Join-Path $NotifierHome 'icon.png'
    if (Test-Path -LiteralPath $target) { return }
    $candidates = @(
        (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'AnthropicClaude') -Filter 'claude.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
        (Get-Command claude.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    ) | Where-Object { $_ }
    foreach ($exe in $candidates) {
        try {
            Add-Type -AssemblyName System.Drawing
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
            $bmp = $ico.ToBitmap(); $bmp.Save($target, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $ico.Dispose()
            return
        } catch { }
    }
}

function Install-Notifier {
    New-Item -ItemType Directory -Force -Path $NotifierHome, $StateDir | Out-Null
    $src = (Resolve-Path $PSScriptRoot).Path.TrimEnd('\')
    $dst = (Resolve-Path $NotifierHome).Path.TrimEnd('\')
    if ($src -ine $dst) {
        Stop-Watcher -Quiet
        foreach ($f in $ProgramFiles) {
            $from = Join-Path $src $f
            if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $dst $f) -Force }
        }
    }
    Write-Host "Program files: $NotifierHome"
    if (-not (Test-Path -LiteralPath $ConfigPath)) { Save-NotifierConfig (Get-NotifierConfig); Write-Host "Config:        $ConfigPath (new)" }
    else { Write-Host "Config:        $ConfigPath (kept)" }

    Save-ClaudeIcon
    Register-ToastApp

    Set-ClaudeHooks
    Write-Host "Hooks:         added to $ClaudeSettings (backup saved next to it)"

    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($StartupLink)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $lnk.Arguments = '--headless "' + (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') + '" ' + (Get-WatcherCommandLine)
    $lnk.WorkingDirectory = $NotifierHome
    $lnk.WindowStyle = 7
    $lnk.Description = 'Reminds you about Claude Code sessions that are waiting on you or idle'
    $lnk.Save()
    Write-Host "Autostart:     $StartupLink"

    if ($src -ine $dst) { Stop-Watcher -Quiet }
    Start-Watcher
    Write-Host ''
    Write-Host 'Hooks load when a Claude Code session starts: sessions that were already open are tracked after you restart them.'
}

function Uninstall-Notifier {
    Stop-Watcher
    Set-ClaudeHooks -Remove
    Write-Host "Hooks removed from $ClaudeSettings"
    if (Test-Path -LiteralPath $StartupLink) { Remove-Item -LiteralPath $StartupLink -Force; Write-Host 'Autostart removed.' }
    Remove-Item -Path "HKCU:\Software\Classes\AppUserModelId\$ToastAppId" -Recurse -Force -ErrorAction SilentlyContinue
    if ($Purge) {
        Remove-Item -LiteralPath $NotifierHome -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Deleted $NotifierHome"
    } else {
        Remove-Item -LiteralPath $StateDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Config and log kept in $NotifierHome (use -Purge to delete them)."
    }
}

# ---------------------------------------------------------------- status / exclusions / settings

function Show-Status {
    $cfg = Get-NotifierConfig
    $w = @(Get-WatcherProcesses)
    Write-Host ('Watcher:   ' + $(if ($w.Count) { "running (pid $($w[0].ProcessId))" } else { 'NOT running  ->  claude-idle start' }))
    Write-Host ('Hooks:     ' + $(if (Test-HooksInstalled) { "installed in $ClaudeSettings" } else { 'NOT installed  ->  claude-idle install' }))
    Write-Host ('Reminders: first after {0} min, then every {1} min, for: {2}; give up after {3} h' -f `
        $cfg.first_reminder_after_minutes, $cfg.remind_every_minutes, ($cfg.notify_when -join ', '), $(if ([double]$cfg.stop_after_hours -gt 0) { $cfg.stop_after_hours } else { 'never' }))
    Write-Host ('Excluded:  ' + $(if ($cfg.exclude_folders.Count) { '' } else { '(none)' }))
    foreach ($x in $cfg.exclude_folders) { Write-Host "  - $x" }
    Write-Host ''
    $views = @(Get-SessionViews -Config $cfg)
    if (-not $views.Count) { Write-Host 'No Claude Code sessions tracked yet (a session is tracked after its first prompt with the hooks loaded).'; return }
    $views | Sort-Object Since | ForEach-Object {
        [pscustomobject]@{
            Session = $_.SessionId.Substring(0, 8)
            Status  = $(if (-not $_.Alive) { 'closed' } elseif ($_.ExcludedBy) { "$($_.Status) (excluded)" } else { $_.Status })
            For     = Format-Age $_.Age
            Name    = $(if ($_.Name.Length -gt 40) { $_.Name.Substring(0, 37) + '...' } else { $_.Name })
            Folder  = $_.Folder
        }
    } | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
}

function Update-Exclusions([string]$Action, [string]$Path) {
    $cfg = Get-NotifierConfig
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($x in $cfg.exclude_folders) { $list.Add([string]$x) }
    switch ($Action) {
        'list' {
            if (-not $list.Count) { Write-Host 'No folders excluded.' } else { $list | ForEach-Object { Write-Host $_ } }
            return
        }
        'add' {
            if (-not $Path) { $Path = (Get-Location).Path }
            $entry = Resolve-FolderPattern $Path
            if ($list | Where-Object { (Resolve-FolderPattern $_) -ieq $entry }) { Write-Host "Already excluded: $entry"; return }
            if ($entry -notmatch '[\*\?]' -and -not (Test-Path -LiteralPath $entry)) { Write-Warning "$entry does not exist (added anyway)." }
            $list.Add($entry)
            Write-Host "Excluded: $entry (and everything under it)"
        }
        { $_ -in 'remove', 'rm', 'delete' } {
            if (-not $Path) { $Path = (Get-Location).Path }
            $entry = Resolve-FolderPattern $Path
            $match = @($list | Where-Object { $_ -ieq $Path -or (Resolve-FolderPattern $_) -ieq $entry })
            if (-not $match.Count) { Write-Host "Not in the exclusion list: $entry"; return }
            foreach ($m in $match) { [void]$list.Remove($m) }
            Write-Host "Monitoring again: $entry"
        }
        default { throw "Unknown exclude action '$Action'. Use: add | remove | list" }
    }
    $cfg.exclude_folders = [object[]]$list.ToArray()
    Save-NotifierConfig $cfg
}

function Set-ConfigValue([string]$Key, [string]$Value) {
    $cfg = Get-NotifierConfig
    if (-not $Key) { $cfg | ConvertTo-Json -Depth 5 | Write-Host; Write-Host "`nFile: $ConfigPath"; return }
    if (-not $DefaultConfig.Contains($Key)) { throw "Unknown setting '$Key'. Known: $($DefaultConfig.Keys -join ', ')" }
    $current = $DefaultConfig[$Key]
    if ($current -is [bool]) { $cfg[$Key] = $Value -match '^(1|true|yes|on)$' }
    elseif ($current -is [int] -or $current -is [double]) { $cfg[$Key] = [double]$Value }
    elseif ($current -is [array]) { $cfg[$Key] = [object[]]@($Value -split '\s*,\s*' | Where-Object { $_ }) }
    else { $cfg[$Key] = $Value }
    Save-NotifierConfig $cfg
    Write-Host "$Key = $(@($cfg[$Key]) -join ', ')"
}

function Send-TestToast {
    Register-ToastApp
    $fake = [pscustomobject]@{
        SessionId = 'test'; Name = 'Test session'; Folder = (Get-Location).Path; Status = 'waiting'
        Since = [DateTime]::UtcNow.AddMinutes(-12); Age = [TimeSpan]::FromMinutes(12)
        Detail = 'This is what a reminder looks like'; Alive = $true; ExcludedBy = $null
    }
    Send-SessionToast -Views @($fake) -Sound ([bool](Get-NotifierConfig).sound)
    Write-Host 'Sent a test notification.'
}

switch ($Command.ToLower()) {
    'install'   { Install-Notifier }
    'uninstall' { Uninstall-Notifier }
    'start'     { Start-Watcher }
    'stop'      { Stop-Watcher }
    'restart'   { Stop-Watcher; Start-Watcher }
    'status'    { Show-Status }
    'exclude'   { Update-Exclusions $(if ($Arg1) { $Arg1.ToLower() } else { 'list' }) $Arg2 }
    'set'       { Set-ConfigValue $Arg1 $Arg2 }
    'config'    { Set-ConfigValue $null $null }
    'test'      { Send-TestToast }
    'log'       { if (Test-Path -LiteralPath $LogPath) { Get-Content -LiteralPath $LogPath -Tail 40 } else { Write-Host 'No log yet.' } }
    default     { Get-Help $MyInvocation.MyCommand.Path -Examples }
}
