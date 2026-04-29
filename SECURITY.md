# Security policy

## Supported versions

The latest tagged release of claudesay is supported. Older versions don't receive security backports — please upgrade.

## Reporting a vulnerability

Please **do not** open a public issue for a security vulnerability.

Use GitHub's [private vulnerability reporting](https://github.com/abryfs/claudesay/security/advisories/new) feature. I'll respond within 7 days, and aim to ship a fix or coordinate disclosure within 30 days for confirmed reports.

If you'd rather email, use the address on the [maintainer's GitHub profile](https://github.com/abryfs).

## Threat model

claudesay is a single-user macOS tool. The threat model assumes:

- Same-user processes can already compromise the user (this is `~/`).
- `~/.claude/settings.json` is treated as trusted input — if your settings are attacker-controlled you have bigger problems than the voice hook.
- Transcript content (`.jsonl` from Claude Code) is treated as untrusted; the hook quotes everything it passes to `say` and validates anything used in arithmetic.

What's specifically guarded against:

- Argv flag injection through `CLAUDESAY_VOICE`, `CLAUDESAY_RATE`, or `--voice=` (rejects leading `-`).
- Bash arithmetic-context code execution through planted state files (`$LAST_AT` validated numeric).
- TOCTOU symlink-redirect attacks against state files (writes are atomic via `mv -f`).
- PID recycling causing kills against unrelated processes (verifies `comm == "say"` first).
- World-writable `/tmp` symlink races (state lives in `${TMPDIR}/claudesay-$(id -u)` at mode `0700`).

What's not in scope:

- Compromise of the GitHub repo itself (mitigation: pin to a tag + verify SHA256 once releases ship).
- Compromise of the user's macOS install or `say` binary.
- Other Claude Code hooks misbehaving.

If you find something outside this scope but adjacent (e.g. an issue with how Claude Code routes inputs to hooks), please report to Anthropic directly.
