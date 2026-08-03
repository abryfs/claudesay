# claudesay — instructions for coding agents

You are installing or operating **claudesay**, a Stop hook that makes Claude Code
speak the last sentence of its reply. This file is the operational contract. The
README is for humans; follow this one.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/abryfs/claudesay/main/install.sh | bash -s -- --no-picker
```

Always pass `--no-picker`. The interactive voice picker needs a TTY, and you do
not have one — without the flag it falls back silently, which works but wastes a
round trip.

Then verify, and report the result to the user rather than assuming it:

```bash
jq '.hooks.Stop' ~/.claude/settings.json          # the hook is wired
~/.claude/hooks/claudesay.sh --version            # it runs
~/.claude/hooks/claudesay.sh --mute-status        # it is not muted
```

**Tell the user two things and then stop:** it takes effect in *new* Claude Code
sessions, and the global mute key is **⌥M**.

## Do not configure anything

Set an env var only when the user names that behaviour. Three things are already
handled, and reaching for them is the common mistake:

- The engine resolves itself: neural voice on Apple Silicon with `uv`, built-in
  `say` otherwise. Leave `CLAUDESAY_ENGINE` unset.
- Meeting detection runs by default. Leave `CLAUDESAY_MUTE_WHEN_MIC` unset.
- `⌥M` is registered by the installer. Do not build a second hotkey out of
  Shortcuts, Automator or `skhd`.

## Operating it

| The user says | Run |
|---|---|
| "mute it" / "I'm going into a meeting" | `~/.claude/hooks/claudesay.sh --mute 60` |
| "mute it until I say otherwise" | `~/.claude/hooks/claudesay.sh --mute` |
| "turn it back on" | `~/.claude/hooks/claudesay.sh --unmute` |
| "is it on?" | `~/.claude/hooks/claudesay.sh --mute-status` |
| "use a different voice" | `--voice=<name>` on a re-run of `install.sh`; `say -v '?'` lists them |
| "remove it" | `./uninstall.sh` from a clone, or delete the Stop entry + `~/.claude/hooks/claudesay*` |

Prefer `--mute 60` over an indefinite mute. A mute nobody lifts is how the tool
quietly stops existing.

## When it isn't speaking

Work down this list. Most "bugs" are the filter doing its job.

```bash
~/.claude/hooks/claudesay.sh --mute-status              # 1. muted?
python3 ~/.claude/hooks/claudesay-mic.py; echo $?       # 2. exit 0 = a mic is live → silent by design
say -v Samantha "test"                                  # 3. does macOS speech work at all?
jq '.hooks.Stop' ~/.claude/settings.json                # 4. hook still wired?

# 5. Replay the user's most recent turn with full tracing. This names the reason.
LATEST=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
echo "{\"transcript_path\":\"$LATEST\",\"session_id\":\"debug\",\"stop_hook_active\":false}" \
  | CLAUDESAY_DEBUG=1 bash ~/.claude/hooks/claudesay.sh
```

Silence is correct when the reply was under 40 chars, was filler ("Let me
check…"), repeated the previous one, landed inside the 4s debounce, or a
microphone was live. `CLAUDESAY_DEBUG=1` prints which of those applied.

## If you are changing the code

```bash
./tests.sh          # 48 tests. Silent by design — it renders instead of playing.
shellcheck -S warning claudesay.sh install.sh uninstall.sh tests.sh
```

- **Never run the suite audibly** (`CLAUDESAY_AUDIBLE_TESTS=1`) unless the user
  explicitly asks. An earlier version talked over a live meeting; that is why
  the default is silent.
- **Never assert on a live `say` process.** macOS `say` exits 0 without speaking
  when the audio device is busy, and always does on CI. Assert on state files
  and PIDs instead.
- **Test helpers must clear ambient `CLAUDESAY_*` config.** A suite that inherits
  the developer's settings fails for the wrong reason.
- New behavior needs a test that fails without it. Verify that by breaking the
  code on purpose and watching the test go red.

## Boundaries

- `settings.json` is the user's file. The installer backs it up and refuses to
  touch invalid JSON — preserve both properties in any change.
- The hook runs on **every** turn. Keep it well under a second; anything slow
  goes behind a cache or a background process.
- Failures degrade to a worse voice, never to silence. A guard that can mute the
  user permanently must fail open.
