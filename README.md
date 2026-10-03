# session-relaunch

`/relaunch` restarts the current Claude Code session so MCP servers added since
it started are loaded, without copying a `claude --resume <id>` command by hand.

```
/relaunch            reopen this session in a new tab and exit this one
/relaunch compact    compact first, then relaunch
/relaunch stay       open the new tab but leave this session running
```

How it works:

1. `register.ts` reads the session id and cwd from `$.session`, so the right
   session comes back even with several open (unlike `--continue`).
2. `hooks/relaunch.ps1` walks up to the parent `claude.exe`, reuses its
   command line minus `-r/--resume`, `-c/--continue`, `--session-id`,
   `--fork-session`, `--from-pr` and `-p/--print`, and opens a new Windows
   Terminal tab (`wt -w 0 new-tab`), or a plain console window outside WT.
3. The new tab waits for the old PID to exit (up to 2 minutes) before running
   `claude --resume <id> <kept flags>`, so two processes never write the same
   transcript.
4. The mod then runs `/exit` through `$.command.run`. If that is refused, it
   says so and you type `/exit` yourself.

`relaunch.ps1 -SessionId <id> -Cwd <dir> -DryRun` prints what it would launch
without opening anything.

Limits: a positional prompt in the original command line (`claude "do X"`) is
carried over and would be sent again. Mods in `~/.claude/skills/` do not
hot-reload, so edits take effect in the next session.
