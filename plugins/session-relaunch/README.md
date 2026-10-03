# session-relaunch

`/relaunch` restarts the current Claude Code session in a new terminal tab, so
MCP servers you added since it started get loaded. It resumes this exact
session by id, so it works even with several sessions open.

Works on Windows, macOS and Linux. Needs Claude Code 2.1.287 or later.

## Install

```
/plugin marketplace add lperezmo/session-relaunch
/plugin install session-relaunch@session-relaunch
```

## Usage

```
/relaunch                 asks: relaunch now, compact first, or open the tab and stay
/relaunch now [note]      reopen this session in a new tab and exit this one
/relaunch compact [note]  compact first (the note steers the summary), then relaunch
/relaunch stay [note]     open the new tab; it starts once you /exit here
/relaunch help            show this
```

The note is typed into the new session's prompt box. When a tool call adds or
removes an MCP server, the mod prints a one-line reminder to `/relaunch`.

One catch: if you started the session with a prompt (`claude "do X"`), that
prompt is part of the command line and gets sent again on relaunch.

## What it does on your machine

- **Commands it runs:** `/exit` after opening the new tab (and `/compact` with `compact`).
- **Programs it starts:** `powershell.exe` with `hooks/relaunch.ps1` on Windows, `bash` with
  `hooks/relaunch.sh` elsewhere. Each opens a terminal tab (Windows Terminal, tmux, iTerm,
  Terminal.app, GNOME Terminal and others) running `claude --resume <session id>` with your
  original flags. Along the way they may call `wt.exe`, `tmux`, `osascript` (macOS asks
  permission once), `ps` or `python3` (macOS, to read the flags).
- **Hooks:** the `/relaunch` command, and after Bash, PowerShell, Write and Edit tool calls a
  check for MCP config changes. It never changes a call or its result.
- **What it reads:** the session id, starting folder, model, your note, tool calls that change MCP
  config, and the parent `claude` process's command line (to reuse its flags; they are shown in
  `/relaunch`'s reply). No credentials.
- **What it stores:** the session id and note, locally, until the new session reads them.
- **What it sends:** nothing. No network calls.

## License

MIT
