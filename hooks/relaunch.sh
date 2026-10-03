#!/usr/bin/env bash
# Opens a new terminal tab that resumes a Claude Code session once the
# current claude process has exited. The macOS/Linux counterpart of
# relaunch.ps1.
#
# Run by the session-relaunch mod through $.process.run, so this process is a
# descendant of the claude being replaced (the native claude binary, or
# node/bun running the npm CLI script). It finds that ancestor by walking
# parent processes, reuses its command line minus the session-picking flags,
# and hands the new tab a script that waits on the old PID before running
# `claude --resume <id>`, so two processes never write the same transcript.
#
# Usage: relaunch.sh --session-id ID --cwd DIR --wait-seconds N [--model M] [--dry-run]
#
# Prints one JSON line and exits 0: { ok, pid, terminal, exe, args, title }
# (plus dir, script and would_use with --dry-run, and lossy_args when argv had
# to be split from ps output) or { ok: false, error }.
#
# Env read: RELAUNCH_CLAUDE_PID, RELAUNCH_TERMINAL, TERM_PROGRAM, and only whether TMUX, WEZTERM_PANE, KITTY_WINDOW_ID, DISPLAY, WAYLAND_DISPLAY, GNOME_TERMINAL_SCREEN, GNOME_TERMINAL_SERVICE, KONSOLE_VERSION, GHOSTTY_RESOURCES_DIR, ALACRITTY_WINDOW_ID are set (PATH only via `command -v`, SHELL only in the new tab); nothing else.
#
# Written for bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.

# Prints S as a JSON string literal into J.
json_str() {
    local s=$1 bs=\\ q='"' i=1 oct c rep
    s=${s//"$bs"/"$bs$bs"}
    s=${s//"$q"/"$bs$q"}
    s=${s//$'\n'/"${bs}n"}
    s=${s//$'\r'/"${bs}r"}
    s=${s//$'\t'/"${bs}t"}

    while [ "$i" -lt 32 ]; do
        case $i in
            9 | 10 | 13) ;;
            *)
                printf -v oct '%03o' "$i"
                printf -v c '%b' "\\0$oct"
                case $s in
                    *"$c"*)
                        printf -v rep '\\u%04x' "$i"
                        s=${s//"$c"/"$rep"}
                        ;;
                esac
                ;;
        esac
        i=$((i + 1))
    done

    J="\"$s\""
}

# Prints the failure JSON line and exits.
fail() {
    json_str "$1"
    printf '{"ok":false,"error":%s}\n' "$J"
    exit 0
}

# Sets Q to S single-quoted for a shell script.
sq() {
    local s=$1 q="'" r="'\\''"
    s=${s//"$q"/"$r"}
    Q="'$s'"
}

# Like sq, but leaves words that need no quoting bare, for display.
sq_display() {
    local bare='^[-[:alnum:]_@%+=:,/.]+$'

    if [[ $1 =~ $bare ]]; then
        Q=$1
    else
        sq "$1"
    fi
}

SESSION_ID=''
CWD_ARG=''
WAIT_SECONDS=120
MODEL=''
DRY_RUN=0

while [ $# -gt 0 ]; do
    case $1 in
        --session-id | --cwd | --wait-seconds | --model)
            [ $# -ge 2 ] || fail "missing value for $1"
            case $1 in
                --session-id) SESSION_ID=$2 ;;
                --cwd) CWD_ARG=$2 ;;
                --wait-seconds) WAIT_SECONDS=$2 ;;
                --model) MODEL=$2 ;;
            esac
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        *) fail "unknown argument: $1" ;;
    esac
done

[ -n "$SESSION_ID" ] || fail 'missing --session-id'
[ -n "$CWD_ARG" ] || fail 'missing --cwd'

case $WAIT_SECONDS in
    '' | *[!0-9]*) fail "--wait-seconds is not a whole number: $WAIT_SECONDS" ;;
esac

# Strips leading zeros so arithmetic never reads the value as octal.
WAIT_SECONDS=$((10#$WAIT_SECONDS))

# Linux has /proc; macOS (and anything without it) asks ps.
USE_PROC=0
[ -r "/proc/$$/status" ] && USE_PROC=1

# The CLI script a node/bun claude runs; the CLI's own flags follow it.
CLI_SCRIPT_RE='(claude-code/.*\.[cm]?js|/claude(\.[cm]?js)?)$'

# Reads a process's exact argv on macOS through sysctl KERN_PROCARGS2:
# int argc, the exec path, NUL padding, then argc NUL-terminated strings.
PROCARGS_PY='
import ctypes, struct, sys
libc = ctypes.CDLL(None)
def sysctl(mib, size):
    arr = (ctypes.c_int * len(mib))(*mib)
    buf = ctypes.create_string_buffer(size)
    n = ctypes.c_size_t(size)
    if libc.sysctl(arr, len(mib), buf, ctypes.byref(n), None, 0) != 0:
        sys.exit(1)
    return buf.raw[:n.value]
argmax = struct.unpack("i", sysctl([1, 8], 4))[0]
data = sysctl([1, 49, int(sys.argv[1])], argmax)
argc = struct.unpack("i", data[:4])[0]
rest = data[4:]
i = rest.index(b"\0")
while i < len(rest) and rest[i:i + 1] == b"\0":
    i += 1
args = rest[i:].split(b"\0")[:argc]
if len(args) != argc:
    sys.exit(1)
sys.stdout.buffer.write(b"".join(a + b"\0" for a in args))
'

# Sets MAC_PY to a python3 that will not pop the Command Line Tools install
# dialog (/usr/bin/python3 is a stub until they are installed), or to nothing.
# Looked up once.
MAC_PY_CHECKED=0
find_mac_python() {
    [ "$MAC_PY_CHECKED" = 1 ] && return
    MAC_PY_CHECKED=1
    MAC_PY=$(command -v python3 2>/dev/null)

    case $MAC_PY in
        /*) ;;
        *) MAC_PY='' ;;
    esac

    if [ "$MAC_PY" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then
        MAC_PY=''
    fi
}

# Sets PARENT to the parent PID of PID, or to nothing.
parent_of() {
    PARENT=''

    if [ "$USE_PROC" = 1 ]; then
        local key value
        [ -r "/proc/$1/status" ] || return

        while read -r key value; do
            if [ "$key" = 'PPid:' ]; then
                PARENT=$value
                break
            fi
        done <"/proc/$1/status"
    else
        PARENT=$(ps -o ppid= -p "$1" 2>/dev/null)
        PARENT=${PARENT//[!0-9]/}
    fi
}

# Fills ARGV with the argv of PID. LOSSY=1 when it had to come from ps output
# split on whitespace (macOS without a usable python3).
read_argv() {
    ARGV=()
    LOSSY=0
    local a='' last line

    if [ "$USE_PROC" = 1 ]; then
        [ -r "/proc/$1/cmdline" ] || return 1

        while IFS= read -r -d '' a || [ -n "$a" ]; do
            ARGV+=("$a")
            a=''
        done <"/proc/$1/cmdline"

        # A process that rewrote its title leaves NUL padding behind.
        while [ ${#ARGV[@]} -gt 0 ]; do
            last=$((${#ARGV[@]} - 1))
            [ -z "${ARGV[$last]}" ] || break
            unset "ARGV[$last]"
        done
    else
        find_mac_python

        if [ -n "$MAC_PY" ]; then
            while IFS= read -r -d '' a; do
                ARGV+=("$a")
            done < <("$MAC_PY" -c "$PROCARGS_PY" "$1" 2>/dev/null)
        fi

        if [ ${#ARGV[@]} -eq 0 ]; then
            line=$(ps -ww -o args= -p "$1" 2>/dev/null) || return 1
            IFS=$' \t' read -r -a ARGV <<<"$line"
            LOSSY=1
        fi
    fi

    [ ${#ARGV[@]} -gt 0 ]
}

# Whether ARGV is claude: the native binary, or node/bun running the CLI
# script. Sets SCRIPT_INDEX to the argv position the CLI's flags follow.
is_claude() {
    local base=${ARGV[0]##*/} j=1
    SCRIPT_INDEX=0

    [ "$base" = claude ] && return 0

    case $base in
        node | nodejs | bun) ;;
        *) return 1 ;;
    esac

    while [ "$j" -lt ${#ARGV[@]} ]; do
        if [[ ${ARGV[$j]} =~ $CLI_SCRIPT_RE ]]; then
            SCRIPT_INDEX=$j
            return 0
        fi
        j=$((j + 1))
    done

    return 1
}

# The nearest claude ancestor, up to 8 levels up: sets CPID, ARGV,
# SCRIPT_INDEX and LOSSY. RELAUNCH_CLAUDE_PID skips the search (tests).
find_claude() {
    if [ -n "${RELAUNCH_CLAUDE_PID:-}" ]; then
        CPID=$RELAUNCH_CLAUDE_PID

        case $CPID in
            *[!0-9]*) fail "RELAUNCH_CLAUDE_PID is not a PID: $CPID" ;;
        esac

        read_argv "$CPID" || return 1
        is_claude
        return 0
    fi

    local pid=$$ depth=0

    while [ "$depth" -lt 8 ]; do
        parent_of "$pid"
        pid=$PARENT

        case $pid in
            '' | 0 | *[!0-9]*) return 1 ;;
        esac

        if read_argv "$pid" && is_claude; then
            CPID=$pid
            return 0
        fi

        depth=$((depth + 1))
    done

    return 1
}

# Fills KEPT with the claude flags after SCRIPT_INDEX, minus the ones that
# pick a session (and --model when MODEL replaces it).
keep_args() {
    KEPT=()
    local i=$((SCRIPT_INDEX + 1)) n=${#ARGV[@]} token name

    while [ "$i" -lt "$n" ]; do
        token=${ARGV[$i]}
        name=${token%%=*}

        case $name in
            -c | --continue | --fork-session | -p | --print)
                i=$((i + 1))
                continue
                ;;
            -r | --resume | --session-id | --from-pr)
                if [[ $token != *=* ]] && [ $((i + 1)) -lt "$n" ] && [[ ${ARGV[i + 1]} != -* ]]; then
                    i=$((i + 1))
                fi
                i=$((i + 1))
                continue
                ;;
        esac

        if [ -n "$MODEL" ] && [ "$name" = --model ]; then
            if [[ $token != *=* ]] && [ $((i + 1)) -lt "$n" ]; then
                i=$((i + 1))
            fi
            i=$((i + 1))
            continue
        fi

        KEPT+=("$token")
        i=$((i + 1))
    done

    if [ -n "$MODEL" ]; then
        KEPT+=(--model "$MODEL")
    fi
}

# Sets EXE to the command the new tab runs: claude from PATH when it is there
# (a symlink such as ~/.local/bin/claude survives auto-updates), else the
# process's own executable, with node/bun getting the CLI script ahead of ARGS.
resolve_exe() {
    local found argv0=${ARGV[0]} script cwd
    EXE=''
    found=$(command -v claude 2>/dev/null)

    case $found in
        /*)
            EXE=$found
            return
            ;;
    esac

    case $argv0 in
        /*) EXE=$argv0 ;;
    esac

    if [ -z "$EXE" ] && [ "$USE_PROC" = 1 ] && command -v readlink >/dev/null 2>&1; then
        EXE=$(readlink "/proc/$CPID/exe" 2>/dev/null)
    fi

    if [ -z "$EXE" ]; then
        found=$(command -v -- "$argv0" 2>/dev/null)
        case $found in
            /*) EXE=$found ;;
            *) EXE=$argv0 ;;
        esac
    fi

    if [ "$SCRIPT_INDEX" -gt 0 ]; then
        script=${ARGV[$SCRIPT_INDEX]}

        # A relative script path is relative to where claude was started.
        if [[ $script != /* ]] && [ "$USE_PROC" = 1 ]; then
            cwd=$(cd "/proc/$CPID/cwd" 2>/dev/null && pwd -P)
            [ -n "$cwd" ] && script=$cwd/$script
        fi

        ARGS=("$script" "${ARGS[@]}")
    fi
}

# Sets SCRIPT to what the new tab runs: wait for the old PID, then start the
# command, then leave an interactive shell so the tab stays open.
build_tab_script() {
    local nl=$'\n' a cmd manual launch alive title dir

    sq "$EXE"
    cmd=$Q
    sq_display "$EXE"
    manual="  $Q"

    for a in "${ARGS[@]}"; do
        sq "$a"
        cmd+=" $Q"
        sq_display "$a"
        manual+=" $Q"
    done

    MANUAL=${manual#  }
    sq "$manual"
    manual=$Q
    sq "$EXE"
    local exe_q=$Q
    sq "Could not find $EXE. Run it yourself:"
    local missing=$Q
    sq "$TITLE"
    title=$Q
    sq "$DIR"
    dir=$Q
    alive="kill -0 $CPID 2>/dev/null"

    launch="if command -v -- $exe_q >/dev/null 2>&1; then${nl}"
    launch+="    $cmd${nl}"
    launch+="else${nl}"
    launch+="    printf '%s\\n' $missing${nl}"
    launch+="    printf '%s\\n' $manual${nl}"
    launch+="fi${nl}"

    SCRIPT="#!/usr/bin/env bash${nl}"
    SCRIPT+="rm -f \"\$0\"${nl}"
    SCRIPT+="printf '\\033]0;%s\\007' $title${nl}"
    SCRIPT+="unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_PID CLAUDE_EFFORT CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_EXECPATH${nl}"
    SCRIPT+="cd -- $dir${nl}"

    if [ "$WAIT_SECONDS" -le 0 ]; then
        SCRIPT+="printf '%s\\n' 'Waiting for the old session (PID $CPID) to exit (no time limit)...'${nl}"
        SCRIPT+="while $alive; do sleep 0.3; done${nl}"
        SCRIPT+=$launch
    else
        SCRIPT+="deadline=\$((SECONDS + $WAIT_SECONDS))${nl}"
        SCRIPT+="printf '%s\\n' 'Waiting up to $WAIT_SECONDS seconds for the old session (PID $CPID) to exit...'${nl}"
        SCRIPT+="while $alive && [ \"\$SECONDS\" -lt \"\$deadline\" ]; do sleep 0.3; done${nl}"
        SCRIPT+="if $alive; then${nl}"
        SCRIPT+="    printf '%s\\n' 'The old session is still running. Type /exit there, then run:'${nl}"
        SCRIPT+="    printf '%s\\n' $manual${nl}"
        SCRIPT+="else${nl}"
        SCRIPT+=$launch
        SCRIPT+="fi${nl}"
    fi

    SCRIPT+="exec \"\${SHELL:-/bin/bash}\" -i${nl}"
}

# Fills CANDIDATES with the terminal kinds worth trying, best first, judged
# only by which terminal variables are set. RELAUNCH_TERMINAL forces one.
pick_terminals() {
    CANDIDATES=()

    if [ -n "${RELAUNCH_TERMINAL:-}" ]; then
        case $RELAUNCH_TERMINAL in
            tmux | wezterm | kitty | iterm | terminal-app | gnome-terminal | konsole | ghostty | alacritty | x-terminal-emulator | xterm | none)
                CANDIDATES=("$RELAUNCH_TERMINAL")
                ;;
            *) fail "unknown RELAUNCH_TERMINAL: $RELAUNCH_TERMINAL" ;;
        esac
        return
    fi

    [ -n "${TMUX+x}" ] && CANDIDATES+=(tmux)
    [ -n "${WEZTERM_PANE+x}" ] && CANDIDATES+=(wezterm)
    [ -n "${KITTY_WINDOW_ID+x}" ] && CANDIDATES+=(kitty)

    case $OSTYPE in
        darwin*)
            [ "${TERM_PROGRAM:-}" = iTerm.app ] && CANDIDATES+=(iterm)
            CANDIDATES+=(terminal-app)
            ;;
        *)
            if [ -n "${DISPLAY+x}" ] || [ -n "${WAYLAND_DISPLAY+x}" ]; then
                if [ -n "${GNOME_TERMINAL_SCREEN+x}" ] || [ -n "${GNOME_TERMINAL_SERVICE+x}" ]; then
                    CANDIDATES+=(gnome-terminal)
                fi
                [ -n "${KONSOLE_VERSION+x}" ] && CANDIDATES+=(konsole)
                [ -n "${GHOSTTY_RESOURCES_DIR+x}" ] && CANDIDATES+=(ghostty)
                [ -n "${ALACRITTY_WINDOW_ID+x}" ] && CANDIDATES+=(alacritty)
                CANDIDATES+=(x-terminal-emulator gnome-terminal-window konsole-window xterm)
            fi
            ;;
    esac
}

# The program a terminal kind needs.
terminal_tool() {
    case $1 in
        iterm | terminal-app) TOOL=osascript ;;
        *-window) TOOL=${1%-window} ;;
        *) TOOL=$1 ;;
    esac
}

# Runs a command that returns quickly, with no tie to our output.
quiet() {
    "$@" </dev/null >/dev/null 2>&1
}

# Starts a command that keeps running (a terminal emulator) in the background,
# detached so $.process.run, which waits for EOF on our output, returns.
detach() {
    command -v "$1" >/dev/null 2>&1 || return 1

    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" </dev/null >/dev/null 2>&1 &
    else
        nohup "$@" </dev/null >/dev/null 2>&1 &
    fi
}

# Opens a tab or window of one terminal kind running FILE. Nonzero when that
# terminal is missing or refused.
open_with() {
    local kind=$1 file=$2
    sq "$file"
    local run="bash $Q"

    case $kind in
        none) return 1 ;;
        tmux) quiet tmux new-window -c "$DIR" -n "$TITLE" bash "$file" ;;
        wezterm) quiet wezterm cli spawn --cwd "$DIR" -- bash "$file" ;;
        kitty) quiet kitty @ launch --type=tab --cwd "$DIR" --tab-title "$TITLE" bash "$file" ;;
        iterm)
            quiet osascript -e 'on run argv' -e 'tell application "iTerm2"' -e 'tell current window' \
                -e 'create tab with default profile command (item 1 of argv)' \
                -e 'end tell' -e 'end tell' -e 'end run' "$run"
            ;;
        terminal-app)
            quiet osascript -e 'on run argv' -e 'tell application "Terminal"' -e 'do script (item 1 of argv)' \
                -e 'activate' -e 'end tell' -e 'end run' "$run"
            ;;
        gnome-terminal) quiet gnome-terminal --tab --title="$TITLE" --working-directory="$DIR" -- bash "$file" ;;
        gnome-terminal-window) quiet gnome-terminal --title="$TITLE" --working-directory="$DIR" -- bash "$file" ;;
        konsole) detach konsole --new-tab --workdir "$DIR" -e bash "$file" ;;
        konsole-window) detach konsole --workdir "$DIR" -e bash "$file" ;;
        ghostty) detach ghostty --working-directory="$DIR" -e bash "$file" ;;
        alacritty) detach alacritty --working-directory "$DIR" -e bash "$file" ;;
        x-terminal-emulator) detach x-terminal-emulator -e bash "$file" ;;
        xterm) detach xterm -T "$TITLE" -e bash "$file" ;;
        *) return 1 ;;
    esac
}

# Prints the success JSON line.
emit_ok() {
    local out a sep=''
    out="{\"ok\":true,\"pid\":$CPID"
    json_str "$TERMINAL"
    out+=",\"terminal\":$J"
    json_str "$EXE"
    out+=",\"exe\":$J,\"args\":["

    for a in "${ARGS[@]}"; do
        json_str "$a"
        out+="$sep$J"
        sep=','
    done

    json_str "$TITLE"
    out+="],\"title\":$J"

    if [ "$DRY_RUN" = 1 ]; then
        json_str "$DIR"
        out+=",\"dir\":$J"
        json_str "$SCRIPT"
        out+=",\"script\":$J"
        json_str "$WOULD_USE"
        out+=",\"would_use\":$J"
    fi

    [ "$LOSSY" = 1 ] && out+=',"lossy_args":true'
    printf '%s}\n' "$out"
}

find_claude || fail 'could not find the parent claude process'
keep_args
ARGS=(--resume "$SESSION_ID" "${KEPT[@]}")
resolve_exe

DIR=$CWD_ARG
while [ "$DIR" != / ] && [ "${DIR%/}" != "$DIR" ]; do
    DIR=${DIR%/}
done

LEAF=${DIR##*/}
[ -n "$LEAF" ] || LEAF=$CWD_ARG
TITLE="$LEAF ${SESSION_ID:0:8}"

build_tab_script
pick_terminals
NO_TAB="no terminal to open a tab in (no tmux, no display); run it yourself: cd $(sq "$DIR"; printf '%s' "$Q") && $MANUAL"

if [ "$DRY_RUN" = 1 ]; then
    [ "${CANDIDATES[0]}" = none ] && fail "$NO_TAB"
    TERMINAL='dry-run'
    WOULD_USE='none'

    if [ -n "${RELAUNCH_TERMINAL:-}" ]; then
        WOULD_USE=$RELAUNCH_TERMINAL
    else
        for kind in "${CANDIDATES[@]}"; do
            terminal_tool "$kind"
            if command -v "$TOOL" >/dev/null 2>&1; then
                WOULD_USE=${kind%-window}
                break
            fi
        done
    fi

    emit_ok
    exit 0
fi

FILE=$(mktemp 2>/dev/null) || fail 'could not create the tab script file'
printf '%s' "$SCRIPT" >"$FILE" || {
    rm -f "$FILE"
    fail 'could not write the tab script file'
}

TERMINAL=''
for kind in "${CANDIDATES[@]}"; do
    if open_with "$kind" "$FILE"; then
        TERMINAL=${kind%-window}
        break
    fi
done

if [ -z "$TERMINAL" ]; then
    rm -f "$FILE"
    fail "$NO_TAB"
fi

emit_ok
exit 0
