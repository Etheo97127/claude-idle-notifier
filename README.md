# Claude Code idle reminders (Windows)

Windows notifications for Claude Code sessions that are **waiting on you** (permission prompt,
question, MCP dialog) or **idle** (finished their turn). First reminder after 10 minutes, then
every 10 minutes, all due sessions batched into one notification. Works for the CLI and for
the Code tab of the Claude desktop app. Plain Windows PowerShell 5.1, nothing to install.

## How it works

| Piece | What it does |
|---|---|
| `hook.ps1` | Claude Code hook (async, so it never slows Claude down). On `UserPromptSubmit` → *active*, `Stop`/`StopFailure` → *idle*, `Notification` (permission / elicitation) and `PermissionRequest` → *waiting*, `SessionEnd` → forget. Writes `state\<session>.json` with the folder, transcript and the owning Claude process id. |
| `watcher.ps1` | Background loop (started at logon). Every 30 s reads the states, skips excluded folders, and shows a toast when a session has been waiting/idle long enough. Sessions whose Claude process has exited are forgotten. |
| transcript check | If a permission prompt was answered, the watcher sees the tool result in the transcript and stops reminding. If a tool call has had no result for 10+ min (e.g. a desktop-app approval or `AskUserQuestion`), it is reported as *may need your input*. |
| `claude-idle.ps1` | Install / status / exclusions / settings. |

## Install

From a clone of this repo, in PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\claude-idle.ps1 install
```

This copies the scripts to `%USERPROFILE%\.claude\idle-notifier\`, adds the hooks to
`~/.claude/settings.json` (a backup is saved next to it), adds a shortcut to your Startup folder
so the watcher runs at logon, and starts the watcher. Re-run it after pulling changes.

## Commands

After installing, run `claude-idle` from `%USERPROFILE%\.claude\idle-notifier\` (or use the full path):

```
claude-idle install                    # copy files, add hooks to ~/.claude/settings.json, autostart, start
claude-idle status                     # watcher + hooks + every tracked session
claude-idle exclude add                # never monitor the current folder (and its subfolders)
claude-idle exclude add "D:\sandbox"   # a specific folder
claude-idle exclude add "%APPDATA%\Claude\scratch-workspaces"   # e.g. all "No folder" desktop sessions
claude-idle exclude add "C:\code\*\tmp"                         # wildcards work
claude-idle exclude remove "D:\sandbox"
claude-idle exclude list
claude-idle set remind_every_minutes 15
claude-idle config                     # print current settings
claude-idle test                       # sample notification
claude-idle log                        # last 40 log lines
claude-idle start | stop | restart
claude-idle uninstall [-Purge]
```

Config changes (including exclusions) apply on the next watcher tick; no restart needed.

## Settings (`config.json`)

| Key | Default | Meaning |
|---|---|---|
| `remind_every_minutes` | 10 | Gap between reminders |
| `first_reminder_after_minutes` | 10 | How long a session must sit before the first reminder |
| `notify_when` | `["waiting","idle"]` | Drop `"idle"` to be reminded only when input is needed |
| `stop_after_hours` | 8 | Stop reminding about a session left this long (0 = never) |
| `detect_pending_tools` | true | Treat a tool call stuck without a result as waiting |
| `pending_tool_ignore` | `["Agent","Task","Workflow"]` | Long-running tools that are not waiting on you |
| `check_every_seconds` | 30 | Watcher poll interval |
| `sound` | true | Play the reminder sound |
| `exclude_folders` | `[]` | Folders never monitored (subfolders included, `*`/`?` wildcards, `%VARS%` and `~` expanded) |

## Notes

* Hooks are read when a Claude Code session starts, so sessions already open at install time are
  tracked once they are restarted.
* Notifications show as "Claude Code idle reminders"; they can be muted or set to banner-only in
  Windows Settings → System → Notifications. Focus / Do Not Disturb suppresses the pop-up.
* Each reminder replaces the previous one in Action Center, so they do not pile up.
