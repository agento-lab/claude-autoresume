#!/bin/sh
#
# scripts/lint.sh [--fix] [files...]
#
# One entry point for `make lint`, `make lint-fix` and lint-staged.
#
# The repo is two languages wearing the same extension:
#
#   bin/*, lib/*.sh      zsh -- uses ${(@f)}, (N) glob qualifiers, ${arr[(I)x]}
#   install.sh, scripts/ POSIX sh -- so `curl | sh` works on any machine
#
# Neither of those tools supports zsh, so running them over bin/ would produce
# nothing but false positives. zsh files get `zsh -n` instead, which is a real
# parse and catches the class of error that actually bites here (this project has
# shipped an unset `extendedglob` backreference, and a `print` flag collision).
# Files are classified by shebang, not by extension.
#
set -eu

FIX=0
if [ "${1:-}" = "--fix" ]; then
    FIX=1
    shift
fi

cd "$(dirname "$0")/.." || exit 1

fails=0
checked=0

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim() { printf '\033[2m%s\033[0m\n' "$*"; }

lint_one() {
    f=$1
    [ -f "$f" ] || return 0
    case "$f" in
        *.json)
            checked=$((checked + 1))
            jq empty "$f" >/dev/null 2>&1 || {
                red "invalid JSON: $f"
                fails=$((fails + 1))
            }
            return 0
            ;;
        *.md | *.yml | *.yaml | *.plist | *.template) return 0 ;;
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
                red "needs formatting: $f (run make lint-fix)"
                fails=$((fails + 1))
            }
        fi
    fi
}

# Iterated positionally. Collecting into one string and re-splitting turned
# "my script.sh" into two tokens that both failed -f and were skipped without
# incrementing the count, so lint reported "clean" having checked nothing.
if [ "$#" -gt 0 ]; then
    for f in "$@"; do lint_one "$f"; done
else
    # Unmatched globs stay literal in sh, and lint_one's -f test drops them.
    for f in install.sh uninstall.sh scripts/*.sh test/*.sh lib/*.sh bin/* .husky/*; do
        lint_one "$f"
    done
fi

dim "checked $checked file(s)"
if [ "$fails" -gt 0 ]; then
    red "$fails problem(s)"
    exit 1
fi
green "clean"
