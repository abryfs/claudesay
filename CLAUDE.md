# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Read [AGENTS.md](AGENTS.md) first.** It is the operational contract for installing and running claudesay (install flags, mute commands, the "when it isn't speaking" checklist). This file covers the parts you only need when *changing* the code.

## Commands

```bash
./tests.sh                              # 56 tests, ~30s, silent by design
./tests.sh -v                           # show each test's output
shellcheck -S warning claudesay.sh install.sh uninstall.sh tests.sh
bash -n claudesay.sh                    # what CI syntax-checks (all four scripts)

# Fire the hook by hand against your real transcript — prints every decision
LATEST=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
echo "{\"transcript_path\":\"$LATEST\",\"session_id\":\"dev\",\"stop_hook_active\":false}" \
  | CLAUDESAY_DEBUG=1 bash claudesay.sh
```

`tests.sh` has **no filter argument** — `-v` is the only flag. To run one test, call its function after the helpers (`fire_hook`, `mk_jsonl`) are in scope, or comment out `run` lines at the bottom. The full suite is 30s; usually just run it.

`CLAUDESAY_AUDIBLE_TESTS=1 ./tests.sh` lets the suite use the speakers. **Never do this unless the user explicitly asks** — an early version talked over a live meeting, which is why silent is the default.

Releases bump `CLAUDESAY_VERSION` in **both** `claudesay.sh:40` and `install.sh:7`, then update `CHANGELOG.md` and tag. Nothing asserts the two constants match — the tests only check that each reports *some* version, so a half-done bump ships green.

## What ships where

Four files land in `~/.claude/hooks/`, installed by `install.sh`:

| Source | Installed as | Role |
|---|---|---|
| `claudesay.sh` | `claudesay.sh` | the Stop hook — all decision logic |
| `claudesay-mic.py` | `claudesay-mic.py` | CoreAudio probe via `ctypes`, stdlib only |
| `claudesay-voice.py` | `claudesay-voice.py` | Kokoro HTTP server, run under `uv` |
| `claudesay-hotkey.swift` | `claudesay-hotkey` (compiled) | ⌥M global mute, a LaunchAgent |

The installer also writes `~/Library/LaunchAgents/com.claudesay.hotkey.plist` and rewrites the `Stop` block in `~/.claude/settings.json`. `uninstall.sh` reverses all of it.

## Hook flow

`Stop` fires on every turn. The hook reads the payload on stdin, and the order of checks is deliberate — cheapest and most-likely-to-skip first, so the common case exits in milliseconds:

```
stdin {transcript_path, session_id, stop_hook_active}
  │
  ├─ stop_hook_active ──────────► exit (loop guard)
  ├─ mute file / CLAUDESAY_DISABLE ► exit
  ├─ mic_is_hot() ─────────────► exit (8s cached; fails OPEN — unknown means speak)
  ├─ debounce (per-session .last) ► exit
  ├─ last text-bearing assistant message from the .jsonl transcript
  ├─ strip_code(): code spans become "the file" / "that command" / …
  ├─ shorter than CLAUDESAY_MIN_LEN ► exit
  ├─ filler heuristic (<120 chars, opens with "Let me"/"I'll"/…) ► exit
  ├─ md5 dedupe vs .hash ──────► exit
  ├─ last sentence ≥15 chars → strip markdown/ANSI → truncate to CLAUDESAY_MAX
  ├─ barge-in: kill this session's player, then its queued job
  └─ speak() → play_queued() behind a machine-wide lock
```

Everything downstream of the transcript read is in the bottom third of `claudesay.sh`, as straight-line script rather than functions.

**`strip_code()` runs before the length, filler and dedupe checks, not after.** Those three all ask questions about what you are going to hear, so they should see the string you will actually hear. The cost is that dedupe now collapses two replies differing only in a filename — correct, since they sound identical. Its classifier is a table of shapes (`CMDS`, `EXTS`, `ARTS`, `NOUNS` in the `BEGIN` block); extending it means adding to a list, not adding a branch.

## The parts that took measuring

These constraints are load-bearing. Changing them without understanding why breaks something subtle.

**The mute file lives outside the state dir.** State is per-boot scratch at `${TMPDIR}/claudesay-<uid>/` (mode 0700, wiped on reboot); the mute switch is `~/.claude/claudesay-muted`, because a mute set before a meeting must survive a reboot and must be visible to every session on the machine at once.

**Per-session state files** are `<session>.last` (debounce timestamp), `.hash` (dedupe), `.pid` (player), `.job` (queue job). All written through `write_state()`, which writes to a temp file and `mv -f`s it — a planted symlink can't make the hook write through to a target. Reads guard with `! -L`.

**The playback lock is `mkdir`**, not `flock` (macOS ships none). Within one session the newest line barges in on the previous one; across sessions they queue, because two overlapping sentences leaves you with neither. A line that can't get the floor within `CLAUDESAY_QUEUE_WAIT` is dropped, not queued forever.

**Two PIDs, not one.** The lock records the `say`/`afplay` PID, not the holding shell's — a shell can't portably learn its own PID inside `( … )` on bash 3.2, and every candidate dies the instant the hook returns, so contenders would see a dead holder and all speak at once. `STALE_GRACE=5` covers the beat between `mkdir` and the player PID appearing. Barge-in kills the player *first* so its `wait` wakes and the EXIT trap frees the lock, then the queued job.

**Engine resolution is automatic** and must stay that way: `auto` picks kokoro only on arm64 with `uv` and `afplay` present, else `say`. A cold or broken voice server speaks this turn through `say` while warming in the background. **Every failure path degrades to a worse voice, never to silence.**

**PIDs recycle on macOS**, so `comm_of()` confirms the process is actually `say`/`afplay` (or `bash`/`sh` for a job) before signalling it.

## Conventions that bite

- **bash 3.2.** macOS ships it. No `BASHPID`, no associative arrays; `shopt -s nocasematch` is ignored inside `case`, so pre-lowercase (see `PREFIX_LOWER`).
- **Stop hooks ignore `matcher`** — the installer omits it, and a test asserts that.
- Claude Code does **not** tilde-expand a hook `command`; the installer writes absolute paths.
- Hook config is read at session start, so upgrades don't reach open sessions. The installer keeps a `voice-notify.sh` shim forwarding to `claudesay.sh` so pre-rename sessions land on the current queue and mute switch instead of being orphaned.
- `settings.json` is the user's file: back it up, refuse to touch invalid JSON, strip prior claudesay entries before adding (self-healing, idempotent). Tests cover all of this.
- Numeric env vars that reach a URL or a `curl` timeout are regex-validated and reset to their default on garbage (`KOKORO_PORT`, `KOKORO_TIMEOUT`, `QUEUE_WAIT`).
- Spoken text that begins with `-` gets a leading space so `say` can't read it as a flag.

## Test suite rules

- **Never assert on a live `say` process.** macOS `say` exits 0 without speaking when the audio device is busy, and always does on CI. Assert on state files and PIDs.
- `fire_hook()` clears ambient `CLAUDESAY_*` with `env -u` and pins `CLAUDESAY_ENGINE=say` — a suite that inherits the developer's `settings.json` fails for the wrong reason. New helpers must do the same.
- Tests run in isolated tmp state dirs and never touch the real `~/.claude`.
- `CLAUDESAY_SILENT` makes the hook render to a file instead of playing; that is how the suite stays quiet.
- New behavior needs a test that fails without it. Break the code on purpose and watch it go red.

## Design rules

From [CONTRIBUTING.md](CONTRIBUTING.md) — PRs that violate them don't land:

1. **Quiet by default.** Speaking when you didn't want it is worse than staying silent. New suppression filters are welcome; new conditions that *trigger* speech need strong justification.
2. **Auditable.** The hook should fit on a screen's worth of reading. A feature that can't is probably the wrong project.
3. **No new runtime dependencies** beyond what's already shipped (`say`, `jq`, `awk`, `sed`, stdlib `python3`, and optional `uv` for the neural path).
4. Add env vars only when a real user has a real need. The default path must need zero configuration.
