#!/usr/bin/env zsh
#
# Shared configuration and helpers for claude-autoresume.
#
# Config is a sourceable shell file rather than JSON on purpose: the sensor runs
# on every status-line render, and forking jq just to read three settings would
# be the most expensive thing it does.

: ${AUTORESUME_DIR:=${CLAUDE_AUTORESUME_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/autoresume}}
CONFIG_FILE="${CLAUDE_AUTORESUME_CONFIG:-$AUTORESUME_DIR/config.sh}"
[[ -r $CONFIG_FILE ]] && source "$CONFIG_FILE"

# The wrapped status line lives in its own machine-managed file, not in the
# user-editable config. It is arbitrary shell and may span lines, and rewriting
# one assignment inside a shared file line-by-line corrupted it: only the first
# physical line was replaced, orphaning the rest, and common.sh then executed the
# fragments on every render. Regenerating a single-value file avoids the problem.
WRAPPED_FILE="${CLAUDE_AUTORESUME_WRAPPED_FILE:-$AUTORESUME_DIR/wrapped.sh}"
[[ -r $WRAPPED_FILE ]] && source "$WRAPPED_FILE"

# Defaults, applied only where the config file left a gap.
: ${AUTORESUME_ARM_PCT:=100}          # window % that counts as spent
: ${AUTORESUME_PROMPT:=continue}      # what to send on resume
: ${AUTORESUME_RESUME:=all}           # all | latest
: ${AUTORESUME_TERMINAL:=auto}        # auto | iterm | terminal | tmux | headless
: ${AUTORESUME_LIVE_PANE:=type}       # type | prefill | notify
: ${AUTORESUME_CLAUDE_BIN:=claude}
: ${AUTORESUME_GRACE:=60}             # seconds past reset before acting
: ${AUTORESUME_FRESH:=90}             # state file younger than this => still open
: ${AUTORESUME_WRAPPED:=}             # status line command we took over from

STATE_DIR="$AUTORESUME_DIR"
MANUAL_DIR="$AUTORESUME_DIR/manual"
FIRED_DIR="$AUTORESUME_DIR/fired"
LOG_FILE="$AUTORESUME_DIR/watch.log"

# Acting on a session must be recorded, or it repeats forever. The state file
# cannot carry that record: the sensor rewrites it every 15s, and an idle session
# makes no API call, so `rate_limits` stays stale and it re-arms with the same
# past resets_at on the very next tick.
#
# The mark is keyed to the reset it was acted on, so a genuinely new window --
# which necessarily carries a different resets_at -- fires again as it should.
ar_fired_mark() { print -r -- "$FIRED_DIR/${1}.last" }

ar_already_fired() {
    local mark; mark=$(ar_fired_mark "$1")
    [[ -f $mark ]] || return 1
    [[ $(<"$mark") == "$2" ]]
}

# Returns non-zero if the mark could not be written. That matters: the caller
# must refuse to resume rather than proceed, because an unrecorded resume is
# repeated on every tick forever. `mkdir -p` succeeds on a directory that exists
# but is unwritable, so its status alone is not enough.
ar_mark_fired() {
    local mark; mark=$(ar_fired_mark "$1")
    mkdir -p "$FIRED_DIR" 2>/dev/null || return 1
    print -r -- "$2" > "$mark" 2>/dev/null || return 1
    [[ -s $mark ]]
}

ar_log() { print -r -- "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$LOG_FILE" 2>/dev/null }

ar_now() { zmodload zsh/datetime 2>/dev/null && print -r -- $EPOCHSECONDS || date +%s }

# JSON emitters. Small enough to hand-roll, and the sensor cannot afford jq.
ar_jnum() { [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$1" || printf 'null' }
# Control characters are legal in a macOS path and illegal in a JSON string. Left
# unescaped they produce a state file jq rejects, and the watcher then skips that
# session forever without saying why.
ar_jstr() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

# The CLI rejects anything outside this set; an unknown value must fall back to
# the user's settings.json rather than abort the resume.
ar_valid_mode() {
    case $1 in
        acceptEdits|auto|bypassPermissions|manual|dontAsk|plan) return 0 ;;
        default) return 1 ;;   # real, but not a flag the CLI accepts -- fall back quietly
        *) return 1 ;;
    esac
}

# Replay the mode the session was actually in when it stopped. Transcript lines
# look like {"type":"permission-mode","permissionMode":"plan",...}.
ar_last_permission_mode() {
    local transcript=$1
    [[ -n $transcript && -r $transcript ]] || return 0
    grep -o '"permissionMode":"[a-zA-Z]*"' "$transcript" 2>/dev/null \
        | tail -1 | cut -d'"' -f4
}
