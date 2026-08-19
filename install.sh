#!/bin/sh
#
# claude-autoresume installer.
#
#   curl -fsSL https://raw.githubusercontent.com/agento-lab/claude-autoresume/main/install.sh | sh
#
# or, from a checkout:
#
#   ./install.sh
#
# Re-running is safe: it will not wrap itself, and it keeps whatever status line
# command it took over the first time.
#
set -eu

REPO="${CLAUDE_AUTORESUME_REPO:-agento-lab/claude-autoresume}"
BRANCH="${CLAUDE_AUTORESUME_BRANCH:-main}"
PREFIX="${CLAUDE_AUTORESUME_PREFIX:-$HOME/.local/share/claude-autoresume}"
BINDIR="${CLAUDE_AUTORESUME_BINDIR:-$HOME/.local/bin}"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE="${CLAUDE_AUTORESUME_DIR:-$CLAUDE_DIR/autoresume}"
SETTINGS="$CLAUDE_DIR/settings.json"
PLIST="$HOME/Library/LaunchAgents/com.claude-autoresume.plist"
LABEL="com.claude-autoresume"
NO_SERVICE="${CLAUDE_AUTORESUME_NO_SERVICE:-0}"

say() { printf '  %s\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die() {
    printf '\033[31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

printf '\n\033[1mclaude-autoresume\033[0m\n\n'

# ---- preflight ---------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "macOS only for now (this release uses launchd, osascript and BSD stat).
Linux support is tracked in the README; the platform-specific pieces are isolated in lib/."

for dep in jq zsh osascript; do
    command -v "$dep" >/dev/null 2>&1 || {
        [ "$dep" = "jq" ] && die "jq is required — install it with: brew install jq"
        die "$dep is required but was not found"
    }
done
command -v claude >/dev/null 2>&1 || warn "claude is not on PATH — resumes will fail until it is"

# ---- get the source ----------------------------------------------------------

SRC=""
SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || SELF_DIR=""
if [ -n "$SELF_DIR" ] && [ -d "$SELF_DIR/bin" ] && [ -d "$SELF_DIR/lib" ]; then
    SRC="$SELF_DIR"
    say "installing from checkout: $SRC"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT INT TERM
    say "downloading $REPO@$BRANCH"
    curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" |
        tar -xzf - -C "$TMP" || die "download failed"
    SRC=$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -1)
    [ -d "$SRC/bin" ] || die "unexpected archive layout"
fi

# ---- files -------------------------------------------------------------------

mkdir -p "$PREFIX" "$BINDIR" "$STATE/manual" "$STATE/fired"

# `make dev` installs with PREFIX pointing at the checkout so edits are live.
# Without this guard the next two lines would delete the repo's own bin/ and
# lib/ and then try to copy them from the hole they just made.
SRC_REAL=$(CDPATH='' cd -- "$SRC" && pwd -P)
PREFIX_REAL=$(CDPATH='' cd -- "$PREFIX" && pwd -P)
if [ "$SRC_REAL" = "$PREFIX_REAL" ]; then
    say "dev install — running straight from the checkout, nothing copied"
else
    rm -rf "${PREFIX:?}/bin" "${PREFIX:?}/lib" "${PREFIX:?}/share"
    cp -R "$SRC/bin" "$SRC/lib" "$SRC/share" "$PREFIX/"
fi
# Ship the uninstaller alongside the code: a piped install leaves no checkout to
# run it from later.
if [ "$SRC_REAL" != "$PREFIX_REAL" ]; then
    cp "$SRC/uninstall.sh" "$PREFIX/uninstall.sh" 2>/dev/null || true
    [ -f "$SRC/README.md" ] && cp "$SRC/README.md" "$PREFIX/README.md"
fi
chmod +x "$PREFIX"/bin/* "$PREFIX/uninstall.sh" 2>/dev/null || true
ok "installed to $PREFIX"

for b in claude-autoresume-watch claude-autoresume-arm claude-autoresume-status; do
    ln -sf "$PREFIX/bin/$b" "$BINDIR/$b"
done
ok "linked commands into $BINDIR"
case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) warn "$BINDIR is not on your PATH — add: export PATH=\"$BINDIR:\$PATH\"" ;;
esac

# ---- take over the status line ----------------------------------------------
#
# rate_limits is delivered to the status line command and nowhere else, so the
# sensor has to sit in that pipe. It runs whatever was there before and prints
# its output unchanged.

SENSOR="$PREFIX/bin/claude-autoresume-sensor"
[ -f "$SETTINGS" ] || {
    mkdir -p "$CLAUDE_DIR"
    printf '{}\n' >"$SETTINGS"
}
cp "$SETTINGS" "$SETTINGS.autoresume-backup.$(date +%Y%m%d-%H%M%S)"

CURRENT=$(jq -r '.statusLine.command // ""' "$SETTINGS")
WRAPPED=""
if [ -f "$STATE/config.sh" ]; then
    WRAPPED=$(sed -n 's/^AUTORESUME_WRAPPED=//p' "$STATE/config.sh" | head -1 |
        sed "s/^'//; s/'$//")
fi
case "$CURRENT" in
    *claude-autoresume-sensor*)
        # Already wrapped. Never record ourselves as the wrapped command --
        # that would make the sensor invoke itself forever.
        say "status line already wrapped, keeping: ${WRAPPED:-<none>}"
        ;;
    "")
        WRAPPED=""
        say "no existing status line — the sensor will print a minimal one"
        ;;
    *)
        WRAPPED="$CURRENT"
        ok "wrapping your existing status line: $CURRENT"
        ;;
esac

# Snapshot the whole statusLine object, not just the command: uninstall has to
# put back padding and refreshInterval as they were, and we cannot reconstruct
# fields we never recorded.
# Kept out of $STATE itself: the watcher's housekeeping deletes *.json older
# than a week from there, which would quietly eat the only record of what your
# status line used to be.
mkdir -p "$STATE/backup"
if [ ! -f "$STATE/backup/statusline.json" ]; then
    jq '.statusLine // null' "$SETTINGS" >"$STATE/backup/statusline.json"
fi

tmp=$(mktemp)
jq --arg cmd "$SENSOR" '
    .statusLine.type = "command"
  | .statusLine.command = $cmd
  | .statusLine.refreshInterval = (
        if (.statusLine.refreshInterval // 999) > 15 then 15
        else .statusLine.refreshInterval end)
' "$SETTINGS" >"$tmp" && mv -f "$tmp" "$SETTINGS"
ok "settings.json updated (backup alongside it)"

# ---- config ------------------------------------------------------------------

if [ -f "$STATE/config.sh" ]; then
    # Preserve the user's choices; only the wrapped command is recomputed.
    sed -i '' "s|^AUTORESUME_WRAPPED=.*|AUTORESUME_WRAPPED='$WRAPPED'|" "$STATE/config.sh"
    ok "kept your existing config"
else
    cat >"$STATE/config.sh" <<CONF
# claude-autoresume configuration. Sourced by every command.

# What the sensor took over. Its output is printed unchanged.
AUTORESUME_WRAPPED='$WRAPPED'

# Percentage of a usage window that counts as spent.
AUTORESUME_ARM_PCT=100

# Sent to the session on resume.
AUTORESUME_PROMPT='continue'

# all    — resume every session that was cut off
# latest — resume only the most recent, leave the rest armed
AUTORESUME_RESUME=all

# auto | iterm | terminal | tmux | headless
# auto reuses whichever terminal the session was running in.
AUTORESUME_TERMINAL=auto

# What to do with a session that is still open when its limit resets.
# A spent limit can leave an interactive menu on screen whose options include
# paid ones, and Enter takes whichever line is highlighted.
#   prefill - type the prompt but do not submit it (safe; you press Enter)
#   type    - submit it too (full automation, accepts the risk above)
#   notify  - leave the pane alone entirely
AUTORESUME_LIVE_PANE=prefill
CONF
    ok "wrote $STATE/config.sh"
fi

# ---- service -----------------------------------------------------------------

if [ "$NO_SERVICE" = "1" ]; then
    warn "skipping launchd registration (CLAUDE_AUTORESUME_NO_SERVICE=1)"
else
    mkdir -p "$HOME/Library/LaunchAgents"
    sed -e "s|__WATCH__|$PREFIX/bin/claude-autoresume-watch|g" \
        -e "s|__STATE__|$STATE|g" \
        -e "s|__PATH__|$BINDIR:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin|g" \
        "$PREFIX/share/launchd.plist.template" >"$PLIST"
    plutil -lint "$PLIST" >/dev/null || die "generated plist is invalid"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" || die "could not load the launchd agent"
    ok "service loaded (checks every 60s)"
fi

printf '\n\033[1mdone\033[0m — restart Claude Code so the new status line takes effect.\n\n'
say "claude-autoresume-status    what is armed and when it fires"
say "claude-autoresume-arm --in 2h30m    arm by hand"
say "touch $STATE/DISABLED    turn it off"
printf '\n'
