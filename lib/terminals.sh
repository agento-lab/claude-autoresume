#!/usr/bin/env zsh
#
# Terminal adapters.
#
# Two jobs, and they are not the same job:
#
#   ar_send_live   the session is still running -- type into the pane it already
#                  owns, so we never start a second process against one session
#   ar_open_new    Claude was quit -- open a window and start it back up
#
# Every adapter prints a one-word result and returns 0, so the watcher can log
# what happened and fall through to the next option.

ar_osa_escape() { local s=${1//\\/\\\\}; print -r -- "${s//\"/\\\"}" }

# pgrep does not match GUI app bundles reliably -- iTerm reports as "iTerm2" to
# ps but matches no pgrep pattern -- and `tell application "X"` would launch it.
# System Events answers without either problem.
ar_app_running() {
    [[ $(osascript -e "tell application \"System Events\" to return (exists process \"$1\")" 2>/dev/null) == true ]]
}

ar_tmux_alive() { command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1 }

# ---- send into an existing pane ---------------------------------------------

ar_send_live() {
    local kind=$1 ident=$2 text=$3
    [[ -n $ident ]] || { print -r -- unsupported; return 0 }
    case $kind in
        tmux)
            ar_tmux_alive || { print -r -- notrunning; return 0 }
            # Array membership, not `| grep -q`: grep would exit on the first
            # match, tmux would take SIGPIPE, and pipefail would turn a found
            # pane into a failed lookup.
            local -a panes
            panes=(${(f)"$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"})
            (( ${panes[(I)$ident]} )) || { print -r -- notfound; return 0 }
            tmux send-keys -t "$ident" "$text" Enter 2>/dev/null \
                && print -r -- sent || print -r -- error
            ;;
        iterm)
            ar_app_running iTerm2 || { print -r -- notrunning; return 0 }
            osascript <<OSA 2>/dev/null || print -r -- error
tell application "iTerm"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if id of s is "$(ar_osa_escape "$ident")" then
                    tell s to write text "$(ar_osa_escape "$text")"
                    return "sent"
                end if
            end repeat
        end repeat
    end repeat
end tell
return "notfound"
OSA
            ;;
        apple_terminal)
            # Terminal.app has no session id, but every tab exposes its tty and
            # the sensor records the one Claude was attached to.
            ar_app_running Terminal || { print -r -- notrunning; return 0 }
            osascript <<OSA 2>/dev/null || print -r -- error
tell application "Terminal"
    repeat with w in windows
        repeat with t in tabs of w
            if (tty of t) is "$(ar_osa_escape "$ident")" then
                do script "$(ar_osa_escape "$text")" in t
                return "sent"
            end if
        end repeat
    end repeat
end tell
return "notfound"
OSA
            ;;
        *) print -r -- unsupported ;;
    esac
    return 0
}

# ---- start a fresh session ---------------------------------------------------

# --resume=<id> rather than a separate argument: the option takes an optional
# value, so the space form could swallow the prompt positional.
ar_build_cmd() {
    local cwd=$1 sid=$2 mode=$3 prompt=$4 headless=${5:-0}
    local cmd="cd ${(q)cwd} && ${AUTORESUME_CLAUDE_BIN} --resume=${sid}"
    ar_valid_mode "$mode" && cmd+=" --permission-mode ${mode}"
    (( headless )) && cmd+=" -p"
    cmd+=" ${(q)prompt}"
    print -r -- "$cmd"
}

# Which terminal to open when the recorded one is gone or was never known.
ar_pick_terminal() {
    local preferred=$1
    if [[ $preferred != auto && -n $preferred ]]; then print -r -- "$preferred"; return; fi
    ar_tmux_alive                       && { print -r -- tmux; return }
    [[ -d /Applications/iTerm.app ]]    && { print -r -- iterm; return }
    [[ -d /System/Applications/Utilities/Terminal.app ]] && { print -r -- apple_terminal; return }
    print -r -- headless
}

ar_open_new() {
    local kind=$1 cwd=$2 sid=$3 mode=$4 prompt=$5
    local cmd
    case $kind in
        tmux)
            ar_tmux_alive || { print -r -- notrunning; return 0 }
            cmd=$(ar_build_cmd "$cwd" "$sid" "$mode" "$prompt")
            tmux new-window -c "$cwd" -n "claude-resume" "zsh -lc ${(q)cmd}" 2>/dev/null \
                && print -r -- opened || print -r -- error
            ;;
        iterm)
            local running=1; ar_app_running iTerm2 || running=0
            cmd=$(ar_build_cmd "$cwd" "$sid" "$mode" "$prompt")
            osascript <<OSA 2>/dev/null || print -r -- error
tell application "iTerm"
    if $running = 1 then
        set targetWindow to (create window with default profile)
    else
        activate
        delay 1.5
        set targetWindow to current window
    end if
    tell current session of targetWindow to write text "$(ar_osa_escape "$cmd")"
end tell
return "opened"
OSA
            ;;
        apple_terminal)
            cmd=$(ar_build_cmd "$cwd" "$sid" "$mode" "$prompt")
            osascript <<OSA 2>/dev/null || print -r -- error
tell application "Terminal"
    activate
    do script "$(ar_osa_escape "$cmd")"
end tell
return "opened"
OSA
            ;;
        headless)
            # No terminal, so no way to answer a permission prompt: print mode
            # at least fails fast and leaves the reason in the log.
            cmd=$(ar_build_cmd "$cwd" "$sid" "$mode" "$prompt" 1)
            local out="$AUTORESUME_DIR/headless-${sid}.log"
            nohup zsh -lc "$cmd" >> "$out" 2>&1 &
            disown 2>/dev/null
            print -r -- "opened-headless"
            ;;
        *) print -r -- unsupported ;;
    esac
    return 0
}
