## What this changes

(One sentence.)

## Why

(Use case, link to issue if any.)

## How I tested

- [ ] `bash tests.sh` passes locally
- [ ] Manually verified the change in a real Claude Code session
- [ ] If installer changed: ran `install.sh` against a clean settings.json, then again to confirm idempotency
- [ ] If hook logic changed: traced with `CLAUDESAY_DEBUG=1` to confirm the new path

## Risk

(Anything reviewers should look at twice. Particularly if you touched: state files, settings.json mutation, the `say` argv, or trap handlers.)
