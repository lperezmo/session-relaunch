#!/usr/bin/env bash
# Tests hooks/relaunch.sh, the macOS/Linux launcher, without a real claude.
#
# A fake claude (.github/relaunch-sh/fake_claude.c, compiled here) is started with
# flags and runs relaunch.sh as its child, the way the mod does, so ancestor
# detection and flag handling run for real. When something opens a tab and
# runs `claude --resume ...`, the fake writes the argv it got, its cwd and
# whether the old session was still alive, and the tests check those.
#
# Cases that need something missing are SKIPped:
#   cc       the native fake claude (most cases)
#   node     the node + claude-code/cli.js detection cases
#   tmux     opening a real tmux window (a private server, nothing of yours)
#   DISPLAY  plus xterm / x-terminal-emulator for the X terminal cases
#
# Environment:
#   RELAUNCH_BASH  the bash that runs relaunch.sh and the tab script
#                  (default: bash). An absolute path is also put first on
#                  PATH as `bash`, so a tab that runs `bash FILE` gets it too.
#   RELAUNCH_SH    the script under test (default: hooks/relaunch.sh)
#   ONLY=name      run just that case
#   RELAUNCH_TEST_TERMINAL_APP=1  also drive Terminal.app (macOS; needs the
#                  Automation permission for osascript)
#   KEEP_TMP=1     keep the temp dir for a look afterwards
#
# Plain bash 3.2. Prints PASS/FAIL/SKIP per case; exits 1 on any FAIL.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SCRIPT="${RELAUNCH_SH:-$REPO/hooks/relaunch.sh}"
RELAUNCH_BASH="${RELAUNCH_BASH:-bash}"
SID="0123abcd-ef45-6789-abcd-ef0123456789"
SHORT="0123abcd"

unset TMUX TMUX_PANE RELAUNCH_TERMINAL RELAUNCH_CLAUDE_PID

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL setup: $SCRIPT not found"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL setup: python3 is needed to check the JSON"
    exit 1
fi

# Short and under /tmp: tmux sockets and macOS paths have length limits.
T=$(mktemp -d /tmp/rlt.XXXXXX)
T=$(cd "$T" && pwd -P)
TMUX_SERVERS=""

cleanup() {
    for s in $TMUX_SERVERS; do
        tmux -L "$s" kill-server >/dev/null 2>&1
    done
    if [ "${KEEP_TMP:-}" = "1" ]; then
        echo "temp dir kept: $T"
    else
        rm -rf "$T"
    fi
}
trap cleanup EXIT

mkdir -p "$T/bin"
ORIG_PATH="$PATH"
export PATH="$T/bin:$PATH"

case "$RELAUNCH_BASH" in
    /*) ln -s "$RELAUNCH_BASH" "$T/bin/bash" ;;
esac

# A $SHELL that exits at once, so a GUI tab closes after `exec $SHELL -i`.
printf '#!/bin/sh\nexit 0\n' > "$T/bin/exitshell"
chmod +x "$T/bin/exitshell"

HAVE_CC=0
if command -v cc >/dev/null 2>&1 && cc -O0 -o "$T/bin/claude" "$HERE/fake_claude.c" 2> "$T/cc.err"; then
    HAVE_CC=1
fi

NODE=$(command -v node 2>/dev/null || true)
if [ -n "$NODE" ]; then
    CLI_DIR="$T/node/lib/node_modules/@anthropic-ai/claude-code"
    mkdir -p "$CLI_DIR"
    cat > "$CLI_DIR/cli.js" <<'EOF'
// Node stand-in for the npm claude CLI; same two roles as fake_claude.c.
const fs = require('fs')
const path = require('path')
const cp = require('child_process')

const dir = process.env.FAKE_DIR
const args = process.argv.slice(2)
const at = (name) => path.join(dir, name)

if (args[0] === '--resume') {
  let alive = 'unknown'
  try {
    const old = parseInt(fs.readFileSync(at('launcher.pid'), 'utf8'), 10)
    try { process.kill(old, 0); alive = 'alive' } catch (e) { alive = e.code === 'EPERM' ? 'alive' : 'dead' }
  } catch (e) {}
  fs.writeFileSync(at('resumed.cwd'), process.cwd())
  fs.writeFileSync(at('resumed.alive'), alive)
  fs.writeFileSync(at('resumed.argv.tmp'), args.map((a) => a + '\0').join(''))
  fs.renameSync(at('resumed.argv.tmp'), at('resumed.argv'))
} else {
  fs.writeFileSync(at('launcher.pid'), process.pid + '\n')
  const argv = fs.readFileSync(at('relaunch.argv'), 'utf8').split('\0')
  argv.pop()
  const r = cp.spawnSync(argv[0], argv.slice(1), { stdio: 'inherit' })
  const linger = parseInt(process.env.FAKE_LINGER_MS || '0', 10)
  setTimeout(() => process.exit(r.status === null ? 1 : r.status), linger)
}
EOF
fi

cat > "$T/check.py" <<'EOF'
"""JSON and file checks for relaunch_sh_test.sh. Exit 0 = ok, else prints why."""
import json
import sys


def report(file):
    with open(file, encoding="utf-8", errors="replace") as f:
        text = f.read()
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) != 1:
        sys.exit("stdout should be one JSON line, got %d lines: %r" % (len(lines), text[:2000]))
    try:
        data = json.loads(lines[0])
    except ValueError as e:
        sys.exit("stdout is not JSON (%s): %r" % (e, lines[0][:2000]))
    if not isinstance(data, dict):
        sys.exit("stdout JSON is not an object: %r" % lines[0][:2000])
    return data


def main():
    cmd, file, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    if cmd == "nul":
        with open(file, "rb") as f:
            got = f.read().decode("utf-8", "replace").split("\0")[:-1]
        if got != rest:
            sys.exit("argv mismatch\n    want %r\n    got  %r" % (rest, got))
        return
    data = report(file)
    if cmd == "json":
        return
    if cmd == "get":
        value = data.get(rest[0])
        sys.stdout.write(value if isinstance(value, str) else json.dumps(value))
        return
    if cmd == "eq":
        key, want = rest[0], json.loads(rest[1])
        if data.get(key, "<missing>") != want:
            sys.exit("%s: want %r, got %r" % (key, want, data.get(key, "<missing>")))
        return
    if cmd == "nonempty":
        if not data.get(rest[0]):
            sys.exit("%s: want a non-empty value, got %r" % (rest[0], data.get(rest[0], "<missing>")))
        return
    if cmd == "absent":
        if rest[0] in data:
            sys.exit("%s: want it absent, got %r" % (rest[0], data[rest[0]]))
        return
    if cmd == "args":
        if data.get("args") != rest:
            sys.exit("args mismatch\n    want %r\n    got  %r" % (rest, data.get("args")))
        return
    if cmd == "contains":
        key, needle = rest
        if needle not in str(data.get(key, "")):
            sys.exit("%s does not contain %r: %r" % (key, needle, data.get(key, "<missing>")))
        return
    sys.exit("unknown check " + cmd)


main()
EOF

# --- case plumbing -----------------------------------------------------------

PASSED=0
FAILED=0
SKIPPED=0
FAILED_NAMES=""
CASE_OK=1
CASE_SKIP=""
CASE_LOG=""
D=""

fail() {
    CASE_OK=0
    CASE_LOG="$CASE_LOG    $*
"
}

skip() {
    CASE_SKIP="$*"
}

# check <check.py args...>: records a failure with check.py's reason.
check() {
    local why
    if ! why=$(python3 "$T/check.py" "$@" 2>&1); then
        fail "$why"
        return 1
    fi
    return 0
}

# Shows the case's stdout and stderr when it failed.
dump_io() {
    local f
    for f in out err; do
        if [ -s "$D/$f" ]; then
            CASE_LOG="$CASE_LOG    --- $f:
$(sed 's/^/    | /' "$D/$f" | head -40)
"
        fi
    done
}

run_case() {
    local name=$1
    CASE_OK=1
    CASE_SKIP=""
    CASE_LOG=""
    D="$T/$name"
    mkdir -p "$D"

    "case_$name"

    if [ -n "$CASE_SKIP" ]; then
        echo "SKIP $name ($CASE_SKIP)"
        SKIPPED=$((SKIPPED + 1))
    elif [ "$CASE_OK" = "1" ]; then
        echo "PASS $name"
        PASSED=$((PASSED + 1))
    else
        dump_io
        echo "FAIL $name"
        printf '%s' "$CASE_LOG"
        FAILED=$((FAILED + 1))
        FAILED_NAMES="$FAILED_NAMES $name"
    fi
}

need_cc() {
    if [ "$HAVE_CC" != "1" ]; then
        skip "no C compiler for the fake claude"
        return 1
    fi
    return 0
}

# set_relaunch <relaunch.sh args...>: what the fake claude runs as its child.
set_relaunch() {
    printf '%s\0' "$RELAUNCH_BASH" "$SCRIPT" "$@" > "$D/relaunch.argv"
}

# fake <claude flags...>: runs the fake claude in $D and waits for it.
fake() {
    FAKE_DIR="$D" "$T/bin/claude" "$@" > "$D/out" 2> "$D/err"
    RC=$?
}

# Waits up to $2 seconds for file $1.
wait_for() {
    local i=0
    local limit=$(($2 * 5))
    while [ ! -e "$1" ]; do
        if [ $i -ge $limit ]; then
            return 1
        fi
        sleep 0.2
        i=$((i + 1))
    done
    return 0
}

launcher_pid() {
    tr -d ' \n' < "$D/launcher.pid"
}

expect_ok_exit() {
    if [ "$RC" != "0" ]; then
        fail "exit code $RC, want 0"
    fi
}

# The checks every successful dry run shares; $1 is the --cwd given.
expect_dry_run() {
    local leaf
    expect_ok_exit
    check json "$D/out" || return
    check eq "$D/out" ok true
    check eq "$D/out" terminal '"dry-run"'
    check eq "$D/out" pid "$(launcher_pid)"
    check nonempty "$D/out" would_use
    check nonempty "$D/out" script
    check nonempty "$D/out" dir
    check contains "$D/out" script "kill -0 $(launcher_pid)"
    leaf=${1%/}
    leaf=${leaf##*/}
    check eq "$D/out" title "\"$leaf $SHORT\""
    case "$(python3 "$T/check.py" get "$D/out" exe)" in
        claude | */claude) ;;
        *) fail "exe: want claude (it is on PATH), got $(python3 "$T/check.py" get "$D/out" exe)" ;;
    esac
}

# Writes the dry run's tab script to $D/tab.sh.
save_tab_script() {
    python3 - "$D/out" "$D/tab.sh" <<'EOF'
import json, sys
data = json.loads([l for l in open(sys.argv[1]).read().splitlines() if l.strip()][0])
open(sys.argv[2], "w").write(data.get("script", ""))
EOF
}

# --- dry-run cases ------------------------------------------------------------

case_syntax() {
    if ! "$RELAUNCH_BASH" -n "$SCRIPT" 2> "$D/err"; then
        fail "$RELAUNCH_BASH -n hooks/relaunch.sh failed"
    fi
}

case_dry_run_basic() {
    need_cc || return
    mkdir -p "$D/proj"
    set_relaunch --session-id "$SID" --cwd "$D/proj" --wait-seconds 120 --dry-run
    fake --dangerously-skip-permissions --add-dir /opt/x --model sonnet
    expect_dry_run "$D/proj"
    check args "$D/out" --resume "$SID" --dangerously-skip-permissions --add-dir /opt/x --model sonnet
    check absent "$D/out" lossy_args
}

case_drops_session_flags() {
    need_cc || return
    set_relaunch --session-id "$SID" --cwd "$D" --wait-seconds 120 --dry-run
    fake --verbose -c --continue --fork-session -p --print -r abc --resume def \
        --session-id 11111111-2222 --from-pr 12 --resume=xyz --session-id=foo --debug
    expect_dry_run "$D"
    check args "$D/out" --resume "$SID" --verbose --debug
}

case_session_flag_value_is_a_flag() {
    need_cc || return
    set_relaunch --session-id "$SID" --cwd "$D" --wait-seconds 120 --dry-run
    fake -r --verbose --from-pr --debug --resume
    expect_dry_run "$D"
    check args "$D/out" --resume "$SID" --verbose --debug
}

case_model_replaced() {
    need_cc || return
    set_relaunch --session-id "$SID" --cwd "$D" --wait-seconds 120 --model 'claude-opus-4-1[1m]' --dry-run
    fake --model old --verbose --model=older
    expect_dry_run "$D"
    check args "$D/out" --resume "$SID" --verbose --model 'claude-opus-4-1[1m]'
}

case_model_kept_without_override() {
    need_cc || return
    set_relaunch --session-id "$SID" --cwd "$D" --wait-seconds 120 --dry-run
    fake --model=opus --verbose
    expect_dry_run "$D"
    check args "$D/out" --resume "$SID" --model=opus --verbose
}

SPECIAL='it'"'"'s a "test" $HOME `id` \back * ; & | ~'

case_special_chars_kept() {
    need_cc || return
    set_relaunch --session-id "$SID" --cwd "$D" --wait-seconds 120 --dry-run
    fake --append-system-prompt "$SPECIAL" --add-dir "/tmp/a b"
    expect_dry_run "$D"
    check args "$D/out" --resume "$SID" --append-system-prompt "$SPECIAL" --add-dir "/tmp/a b"
    check absent "$D/out" lossy_args
}

case_empty_arg_kept() {
    need_cc || return
    set_relaunch --session-id "$SID" --cwd "$D" --wait-seconds 120 --dry-run
    fake --append-system-prompt "" --verbose
    expect_dry_run "$D"
    check args "$D/out" --resume "$SID" --append-system-prompt "" --verbose
}

case_newline_in_arg_kept() {
    need_cc || return
    set_relaunch --session-id "$SID" --cwd "$D" --wait-seconds 120 --dry-run
    fake --append-system-prompt "line one
line two" --verbose
    expect_dry_run "$D"
    check args "$D/out" --resume "$SID" --append-system-prompt "line one
line two" --verbose
}

case_title_short_id_trailing_slash() {
    need_cc || return
    mkdir -p "$D/my proj"
    set_relaunch --session-id abc --cwd "$D/my proj/" --wait-seconds 120 --dry-run
    fake --verbose
    expect_ok_exit
    check eq "$D/out" ok true
    check eq "$D/out" title '"my proj abc"'
    check args "$D/out" --resume abc --verbose
}

# RELAUNCH_CLAUDE_PID names a process that is not an ancestor.
case_claude_pid_override() {
    local pid
    need_cc || return
    printf '%s\0' sleep 10 > "$D/relaunch.argv"
    FAKE_DIR="$D" "$T/bin/claude" --verbose --model haiku > /dev/null 2>&1 &
    pid=$!
    wait_for "$D/launcher.pid" 5
    RELAUNCH_CLAUDE_PID=$pid "$RELAUNCH_BASH" "$SCRIPT" --session-id "$SID" --cwd "$D" --wait-seconds 120 --dry-run > "$D/out" 2> "$D/err"
    RC=$?
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
    expect_ok_exit
    check eq "$D/out" ok true
    check eq "$D/out" pid "$pid"
    check args "$D/out" --resume "$SID" --verbose --model haiku
}

has_claude_ancestor() {
    local p=$$ i=0 args first
    while [ -n "$p" ] && [ "$p" -gt 1 ] && [ $i -lt 40 ]; do
        args=$(ps -o args= -p "$p" 2>/dev/null)
        first=${args%% *}
        case "${first##*/}" in
            claude) return 0 ;;
        esac
        case "$args" in
            *claude-code/*) return 0 ;;
        esac
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        i=$((i + 1))
    done
    return 1
}

case_no_claude_ancestor() {
    if has_claude_ancestor; then
        skip "this run itself is under a claude process"
        return
    fi
    "$RELAUNCH_BASH" "$SCRIPT" --session-id "$SID" --cwd "$D" --wait-seconds 120 --dry-run > "$D/out" 2> "$D/err"
    RC=$?
    expect_ok_exit
    check eq "$D/out" ok false
    check nonempty "$D/out" error
}

case_missing_session_id() {
    need_cc || return
    set_relaunch --cwd "$D" --wait-seconds 120 --dry-run
    fake --verbose
    expect_ok_exit
    check eq "$D/out" ok false
    check nonempty "$D/out" error
}

case_node_cli_detected() {
    if [ -z "$NODE" ]; then
        skip "no node"
        return
    fi
    if [ "$HAVE_CC" != "1" ]; then
        skip "needs the native fake claude on PATH"
        return
    fi
    set_relaunch --session-id "$SID" --cwd "$D" --wait-seconds 120 --dry-run
    FAKE_DIR="$D" "$NODE" "$CLI_DIR/cli.js" --verbose --resume old > "$D/out" 2> "$D/err"
    RC=$?
    expect_dry_run "$D"
    check args "$D/out" --resume "$SID" --verbose
}

# Without `claude` on PATH the new tab has to run node with the CLI script.
case_node_cli_without_claude_on_path() {
    local exe
    if [ -z "$NODE" ]; then
        skip "no node"
        return
    fi
    set_relaunch --session-id "$SID" --cwd "$D" --wait-seconds 120 --dry-run
    mkdir -p "$D/bin"
    ln -s "$NODE" "$D/bin/node"
    case "$RELAUNCH_BASH" in
        /*) ln -s "$RELAUNCH_BASH" "$D/bin/bash" ;;
    esac
    PATH="$D/bin:$(path_without_claude)" FAKE_DIR="$D" "$NODE" "$CLI_DIR/cli.js" --verbose > "$D/out" 2> "$D/err"
    RC=$?
    expect_ok_exit
    check eq "$D/out" ok true || return
    exe=$(python3 "$T/check.py" get "$D/out" exe)
    case "$exe" in
        *node) check args "$D/out" "$CLI_DIR/cli.js" --resume "$SID" --verbose ;;
        *) fail "exe: want the node binary, got $exe" ;;
    esac
}

# PATH minus $T/bin and any directory that holds a claude.
path_without_claude() {
    local out="" dir
    local IFS=:
    for dir in $ORIG_PATH; do
        if [ -z "$dir" ] || [ -e "$dir/claude" ]; then
            continue
        fi
        out="$out${out:+:}$dir"
    done
    printf '%s' "$out"
}

# Runs the dry run's tab script directly, no terminal: it should see the old
# session gone, resume with the same flags in the right place, then exec
# $SHELL (here one that exits).
case_tab_script_runs() {
    local work tab_pid
    need_cc || return
    work="$D/my proj"
    mkdir -p "$work"
    set_relaunch --session-id "$SID" --cwd "$work" --wait-seconds 30 --dry-run
    fake --verbose --append-system-prompt "$SPECIAL" --add-dir "/tmp/a b"
    check eq "$D/out" ok true || return
    save_tab_script
    if ! "$RELAUNCH_BASH" -n "$D/tab.sh" 2> "$D/err"; then
        fail "the tab script does not parse under $RELAUNCH_BASH"
        return
    fi
    (cd "$work" && SHELL="$T/bin/exitshell" FAKE_DIR="$D" exec "$RELAUNCH_BASH" "$D/tab.sh") > "$D/tab.out" 2>&1 < /dev/null &
    tab_pid=$!
    if ! wait_for "$D/resumed.argv" 20; then
        kill "$tab_pid" 2>/dev/null
        fail "the tab script never ran claude --resume; its output:"
        fail "$(head -20 "$D/tab.out")"
        return
    fi
    wait "$tab_pid" 2>/dev/null
    check nul "$D/resumed.argv" --resume "$SID" --verbose --append-system-prompt "$SPECIAL" --add-dir "/tmp/a b"
    if [ "$(cat "$D/resumed.alive")" != "dead" ]; then
        fail "resumed while the old session was $(cat "$D/resumed.alive")"
    fi
}

# --- real terminal cases ----------------------------------------------------------

# Starts a private tmux server whose windows see FAKE_DIR=$D, and sets
# TMUX_VALUE to what $TMUX holds inside it.
start_tmux() {
    local name="rlt$$$1"
    TMUX_NAME=$name
    TMUX_SERVERS="$TMUX_SERVERS $name"
    FAKE_DIR="$D" tmux -L "$name" -f /dev/null new-session -d -s main -x 120 -y 30 || return 1
    TMUX_VALUE="$(tmux -L "$name" display-message -p '#{socket_path}'),$(tmux -L "$name" display-message -p '#{pid}'),0"
}

# The full flow through terminal $1: the old claude runs relaunch.sh, stays a
# moment, exits; the new tab must then resume with the same flags. $2 is the
# fake claude to use (default $T/bin/claude); its directory goes first on PATH.
e2e_resume() {
    local kind=$1 claude=${2:-$T/bin/claude} work lpid i=0
    work="$D/my proj"
    mkdir -p "$work"
    set_relaunch --session-id "$SID" --cwd "$work" --wait-seconds 30

    if [ "$kind" = "tmux" ]; then
        start_tmux "$kind" || { fail "could not start tmux"; return; }
        TMUX="$TMUX_VALUE" FAKE_DIR="$D" FAKE_LINGER_MS=2000 "$claude" \
            --verbose --add-dir "/tmp/a b" --append-system-prompt "$SPECIAL" --resume old-id \
            > "$D/out" 2> "$D/err" &
    else
        PATH="${claude%/*}:$PATH" RELAUNCH_TERMINAL=$kind SHELL="$T/bin/exitshell" FAKE_DIR="$D" FAKE_LINGER_MS=2000 "$claude" \
            --verbose --add-dir "/tmp/a b" --append-system-prompt "$SPECIAL" --resume old-id \
            > "$D/out" 2> "$D/err" &
    fi
    lpid=$!

    # A terminal that blocks (an Automation prompt nobody answers) must not
    # hang the run.
    while kill -0 "$lpid" 2>/dev/null; do
        if [ $i -ge 300 ]; then
            pkill -P "$lpid" 2>/dev/null
            kill "$lpid" 2>/dev/null
            fail "relaunch.sh did not return within 60 seconds"
            return
        fi
        sleep 0.2
        i=$((i + 1))
    done
    wait "$lpid"
    RC=$?

    expect_ok_exit
    check json "$D/out" || return
    check eq "$D/out" ok true || return
    check eq "$D/out" terminal "\"$kind\""
    check eq "$D/out" pid "$lpid"
    check eq "$D/out" title "\"my proj $SHORT\""

    if ! wait_for "$D/resumed.argv" 30; then
        fail "no claude --resume ran within 30 seconds of the old one exiting"
        if [ "$kind" = "tmux" ]; then
            fail "tmux windows: $(tmux -L "$TMUX_NAME" list-windows -F '#{window_name}' 2>&1 | tr '\n' '|')"
            fail "last window: $(tmux -L "$TMUX_NAME" capture-pane -p -t main:1 2>&1 | grep -v '^$' | tail -5 | tr '\n' '|')"
        fi
        return
    fi

    check nul "$D/resumed.argv" --resume "$SID" --verbose --add-dir "/tmp/a b" --append-system-prompt "$SPECIAL"
    if [ "$(cat "$D/resumed.alive")" != "dead" ]; then
        fail "resumed while the old session was $(cat "$D/resumed.alive")"
    fi
    if [ "$(cat "$D/resumed.cwd")" != "$(cd "$work" && pwd -P)" ]; then
        fail "resumed in $(cat "$D/resumed.cwd"), want $work"
    fi
    if [ "$kind" = "tmux" ]; then
        if ! tmux -L "$TMUX_NAME" list-windows -F '#{window_name}' | grep -qx "my proj $SHORT"; then
            fail "no tmux window named 'my proj $SHORT': $(tmux -L "$TMUX_NAME" list-windows -F '#{window_name}' | tr '\n' '|')"
        fi
    fi
}

case_tmux_resume() {
    need_cc || return
    if ! command -v tmux >/dev/null 2>&1; then
        skip "no tmux"
        return
    fi
    e2e_resume tmux
}

# The old session outlives --wait-seconds: the tab must not resume over it.
case_tmux_gives_up_while_old_runs() {
    need_cc || return
    if ! command -v tmux >/dev/null 2>&1; then
        skip "no tmux"
        return
    fi
    start_tmux gu || { fail "could not start tmux"; return; }
    set_relaunch --session-id "$SID" --cwd "$D" --wait-seconds 1
    TMUX="$TMUX_VALUE" FAKE_DIR="$D" FAKE_LINGER_MS=4000 "$T/bin/claude" --verbose > "$D/out" 2> "$D/err"
    RC=$?
    expect_ok_exit
    check eq "$D/out" ok true || return
    check eq "$D/out" terminal '"tmux"'
    sleep 3
    if [ -e "$D/resumed.argv" ]; then
        fail "claude --resume ran although the old session outlived --wait-seconds 1 (old was $(cat "$D/resumed.alive"))"
    fi
}

e2e_x() {
    need_cc || return
    if [ -z "${DISPLAY:-}" ]; then
        skip "no DISPLAY"
        return
    fi
    if ! command -v "$1" >/dev/null 2>&1; then
        skip "no $1"
        return
    fi
    e2e_resume "$1"
}

case_xterm_resume() {
    e2e_x xterm
}

case_x_terminal_emulator_resume() {
    e2e_x x-terminal-emulator
}

# Opt-in (RELAUNCH_TEST_TERMINAL_APP=1): drives Terminal.app via osascript,
# which needs the Automation permission. The new window does not inherit our
# environment, so this fake claude has $D built in.
case_terminal_app_resume() {
    if [ "${RELAUNCH_TEST_TERMINAL_APP:-}" != "1" ] || [ "$(uname -s)" != "Darwin" ]; then
        skip "macOS with RELAUNCH_TEST_TERMINAL_APP=1 only"
        return
    fi
    need_cc || return
    mkdir -p "$D/bin"
    if ! cc -O0 -DFAKE_DIR_DEFAULT="\"$D\"" -o "$D/bin/claude" "$HERE/fake_claude.c" 2> "$D/err"; then
        fail "could not build the fake claude"
        return
    fi
    e2e_resume terminal-app "$D/bin/claude"
}

# macOS without python3: argv comes from ps, split on whitespace.
case_mac_ps_fallback() {
    if [ "$(uname -s)" != "Darwin" ]; then
        skip "macOS only"
        return
    fi
    need_cc || return
    set_relaunch --session-id "$SID" --cwd "$D" --wait-seconds 120 --dry-run
    PATH="$T/bin:/bin" FAKE_DIR="$D" "$T/bin/claude" --verbose --model haiku --resume old > "$D/out" 2> "$D/err"
    RC=$?
    expect_ok_exit
    check eq "$D/out" ok true
    check eq "$D/out" lossy_args true
    check args "$D/out" --resume "$SID" --verbose --model haiku
}

# --- run -------------------------------------------------------------------------

echo "relaunch.sh under $("$RELAUNCH_BASH" -c 'echo "bash $BASH_VERSION"') on $(uname -s)"
if [ "$HAVE_CC" != "1" ]; then
    echo "note: no fake claude, cc failed: $(head -3 "$T/cc.err" 2>/dev/null)"
fi

for name in \
    syntax \
    dry_run_basic \
    drops_session_flags \
    session_flag_value_is_a_flag \
    model_replaced \
    model_kept_without_override \
    special_chars_kept \
    empty_arg_kept \
    newline_in_arg_kept \
    title_short_id_trailing_slash \
    claude_pid_override \
    no_claude_ancestor \
    missing_session_id \
    node_cli_detected \
    node_cli_without_claude_on_path \
    tab_script_runs \
    mac_ps_fallback \
    tmux_resume \
    tmux_gives_up_while_old_runs \
    xterm_resume \
    x_terminal_emulator_resume \
    terminal_app_resume; do
    if [ -n "${ONLY:-}" ] && [ "$ONLY" != "$name" ]; then
        continue
    fi
    run_case "$name"
done

echo "passed $PASSED, failed $FAILED, skipped $SKIPPED"
if [ "$FAILED" -gt 0 ]; then
    echo "failed:$FAILED_NAMES"
    exit 1
fi
exit 0
