# Changelog

All notable changes to claudesay are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[SemVer](https://semver.org/spec/v2.0.0.html).

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
