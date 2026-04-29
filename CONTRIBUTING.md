# Contributing to claudesay

Thanks for considering a contribution. claudesay is a small, opinionated tool — most PRs that land are a tight bug fix or a focused feature with no new dependencies.

## Design rules (please honor them)

These are the constraints that make claudesay claudesay. PRs that violate them are unlikely to land:

1. **No new runtime dependencies.** macOS built-ins only — `say`, `jq`, `awk`, `sed`, standard bash. The README's "$0/month, no daemon, no API key" pitch breaks the moment we add `python3`, a TTS library, an API client, or a long-running process.
2. **Bash 3.2 compatible.** macOS ships with bash 3.2 by default. We don't assume bash 4+. (Caveats: `+=` on arrays has corner cases; use explicit indexing. `shopt -s nocasematch` is ignored inside `case` — pre-lowercase instead.)
3. **Quiet by default.** False positives (speaking when you didn't want it) are worse than false negatives. New filters that suppress speech are welcome; new conditions that *trigger* speech need a strong justification.
4. **Auditable.** The whole hook should fit on a screen. If a feature can't fit, it's probably the wrong project.

## Getting set up

```bash
git clone https://github.com/abryfs/claudesay
cd claudesay

# Run the test suite (macOS only)
bash tests.sh

# Run with debug tracing against your real transcript
LATEST=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
echo "{\"transcript_path\":\"$LATEST\",\"session_id\":\"dev\",\"stop_hook_active\":false}" \
  | CLAUDESAY_DEBUG=1 bash claudesay.sh
```

## Workflow

1. Open an issue first for anything more than a one-line change.
2. Fork, branch, code, run `bash tests.sh`.
3. Add or update a test. PRs without test coverage on new behavior won't land.
4. Open a PR. The CI workflow will run the suite on `macos-latest`.

## Style

- Follow the existing structure of `claudesay.sh`. Comments explain *why*, not *what*.
- Don't add features by default. Add env vars only when an existing user has a real need.
- Keep `say`-related changes minimal — the script is one of the only paths between an attacker-controlled string and an OS-level argv.

## Release process (maintainer-facing)

1. Bump `CLAUDESAY_VERSION` in both `claudesay.sh` and `install.sh`.
2. Update `CHANGELOG.md` with the new version section.
3. Tag (`git tag -s v0.4.0 -m "v0.4.0"`) and push the tag.
4. Cut a GitHub release with the changelog excerpt.
