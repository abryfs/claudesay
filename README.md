<p align="center">
  <img src="samples/hero.png" alt="claudesay — Claude Code tells you the one sentence that matters" width="100%">
</p>

# claudesay

[![tests](https://github.com/abryfs/claudesay/actions/workflows/test.yml/badge.svg)](https://github.com/abryfs/claudesay/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/abryfs/claudesay?label=version)](https://github.com/abryfs/claudesay/releases)
[![license](https://img.shields.io/github/license/abryfs/claudesay)](LICENSE)
![macOS](https://img.shields.io/badge/macOS-only-blue)

**Tasteful voice notifications for Claude Code.** A single bash hook that speaks the meaningful end of Claude's reply when a turn finishes — and stays silent the rest of the time. Pure macOS `say` by default. No API keys, no per-call cost.

Want a neural voice instead? `CLAUDESAY_ENGINE=kokoro` runs [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) locally — still free, still no API key, and it **releases its memory when you stop working**. See [Neural voice](#neural-voice-optional).

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

### Verify it's working

```bash
~/.claude/hooks/claudesay.sh --test     # speaks a fixed sentence in your voice
~/.claude/hooks/claudesay.sh --version  # prints version
```

---

## Hear it

Same sentence, both engines, back to back — `say` first, then Kokoro. Press play:

<video src="https://github.com/abryfs/claudesay/raw/main/samples/0-comparison.mp4" controls muted="false" width="100%"></video>

*(No player above? GitHub only renders video on some surfaces — grab the audio directly: [**comparison.mp3**](samples/0-comparison.mp3) · [`say` alone](samples/1-say-samantha.mp3) · [Kokoro alone](samples/2-kokoro-af-heart.mp3).)*

Or play them straight from the terminal, no clone:

```bash
curl -fsSL https://raw.githubusercontent.com/abryfs/claudesay/main/samples/0-comparison.mp3 \
  -o /tmp/claudesay-demo.mp3 && afplay /tmp/claudesay-demo.mp3
```

Both clips are loudness-normalized to −16 LUFS, so you're comparing the voices and not the volume. Neither came from a demo script: they're `say -v Samantha` and a `POST /speak` to the same voice server the hook uses.

### What it picks out of a turn

The sample isn't a cherry-picked line — it's the output of the filter. Given this final message from Claude:

> I've updated the migration to backfill in batches of 500 instead of all at once, added an index on `events.team_id`, and re-ran the suite. **All three tests pass and the migration completed cleanly, so this is ready to deploy to staging whenever you want.**

claudesay speaks exactly the bolded sentence, and nothing else. That's the whole editorial rule: **the last sentence, because that's where the verdict or the question lands.** The setup you already read on screen; the part you need to act on is the part worth saying out loud.

Run it yourself to see the selection without waiting for a turn:

```bash
CLAUDESAY_DEBUG=1 ~/.claude/hooks/claudesay.sh --test   # or replay a real transcript, see Troubleshooting
```

---

## Why

Claude Code 2.1 still ships **no native TTS** ([feature request #50720](https://github.com/anthropics/claude-code/issues/50720) is open). The community's filling the gap, but most options either (a) require an API key and per-call billing (ElevenLabs, Cartesia, OpenAI), (b) install a daemon or MCP server (VoiceMode, AgentVibes), or (c) say "Done" so often you turn them off in a day.

claudesay is the smallest thing that actually works:

- **The core hook is one readable bash file.** Read it. Audit it. Modify it.
- **macOS built-ins by default** — `say` + `jq`. Zero install footprint.
- **Quiet by default.** It doesn't speak unless Claude said something worth hearing.
- **$0/month forever.** No subscription, no key, no quota — including the neural voice.
- **A better voice never costs you latency or idle RAM.** Kokoro is opt-in, warms in the background, and exits when you stop working. `say` covers every gap.
- **Security-conscious:** validates `$VOICE` argv to prevent flag injection, scopes state to a private per-user dir under `$TMPDIR` (not world-writable `/tmp`), refuses to follow symlinked state files, atomic-renames `settings.json` so you can't end up with a half-written config.

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
| You start typing while it speaks | **Cut off** *(barge-in, PID-tracked per session)* |

## Voice picker

Run `./install.sh` (or `bash install.sh`) in a real terminal and you'll get an arrow-key TUI:

```
  Pick a voice for claudesay
  ↑↓ navigate (auto-preview)   ⏎ select   r replay   q default

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

## Neural voice (optional)

`say` is instant and free but unmistakably synthetic. Kokoro-82M sounds far more natural and is also free — the catch is that it needs a model in memory. claudesay's answer is to keep the model warm **only while you're actually working**, and to never make you wait for it.

```jsonc
// ~/.claude/settings.json
{ "env": { "CLAUDESAY_ENGINE": "kokoro" } }
```

Requires [`uv`](https://docs.astral.sh/uv/) (`brew install uv`). Nothing else to install — the first run fetches the model and Python deps into uv's and Hugging Face's own caches.

**How it behaves:**

- **First turn after a quiet spell** is spoken by `say`, instantly, while the voice server warms in the background (~30s, once). You are never left waiting on a model.
- **Every turn after that** is Kokoro, in ~0.7s.
- **After 5 minutes of silence** the server exits and gives the memory back. Next turn starts the cycle again — one `say` turn, then neural.
- **Anything that goes wrong** — server down, synthesis error, timeout, no `uv` — falls back to `say`. The failure mode is a worse voice, never silence.

**Measured on an M3 Pro** (187-char sentence → 11.5s of speech):

| | `say` | `kokoro` |
|---|---|---|
| Time to audio | instant | **0.66s** warm · instant (via `say`) when cold |
| Resident memory | 0 | **~110–460 MB** warm (grows with use, then flat) · **0 when idle** |
| Peak during model load | — | ~740 MB, once per warm-up |
| Cost | $0 | $0 |
| Network | none | model download, once |

Memory settles rather than creeping: ~110 MB after a couple of utterances, rising to ~460 MB under sustained use and then holding flat (457 MB → 460 MB across 15 utterances). A long-lived TTS server that leaks would keep climbing past that.

**Why a server and not just one process per turn?** Because per-turn is unusable: synthesis is fast (~0.8s) but importing the ML stack and loading the model costs ~3s *every time*, so a fresh process per turn measured ~4s before you hear anything. The server pays that once; idle-exit is what keeps "warm" from meaning "resident forever."

**Why MLX and not ONNX?** Measured on the same machine and sentence: MLX 0.76s, ONNX fp32 2.51s, ONNX int8 4.69s. Quantized int8 is *slower* than fp32 on Apple Silicon, and CoreML is slower than plain CPU because it can only claim a fraction of the graph. MLX uses the GPU and wins by ~3.8x.

Tune it:

```jsonc
{ "env": {
    "CLAUDESAY_ENGINE": "kokoro",
    "CLAUDESAY_KOKORO_VOICE": "af_bella",   // af_heart, af_bella, am_michael, …
    "CLAUDESAY_KOKORO_IDLE": "900"          // hold the model 15min instead of 5
} }
```

## It shuts up when you're on a call

If a microphone is live, claudesay stays silent. No configuration, no app list.

This is the one failure the tool cannot walk back: a notification during a meeting is broadcast to everyone listening, and you can't un-say it. Muting after the fact is too late.

The signal is CoreAudio's `DeviceIsRunningSomewhere` — the same flag behind the orange dot in your menu bar. It's true whenever any process holds an input stream, so Zoom, Meet, Teams, Slack huddles, Granola and QuickTime all work without claudesay knowing they exist. **It reads a property flag; it never opens an audio stream, captures nothing, and never triggers a microphone permission prompt.**

Two details that matter:

- **It checks every input device, not just the default one.** Measured on a MacBook Pro: opening the mic lit up device 95 while the default input was device 90 — a default-only check reported "idle" straight through a live capture.
- **It fails open.** If the probe can't answer, claudesay speaks. A detector that silently mutes you forever is worse than one that occasionally talks, because you'd never find out.

Turn it off with `CLAUDESAY_MUTE_WHEN_MIC=0`.

## Mute (and a global hotkey)

```bash
claudesay.sh --mute          # silence every session until you unmute
claudesay.sh --mute 45       # ...for 45 minutes, then it lifts itself
claudesay.sh --unmute
claudesay.sh --toggle-mute   # bind this to a hotkey
claudesay.sh --mute-status
```

Mute is machine-wide and live: it takes effect in sessions that are **already running**, and it silences whatever is speaking right now. It mutes claudesay only — your system volume, music, and call audio are untouched.

**For a global hotkey that works when Claude isn't focused**, use the Shortcuts app (built into macOS — no extra tools):

1. Shortcuts → **+** → add the **Run Shell Script** action.
2. Script: `$HOME/.claude/hooks/claudesay.sh --toggle-mute`
3. Name it "Mute Claude", then **⌘I** → *Add Keyboard Shortcut* → press your combination.

It now fires from any app. `--mute 45` is the better meeting default than a plain toggle, because the mute you forget to lift is the one that quietly turns the tool off for good.

## Two sessions ending at once

Speech from different Claude Code sessions **queues** instead of overlapping.

Within one session the newest line still cuts off the previous one — that's barge-in, and it's what you want. Across sessions the lines wait their turn, because two sentences spoken simultaneously are both lost. You can re-read a screen; you can't un-hear an overlap.

The queue is a `mkdir` mutex holding the *player's* PID (a shell can't portably learn its own PID inside a subshell, and every candidate for it dies the moment the hook returns). A line that can't get the floor within `CLAUDESAY_QUEUE_WAIT` seconds is dropped rather than queued forever — speech that arrives a minute late describes work you've moved on from.

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
| `CLAUDESAY_DEBUG` | unset | Set to anything to print every decision the hook makes to stderr (handy for "why didn't it speak?"). |
| `CLAUDESAY_STATE` | per-user `$TMPDIR` | Override the state directory location. |
| `CLAUDESAY_ENGINE` | `say` | `say` or `kokoro`. An unrecognized value degrades to `say`. |
| `CLAUDESAY_KOKORO_VOICE` | `af_heart` | Kokoro voice name. |
| `CLAUDESAY_KOKORO_IDLE` | `300` | Seconds of silence before the voice server exits. `0` never exits. |
| `CLAUDESAY_KOKORO_PORT` | `8787` | Loopback port for the voice server. |
| `CLAUDESAY_KOKORO_TIMEOUT` | `10` | Seconds to wait for synthesis before falling back to `say`. |
| `CLAUDESAY_MUTE_WHEN_MIC` | `1` | Stay silent while any microphone is live. `0` disables. |
| `CLAUDESAY_MIC_TTL` | `8` | Seconds to cache the mic check, so the hook stays fast. |
| `CLAUDESAY_QUEUE_WAIT` | `30` | Max seconds a line waits behind another session before being dropped. |
| `CLAUDESAY_MUTE_FILE` | `~/.claude/claudesay-muted` | Where the mute switch lives. |
| `CLAUDESAY_SILENT` | unset | Dry run: render speech to a file instead of playing it. |

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

The installer adds a `Stop` hook entry in `~/.claude/settings.json`. **Use absolute paths** — Claude Code does not tilde-expand `command`:

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "/Users/<you>/.claude/hooks/claudesay.sh",
        "timeout": 15
      }]
    }]
  }
}
```

`Stop` fires when Claude finishes a turn. The script reads the transcript path from stdin, pulls the last text-bearing assistant message, and decides whether to speak it. The `timeout: 15` is a safety floor in case `say` ever blocks; the hook itself returns in well under a second.

> **Note:** Stop hooks don't honor a `matcher` field — Anthropic's docs say it's silently ignored. claudesay omits it for clarity.

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

## If something goes wrong

The installer always writes a timestamped backup before touching `settings.json`. Find it and restore:

```bash
ls -t ~/.claude/settings.json.bak.* | head -1     # most recent backup
cp "$(ls -t ~/.claude/settings.json.bak.* | head -1)" ~/.claude/settings.json
```

If the picker exited badly and your terminal looks stuck (no cursor, no echo):

```bash
stty sane && tput cnorm
```

The installer refuses to touch a `settings.json` that isn't valid JSON. If that happens, the file is left untouched and you'll see exactly which file to fix.

### No audio when Claude finishes a turn?

Run through these in order — most setups break at one of these:

```bash
# 1. Does `say` work at all?
say -v Samantha "test"

# 2. Is the hook executable and present?
ls -l ~/.claude/hooks/claudesay.sh

# 3. Is the Stop hook actually wired?
jq '.hooks.Stop' ~/.claude/settings.json

# 4. Replay the hook against your most recent transcript and trace it.
LATEST=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
echo "{\"transcript_path\":\"$LATEST\",\"session_id\":\"debug\",\"stop_hook_active\":false}" \
  | bash -x ~/.claude/hooks/claudesay.sh
```

Common reasons it stays silent (all by design):

- The last assistant message is shorter than `CLAUDESAY_MIN_LEN` (40 chars).
- The message is filler ("Let me check…", "I'll run X").
- The same content was just spoken (deduped).
- A previous Stop fired within `CLAUDESAY_DEBOUNCE` seconds (4s).

To temporarily disable without uninstalling: `export CLAUDESAY_DISABLE=1` (or set it in `settings.json` `env`).

## How it filters noise

Three independent guards stack:

1. **`stop_hook_active` loop guard** — if a previous hook forced Claude to continue, skip; otherwise we'd narrate the loop.
2. **Per-session debounce** — collapses Stop events that fire within `DEBOUNCE_SEC` of each other (the typical "task in the middle finished" case).
3. **Filler heuristic** — short messages (<120 chars) starting with `Let me`, `I'll`, `Now`, `Running`, `Reading`, `Checking`, `OK`, `Done`, etc. (smart-quote variants included) are treated as transitional and skipped.

Then it dedupes on a content hash, strips markdown + ANSI escapes so `say` doesn't read literal asterisks or color codes, and speaks the last sentence ≥15 chars (where summaries and questions land).

State lives in `${TMPDIR}/claudesay-<uid>/<session_id>.{last,hash,pid}` with mode `0700` (plus `.wav` when the kokoro engine is on, and a shared `voice.log`). Wiped on reboot. Override with `CLAUDESAY_STATE`. Barge-in is PID-tracked per session and checks the process is still a `say`/`afplay` before signalling it — interrupting your speech doesn't kill playback from other apps or other Claude sessions.

### Neural voice won't start

```bash
# 1. Is uv installed?
command -v uv || brew install uv

# 2. Ask the hook directly — it reports whether the server is warm.
CLAUDESAY_ENGINE=kokoro ~/.claude/hooks/claudesay.sh --test

# 3. Read the server's own log.
cat "${TMPDIR}/claudesay-$(id -u)/voice.log"

# 4. Is it listening?
curl -sS http://127.0.0.1:8787/health
```

The first `--test` after a quiet spell always reports "cold" and speaks via `say` — that's the design, not a fault. Wait ~30s and run it again. If it's still cold, the log will say why (most often: `uv` missing, or the model download failed).

## Why not [other thing]

- **macOS `say` directly in `settings.json`** — fires on every Stop with no transcript awareness, no debounce, no filler filter. You'll hear "Done" 50 times an hour.
- **[peon-ping](https://github.com/PeonPing/peon-ping)** — sound effects, not speech. Different niche.
- **[VoiceMode](https://github.com/mbailey/voicemode)** — full two-way conversation via MCP + Whisper + Kokoro. Heavier, breaks on Claude Code 2.1.105+. Use if you want duplex.
- **[AgentVibes](https://github.com/paulpreibisch/AgentVibes)** — feature-rich (904 Piper voices, per-LLM routing, FX). Use if you want the kitchen sink.
- **[claude-code-tts](https://github.com/ktaletsk/claude-code-tts)** — Kokoro via a per-turn CLI. Same model, no server — which means paying model load on every single turn.
- **[Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI)** — the general-purpose Kokoro server. Great building block, but it's a container you start and it stays resident (with a documented memory leak under sustained use). claudesay's server starts itself and exits itself.
- **[claude-code-hooks-mastery](https://github.com/disler/claude-code-hooks-mastery)** — reference patterns; great to study, larger to deploy.

claudesay is what you want when you just want Claude to talk to you sensibly without any of the above.

## Requirements

- macOS (uses `/usr/bin/say` and `/usr/bin/afplay`)
- `jq` — `brew install jq` if missing
- `python3` — ships with macOS; used only for the mic check (stdlib only, no packages)
- Claude Code 2.x (tested on 2.1.123)
- *For the neural voice only:* [`uv`](https://docs.astral.sh/uv/) and an Apple Silicon Mac (MLX). Intel Macs stay on `say`.

Linux / Windows ports welcome — see `claudesay.sh` for the contract; swap the `say` invocation for `espeak-ng` or PowerShell `Add-Type … SpeechSynthesizer`.

## License

MIT — see [LICENSE](LICENSE).
