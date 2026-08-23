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

# Single-quote a value for safe inclusion in config.sh. The wrapped status line
# is arbitrary user shell, and one apostrophe in it -- `awk '{print $1}'` is
# enough -- produced a config.sh that fails to parse. common.sh sources that
# file on every status-line render, so the breakage is continuous and silent.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# settings.json may be a symlink into a dotfiles repo. Resolve it so the write
# lands on the real file, keeps its mode, and does not orphan the original.
resolve_link() {
    _t=$1
    while [ -L "$_t" ]; do
        _l=$(readlink "$_t")
        case "$_l" in
            /*) _t=$_l ;;
            *) _t=$(dirname "$_t")/$_l ;;
        esac
    done
    printf '%s' "$_t"
}

# Atomic within the target's own directory, preserving the existing mode.
replace_file() {
    _src=$1
    _dst=$(resolve_link "$2")
    _mode=$(stat -f %Lp "$_dst" 2>/dev/null || printf '644')
    _tmp="$_dst.autoresume.$$"
    cat "$_src" >"$_tmp" || {
        rm -f "$_tmp" "$_src"
        die "could not write $_dst"
    }
    chmod "$_mode" "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$_dst" || {
        rm -f "$_tmp" "$_src"
        die "could not replace $_dst"
    }
    rm -f "$_src"
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
# Tested against a repo-unique file, not just bin/ + lib/. Piped to sh, $0 is
# "sh" and dirname is ".", so any project directory that happens to contain a
# bin/ and a lib/ was being treated as the source checkout.
if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/bin/claude-autoresume-sensor" ] &&
    [ -d "$SELF_DIR/lib" ] && [ -d "$SELF_DIR/share" ]; then
    SRC="$SELF_DIR"
    say "installing from checkout: $SRC"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    trap 'rm -rf "$TMP"; exit 130' INT TERM
    say "downloading $REPO@$BRANCH"
    # Downloaded to a file rather than piped into tar: a pipeline reports only
    # the LAST command's status, and bsdtar exits 0 on an empty stream, so a 404
    # from curl was read as success. SRC then came out empty, `[ -d "$SRC/bin" ]`
    # tested `/bin` and passed, and the installer went on to delete a working
    # prefix and copy system binaries into it.
    curl -fsSL -o "$TMP/src.tgz" \
        "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" ||
        die "download failed — is $REPO@$BRANCH correct and public?"
    tar -xzf "$TMP/src.tgz" -C "$TMP" || die "could not unpack the download"
    SRC=$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -1)
    [ -n "$SRC" ] || die "unexpected archive layout: nothing unpacked"
    for d in bin lib share; do
        [ -d "$SRC/$d" ] || die "unexpected archive layout: $d/ missing"
    done
    [ -f "$SRC/bin/claude-autoresume-sensor" ] || die "unexpected archive layout: sensor missing"
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
    # Staged into a sibling and swapped in, so a failed copy cannot leave the
    # prefix half-deleted with no way to regenerate the plist.
    _stage="${PREFIX:?}.new.$$"
    rm -rf "$_stage"
    mkdir -p "$_stage" || die "could not create $_stage"
    cp -R "$SRC/bin" "$SRC/lib" "$SRC/share" "$_stage/" || {
        rm -rf "$_stage"
        die "could not copy the source tree"
    }
    rm -rf "${PREFIX:?}/bin" "${PREFIX:?}/lib" "${PREFIX:?}/share"
    mv "$_stage/bin" "$_stage/lib" "$_stage/share" "$PREFIX/" || {
        rm -rf "$_stage"
        die "could not install into $PREFIX"
    }
    rm -rf "$_stage"
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
    # Sourced rather than string-stripped: the value is shell-quoted, and a
    # naive s/^'// s/'$// mangles anything containing an escaped quote.
    WRAPPED=$(
        # shellcheck source=/dev/null
        . "$STATE/config.sh" 2>/dev/null
        printf '%s' "${AUTORESUME_WRAPPED:-}"
    )
fi
case "$CURRENT" in
    *claude-autoresume-sensor*)
        # Already wrapped. Never record ourselves as the wrapped command --
        # that would make the sensor invoke itself forever.
        #
        # If config.sh is gone (an aborted install, a deleted state dir) the
        # snapshot still knows what was there. Without this the recovery path
        # silently adopts "no status line" and the user's is lost for good.
        if [ -z "$WRAPPED" ] && [ -f "$STATE/backup/statusline.json" ]; then
            WRAPPED=$(jq -r '.command // ""' "$STATE/backup/statusline.json" 2>/dev/null)
            case "$WRAPPED" in *claude-autoresume-sensor*) WRAPPED="" ;; esac
            [ -n "$WRAPPED" ] && say "recovered the wrapped command from the snapshot"
        fi
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
# Refreshed whenever we are wrapping something new, not only written once. A
# user who switches status line and re-installs would otherwise be restored to
# the command they had two installs ago, while the success message named the
# new one.
if [ ! -f "$STATE/backup/statusline.json" ] || [ -n "${CURRENT#*claude-autoresume-sensor}" ]; then
    case "$CURRENT" in
        *claude-autoresume-sensor*) ;;
        *) jq '.statusLine // null' "$SETTINGS" >"$STATE/backup/statusline.json" ;;
    esac
fi
[ -f "$STATE/backup/statusline.json" ] || jq '.statusLine // null' "$SETTINGS" >"$STATE/backup/statusline.json"

tmp=$(mktemp)
jq --arg cmd "$SENSOR" '
    .statusLine.type = "command"
  | .statusLine.command = $cmd
  | .statusLine.refreshInterval = (
        if (.statusLine.refreshInterval // 999) > 15 then 15
        else .statusLine.refreshInterval end)
' "$SETTINGS" >"$tmp" || {
    rm -f "$tmp"
    die "could not rewrite $SETTINGS (is .statusLine an object?)"
}
replace_file "$tmp" "$SETTINGS"
ok "settings.json updated (backup alongside it)"

# ---- config ------------------------------------------------------------------

if [ -f "$STATE/config.sh" ]; then
    # Rewritten by filtering and appending, not by sed. The old
    # `sed "s|^AUTORESUME_WRAPPED=.*|...'$WRAPPED'|"` interpolated the user's
    # status line into both the pattern and the replacement: a `|` in it (the
    # documented Claude Code example has one) aborted the installer half way,
    # after settings.json had been repointed but before the service was
    # registered. An `&` silently corrupted the value instead.
    _cfg_tmp=$(mktemp)
    {
        grep -v '^AUTORESUME_WRAPPED=' "$STATE/config.sh" || true
        printf 'AUTORESUME_WRAPPED=%s\n' "$(shq "$WRAPPED")"
    } >"$_cfg_tmp"
    if ! mv -f "$_cfg_tmp" "$STATE/config.sh"; then
        rm -f "$_cfg_tmp"
        die "could not update $STATE/config.sh"
    fi
    ok "kept your existing config"
else
    cat >"$STATE/config.sh" <<CONF
# claude-autoresume configuration. Sourced by every command.

# What the sensor took over. Its output is printed unchanged.
AUTORESUME_WRAPPED=$(shq "$WRAPPED")

# Percentage of a usage window that counts as spent.
AUTORESUME_ARM_PCT=100

# Sent to the session on resume.
AUTORESUME_PROMPT='continue'

# all    — resume every session that was cut off
# latest — resume only the most recent, leave the rest armed
AUTORESUME_RESUME=all

# Absolute path resolved at install time. Under launchd the PATH is fixed, so a
# claude installed by nvm, fnm, volta or bun would not be found at all.
AUTORESUME_CLAUDE_BIN=$(shq "$(command -v claude || printf 'claude')")

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
