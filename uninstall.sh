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
PLIST="$HOME/Library/LaunchAgents/com.claude-autoresume.plist"
LABEL="com.claude-autoresume"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }

printf '\n\033[1mremoving claude-autoresume\033[0m\n\n'

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
ok "service unloaded"

# Put the status line back. The wrapped command is the only record of what was
# there before, so read it before anything gets deleted.
if [ -f "$SETTINGS" ]; then
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
            ok "status line restored to: ${WRAPPED:-its original setting}"
        fi
    elif [ -n "$WRAPPED" ]; then
        jq --arg cmd "$WRAPPED" '.statusLine.command = $cmd' "$SETTINGS" >"$tmp"
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
rm -rf "$PREFIX"
ok "files removed"

if [ "$PURGE" = "1" ]; then
    rm -rf "$STATE"
    ok "state purged"
else
    printf '  kept %s (use --purge to remove)\n' "$STATE"
fi

printf '\ndone — restart Claude Code.\n\n'
