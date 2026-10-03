# session-relaunch

`/relaunch` restarts the current Claude Code session so MCP servers added since
it started are loaded, without copying a `claude --resume <id>` command by hand.

Windows only for now (PowerShell 5.1, Windows Terminal preferred); macOS and
Linux support is planned. Needs Claude Code 2.1.287 or later, where mods are on
by default.

## Install

```
/plugin marketplace add lperezmo/session-relaunch
/plugin install session-relaunch@session-relaunch
```

Or try it from a clone with `claude --plugin-dir ./session-relaunch`.

## Usage

```
/relaunch                 ask: relaunch now, compact first, or open the tab and stay
/relaunch now [note]      reopen this session in a new tab and exit this one
/relaunch compact [note]  compact first, then relaunch
/relaunch stay [note]     open the new tab; it starts once you /exit here
/relaunch <note>          text without a keyword is a note; it still asks first
/relaunch help            show this
```

Only the first word can be a keyword, so a typo like `/relaunch stya` becomes a
note and opens the dialog instead of relaunching on the spot. The note is typed
into the new session's prompt box, and the new session shows a
"Resumed via /relaunch" toast. With `compact`, the note is also handed to the
compaction as its instructions, the same as `/compact <note>`, so the summary
keeps what it names.

When a tool call changes the MCP configuration (`claude mcp add`, `remove`,
`add-json`, or an edit to a `.mcp.json`), the mod prints one line suggesting
`/relaunch`. The line is for you only; the model never sees it.

How it works:

1. `register.ts` reads the session id and cwd from `$.session`, so the right
   session comes back even with several open (unlike `--continue`).
2. `hooks/relaunch.ps1` walks up to the parent claude process (`claude.exe`,
   or node/bun running the npm CLI), reuses its command line minus
   `-r/--resume`, `-c/--continue`, `--session-id`, `--fork-session`,
   `--from-pr` and `-p/--print`, and opens a new Windows Terminal tab
   (`wt -w 0 new-tab`) titled with the folder and a short session id, or a
   plain console window outside WT. The new tab runs `claude` from PATH, so an
   auto-update in between is picked up.
3. If you switched models with `/model` mid-session, the new tab gets
   `--model <current model>`.
4. The new tab waits for the old process to exit (up to 2 minutes; no limit
   with `stay`) before running `claude --resume <id> <kept flags>`, so two
   processes never write the same transcript.
5. The mod then runs `/exit` just after replying. If that is refused, it says
   so and you type `/exit` yourself.

`relaunch.ps1 -SessionId <id> -Cwd <dir> -DryRun` prints what it would launch
without opening anything.

Limits: a positional prompt in the original command line (`claude "do X"`) is
carried over and would be sent again. The helper runs with
`-ExecutionPolicy Bypass` and reads the parent process's command line to reuse
its flags. The TypeScript module loads as-is; there is no build step.

## License

MIT
