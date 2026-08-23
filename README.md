# claude-autoresume

[![ci](https://github.com/agento-lab/claude-autoresume/actions/workflows/main.yml/badge.svg)](https://github.com/agento-lab/claude-autoresume/actions/workflows/main.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)](#requirements)

Pick your work back up the moment your Claude subscription limit resets.

When you hit the 5-hour or weekly cap, Claude Code stops and tells you when the window
rolls over. `claude-autoresume` waits for that moment, says so out loud, and continues the
sessions that were cut off — in the terminal panes they were already running in, or in
fresh windows if you had quit.

```
$ claude-autoresume-status
claude-autoresume
  service   loaded
  state     active
  resume    all  terminal=auto prompt="continue"

sessions
  ● api-server            in 1h12m  (five_hour, iterm, 5h 100% / 7d 61%)
  ○ docs-site             idle — 5h 12% / 7d 61% (tmux)
```

**Contents** — [How it works](#how-it-works) · [Requirements](#requirements) ·
[Install](#install) · [Commands](#commands) · [Configuration](#configuration) ·
[Terminals](#terminals) · [The usage-limit menu](#the-usage-limit-menu) ·
[Troubleshooting](#troubleshooting) · [Known limits](#known-limits) ·
[Uninstall](#uninstall) · [Contributing](#contributing)

---

## How it works

### The constraint everything follows from

Claude Code has **no rate-limit hook**. The hook events are `PreToolUse`, `PostToolUse`,
`Notification`, `UserPromptSubmit`, `Stop`, `SubagentStop`, `PreCompact`, `PostCompact`,
`SessionStart` and `SessionEnd` — nothing fires when a limit is hit. The reset time is not
written to disk anywhere either.

It is delivered to exactly one place: the JSON that Claude Code pipes to your **status line
command**, once per render.

```jsonc
{
  "session_id": "…",
  "transcript_path": "…",
  "workspace": { "current_dir": "…" },
  "rate_limits": {
    "five_hour": { "used_percentage": 100, "resets_at": 1787030000 },  // epoch seconds
    "seven_day": { "used_percentage": 61,  "resets_at": 1787460000 }
  }
}
```

So to know when a limit resets, you have to sit in that pipe. That single fact shapes the
whole design.

### The three pieces

```
status line payload ─► sensor ─┬─► ~/.claude/autoresume/<session>.json
   (every render, and          └─► your original status line ─► your terminal
    every 15s while idle)

               launchd, every 60s ─► watch ─► has resets_at passed?
                                                 │
                                   say + notification, then:
                                   session still open ─► type into its own pane
                                   session was quit   ─► new window, claude --resume
```

**1. The sensor** (`bin/claude-autoresume-sensor`) is a status line wrapper. Install points
`statusLine.command` at it; it records what it sees, then runs **whatever command was
configured before** and prints that output unchanged. Your status line keeps working — it
just has a passenger. Install also lowers `refreshInterval` to 15 if it is absent or higher, so the state stays
fresh while a session sits idle; a shorter interval you already set is left alone.

Per render it writes one file per session:

```jsonc
{
  "session_id": "…",  "cwd": "…",  "transcript_path": "…",
  "term_kind": "iterm",            // iterm | apple_terminal | tmux
  "term_ident": "A9F27D6A-…",      // pane GUID, tmux pane id, or tty
  "five_hour": { "used_percentage": 100, "resets_at": 1787030000 },
  "seven_day": { "used_percentage": 61,  "resets_at": 1787460000 },
  "armed": true, "armed_window": "five_hour", "resets_at": 1787030000,
  "updated_at": 1787012000
}
```

The file is rewritten in full every render, which is why a window that rolls over while the
session is open disarms itself with no extra bookkeeping.

**2. The watcher** (`bin/claude-autoresume-watch`) runs once a minute and acts on anything
whose `resets_at` passed at least `AUTORESUME_GRACE` seconds ago (60 by default, to clear the
boundary). Acting on a session is recorded against that specific reset, so it cannot fire
twice for the same window — without that it would re-fire every minute forever, since an idle
session makes no API call and its `rate_limits` payload never refreshes.

**3. The clock** is a launchd agent, `com.claude-autoresume`, on a 60-second
`StartInterval`. launchd re-runs a missed interval job on wake, which is what makes
"resume however late" work without scheduling a hardware wake.

### Decisions worth knowing

**An exhausted weekly quota arms on the weekly reset.** If both windows are spent, arming
on the 5-hour one would fire uselessly every five hours into a limit that has not moved. So
the binding window wins, even when that means waiting days.

**Still-open and quit sessions are told apart by file mtime.** The sensor refreshes every
15 s, so a state file older than 90 s means Claude is gone. A live session is resumed in the
pane it already owns rather than by starting a second process against the same session file.

**The permission mode is replayed, not guessed.** Transcripts record
`{"type":"permission-mode","permissionMode":"plan"}`. The watcher reads the last one back
and passes it to `claude --resume`, so the session returns in the mode it stopped in. An
unrecognised value falls back to your `settings.json` rather than failing the resume.

**Manual arms live in their own directory.** The sensor rewrites its own state file every
15 s, so a hand-armed session written there would be un-armed within seconds.
`claude-autoresume-arm` writes to `autoresume/manual/` instead, which the sensor never
touches; the watcher reads both and de-duplicates.

**Nothing submits blind into a live pane.** See [the usage-limit
menu](#the-usage-limit-menu) — this one is a safety property, not a preference.

---

## Requirements

| | |
|---|---|
| **macOS** | launchd, `osascript`, BSD `stat -f` / `date -r` / `sed -i ''`. The installer exits with a clear message elsewhere |
| **`jq`** | `brew install jq` — required at runtime, not just to install |
| **`zsh`** | ships with macOS |
| **`claude`** | on your `PATH`; a warning, not a failure, if missing |

---

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/agento-lab/claude-autoresume/main/install.sh | sh
```

Or from a checkout:

```sh
git clone https://github.com/agento-lab/claude-autoresume
cd claude-autoresume && ./install.sh
```

**Restart Claude Code afterwards** so it picks up the new status line. Then check it:

```sh
claude-autoresume-status     # expect: service loaded / state active
```

Re-running the installer is safe. It will not wrap itself, and it keeps whatever status line
command it took over the first time.

### What it touches

A `curl | sh` install should say exactly what it does. This one:

| Path | What happens |
|---|---|
| `~/.local/share/claude-autoresume/` | the code |
| `~/.local/bin/claude-autoresume-*` | symlinks to the three commands |
| `~/.claude/settings.json` | `statusLine.command` → the sensor; `refreshInterval` lowered to 15 only if absent or higher. Copied to `settings.json.autoresume-backup.<timestamp>` first — **these accumulate and are never cleaned up**, not even by `--purge` — and the original `statusLine` object is snapshotted so uninstall restores it exactly |
| `~/.claude/autoresume/` | state files, `config.sh`, `wrapped.sh`, `watch.log`, plus `manual/`, `fired/`, `backup/statusline.json`, launchd's stdout/stderr logs and any `headless-<session>.log` |
| `~/Library/LaunchAgents/com.claude-autoresume.plist` | the 60-second timer |

Nothing else is modified, and there are no network calls after install.

If `~/.local/bin` is not on your `PATH`, the installer says so — add
`export PATH="$HOME/.local/bin:$PATH"` to your shell profile.

---

## Commands

```sh
claude-autoresume-status              # what's armed, when it fires, recent resumes
claude-autoresume-arm --in 2h30m      # arm by hand
claude-autoresume-arm --at 1787030000 # ... at an exact epoch second
claude-autoresume-arm --session <id>  # target a specific session
claude-autoresume-arm --list          # what the sensor has recorded
claude-autoresume-arm --disarm        # stop a session firing this window
touch ~/.claude/autoresume/DISABLED   # off, without uninstalling
```

Use `claude-autoresume-arm` when the sensor misses — for instance if your window tops out
fractionally under 100%.

`--list` reads the sensor's own state files, so a hand-armed session does not appear there;
`claude-autoresume-status` shows both. `--disarm` removes a manual arm *and* records the
current window as already handled, which is what actually stops a sensor-armed session
firing — the sensor rewrites its own state every 15 s, so deleting anything there would be
undone within seconds. A genuinely new window arms again as normal.

---

## Configuration

`~/.claude/autoresume/config.sh` — a plain shell file, sourced by every command. It is a
config file, so **its values take precedence over the environment**: exporting
`AUTORESUME_TERMINAL` will not override a line that assigns it. Edit the file, or point
`CLAUDE_AUTORESUME_CONFIG` elsewhere.

| Setting | Default | Notes |
|---|---|---|
| `AUTORESUME_RESUME` | `all` | `all` resumes every cut-off session; `latest` resumes only the most recent and drops the rest for that window (logged; arm them by hand to run them) |
| `AUTORESUME_TERMINAL` | `auto` | `auto` reuses whichever terminal the session was in. Or force `iterm`, `terminal`, `tmux`, `headless` |
| `AUTORESUME_LIVE_PANE` | `prefill` | For a session still open: `prefill` types the prompt without submitting, `type` submits it, `notify` leaves the pane alone. See [below](#the-usage-limit-menu) |
| `AUTORESUME_PROMPT` | `continue` | what gets sent |
| `AUTORESUME_ARM_PCT` | `100` | the % that counts as spent. Lower it if your window tops out just under |
| `AUTORESUME_CLAUDE_BIN` | `claude` | the executable to resume with |
| `AUTORESUME_GRACE` | `60` | seconds to wait past `resets_at` before acting |
| `AUTORESUME_FRESH` | `90` | a state file younger than this means the session is still open |
| `AUTORESUME_WRAPPED` | *(set by install)* | the status line command being passed through. Lives in `wrapped.sh`, not `config.sh` — it is arbitrary shell and may span lines, so it is regenerated whole rather than edited in place |

---

## Terminals

| Terminal | Resume in place | New window | Tested |
|---|---|---|---|
| iTerm2 | ✅ | ✅ | ✅ |
| Terminal.app | ⚠️ see below | ✅ | ✅ |
| tmux | ✅ | ✅ | ⚠️ written, not yet verified |
| anything else | — | headless fallback | ⚠️ written, not yet verified |

The headless fallback runs `claude --resume … -p "continue"` in the background, logging to
`~/.claude/autoresume/headless-<session>.log`. It works anywhere, but nothing can answer a
permission prompt, so it stalls if one appears.

---

## The usage-limit menu

A spent limit does not always leave the session at a prompt. Claude Code often puts up a
menu — internally `rate_limit_options_menu`:

```
What do you want to do?
  Upgrade your plan
  Add funds to continue with usage credits
  Stop and wait for limit to reset
```

That is a select list. Typed letters are ignored and **Enter takes whichever line is
highlighted** — so blindly submitting `continue` into it would choose one at random, and two
of the three cost money. If you walked away when the limit hit, this menu is exactly what is
on screen hours later when the window resets.

Two defences were tried and both failed, so neither is in the code:

- **Detect the menu first.** iTerm's `contents` returns the whole scrollback, not the visible
  screen, so a menu that appeared once and was answered still matches forever — the session
  would be locked out of ever resuming.
- **Send Escape ahead of the text.** iTerm merges it with whatever follows, even across
  separate `osascript` calls seconds apart, and `ESC`+`c` is then read as Meta-c, which eats
  the first character: `continue` arrives as `ontinue`.

What survives is that the dangerous act is specifically **Enter**. So for a session that is
still open, the default types the prompt and stops there — inert against a menu, one keypress
from running at a prompt. You get a spoken alert and a notification saying so, and by the
time you press Enter you are looking at the screen and can see which of the two it is.

**Sessions you had quit stay fully automatic**, since a fresh `claude --resume` in a new
window never has that menu up. Set `AUTORESUME_LIVE_PANE=type` for full automation of open
sessions too, accepting the risk above. Terminal.app cannot type without submitting at all
(`do script` always appends a return), so it refuses rather than guessing.

---

## Troubleshooting

**Nothing happens when the limit resets.** Check `claude-autoresume-status` — if the service
is not loaded, `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.claude-autoresume.plist`.
Then read `~/.claude/autoresume/watch.log`.

**No sessions listed.** The sensor only writes once Claude Code renders a status line with
`rate_limits` present, which needs one API response. Start a session and send a message.

**It never arms.** Your window may top out just under 100%. Watch the percentages in
`claude-autoresume-status`, then lower `AUTORESUME_ARM_PCT`, or arm by hand.

**My status line disappeared.** Something replaced `statusLine.command` — running
`/statusline` does this. Re-run the installer to re-wrap.

**It resumed but nothing ran.** With the default `prefill`, a still-open session gets the
text without the Enter. That is deliberate; press Enter.

---

## Known limits

- **macOS only.** launchd, `osascript`, `say` and BSD `stat`/`date`. The platform-specific
  pieces are isolated in `lib/`, so a systemd + `notify-send` port is a contained change.
- **Changing your status line later removes the sensor.** Re-run the installer to re-wrap.
- **A resumed session spends your fresh quota while you are away.** `AUTORESUME_RESUME=latest`
  and the `DISABLED` switch exist for this.
- **A spent weekly limit cannot be hurried.** It will correctly wait days, and tell you which
  window it is waiting on.
- **Sleep.** launchd re-runs a missed check on wake, so a Mac asleep through the reset catches
  up when you open the lid. No hardware wake is scheduled.

---

## Uninstall

```sh
~/.local/share/claude-autoresume/uninstall.sh           # keeps recorded state
~/.local/share/claude-autoresume/uninstall.sh --purge   # removes it too
```

Your `settings.json` is restored to exactly what it was — padding, hooks and
`refreshInterval` included — from the snapshot taken at install. An install → uninstall round
trip is asserted byte-for-byte by the test suite.

---

## Contributing

Issues and pull requests are welcome. The tmux and headless paths in particular are written
but unverified — reports from anyone running those are useful.

### Getting set up

```sh
git clone https://github.com/agento-lab/claude-autoresume
cd claude-autoresume
make setup     # prerequisites + asdf tools + bun install + git hooks
make dev       # install live from this checkout
```

`make dev` points the launchd agent and your status line at the working copy, so edits take
effect immediately — don't move or delete the checkout while it is active. `make install`
does a normal copy instead.

```sh
make ci        # everything CI runs: lint, security, test
make test      # integration suite, in a throwaway HOME
make lint      # shellcheck + shfmt on sh, zsh -n on zsh
make lint-fix  # apply formatting
make help      # everything else
```

Toolchain versions are pinned in `.tool-versions` (bun, shellcheck, shfmt) and installed by
`make setup` via asdf.

### Layout

```
bin/     the four shipped commands: sensor, watch, arm, status
lib/     common.sh (config, helpers) and terminals.sh (per-terminal adapters)
share/   the launchd plist template
scripts/ lint.sh — the one entry point for make, CI and lint-staged
test/    run.sh — the integration suite
```

Anything macOS- or terminal-specific belongs in `lib/`, which is what would make a Linux port
a contained change.

### The repo is two shells

| | language | checked with |
|---|---|---|
| `bin/*`, `lib/*.sh` | zsh — `${(@f)}`, `(N)` glob qualifiers, `${arr[(I)x]}` | `zsh -n` |
| `install.sh`, `scripts/`, `test/` | POSIX sh, so `curl \| sh` works anywhere | shellcheck + shfmt |

Neither shellcheck nor shfmt supports zsh, so pointing them at `bin/` produces only false
positives. `scripts/lint.sh` routes each file by its **shebang**, not its extension.

`zsh -n` is a real parse and it earns its place — this project has shipped a `(#b)`
backreference that silently matched nothing because `extendedglob` was off, and a `print`
call that ate its own message as a flag.

One repo-specific trap: two bugs here came from `set -o pipefail` plus `grep -q`. grep exits
on the first match, the writer takes SIGPIPE, and the pipeline reports 141 — so a successful
check reads as a failure. If you find yourself writing `cmd | grep -q`, don't.

### Tests

`test/run.sh` is not unit tests. It installs into a throwaway `HOME`, drives the real sensor
and watcher, and uninstalls again, asserting `settings.json` comes back byte-for-byte. It is
scoped by `CLAUDE_CONFIG_DIR`, `CLAUDE_AUTORESUME_DIR`, `CLAUDE_AUTORESUME_PREFIX` and
`CLAUDE_AUTORESUME_BINDIR`, and sets `CLAUDE_AUTORESUME_NO_SERVICE=1` so neither install nor
uninstall touches launchd. That last part is load-bearing: `uninstall.sh` used to ignore the
flag, and because launchctl cannot be redirected by a fake `HOME`, every `make test` run
silently unloaded and deleted the developer's own agent.

Anything that opens a window or speaks runs under `--dry-run`.

### Commits and PRs

Work on a branch — a `pre-commit` hook refuses direct commits to `main`. That is not just
hygiene: `auto` builds the changelog from what lands on `main`, so going through a PR is what
gives a release something to cite.

[Conventional Commits](https://www.conventionalcommits.org), enforced by a `commit-msg` hook
running `commitlint --strict`:

```
fix(watch): stop grep -q reporting SIGPIPE as a missing service
```

Warnings fail, deliberately. A `footer-leading-blank` warning means the parser stopped
reading your body as prose — usually because a line wrapped so it *begins* with a
colon-word — and trailers after that point can be dropped.

Hooks run `lint-staged` before each commit and the full suite before each push.

### CI and releases

Every merge to `main` runs `.github/workflows/main.yml`:

```
push to main ─┬─► lint   (shellcheck + shfmt + zsh -n, commit messages)
              ├─► test   (integration suite, macOS runner)
              ├─► scan   (dependency advisories, installer sanity)
              │
              └─ all three must pass ─► release  (auto shipit — tag, release, CHANGELOG)
```

`lint`, `test` and `scan` also run on their own for pull requests.

`test` is on a macOS runner and cannot move. `scan` reports every dependency advisory but
only **high and critical** fail the build — every dependency here is dev-only release
tooling, nothing ships to users, and gating on a moderate advisory inside `auto` would
deadlock releases. It also asserts the installer carries no unresolved repo placeholder and
that every shipped script is executable, either of which would silently break `curl | sh`
while every other check passed.

Versioning is [`auto`](https://intuit.github.io/auto/) with the `conventional-commits` and
`git-tag` plugins, so the bump comes from commit types — no release labels to maintain.
`feat:` is a minor, `fix:` a patch, `BREAKING CHANGE` a major, and everything else (`ci:`,
`docs:`, `chore:`) ships nothing. A tooling-only merge therefore ends with
`Calculated version bump: none`, which is correct rather than a failure.

Releases need a `GH_ACTIONS_WRITE` secret with repo write access, inherited from the
organisation.

---

## License

MIT — see [LICENSE](LICENSE).
