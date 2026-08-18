#!/bin/sh
#
# Integration tests. No mocks: this installs into a throwaway HOME, drives the
# real sensor and watcher, and uninstalls again.
#
# Everything is scoped by CLAUDE_CONFIG_DIR / CLAUDE_AUTORESUME_DIR / PREFIX /
# BINDIR, and the launchd agent is never registered, so your real installation
# is untouched. The watcher runs in --dry-run wherever a live run would open a
# window or speak.
#
set -eu

cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
SB="$REPO/test/.sandbox"

pass=0
fail=0

ok() {
    pass=$((pass + 1))
    printf '  \033[32m✓\033[0m %s\n' "$1"
}
bad() {
    fail=$((fail + 1))
    printf '  \033[31m✗\033[0m %s\n' "$1"
    [ $# -gt 1 ] && printf '      %s\n' "$2"
    return 0
}
is() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
group() { printf '\n\033[1m%s\033[0m\n' "$1"; }

reset_sandbox() {
    rm -rf "$SB"
    mkdir -p "$SB/.claude" "$SB/prefix" "$SB/bin"
    printf '#!/bin/sh\ncat >/dev/null; printf "ORIGINAL-LINE"\n' >"$SB/.claude/sl.sh"
    chmod +x "$SB/.claude/sl.sh"
    jq -n --arg c "$SB/.claude/sl.sh" \
        '{statusLine:{type:"command",command:$c,padding:1},effortLevel:"max",hooks:{Stop:[{hooks:[{type:"command",command:"say hi"}]}]}}' \
        >"$SB/.claude/settings.json"
    cp "$SB/.claude/settings.json" "$SB/before.json"

    export CLAUDE_CONFIG_DIR="$SB/.claude"
    export CLAUDE_AUTORESUME_DIR="$SB/.claude/autoresume"
    export CLAUDE_AUTORESUME_PREFIX="$SB/prefix"
    export CLAUDE_AUTORESUME_BINDIR="$SB/bin"
    export CLAUDE_AUTORESUME_NO_SERVICE=1
}

sensor() { "$SB/prefix/bin/claude-autoresume-sensor"; }

# Feed one payload to the sensor and return the named field from its state file.
state_of() { jq -r "$2" "$CLAUDE_AUTORESUME_DIR/$1.json" 2>/dev/null; }

payload() {
    # $1 session, $2 5h pct, $3 5h reset, $4 7d pct, $5 7d reset
    jq -nc --arg s "$1" --argjson a "$2" --argjson b "$3" --argjson c "$4" --argjson d "$5" \
        '{session_id:$s,cwd:"/tmp",transcript_path:"",model:{display_name:"Opus 5"},
        rate_limits:{five_hour:{used_percentage:$a,resets_at:$b},
                     seven_day:{used_percentage:$c,resets_at:$d}}}'
}

printf '\n\033[1mclaude-autoresume integration tests\033[0m\n'

# -----------------------------------------------------------------------------
group "install"
reset_sandbox
sh "$REPO/install.sh" >/dev/null 2>&1
if [ -x "$SB/prefix/bin/claude-autoresume-sensor" ]; then ok "sensor installed"; else bad "sensor installed"; fi
if [ -x "$SB/prefix/uninstall.sh" ]; then ok "uninstaller shipped alongside"; else bad "uninstaller shipped alongside"; fi
is "settings points at the sensor" \
    "$(jq -r '.statusLine.command' "$SB/.claude/settings.json" | sed 's|.*/||')" \
    "claude-autoresume-sensor"
is "refreshInterval set" "$(jq -r '.statusLine.refreshInterval' "$SB/.claude/settings.json")" "15"
is "original snapshotted" \
    "$(jq -r '.command' "$CLAUDE_AUTORESUME_DIR/backup/statusline.json" | sed 's|.*/||')" "sl.sh"

# -----------------------------------------------------------------------------
group "status line passthrough"
for variant in full norl bad; do
    case $variant in
        full) p=$(payload s-pass 10 9999999999 5 9999999999) ;;
        norl) p=$(payload s-pass 10 9999999999 5 9999999999 | jq -c 'del(.rate_limits)') ;;
        bad) p='{"nonsense":true}' ;;
    esac
    a=$(printf '%s' "$p" | "$SB/.claude/sl.sh" | od -An -c | tr -d ' \n')
    b=$(printf '%s' "$p" | sensor | od -An -c | tr -d ' \n')
    is "payload [$variant] passes through byte-identical" "$b" "$a"
done

# -----------------------------------------------------------------------------
group "arming"
printf '%s' "$(payload s1 100 1700000000 5 1900000000)" | sensor >/dev/null
is "5h spent arms on the 5h reset" "$(state_of s1 '.armed_window')" "five_hour"
is "  ... with that window's reset" "$(state_of s1 '.resets_at')" "1700000000"

printf '%s' "$(payload s2 100 1700000000 100 1900000000)" | sensor >/dev/null
is "both spent arms on the WEEKLY reset" "$(state_of s2 '.armed_window')" "seven_day"
is "  ... waiting days, not 5 hours" "$(state_of s2 '.resets_at')" "1900000000"

printf '%s' "$(payload s3 99.8 1700000000 5 1900000000)" | sensor >/dev/null
is "99.8% does not arm" "$(state_of s3 '.armed')" "false"

printf '%s' "$(payload s1 3 1900000000 5 1900000000)" | sensor >/dev/null
is "window rolling over mid-session self-disarms" "$(state_of s1 '.armed')" "false"

# -----------------------------------------------------------------------------
group "watcher"
NOW=$(date +%s)
rm -f "$CLAUDE_AUTORESUME_DIR"/*.json
printf '%s' "$(payload due 100 $((NOW - 300)) 5 1900000000)" | sensor >/dev/null
printf '%s' "$(payload notyet 100 $((NOW + 7200)) 5 1900000000)" | sensor >/dev/null
out=$("$SB/prefix/bin/claude-autoresume-watch" --dry-run 2>&1)
case "$out" in
    *"resuming 1 session"*) ok "fires for the due session only" ;;
    *) bad "fires for the due session only" "$out" ;;
esac
if [ -f "$CLAUDE_AUTORESUME_DIR/notyet.json" ]; then ok "not-yet-due session left alone"; else bad "not-yet-due session left alone"; fi

jq '.cwd="/no/such/place"' "$CLAUDE_AUTORESUME_DIR/due.json" >"$SB/t" && mv "$SB/t" "$CLAUDE_AUTORESUME_DIR/due.json"
"$SB/prefix/bin/claude-autoresume-watch" --dry-run >/dev/null 2>&1
if grep -c retire "$CLAUDE_AUTORESUME_DIR/watch.log" >/dev/null 2>&1; then
    ok "vanished directory is retired, not counted"
else
    bad "vanished directory is retired, not counted"
fi

# -----------------------------------------------------------------------------
group "resume=latest"
rm -f "$CLAUDE_AUTORESUME_DIR"/*.json "$CLAUDE_AUTORESUME_DIR/watch.log"
sed -i '' 's/^AUTORESUME_RESUME=all/AUTORESUME_RESUME=latest/' "$CLAUDE_AUTORESUME_DIR/config.sh"
printf '%s' "$(payload old 100 $((NOW - 600)) 5 1900000000)" | sensor >/dev/null
printf '%s' "$(payload new 100 $((NOW - 300)) 5 1900000000)" | sensor >/dev/null
out=$("$SB/prefix/bin/claude-autoresume-watch" --dry-run 2>&1)
case "$out" in
    *"resuming 1 session"*) ok "only one session resumed" ;;
    *) bad "only one session resumed" "$out" ;;
esac
if grep -c held "$CLAUDE_AUTORESUME_DIR/watch.log" >/dev/null 2>&1; then
    ok "the held session is logged, not silently dropped"
else
    bad "held session logged"
fi

# -----------------------------------------------------------------------------
group "hygiene"
out=$("$SB/prefix/bin/claude-autoresume-arm" --list 2>&1)
case "$out" in
    *null*) bad "arm --list shows no null rows" "$out" ;;
    *) ok "arm --list shows no null rows" ;;
esac

# -----------------------------------------------------------------------------
group "re-install"
sh "$REPO/install.sh" >/dev/null 2>&1
w=$(sed -n "s/^AUTORESUME_WRAPPED=//p" "$CLAUDE_AUTORESUME_DIR/config.sh" | tr -d "'")
case "$w" in
    *claude-autoresume-sensor*) bad "re-install does not wrap itself" "wrapped=$w" ;;
    *sl.sh) ok "re-install does not wrap itself" ;;
    *) bad "re-install does not wrap itself" "wrapped=$w" ;;
esac

# -----------------------------------------------------------------------------
group "uninstall"
sh "$SB/prefix/uninstall.sh" >/dev/null 2>&1
jq -S . "$SB/before.json" >"$SB/a"
jq -S . "$SB/.claude/settings.json" >"$SB/b"
if diff "$SB/a" "$SB/b" >/dev/null; then
    ok "settings.json restored byte-for-byte (padding, hooks, refreshInterval)"
else
    bad "settings.json restored byte-for-byte" "$(diff "$SB/a" "$SB/b" | head -5)"
fi
if [ -d "$SB/prefix" ]; then bad "install prefix removed"; else ok "install prefix removed"; fi

# -----------------------------------------------------------------------------
rm -rf "$SB"
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
