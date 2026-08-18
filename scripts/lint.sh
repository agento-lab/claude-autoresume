#!/bin/sh
#
# scripts/lint.sh [--fix] [files...]
#
# One entry point for `make lint`, `make fmt` and lint-staged.
#
# The repo is two languages wearing the same extension:
#
#   bin/*, lib/*.sh      zsh  -- uses ${(@f)}, (N) glob qualifiers, ${arr[(I)x]}
#   install.sh, scripts/ POSIX sh -- so `curl | sh` works on any machine
#
# Neither of those tools supports zsh at all, so running them over bin/
# would produce nothing but false positives. zsh files get `zsh -n` instead,
# which is a real parse and catches the class of error that actually bites here
# (this project has shipped two: an unset `extendedglob` backreference, and a
# `print` flag collision). Files are classified by shebang, not by extension.
#
set -eu

FIX=0
if [ "${1:-}" = "--fix" ]; then
    FIX=1
    shift
fi

cd "$(dirname "$0")/.." || exit 1

# Globbed rather than listed with `ls`: an unmatched glob makes ls exit
# non-zero, and under `set -e` that killed the script before it checked
# anything. Unmatched globs stay literal in sh, so -f filters them out.
if [ "$#" -gt 0 ]; then
    TARGETS="$*"
else
    TARGETS=""
    for f in install.sh uninstall.sh scripts/*.sh test/*.sh lib/*.sh bin/*; do
        [ -f "$f" ] && TARGETS="$TARGETS $f"
    done
fi

fails=0
checked=0

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }

for f in $TARGETS; do
    [ -f "$f" ] || continue
    case "$f" in
        *.json)
            checked=$((checked + 1))
            jq empty "$f" >/dev/null 2>&1 || {
                red "invalid JSON: $f"
                fails=$((fails + 1))
            }
            continue
            ;;
        *.md | *.yml | *.yaml | *.plist | *.template) continue ;;
    esac

    # case on the shebang, not `head | grep -q`: that pipeline is exactly the
    # SIGPIPE trap that made the service check misreport earlier in this repo.
    case "$(head -n 1 "$f")" in
        *zsh*) kind="zsh" ;;
        *) kind="sh" ;;
    esac
    checked=$((checked + 1))

    if [ "$kind" = "zsh" ]; then
        zsh -n "$f" || {
            red "zsh parse failed: $f"
            fails=$((fails + 1))
        }
    else
        shellcheck -s sh "$f" || fails=$((fails + 1))
        if [ "$FIX" = "1" ]; then
            shfmt -w -i 4 -ci "$f"
        else
            shfmt -d -i 4 -ci "$f" || {
                red "needs formatting: $f (run make fmt)"
                fails=$((fails + 1))
            }
        fi
    fi
done

dim "checked $checked file(s)"
if [ "$fails" -gt 0 ]; then
    red "$fails problem(s)"
    exit 1
fi
green "clean"
