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
NL='
'

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
    # Reads stdin and echoes something derived from it, so a sensor that fails to
    # pass the payload through is detectable. Emits an ANSI escape and a trailing
    # space too -- both were invisible to the previous comparison.
    # shellcheck disable=SC2016  # writing a script file; $() must stay literal
    printf '%s\n' '#!/bin/sh' \
        'printf "\033[32mORIGINAL\033[0m model=%s \\n" "$(jq -r ".model.display_name // \"NONE\"")"' \
        >"$SB/.claude/sl.sh"
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

# `timeout` is GNU coreutils. It is not on a stock macOS -- it was present on the
# author's machine via Homebrew and absent on the CI runner, so a test that
# depended on it passed locally and failed in CI. Run it in the background and
# kill it if it outlives the limit instead.
with_limit() {
    _lim=$1
    shift
    "$@" >"$SB/limited.out" 2>&1 &
    _p=$!
    (
        sleep "$_lim"
        kill -9 "$_p" 2>/dev/null
    ) >/dev/null 2>&1 &
    _k=$!
    if wait "$_p" 2>/dev/null; then _rc=0; else _rc=$?; fi
    kill -9 "$_k" 2>/dev/null || true
    cat "$SB/limited.out"
    return "$_rc"
}

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
    # cmp on real bytes. The previous `od -An -c | tr -d ' '` deleted every space
    # from od's own output, so "a b" and "ab" compared equal, as did "X" and "X ",
    # and ESC collided with the literal characters 0,3,3.
    printf '%s' "$p" | "$SB/.claude/sl.sh" >"$SB/want.bin" 2>/dev/null
    printf '%s' "$p" | sensor >"$SB/got.bin" 2>/dev/null
    if cmp -s "$SB/want.bin" "$SB/got.bin"; then
        ok "payload [$variant] passes through byte-identical"
    else
        bad "payload [$variant] passes through byte-identical" "$(cmp "$SB/want.bin" "$SB/got.bin" 2>&1 | head -1)"
    fi
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
: >"$CLAUDE_AUTORESUME_DIR/watch.log"
out=$("$SB/prefix/bin/claude-autoresume-watch" --dry-run 2>&1)
if grep -q '\[skip\]' "$CLAUDE_AUTORESUME_DIR/watch.log"; then
    ok "unavailable directory is skipped"
else
    bad "unavailable directory is skipped" "$(cat "$CLAUDE_AUTORESUME_DIR/watch.log")"
fi
# The "not counted" half: it must not appear in the spoken batch at all.
case "$out" in
    *"would announce"*) bad "skipped session is not counted in the announcement" "$out" ;;
    *) ok "skipped session is not counted in the announcement" ;;
esac

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
if grep -q '\[skipped\]' "$CLAUDE_AUTORESUME_DIR/watch.log"; then
    ok "the dropped session is logged, not silently discarded"
else
    bad "the dropped session is logged" "$(cat "$CLAUDE_AUTORESUME_DIR/watch.log")"
fi

# -----------------------------------------------------------------------------
group "fire-once"
# The watcher used to write into fired/ but never read it. An idle session makes
# no API call, so the sensor rewrites its state file 15s later with the same
# stale rate_limits and it re-arms -- the same session then resumed every 60s
# forever. These run for real (not --dry-run), with claude and the notifiers
# stubbed, because the bookkeeping only executes outside dry-run.
STUB="$SB/stub"
mkdir -p "$STUB"
for c in say osascript; do
    printf '#!/bin/sh\nexit 0\n' >"$STUB/$c"
    chmod +x "$STUB/$c"
done
printf '#!/bin/sh\necho "RESUMED $*" >> "%s/resumed.log"\n' "$SB" >"$STUB/fakeclaude"
chmod +x "$STUB/fakeclaude"
PATH="$STUB:$PATH"
export PATH
# Written into the sandbox config, not exported. common.sh sources config.sh and
# that file assigns these outright, so an exported value was silently ignored --
# which meant this group spawned the developer's REAL claude twice per run. CI
# never saw it because the runner has no claude installed.
sed -i '' "s|^AUTORESUME_TERMINAL=.*|AUTORESUME_TERMINAL=headless|" "$CLAUDE_AUTORESUME_DIR/config.sh"
if grep -q "^AUTORESUME_CLAUDE_BIN=" "$CLAUDE_AUTORESUME_DIR/config.sh"; then
    sed -i '' "s|^AUTORESUME_CLAUDE_BIN=.*|AUTORESUME_CLAUDE_BIN='$STUB/fakeclaude'|" "$CLAUDE_AUTORESUME_DIR/config.sh"
else
    printf "AUTORESUME_CLAUDE_BIN='%s'\n" "$STUB/fakeclaude" >>"$CLAUDE_AUTORESUME_DIR/config.sh"
fi
is "the stub claude is the one actually configured" \
    "$(zsh -c "CLAUDE_AUTORESUME_DIR='$CLAUDE_AUTORESUME_DIR' source '$REPO/lib/common.sh'; print -r -- \$AUTORESUME_CLAUDE_BIN")" \
    "$STUB/fakeclaude"

rm -f "$CLAUDE_AUTORESUME_DIR"/*.json "$CLAUDE_AUTORESUME_DIR"/fired/* "$CLAUDE_AUTORESUME_DIR/watch.log"
sed -i '' 's/^AUTORESUME_RESUME=latest/AUTORESUME_RESUME=all/' "$CLAUDE_AUTORESUME_DIR/config.sh"
NOW=$(date +%s)
printf '%s' "$(payload once 100 $((NOW - 300)) 5 1900000000)" | sensor >/dev/null
"$SB/prefix/bin/claude-autoresume-watch" >/dev/null 2>&1
first=$(grep -c '\[resume\]' "$CLAUDE_AUTORESUME_DIR/watch.log" 2>/dev/null || echo 0)
is "a due session resumes once" "$first" "1"

# The sensor re-arms it with the same stale reset, exactly as it would in life.
printf '%s' "$(payload once 100 $((NOW - 300)) 5 1900000000)" | sensor >/dev/null
"$SB/prefix/bin/claude-autoresume-watch" >/dev/null 2>&1
"$SB/prefix/bin/claude-autoresume-watch" >/dev/null 2>&1
again=$(grep -c '\[resume\]' "$CLAUDE_AUTORESUME_DIR/watch.log" 2>/dev/null || echo 0)
is "and does not resume again on later ticks" "$again" "1"

# A genuinely new window carries a different resets_at and must fire again.
printf '%s' "$(payload once 100 $((NOW - 100)) 5 1900000000)" | sensor >/dev/null
"$SB/prefix/bin/claude-autoresume-watch" >/dev/null 2>&1
newwin=$(grep -c '\[resume\]' "$CLAUDE_AUTORESUME_DIR/watch.log" 2>/dev/null || echo 0)
is "but a new reset window does fire" "$newwin" "2"

# An unrecorded resume repeats on every tick forever, so it must refuse to act at
# all when the mark cannot be written. mkdir -p succeeds on a directory that
# exists but is unwritable, so its status alone did not catch this.
rm -f "$CLAUDE_AUTORESUME_DIR"/*.json "$CLAUDE_AUTORESUME_DIR"/fired/* "$CLAUDE_AUTORESUME_DIR/watch.log"
NOW=$(date +%s)
printf '%s' "$(payload noperm 100 $((NOW - 300)) 5 1900000000)" | sensor >/dev/null
chmod 555 "$CLAUDE_AUTORESUME_DIR/fired"
"$SB/prefix/bin/claude-autoresume-watch" >/dev/null 2>&1
chmod 755 "$CLAUDE_AUTORESUME_DIR/fired"
if grep -q '\[abort\]' "$CLAUDE_AUTORESUME_DIR/watch.log"; then
    ok "refuses to resume when the fire mark cannot be written"
else
    bad "refuses to resume when the fire mark cannot be written" \
        "$(cat "$CLAUDE_AUTORESUME_DIR/watch.log" 2>/dev/null)"
fi

# -----------------------------------------------------------------------------
group "grace period"
rm -f "$CLAUDE_AUTORESUME_DIR"/*.json "$CLAUDE_AUTORESUME_DIR"/fired/* "$CLAUDE_AUTORESUME_DIR/watch.log"
NOW=$(date +%s)
printf '%s' "$(payload toosoon 100 $((NOW - 5)) 5 1900000000)" | sensor >/dev/null
out=$("$SB/prefix/bin/claude-autoresume-watch" --dry-run 2>&1)
case "$out" in
    *"would announce"*) bad "a reset 5s ago waits for the grace period" "$out" ;;
    *) ok "a reset 5s ago waits for the grace period" ;;
esac
rm -f "$CLAUDE_AUTORESUME_DIR"/*.json
printf '%s' "$(payload ready 100 $((NOW - 120)) 5 1900000000)" | sensor >/dev/null
out=$("$SB/prefix/bin/claude-autoresume-watch" --dry-run 2>&1)
case "$out" in
    *"would announce"*) ok "a reset 120s ago is past it" ;;
    *) bad "a reset 120s ago is past it" "$out" ;;
esac

# -----------------------------------------------------------------------------
group "permission mode replay"
rm -f "$CLAUDE_AUTORESUME_DIR"/*.json "$CLAUDE_AUTORESUME_DIR"/fired/* "$CLAUDE_AUTORESUME_DIR/watch.log"
TR="$SB/transcript.jsonl"
{
    printf '%s\n' '{"type":"permission-mode","permissionMode":"plan"}'
    printf '%s\n' '{"type":"permission-mode","permissionMode":"acceptEdits"}'
} >"$TR"
NOW=$(date +%s)
payload replay 100 $((NOW - 300)) 5 1900000000 |
    jq -c --arg t "$TR" '.transcript_path=$t' | sensor >/dev/null
# Force the quit-session route. The sensor stamps term_kind from the ambient
# shell, so run from iTerm this took the pane route -- which never reads a
# transcript -- and the assertion passed or failed by luck of where it ran.
jq -c '.term_kind="" | .term_ident=""' "$CLAUDE_AUTORESUME_DIR/replay.json" >"$SB/t" &&
    mv "$SB/t" "$CLAUDE_AUTORESUME_DIR/replay.json"
touch -t 200001010000 "$CLAUDE_AUTORESUME_DIR/replay.json"
"$SB/prefix/bin/claude-autoresume-watch" --dry-run >/dev/null 2>&1
if grep -q 'mode=acceptEdits' "$CLAUDE_AUTORESUME_DIR/watch.log"; then
    ok "resumes in the mode the session last recorded, not the first"
else
    bad "resumes in the last recorded mode" "$(grep '\[resume\]' "$CLAUDE_AUTORESUME_DIR/watch.log")"
fi

# -----------------------------------------------------------------------------
group "manual arm"
rm -f "$CLAUDE_AUTORESUME_DIR"/*.json "$CLAUDE_AUTORESUME_DIR"/manual/* "$CLAUDE_AUTORESUME_DIR"/fired/*
NOW=$(date +%s)
printf '%s' "$(payload marm 12 $((NOW + 9000)) 5 1900000000)" | sensor >/dev/null
ARM="$SB/prefix/bin/claude-autoresume-arm"

# zsh's `shift 2` with one argument left errors without shifting, which spun forever.
for flag in --session --in --at; do
    out=$(with_limit 5 "$ARM" "$flag") || true
    case "$out" in
        *"needs a value"*) ok "$flag with no value fails instead of hanging" ;;
        *) bad "$flag with no value fails instead of hanging" "$out" ;;
    esac
done

# With no --session, arm targets the most recent. The glob qualifier was (NOm),
# which is oldest-FIRST, so it silently armed the wrong session -- and made
# --disarm clear a stale one while the imminent resume went ahead.
printf '%s' "$(payload older 12 $((NOW + 9000)) 5 1900000000)" | sensor >/dev/null
sleep 1
printf '%s' "$(payload newer 12 $((NOW + 9000)) 5 1900000000)" | sensor >/dev/null
"$ARM" --in 1h >/dev/null 2>&1
if [ -f "$CLAUDE_AUTORESUME_DIR/manual/newer.json" ]; then
    ok "with no --session it targets the most recent, not the oldest"
else
    bad "with no --session it targets the most recent" \
        "armed: $(find "$CLAUDE_AUTORESUME_DIR/manual" -name '*.json' -exec basename {} \; 2>/dev/null | tr '\n' ' ')"
fi
rm -f "$CLAUDE_AUTORESUME_DIR"/manual/*.json \
    "$CLAUDE_AUTORESUME_DIR/older.json" "$CLAUDE_AUTORESUME_DIR/newer.json"

"$ARM" --session marm --in 2h30m >/dev/null 2>&1
is "--in parses hours and minutes" \
    "$(jq -r '.resets_at' "$CLAUDE_AUTORESUME_DIR/manual/marm.json" 2>/dev/null | awk -v n="$NOW" '{print int(($1-n)/60)}')" \
    "150"

# The whole reason manual arms live in their own directory.
printf '%s' "$(payload marm 12 $((NOW + 9000)) 5 1900000000)" | sensor >/dev/null
is "a manual arm survives the sensor rewriting its own state" \
    "$(jq -r .armed "$CLAUDE_AUTORESUME_DIR/manual/marm.json" 2>/dev/null)" "true"

"$ARM" --session marm --at 1700000000 >/dev/null 2>&1
is "--at takes an exact epoch" \
    "$(jq -r .resets_at "$CLAUDE_AUTORESUME_DIR/manual/marm.json" 2>/dev/null)" "1700000000"

"$ARM" --session marm --disarm >/dev/null 2>&1
if [ -f "$CLAUDE_AUTORESUME_DIR/manual/marm.json" ]; then
    bad "--disarm removes the manual arm"
else
    ok "--disarm removes the manual arm"
fi

# A sensor-armed session: --disarm must actually stop it firing, not just claim to.
rm -f "$CLAUDE_AUTORESUME_DIR"/*.json "$CLAUDE_AUTORESUME_DIR"/fired/* "$CLAUDE_AUTORESUME_DIR/watch.log"
printf '%s' "$(payload sarm 100 $((NOW - 300)) 5 1900000000)" | sensor >/dev/null
"$ARM" --session sarm --disarm >/dev/null 2>&1
out=$("$SB/prefix/bin/claude-autoresume-watch" --dry-run 2>&1)
case "$out" in
    *"would announce"*) bad "--disarm stops a sensor-armed session firing" "$out" ;;
    *) ok "--disarm stops a sensor-armed session firing" ;;
esac

# -----------------------------------------------------------------------------
group "kill switch"
rm -f "$CLAUDE_AUTORESUME_DIR"/*.json "$CLAUDE_AUTORESUME_DIR"/fired/*
printf '%s' "$(payload killsw 100 $((NOW - 300)) 5 1900000000)" | sensor >/dev/null
: >"$CLAUDE_AUTORESUME_DIR/DISABLED"
out=$("$SB/prefix/bin/claude-autoresume-watch" --dry-run 2>&1)
case "$out" in
    *"would announce"*) bad "DISABLED stops everything" "$out" ;;
    *) ok "DISABLED stops everything" ;;
esac
rm -f "$CLAUDE_AUTORESUME_DIR/DISABLED"

# -----------------------------------------------------------------------------
group "arming edge cases"
rm -f "$CLAUDE_AUTORESUME_DIR"/*.json
# A spent weekly window with no reset must not fall through and arm the 5-hour
# one -- that fires every five hours into a limit that has not moved.
payload nullwk 100 1700000000 100 1900000000 |
    jq -c '.rate_limits.seven_day.resets_at=null' | sensor >/dev/null
is "spent weekly with no reset does not arm the 5-hour window" \
    "$(state_of nullwk '.armed')" "false"

# Control characters are legal in a macOS path and illegal in a JSON string.
payload ctrl 12 1900000000 5 1900000000 |
    jq -c '.cwd="/tmp/we\tird\nname"' | sensor >/dev/null
if jq empty "$CLAUDE_AUTORESUME_DIR/ctrl.json" 2>/dev/null; then
    ok "a control character in cwd still yields valid JSON"
else
    bad "a control character in cwd still yields valid JSON"
fi

# -----------------------------------------------------------------------------
group "live-pane safety"
# A spent limit can leave a select menu on screen whose options include paid
# ones, and Enter takes whichever line is highlighted. Nothing may submit into a
# live pane unless the user has explicitly opted in.
# CLAUDE_AUTORESUME_CONFIG is pointed away from the sandbox on purpose: the
# installed config.sh assigns AUTORESUME_LIVE_PANE outright, and a config file
# is meant to win over the environment, so the env alone would not take here.
probe() {
    zsh -c "AUTORESUME_LIVE_PANE=$1
            CLAUDE_AUTORESUME_CONFIG=/nonexistent
            source '$REPO/lib/common.sh'
            source '$REPO/lib/terminals.sh'
            ar_send_live $2 some-ident 'continue' 2>/dev/null"
}
is "the default is prefill, not submit" \
    "$(zsh -c "unset AUTORESUME_LIVE_PANE; CLAUDE_AUTORESUME_CONFIG=/nonexistent source '$REPO/lib/common.sh'; print -r -- \$AUTORESUME_LIVE_PANE")" \
    "prefill"
is "notify mode touches nothing" "$(probe notify tmux)" "skipped"
is "Terminal.app cannot prefill, so it refuses rather than submitting blind" \
    "$(probe prefill apple_terminal)" "unsupported-prefill"

# -----------------------------------------------------------------------------
group "hygiene"
# Plant a file that is genuinely unparseable, which the previous version never did.
printf 'this is not json\n' >"$CLAUDE_AUTORESUME_DIR/broken.json"
out=$("$SB/prefix/bin/claude-autoresume-arm" --list 2>&1)
case "$out" in
    # Matches a null *session id*; plain "null" is also a legitimate percentage
    # for a session whose payload carried no rate_limits yet.
    "null  armed="* | *"${NL}null  armed="*) bad "arm --list skips an unparseable state file" "$out" ;;
    *) ok "arm --list skips an unparseable state file" ;;
esac
out=$("$SB/prefix/bin/claude-autoresume-status" 2>&1)
case "$out" in
    *"parameter not set"*) bad "status survives an unparseable state file" "$out" ;;
    *sessions*) ok "status survives an unparseable state file" ;;
    *) bad "status survives an unparseable state file" "$out" ;;
esac
rm -f "$CLAUDE_AUTORESUME_DIR/broken.json"

# -----------------------------------------------------------------------------
group "re-install"
sh "$REPO/install.sh" >/dev/null 2>&1
w=$(
    set +u
    # shellcheck source=/dev/null
    . "$CLAUDE_AUTORESUME_DIR/wrapped.sh" 2>/dev/null || true
    printf '%s' "${AUTORESUME_WRAPPED:-}"
)
case "$w" in
    *claude-autoresume-sensor*) bad "re-install does not wrap itself" "wrapped=$w" ;;
    *sl.sh) ok "re-install does not wrap itself" ;;
    *) bad "re-install does not wrap itself" "wrapped=$w" ;;
esac

# -----------------------------------------------------------------------------
group "uninstall"
sh "$SB/prefix/uninstall.sh" >/dev/null 2>&1
# cmp, because the README claims "byte-for-byte" and the previous jq -S compare
# would have passed a compact-JSON restore.
if cmp -s "$SB/before.json" "$SB/.claude/settings.json"; then
    ok "settings.json restored byte-for-byte (padding, hooks, refreshInterval)"
else
    bad "settings.json restored byte-for-byte" "$(diff "$SB/before.json" "$SB/.claude/settings.json" | head -5)"
fi
if [ -d "$SB/prefix" ]; then bad "install prefix removed"; else ok "install prefix removed"; fi

# -----------------------------------------------------------------------------
rm -rf "$SB"
printf '\n\033[1m%d passed, %d failed\033[0m\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
