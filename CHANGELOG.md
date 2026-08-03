# Changelog

All notable changes to claudesay are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[SemVer](https://semver.org/spec/v2.0.0.html).

## [0.6.0] — 2026-08-03

Fewer decisions. Everything that used to be a setting or a setup step is now a
default that picks itself.

### Added
- **A real global mute hotkey, installed for you: ⌃⌥⌘M.** Works from any app,
  focused or not. Previously the README asked you to build one in Shortcuts by
  hand — three steps of homework for one keystroke. It's a small Swift helper
  on Carbon's `RegisterEventHotKey`, which needs **no Accessibility permission**
  and can only observe the single combination it claims, so there is nothing to
  approve. Runs as a LaunchAgent; `uninstall.sh` removes it.
- **`AGENTS.md`** — an operational contract for coding agents installing or
  running claudesay, so the install prompt is one line and the agent already
  knows not to configure anything.

### Changed
- **`CLAUDESAY_ENGINE` now defaults to `auto`.** If the machine can run the
  neural voice (Apple Silicon + `uv`) it uses it, otherwise the built-in voice.
  Choosing an engine was never a decision anyone wanted to make, and guessing
  wrong costs nothing because the neural path already falls back per utterance.
- The install prompt for Claude Code is the primary path in the README, ahead of
  the curl one-liner.
- README: configuration folded into a collapsible and prefaced with "you
  shouldn't need this"; the neural voice is documented as automatic rather than
  as an opt-in with a tuning block.

### Fixed
- The hotkey LaunchAgent is bootstrapped into the **GUI domain**
  (`launchctl bootstrap gui/$(id -u)`). `launchctl load` inherits whatever
  domain the installer runs in, and from an agent's shell the helper landed
  outside the Aqua session, where `NSApplication` can't start — it exited 78
  immediately and the hotkey silently never worked.

## [0.5.0] — 2026-08-03

Everything here comes from one bad afternoon: a test run talked over a live
meeting while three sessions spoke on top of each other. Each fix targets a
failure the user cannot undo after the fact.

### Added
- **Silence while a microphone is live.** If any input device is in use,
  claudesay says nothing. The signal is CoreAudio's `DeviceIsRunningSomewhere`
  — the flag behind the orange mic dot — so Zoom, Meet, Teams, Slack huddles,
  Granola and QuickTime all work without an app list to maintain. It reads a
  property; it never opens a stream, captures nothing, and never triggers a
  microphone permission prompt. Disable with `CLAUDESAY_MUTE_WHEN_MIC=0`.
- **A cross-session playback queue.** Two sessions ending at the same moment
  now speak in turn instead of over each other. Within a session, barge-in is
  unchanged: the newest line still cuts off the previous one.
- **Mute, machine-wide and live:** `--mute [MINUTES]`, `--unmute`,
  `--toggle-mute`, `--mute-status`. It takes effect in sessions that are already
  running and silences whatever is speaking right now, without touching system
  audio. `--toggle-mute` is meant to be bound to a global hotkey (README shows
  the Shortcuts.app recipe, which needs no extra tools).
- **`CLAUDESAY_SILENT=1`** — dry run that renders speech to a file instead of
  playing it. The test suite now uses it by default.
- Audio samples and a playable comparison clip in `samples/`.

### Fixed
- **Queued speech was killed the moment the hook returned.** `play_queued`
  backgrounded its job inside a command substitution, so the job did not outlive
  the hook process and playback was cut off instantly. It now backgrounds from
  the main shell.
- **The queue lock never actually held.** It recorded `$$`, which inside a
  subshell still names the *original* shell — a PID that exits immediately, so
  every other session saw a dead holder and broke the lock. Three sessions still
  spoke at once. The lock now holds the player's PID, which lives exactly as long
  as the speech. (`$BASHPID` is unavailable on stock macOS bash 3.2, and
  `sh -c 'echo $PPID'` names the wrong shell.)
- Sessions started before an upgrade kept calling `voice-notify.sh` and so
  bypassed the queue and the mute switch entirely. The installer now forwards
  that path to `claudesay.sh` instead of orphaning it.

### Changed
- **The test suite no longer uses the speakers.** It renders instead, and the
  handful of tests that must observe real overlapping playback are gated behind
  `CLAUDESAY_AUDIBLE_TESTS=1`. Reason: the suite is developed on a laptop that
  also joins meetings.
- Test helpers now clear ambient `CLAUDESAY_*` config. `engine defaults to say`
  previously failed for anyone who had actually enabled a different engine.

## [0.4.0] — 2026-08-03

Adds an optional neural voice without giving up any of the properties that made
0.3.0 worth using: no API key, no cost, no permanently resident process, and no
turn ever delayed waiting on speech.

### Added
- `CLAUDESAY_ENGINE=kokoro` — local [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M)
  speech via `claudesay-voice.py`, a small loopback server that **starts itself on
  demand and exits itself after `CLAUDESAY_KOKORO_IDLE` seconds** (default 300),
  so it holds memory only while you're working. Measured on an M3 Pro: ~0.66s to
  audio warm, ~460 MB resident warm, 0 MB idle, flat across 15 utterances.
- Cold-start is invisible: when the server isn't up, the turn is spoken by `say`
  immediately while the server warms in the background. You never wait on a model.
- `CLAUDESAY_KOKORO_VOICE`, `_IDLE`, `_PORT`, `_TIMEOUT` env knobs.
- `--test` now exercises the configured engine and reports whether the voice
  server is warm, instead of hardcoding `say`.
- Engine-layer tests using a stub HTTP server, so the suite stays offline and
  never loads a model: dispatch, cold fallback, warm path, HTTP 500 fallback,
  port sanitization, and verbatim request encoding.

### Security
- The synthesis request sends text via `--data-binary @-` on stdin. Passing it
  inline would let a reply beginning with `@` make curl read a local file and
  send its contents to the server; there is a regression test for this.
- `CLAUDESAY_KOKORO_PORT` / `_TIMEOUT` are validated as integers before being
  interpolated into a URL, and an unknown `CLAUDESAY_ENGINE` degrades to `say`.
- The voice server binds `127.0.0.1` only.

### Fixed
- Barge-in now recognizes `afplay` as well as `say` as its own player, so
  interrupting neural speech works the way it always did for `say`.
- The voice server uses `os._exit` for idle shutdown. mlx-audio, spaCy and
  tokenizers leave non-daemon threads behind, so a clean return left the
  interpreter alive holding the model — idle-exit silently did nothing.
- The server no longer logs a traceback when a client hangs up mid-request
  (every health probe during model load did this).

## [0.3.0] — 2026-04-29

First public release. Three review passes converged before tagging.

### Added
- Interactive arrow-key voice picker in `install.sh` with live `say` previews on highlight, page-up/down, replay, and a per-frame `tput lines` re-query so terminal resize is handled.
- `--voice=<name>`, `--no-picker`, `--version`, `--help` flags on `install.sh`.
- `--version`, `--help`, `--test` modes on the hook itself, so users can sanity-check the install without waiting for Claude to finish a turn.
- `CLAUDESAY_DEBUG=1` env: streams every decision the hook makes (`skip: filler`, `skip: debounced`, `speak: …`) to stderr.
- Hook contract honors `timeout: 15` on the Stop entry; reads `transcript_path`, `session_id`, `stop_hook_active`; filters compaction summaries.
- Atomic state writes via `mktemp + mv -f`. State directory is per-user `${TMPDIR}/claudesay-$(id -u)` at mode `0700` (no longer world-writable `/tmp`).
- PID-tracked, identity-verified barge-in: the hook only kills its own session's previous `say` process after confirming the PID is still a `say` process (PIDs can recycle).
- Self-healing installer: strips prior `claudesay.sh`/`voice-notify.sh` Stop entries before adding the canonical one — running install twice never produces duplicates.
- Test suite (`tests.sh`) covering filler/dedup/debounce/security guards/installer idempotency, plus a GitHub Actions workflow running it on `macos-latest`.

### Security
- Validates `$LAST_AT` is numeric before use in arithmetic context — blocks the bash recursive-evaluation attack where a planted state file value like `'a[$(id)]'` would otherwise execute.
- TOCTOU mitigation: writes use `mv -f` (rename(2)), which atomically replaces a planted symlink at the destination rather than following it through to a victim file.
- Validates `CLAUDESAY_VOICE` and `--voice=…` reject leading `-` so attacker-controlled values can't reorder `say` argv into flag-injection.
- Strips ANSI escape sequences alongside markdown so `say` doesn't read raw escape codes if a transcript ever contains them.

### Fixed
- Filler detection now lowercases the prefix before matching, since bash 3.2 (default macOS) ignores `shopt -s nocasematch` inside `case` statements. `NOW LET ME …` is now correctly skipped.
- Smart-quoted apostrophes (U+2019) in `I'll`, `Let's`, `I'm` no longer bypass the filler filter.
- Installer refuses to overwrite a malformed `settings.json` and surfaces a clear error instead of corrupting it.
- Installer mutation is atomic — `mktemp` is in the same directory as `settings.json` so `mv` is `rename(2)` even if `$TMPDIR` is on a different filesystem.
- Voice list parser uses `awk` anchored on the locale code instead of bash regex (bash 3.2's `{n,}` quantifier is unreliable inside `[[ =~ ]]`); arrays use explicit indexing instead of `+=` (bash 3.2 corner case where `NAMES[0]` ends up unset).
- Picker trap chain extended from `INT/TERM` to `EXIT/INT/TERM/HUP/QUIT` so an early `read` failure can't leave the cursor hidden or `stty` in `-echo` state.

### Removed
- `"matcher": "*"` from the Stop hook entry — Anthropic docs note Stop ignores matchers; including the field was misleading.

### Known limitations
- macOS only. Linux/Windows ports welcome — the hook's contract is in `claudesay.sh`.
- Single-language filler heuristic (English).
- No SHA256 release pinning yet — treat `curl … | bash` as TOFU until the first signed release.

[0.3.0]: https://github.com/abryfs/claudesay/releases/tag/v0.3.0
