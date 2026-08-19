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

# Defaults, applied only where the config file left a gap.
: ${AUTORESUME_ARM_PCT:=100}          # window % that counts as spent
: ${AUTORESUME_PROMPT:=continue}      # what to send on resume
: ${AUTORESUME_RESUME:=all}           # all | latest
: ${AUTORESUME_TERMINAL:=auto}        # auto | iterm | terminal | tmux | headless
: ${AUTORESUME_LIVE_PANE:=prefill}    # prefill | type | notify
: ${AUTORESUME_CLAUDE_BIN:=claude}
: ${AUTORESUME_GRACE:=60}             # seconds past reset before acting
: ${AUTORESUME_FRESH:=90}             # state file younger than this => still open
: ${AUTORESUME_WRAPPED:=}             # status line command we took over from

STATE_DIR="$AUTORESUME_DIR"
MANUAL_DIR="$AUTORESUME_DIR/manual"
FIRED_DIR="$AUTORESUME_DIR/fired"
LOG_FILE="$AUTORESUME_DIR/watch.log"

ar_log() { print -r -- "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$LOG_FILE" 2>/dev/null }

ar_now() { zmodload zsh/datetime 2>/dev/null && print -r -- $EPOCHSECONDS || date +%s }

# JSON emitters. Small enough to hand-roll, and the sensor cannot afford jq.
ar_jnum() { [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$1" || printf 'null' }
ar_jstr() { local s=${1//\\/\\\\}; printf '"%s"' "${s//\"/\\\"}" }

# The CLI rejects anything outside this set; an unknown value must fall back to
# the user's settings.json rather than abort the resume.
ar_valid_mode() {
    case $1 in
        acceptEdits|auto|bypassPermissions|manual|dontAsk|plan) return 0 ;;
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
