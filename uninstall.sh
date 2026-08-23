#!/bin/sh
#
# claude-autoresume uninstaller.
#
#   ./uninstall.sh            remove the tool, keep your recorded state
#   ./uninstall.sh --purge    remove the state directory too
#
# Your original status line command is put back exactly as it was.
#
set -eu

PREFIX="${CLAUDE_AUTORESUME_PREFIX:-$HOME/.local/share/claude-autoresume}"
BINDIR="${CLAUDE_AUTORESUME_BINDIR:-$HOME/.local/bin}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE="${CLAUDE_AUTORESUME_DIR:-$CLAUDE_DIR/autoresume}"
SETTINGS="$CLAUDE_DIR/settings.json"
PLIST="${CLAUDE_AUTORESUME_PLIST:-$HOME/Library/LaunchAgents/com.claude-autoresume.plist}"
LABEL="com.claude-autoresume"
# install.sh honours this; uninstall.sh must too. Without it the test suite --
# which installs into a throwaway HOME but cannot redirect launchctl -- boots
# out and deletes the developer's own agent on every run.
NO_SERVICE="${CLAUDE_AUTORESUME_NO_SERVICE:-0}"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }

printf '\n\033[1mremoving claude-autoresume\033[0m\n\n'

if [ "$NO_SERVICE" = "1" ]; then
    ok "left the launchd agent alone (CLAUDE_AUTORESUME_NO_SERVICE=1)"
else
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    ok "service unloaded"
fi

# Put the status line back. The wrapped command is the only record of what was
# there before, so read it before anything gets deleted.
CURRENT=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null || printf '')
case "$CURRENT" in
    *claude-autoresume-sensor*) MINE=1 ;;
    *) MINE=0 ;;
esac

if [ "$MINE" = "0" ]; then
    # Refuse to touch a status line that is not ours. Previously the fallback
    # branch ran `jq del(.statusLine)` whenever no snapshot was found, so running
    # this on a machine where autoresume was never installed -- or a second time
    # after --purge removed the snapshot -- silently deleted the user's own
    # status line and reported it as a success.
    ok "status line is not ours — left untouched"
elif [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.autoresume-backup.$(date +%Y%m%d-%H%M%S)"
    WRAPPED=""
    [ -f "$STATE/config.sh" ] && WRAPPED=$(sed -n "s/^AUTORESUME_WRAPPED=//p" "$STATE/config.sh" |
        head -1 | sed "s/^'//; s/'$//")
    tmp=$(mktemp)
    BACKUP="$STATE/backup/statusline.json"
    [ -s "$BACKUP" ] || BACKUP="$STATE/statusline.backup.json" # pre-0.1.1 layout
    if [ -s "$BACKUP" ]; then
        # Restore the object exactly as it was, padding and refreshInterval too.
        if [ "$(cat "$BACKUP")" = "null" ]; then
            jq 'del(.statusLine)' "$SETTINGS" >"$tmp"
            ok "status line entry removed (there was none before)"
        else
            jq --slurpfile sl "$BACKUP" \
                '.statusLine = $sl[0]' "$SETTINGS" >"$tmp"
            # Report what the snapshot actually holds. Naming $WRAPPED here was
            # wrong whenever the two disagreed, so the message could confidently
            # cite a command that was not the one being written.
            ok "status line restored to: $(jq -r '.command // "its original setting"' "$BACKUP" 2>/dev/null)"
        fi
    elif [ -n "$WRAPPED" ]; then
        # No snapshot, so refreshInterval cannot be restored to its old value --
        # drop the one we added rather than leaving it behind as residue.
        jq --arg cmd "$WRAPPED" \
            '.statusLine.command = $cmd | del(.statusLine.refreshInterval)' \
            "$SETTINGS" >"$tmp"
        ok "status line command restored to: $WRAPPED"
    else
        jq 'del(.statusLine)' "$SETTINGS" >"$tmp"
        ok "status line entry removed"
    fi
    mv -f "$tmp" "$SETTINGS"
fi

for b in claude-autoresume-watch claude-autoresume-arm claude-autoresume-status; do
    rm -f "$BINDIR/$b"
done
# `make dev` installs with PREFIX pointing at the checkout, and in that mode
# $PREFIX/uninstall.sh IS the repo's own file -- the documented entry point. A
# bare rm -rf here deleted the entire working tree, .git included.
if [ -e "$PREFIX/.git" ] || { [ -f "$PREFIX/install.sh" ] && [ -f "$PREFIX/README.md" ]; }; then
    ok "left the source checkout at $PREFIX alone (dev install)"
else
    rm -rf "${PREFIX:?}"
fi
ok "files removed"

if [ "$PURGE" = "1" ]; then
    rm -rf "$STATE"
    ok "state purged"
else
    printf '  kept %s (use --purge to remove)\n' "$STATE"
fi

printf '\ndone — restart Claude Code.\n\n'
