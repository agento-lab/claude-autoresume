# claude-autoresume

Pick your work back up the moment your Claude subscription limit resets.

When you hit the 5-hour or weekly cap, Claude Code stops and tells you when the window
rolls over. `claude-autoresume` waits for that moment, says so out loud, and continues the
sessions that were cut off — in the terminal panes they were already running in, or in fresh
windows if you'd quit.

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

## How it works

There is **no rate-limit hook** in Claude Code, and the reset time is written nowhere on
disk. It is delivered to exactly one place: the JSON that Claude Code pipes to your
**status line command**, as `rate_limits.five_hour.resets_at` (a Unix epoch second).

So this tool sits in that pipe. On install it points `statusLine.command` at its own sensor,
which records what it sees and then runs **whatever your status line was before**, printing
that output unchanged. Your status line keeps working exactly as it did; it just has a
passenger now.

```
status line payload ─► sensor ─┬─► ~/.claude/autoresume/<session>.json
                               └─► your original status line ─► your terminal

                    launchd (every 60s) ─► watch ─► reset reached?
                                                      │
                                        say + notification, then:
                                        pane still alive ─► type "continue" into it
                                        pane gone        ─► new window, claude --resume
```

Two details that matter:

- **It resumes with the permission mode the session was actually in.** That is read back from
  the session transcript, which records `{"type":"permission-mode","permissionMode":"..."}`.
- **If your weekly limit is the one that's spent, it waits for the weekly reset** — not the
  5-hour one, which would fire uselessly every five hours into a limit that hasn't moved.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/agento-lab/claude-autoresume/main/install.sh | sh
```

Or from a checkout:

```sh
git clone https://github.com/agento-lab/claude-autoresume && cd claude-autoresume && ./install.sh
```

Restart Claude Code afterwards so the new status line takes effect.

Requires macOS, `jq` (`brew install jq`), and zsh. Re-running the installer is safe.

### What it touches

A `curl | sh` install should tell you exactly what it does. This one:

| Path | What happens |
|---|---|
| `~/.local/share/claude-autoresume/` | the code |
| `~/.local/bin/claude-autoresume-*` | symlinks to the three commands |
| `~/.claude/settings.json` | `statusLine.command` → the sensor; `refreshInterval` → 15. **Backed up first**, and the original object is snapshotted so uninstall restores it exactly |
| `~/.claude/autoresume/` | recorded state, config, log |
| `~/Library/LaunchAgents/com.claude-autoresume.plist` | the 60-second timer |

Nothing else is modified. No network calls after install.

## Commands

```sh
claude-autoresume-status              # what's armed, when it fires, recent resumes
claude-autoresume-arm --in 2h30m      # arm by hand
claude-autoresume-arm --list          # everything the sensor has recorded
claude-autoresume-arm --disarm
touch ~/.claude/autoresume/DISABLED   # off, without uninstalling
```

## Configuration

`~/.claude/autoresume/config.sh` — a plain shell file, sourced by every command.

| Setting | Default | Notes |
|---|---|---|
| `AUTORESUME_RESUME` | `all` | `all` resumes every cut-off session; `latest` resumes only the most recent and leaves the rest armed |
| `AUTORESUME_TERMINAL` | `auto` | `auto` reuses whichever terminal the session was in. Or force `iterm`, `terminal`, `tmux`, `headless` |
| `AUTORESUME_PROMPT` | `continue` | what gets sent |
| `AUTORESUME_ARM_PCT` | `100` | the % that counts as spent. Lower it if your window tops out just under 100 |
| `AUTORESUME_WRAPPED` | *(set by install)* | the status line command being passed through |

## Terminals

| Terminal | Resume in place | New window | Tested |
|---|---|---|---|
| iTerm2 | ✅ | ✅ | ✅ |
| Terminal.app | ✅ | ✅ | ✅ |
| tmux | ✅ | ✅ | ⚠️ written, not yet verified |
| anything else | — | headless fallback | ⚠️ written, not yet verified |

The headless fallback runs `claude --resume ... -p "continue"` in the background and logs to
`~/.claude/autoresume/headless-<session>.log`. It works anywhere, but nothing can answer a
permission prompt, so it will stall if one appears.

## Known limits

- **macOS only.** launchd, `osascript`, `say` and BSD `stat`/`date`. The platform-specific
  pieces are isolated in `lib/`, so a systemd + `notify-send` port is a contained change.
- **Changing your status line later removes the sensor.** If you run `/statusline` or edit
  `statusLine.command` by hand, you'll overwrite the wrapper. Re-run the installer to
  re-wrap.
- **A resumed session spends your fresh quota while you're away.** `AUTORESUME_RESUME=latest`
  and the `DISABLED` switch exist for this.
- **A spent weekly limit can't be hurried.** It will correctly wait days, and tell you which
  window it's waiting on.
- **Sleep.** launchd re-runs a missed check on wake, so a Mac asleep through the reset catches
  up when you open the lid. No hardware wake is scheduled.

## Uninstall

```sh
~/.local/share/claude-autoresume/uninstall.sh           # keeps recorded state
~/.local/share/claude-autoresume/uninstall.sh --purge   # removes it too
```

Your `settings.json` is restored to exactly what it was, verified byte-for-byte by an
install → uninstall round trip test.

## Development

```sh
make setup   # asdf tools (bun, shellcheck, shfmt) + bun install + git hooks
make dev     # install live from this checkout — edits take effect immediately
make test    # full install/uninstall suite in a throwaway HOME
make lint    # shellcheck + shfmt on sh, zsh -n on zsh
make fmt     # apply formatting
make help    # everything else
```

`make dev` points the launchd agent and your status line at the working copy, so
don't move or delete the checkout while it's active. `make install` does a normal copy.

### A note on linting two shells

The repo is two languages sharing one extension:

| | language | checked with |
|---|---|---|
| `bin/*`, `lib/*.sh` | zsh — `${(@f)}`, `(N)` glob qualifiers, `${arr[(I)x]}` | `zsh -n` |
| `install.sh`, `scripts/`, `test/` | POSIX sh, so `curl \| sh` works anywhere | shellcheck + shfmt |

Neither shellcheck nor shfmt supports zsh, so pointing them at `bin/` produces only
false positives. `scripts/lint.sh` routes each file by its **shebang**, not its
extension. `zsh -n` is a real parse, and it earns its place: this project has shipped
a `(#b)` backreference that silently matched nothing because `extendedglob` was off,
and a `print` call that ate its own message as a flag.

Two bugs here came from `set -o pipefail` plus `grep -q` — grep exits on the first
match, the writer takes SIGPIPE, and the pipeline reports 141. If you find yourself
writing `cmd | grep -q`, don't.

### CI and releases

Every merge to `main` runs `.github/workflows/main.yml`, which fans out to reusable
workflows and ends in a release:

```
push to main ─┬─► lint   (shellcheck + shfmt + zsh -n, commit messages)
              ├─► test   (full install/uninstall suite, macOS runner)
              └─► scan   (dependency advisories, installer sanity)
                      └─► release  (auto shipit — tag + GitHub release + CHANGELOG)
```

Each of `lint`, `test` and `scan` also runs on its own for pull requests.

`test` is on a macOS runner and cannot move: the code under test uses launchd,
osascript, BSD `stat -f` / `date -r` and `sed -i ''`. The others run on Ubuntu.

`scan` checks two things that nothing else would catch. Dependency advisories are
reported in full but only **high and critical** fail the build — every dependency
here is dev-only release tooling, nothing ships to users, and gating on a moderate
advisory inside `auto` would deadlock releases. It also asserts the installer has no
unresolved repo placeholder and that every shipped script is executable, either of
which would silently break `curl | sh` for new users while every other check passed.

Versioning is [`auto`](https://intuit.github.io/auto/) with the `conventional-commits`
and `git-tag` plugins, so the version comes from commit types. Releases need a
`GH_ACTIONS_WRITE` secret with write access, and the repo needs `auto`'s labels once:

```sh
GH_TOKEN=$(gh auth token) bunx auto create-labels
```

### Commits

[Conventional Commits](https://www.conventionalcommits.org), enforced by a
`commit-msg` hook. Scopes: `sensor`, `watch`, `arm`, `status`, `install`,
`terminals`, `lint`, `test`, `ci`, `docs`, `deps`.

```
fix(watch): stop grep -q reporting SIGPIPE as a missing service
```

## License

MIT
