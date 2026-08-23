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

# A spent limit does not leave the session at a plain prompt. Claude Code puts up
# a select menu -- internally `rate_limit_options_menu` -- offering to upgrade the
# plan, add funds for usage credits, or stop and wait. Letters are ignored in a
# select list and Enter takes whichever line is highlighted, so submitting blind
# could pick an option that costs money.
#
# Two obvious defences were tried and both failed. Detecting the menu first does
# not work: iTerm's `contents` returns the whole buffer rather than the visible
# screen, so a menu that appeared once still matches forever and the session
# would never resume again. Sending Escape ahead of the text does not work
# either -- iTerm merges it with whatever follows, even across separate osascript
# calls seconds apart, and ESC+"c" is then read as Meta-c, eating the first
# character.
#
# The dangerous act is specifically Enter, so the mode decides who presses it.
#
# The default submits, because unattended continuation is the entire point of the
# tool. The exposure is bounded: a stray Enter on that menu opens a browser tab
# (upgrade) or a further confirmation dialog (add funds, which has its own
# enable/buy confirm step). One Enter cannot complete a purchase.
#
#   type     type and submit                (default -- fully unattended)
#   prefill  type the text, do not submit   (you press Enter; inert against a menu)
#   notify   touch nothing
ar_send_live() {
    local kind=$1 ident=$2 text=$3 mode=${4:-${AUTORESUME_LIVE_PANE:-type}}
    [[ -n $ident ]] || { print -r -- unsupported; return 0 }
    [[ $mode == notify ]] && { print -r -- skipped; return 0 }
    case $kind in
        tmux)
            ar_tmux_alive || { print -r -- notrunning; return 0 }
            # Array membership, not `| grep -q`: grep would exit on the first
            # match, tmux would take SIGPIPE, and pipefail would turn a found
            # pane into a failed lookup.
            local -a panes
            panes=(${(f)"$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)"})
            (( ${panes[(Ie)$ident]} )) || { print -r -- notfound; return 0 }
            if [[ $mode == type ]]; then
                tmux send-keys -t "$ident" -l -- "$text" 2>/dev/null && tmux send-keys -t "$ident" Enter 2>/dev/null \
                    && print -r -- sent || print -r -- error
            else
                tmux send-keys -t "$ident" -l -- "$text" 2>/dev/null \
                    && print -r -- prefilled || print -r -- error
            fi
            ;;
        iterm)
            ar_app_running iTerm2 || { print -r -- notrunning; return 0 }
            # `newline NO` is what makes prefill possible: the text reaches the
            # prompt without the return that would submit it.
            local itermNL="" itermResult=sent
            [[ $mode == type ]] || { itermNL=" newline NO"; itermResult=prefilled }
            osascript <<OSA 2>/dev/null || print -r -- error
tell application "iTerm"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if id of s is "$(ar_osa_escape "$ident")" then
                    tell s to write text "$(ar_osa_escape "$text")"$itermNL
                    return "$itermResult"
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
            #
            # `do script` always appends a return, so typing without submitting
            # is not possible here. Rather than submit blind into a menu that may
            # be open, this degrades to leaving the pane alone.
            [[ $mode == type ]] || { print -r -- unsupported-prefill; return 0 }
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

# Whether a terminal can actually be driven right now, as opposed to whether the
# session was recorded under it. A tmux server that has since exited, or iTerm
# uninstalled since, both need to fall back rather than be trusted.
ar_terminal_usable() {
    case $1 in
        tmux) ar_tmux_alive ;;
        iterm) [[ -d /Applications/iTerm.app || -d $HOME/Applications/iTerm.app ]] ;;
        apple_terminal|headless) return 0 ;;
        *) return 1 ;;
    esac
}

# Which terminal to open when the recorded one is gone or was never known.
ar_pick_terminal() {
    local preferred=$1
    # `terminal` is what the config documents and what a user would type;
    # `apple_terminal` is what the sensor records. Accept both, or the value
    # falls through every case below and silently degrades to headless.
    [[ $preferred == terminal ]] && preferred=apple_terminal
    if [[ $preferred != auto && -n $preferred ]]; then print -r -- "$preferred"; return; fi
    ar_tmux_alive                       && { print -r -- tmux; return }
    [[ -d /Applications/iTerm.app || -d $HOME/Applications/iTerm.app ]] && { print -r -- iterm; return }
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
