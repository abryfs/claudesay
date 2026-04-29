# claudesay

**Tasteful voice notifications for Claude Code.** A single bash hook that speaks the meaningful end of Claude's reply when a turn finishes — and stays silent the rest of the time. Pure macOS `say`. No API keys, no daemon, no per-call cost.

## Install

### Tell Claude Code to install it for you

Open a Claude Code session and paste:

```
Install claudesay (https://github.com/abryfs/claudesay) for me by running its install script. Use --no-picker so it runs non-interactively, then confirm the Stop hook is wired in ~/.claude/settings.json. If I want a non-default voice later, I can re-run install.sh interactively to use the picker.
```

Claude Code will run the equivalent of:

```bash
curl -fsSL https://raw.githubusercontent.com/abryfs/claudesay/main/install.sh | bash -s -- --no-picker
```

To pick a specific voice non-interactively (e.g. for a remote install via Claude Code):

```bash
curl -fsSL https://raw.githubusercontent.com/abryfs/claudesay/main/install.sh | bash -s -- --voice=Daniel
```

### Run it yourself in a terminal (interactive voice picker)

```bash
curl -fsSL https://raw.githubusercontent.com/abryfs/claudesay/main/install.sh | bash
```

Use ↑↓ to walk through every English voice on your Mac. Each highlight previews the voice live. ⏎ to select, `r` to replay, `q` to keep the default.

### Or clone and run

```bash
git clone https://github.com/abryfs/claudesay && cd claudesay && ./install.sh
```

Open a new Claude Code session. Ask something. When the response ends, you'll hear the last sentence.

---

## Why

Claude Code 2.1 still ships **no native TTS** ([feature request #50720](https://github.com/anthropics/claude-code/issues/50720) is open). The community's filling the gap, but most options either (a) require an API key and per-call billing (ElevenLabs, Cartesia, OpenAI), (b) install a daemon or MCP server (VoiceMode, AgentVibes), or (c) say "Done" so often you turn them off in a day.

claudesay is the smallest thing that actually works:

- **~140 lines of bash.** Read it. Audit it. Modify it.
- **macOS built-ins only** — `say` + `jq`. Zero install footprint.
- **Quiet by default.** It doesn't speak unless Claude said something worth hearing.
- **$0/month forever.** No subscription, no key, no quota.

## What it speaks (and what it doesn't)

| Claude's response | claudesay |
|---|---|
| "Tests pass. I changed three files…" *(long final summary)* | Speaks the **last sentence** |
| "Want me to deploy now?" *(question)* | Speaks the **question** |
| "Let me check the logs." *(mid-pipeline filler)* | **Skipped** |
| "Done." / "OK." *(trivial ack)* | **Skipped** |
| Same response twice in a row | **Skipped** *(deduped)* |
| Stop fires twice in 4s *(pipeline pause)* | Second one **skipped** *(debounced)* |
| Tool-use-only assistant turn *(no prose)* | **Skipped** |
| You start typing while it speaks | **Cut off** *(barge-in via `killall say`)* |

## Voice picker

Run `./install.sh` (or `bash install.sh`) in a real terminal and you'll get an arrow-key TUI:

```
  Pick a voice for claudesay
  ↑↓ navigate (auto-preview)   ⏎ select   r replay   a all/english   q default

    Alex                       en_US
  ▸ Samantha                   en_US
    Daniel                     en_GB
    Karen                      en_AU
    Moira                      en_IE
    Tessa                      en_ZA
    Veena                      en_IN
    …

  Hello! My name is Samantha.
```

Each ↑/↓ kills the current preview and starts a new `say -v <voice>` so you can audition voices in seconds. `⏎` writes your choice to `~/.claude/settings.json` under `env.CLAUDESAY_VOICE`.

If you don't have a TTY (e.g. running through Claude Code's Bash tool), the picker auto-falls-back to `Samantha` unless you pass `--voice=<name>`.

## Configuration

Set env vars in `~/.claude/settings.json` (or your shell):

| Variable | Default | What it does |
|---|---|---|
| `CLAUDESAY_VOICE` | `Samantha` | Any macOS voice. Run `say -v '?'` for the list. |
| `CLAUDESAY_DEBOUNCE` | `4` | Seconds between fires per session — collapses pipeline noise. |
| `CLAUDESAY_MIN_LEN` | `40` | Skip messages shorter than this many chars. |
| `CLAUDESAY_MAX` | `220` | Truncate spoken text to this many chars. |
| `CLAUDESAY_RATE` | system | `say -r` words/min. Try `200`–`260` for snappier reads. |
| `CLAUDESAY_DISABLE` | unset | Set to anything to silence without uninstalling. |

Example settings.json snippet:

```json
{
  "env": {
    "CLAUDESAY_VOICE": "Daniel",
    "CLAUDESAY_RATE": "230"
  }
}
```

## How it's wired

The installer adds a `Stop` hook entry in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{
      "matcher": "*",
      "hooks": [{ "type": "command", "command": "~/.claude/hooks/claudesay.sh" }]
    }]
  }
}
```

`Stop` fires when Claude finishes a turn. The script reads the transcript path from stdin, pulls the last text-bearing assistant message, and decides whether to speak it.

## Manual install (no script)

```bash
mkdir -p ~/.claude/hooks
curl -fsSL https://raw.githubusercontent.com/abryfs/claudesay/main/claudesay.sh \
    -o ~/.claude/hooks/claudesay.sh
chmod +x ~/.claude/hooks/claudesay.sh
```

Then add the Stop hook block above to `~/.claude/settings.json`.

## Uninstall

```bash
./uninstall.sh
```

Or remove the Stop hook block from `~/.claude/settings.json` and delete `~/.claude/hooks/claudesay.sh`.

## How it filters noise

Three independent guards stack:

1. **`stop_hook_active` loop guard** — if a previous hook forced Claude to continue, skip; otherwise we'd narrate the loop.
2. **Per-session debounce** — collapses Stop events that fire within `DEBOUNCE_SEC` of each other (the typical "task in the middle finished" case).
3. **Filler heuristic** — short messages (<120 chars) starting with `Let me`, `I'll`, `Now`, `Running`, `Reading`, `Checking`, `OK`, `Done`, etc. are treated as transitional and skipped.

Then it dedupes on a content hash, strips markdown so `say` doesn't read literal asterisks, and speaks the last sentence ≥15 chars (where summaries and questions land).

State lives in `/tmp/claudesay/<session_id>.{last,hash}`. Wiped on reboot. Override with `CLAUDESAY_STATE`.

## Why not [other thing]

- **macOS `say` directly in `settings.json`** — fires on every Stop with no transcript awareness, no debounce, no filler filter. You'll hear "Done" 50 times an hour.
- **[peon-ping](https://github.com/PeonPing/peon-ping)** — sound effects, not speech. Different niche.
- **[VoiceMode](https://github.com/mbailey/voicemode)** — full two-way conversation via MCP + Whisper + Kokoro. Heavier, breaks on Claude Code 2.1.105+. Use if you want duplex.
- **[AgentVibes](https://github.com/paulpreibisch/AgentVibes)** — feature-rich (904 Piper voices, per-LLM routing, FX). Use if you want the kitchen sink.
- **[claude-code-hooks-mastery](https://github.com/disler/claude-code-hooks-mastery)** — reference patterns; great to study, larger to deploy.

claudesay is what you want when you just want Claude to talk to you sensibly without any of the above.

## Requirements

- macOS (uses `/usr/bin/say`)
- `jq` — `brew install jq` if missing
- Claude Code 2.x (tested on 2.1.123)

Linux / Windows ports welcome — see `claudesay.sh` for the contract; swap the `say` invocation for `espeak-ng` or PowerShell `Add-Type … SpeechSynthesizer`.

## License

MIT — see [LICENSE](LICENSE).
