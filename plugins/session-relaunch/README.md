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

A session started in Code Mode (experimental, `CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1`) is relaunched
with it on, since it cannot be resumed without it. A relaunch cannot turn Code Mode on or off: a
conversation keeps the mode it was started in.

### Background sessions

A session running in the background (`claude --bg`, or sent there with `/background`) has no
terminal tab of its own, so `/relaunch` restarts it in place with `claude respawn <id>`. The view
you had open closes for a moment. If it was in a tmux pane, `claude attach <id>` is typed there
for you once the pane is back at its shell prompt, so the session returns where it was, note
included. Outside tmux, run `claude attach <id>` yourself; the reply names the id.

`/relaunch stay` is refused for a background session, since there is no tab to keep waiting. A
respawn keeps the flags and environment the session started with, so a model changed with
`/model` is not carried over.

One catch: if you started the session with a prompt (`claude "do X"`), that
prompt is part of the command line and gets sent again on relaunch.

## What it does on your machine

- **Commands it runs:** `/exit` after opening the new tab (and `/compact` with `compact`). Not for a
  background session, which is restarted with `claude respawn` instead.
- **Programs it starts:** `powershell.exe` with `hooks/relaunch.ps1` on Windows, `bash` with
  `hooks/relaunch.sh` elsewhere. Each opens a terminal tab (Windows Terminal, tmux, iTerm,
  Terminal.app, GNOME Terminal and others) running `claude --resume <session id>` with your
  original flags. Along the way they may call `wt.exe`, `tmux`, `osascript` (macOS asks
  permission once), `ps` or `python3` (macOS, to read the flags).
- **For a background session:** `claude respawn <id>`, then for up to 20 seconds it reads the
  last four lines of each tmux pane that sits at a shell prompt, looking for
  `Session <id> has exited`, and types `claude attach <id>` plus Enter into a pane that shows it.
  Nothing is typed into a pane that showed that line before the restart, or that is running
  something other than a shell.
- **Hooks:** the `/relaunch` command, and after Bash, PowerShell, Write and Edit tool calls a
  check for MCP config changes. It never changes a call or its result.
- **What it reads:** the session id, starting folder, model, your note, tool calls that change MCP
  config, and the parent `claude` process's command line (to reuse its flags; they are shown in
  `/relaunch`'s reply). No credentials.
- **What it stores:** the session id and note, locally, until the new session reads them.
- **What it sends:** nothing. No network calls.

## License

MIT
