# session-relaunch

`/relaunch` restarts the current Claude Code session in a new terminal tab, so
MCP servers you added since it started get loaded. It resumes this exact
session by id, so it works even with several sessions open.

Windows only for now (macOS and Linux are in progress). Needs Claude Code
2.1.287 or later.

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

- **Runs a command:** `/exit`, right after it opens the new tab, so the old
  session closes and the new one takes over. With `compact` it also compacts
  the session first, the same as `/compact <note>`.
- **Starts programs:** `powershell.exe` running the bundled
  `hooks/relaunch.ps1` with this session's id, folder, a wait time and (if you
  switched with `/model`) the model. That script reads the parent `claude`
  process's command line to reuse its flags, then opens a Windows Terminal tab
  (`wt.exe`, or a plain PowerShell window) that waits for the old session to
  exit and runs `claude --resume <id>` with those flags.
- **Reads:** the session id, working folder and model, your note, and the
  command line of tool calls that look like MCP config changes
  (`claude mcp add/remove`, edits to `.mcp.json`).
- **Stores:** the session id and note in the plugin's local store for up to 12
  hours, so the new session can show "Resumed via /relaunch" and fill in the
  note. It is deleted once read.
- **Sends:** nothing. There are no network calls; everything stays on your
  machine.

## License

MIT
