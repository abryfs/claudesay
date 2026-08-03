<p align="center">
  <img src="samples/hero.png" alt="claudesay: Claude Code tells you the one sentence that matters" width="100%">
</p>

# claudesay

[![tests](https://github.com/abryfs/claudesay/actions/workflows/test.yml/badge.svg)](https://github.com/abryfs/claudesay/actions/workflows/test.yml)
[![version](https://img.shields.io/github/v/tag/abryfs/claudesay?label=version)](https://github.com/abryfs/claudesay/releases)
[![license](https://img.shields.io/github/license/abryfs/claudesay)](LICENSE)
![macOS](https://img.shields.io/badge/macOS-only-blue)

A Stop hook that speaks the last sentence of Claude's reply, then shuts up. It won't talk over a meeting and it won't talk over another session.

## Hear it

One sentence, built-in `say` first, then the local neural voice:

```bash
curl -fsSL https://raw.githubusercontent.com/abryfs/claudesay/main/samples/0-comparison.mp3 \
  -o /tmp/claudesay.mp3 && afplay /tmp/claudesay.mp3
```

Or download [comparison.mp3](samples/0-comparison.mp3), [say](samples/1-say-samantha.mp3), [neural](samples/2-kokoro-af-heart.mp3). Both voices are normalized to −16 LUFS so you're judging the voice, not the volume.

## Install

Paste into Claude Code:

```text
Install claudesay from https://github.com/abryfs/claudesay, following its AGENTS.md.
```

It reads [AGENTS.md](AGENTS.md), which covers the non-TTY flag, the verification steps, and the failure modes worth checking.

Or run it yourself:

```bash
curl -fsSL https://raw.githubusercontent.com/abryfs/claudesay/main/install.sh | bash
```

Either way, open a new Claude Code session and ask something. When the reply ends you'll hear the last sentence. Nothing to configure after this.

<details>
<summary>Other ways in</summary>

```bash
curl -fsSL .../install.sh | bash -s -- --no-picker      # non-interactive
curl -fsSL .../install.sh | bash -s -- --voice=Daniel   # pick a voice up front
git clone https://github.com/abryfs/claudesay && cd claudesay && ./install.sh
```

In a terminal, the installer opens a voice picker that auditions each macOS voice as you arrow through it. Without a TTY it uses Samantha unless you pass `--voice=`.

By hand: copy `claudesay.sh`, `claudesay-mic.py` and `claudesay-voice.py` into `~/.claude/hooks/`, `chmod +x`, then add the Stop block from [How it's wired](#how-its-wired).

</details>

## What it speaks

Given this reply:

> I've updated the migration to backfill in batches of 500 instead of all at once, added an index on `events.team_id`, and re-ran the suite. **All three tests pass and the migration completed cleanly, so this is ready to deploy to staging whenever you want.**

you hear the bold part and nothing else. The rule is the last sentence, because that's where the verdict or the question lands.

| Claude's reply | claudesay |
|---|---|
| A long final summary | last sentence |
| "Want me to deploy now?" | the question |
| "Let me check the logs." | silent (filler) |
| "Done." / "OK." | silent (too short) |
| The same reply twice | silent (deduped) |
| Two Stops within 4s | silent (debounced) |
| A tool-use-only turn | silent (no prose) |
| You start typing | cut off |

<details>
<summary>How the filter works</summary>

Four checks, cheapest first: the `stop_hook_active` loop guard, a per-session debounce, a filler heuristic for short messages opening with `Let me` / `I'll` / `Now` / `Checking` / `Done` and friends, then an md5 dedupe on the chosen text.

What survives loses its markdown and ANSI escapes, gets truncated to `CLAUDESAY_MAX`, and the last sentence of 15 characters or more is what gets spoken.

State lives in `${TMPDIR}/claudesay-<uid>/<session>.{last,hash,pid,job}` at mode 0700, wiped on reboot.

</details>

## Staying quiet

### On calls

A live microphone silences it.

The signal is CoreAudio's `DeviceIsRunningSomewhere`, the flag behind the orange dot in your menu bar. It goes true whenever any process holds an input stream, which is why Zoom, Meet, Teams, Slack huddles, Granola and QuickTime all work without claudesay carrying a list of their names. It reads a property. It never opens a stream, records nothing, and triggers no permission prompt.

Two details that took measuring:

- It polls every input device, not the default one. On a MacBook Pro, opening the mic lit device 95 while the default input was device 90, so a default-only check read "idle" through a live capture.
- It fails open. If the probe can't answer, claudesay speaks. A detector that mutes you forever without saying so is the worse bug.

Set `CLAUDESAY_MUTE_WHEN_MIC=0` to turn it off.

### By hand

**⌥M** toggles mute from any app, focused or not. It reaches sessions that are already running and stops whatever is mid-sentence. Your system volume, music and call audio are untouched.

The installer registers it: a small Swift helper on Carbon's `RegisterEventHotKey`, which claims one chord, sees nothing else, and needs no Accessibility permission. Pick a different one with `CLAUDESAY_HOTKEY="shift+opt+k" ./install.sh`.

The one thing a toggle can't express is a deadline, so there's `claudesay.sh --mute 45` for a mute that lifts itself in 45 minutes. `--help` lists the rest.

### Over each other

Speech from different sessions queues. Inside one session the newest line still cuts off the previous one, which is what you want when you've moved on. Across sessions they wait their turn, since two sentences at once leaves you with neither.

A line that can't get the floor within `CLAUDESAY_QUEUE_WAIT` seconds gets dropped instead of queued forever.

## The neural voice

On Apple Silicon with [`uv`](https://docs.astral.sh/uv/) installed, claudesay uses [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) and falls back to the built-in voice everywhere else.

A neural voice needs a model in memory, so claudesay holds it only while you're working:

- The first turn after a quiet spell goes out through `say` while the server warms behind it (~30s, once).
- Every turn after that is neural, in about 0.7s.
- Five minutes of silence and the server exits, returning the memory.
- Server down, synthesis error, timeout, no `uv`: it falls back to `say`. You get a worse voice, never silence.

Measured on an M3 Pro, 187 characters of text making 11.5s of speech:

| | `say` | `kokoro` |
|---|---|---|
| Time to audio | instant | 0.66s warm, instant via `say` when cold |
| Resident memory | 0 | 110–460 MB warm, 0 idle |
| Peak during load | | ~740 MB, once per warm-up |
| Network | none | one model download |

<details>
<summary>Why a server, and why MLX</summary>

**Why not one process per turn?** Synthesis takes 0.8s but importing the ML stack and loading the model costs 3s every time, so a fresh process measured about 4s before you hear anything. The server pays that once, and idle-exit stops "warm" from meaning "resident forever."

**Why MLX over ONNX?** Same machine, same sentence: MLX 0.76s, ONNX fp32 2.51s, ONNX int8 4.69s. Two surprises in there. Quantized int8 runs *slower* than fp32 on Apple Silicon, and CoreML loses to plain CPU because it only claims about 1300 of 3400 graph nodes, so partition overhead eats the gain.

**Does it leak?** No. It settles at about 460 MB under sustained use and holds there (457 → 460 MB across 15 utterances).

</details>

## Environment variables

<details>
<summary>All of them</summary>

Set them in `~/.claude/settings.json` under `env`, or in your shell.

| Variable | Default | What it does |
|---|---|---|
| `CLAUDESAY_ENGINE` | `auto` | `auto` picks the best available. Force with `say` or `kokoro`. |
| `CLAUDESAY_VOICE` | `Samantha` | Any macOS voice. `say -v '?'` lists them. |
| `CLAUDESAY_RATE` | system | `say -r` words per minute. 200–260 reads snappier. |
| `CLAUDESAY_DEBOUNCE` | `4` | Seconds between fires per session. |
| `CLAUDESAY_MIN_LEN` | `40` | Skip messages shorter than this. |
| `CLAUDESAY_MAX` | `220` | Truncate spoken text to this many characters. |
| `CLAUDESAY_MUTE_WHEN_MIC` | `1` | Stay silent while a microphone is live. |
| `CLAUDESAY_MIC_TTL` | `8` | Seconds to cache the mic check. |
| `CLAUDESAY_MUTE_FILE` | `~/.claude/claudesay-muted` | Where the mute switch lives. |
| `CLAUDESAY_QUEUE_WAIT` | `30` | Seconds a line waits behind another session before being dropped. |
| `CLAUDESAY_DISABLE` | unset | Silence it without uninstalling. |
| `CLAUDESAY_KOKORO_VOICE` | `af_heart` | Kokoro voice name. |
| `CLAUDESAY_KOKORO_IDLE` | `300` | Seconds of silence before the voice server exits. `0` never exits. |
| `CLAUDESAY_KOKORO_PORT` | `8787` | Loopback port for the voice server. |
| `CLAUDESAY_KOKORO_TIMEOUT` | `10` | Seconds to wait for synthesis before falling back. |
| `CLAUDESAY_DEBUG` | unset | Print every decision the hook makes to stderr. |
| `CLAUDESAY_SILENT` | unset | Dry run: render speech to a file instead of playing it. |
| `CLAUDESAY_STATE` | per-user `$TMPDIR` | Override the state directory. |

</details>

## How it's wired

The installer adds a `Stop` hook to `~/.claude/settings.json`. Use absolute paths, since Claude Code doesn't tilde-expand `command`:

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

`Stop` fires when Claude finishes a turn. The hook reads `transcript_path` from stdin, takes the last text-bearing assistant message, and decides whether to speak it. The 15s timeout is a safety floor; the hook returns in well under a second. Stop hooks ignore `matcher`, so claudesay omits it.

Upgrading with sessions already open: Claude Code reads hook config at session start, so those sessions keep calling the path they launched with. The installer forwards the old `voice-notify.sh` name to `claudesay.sh` instead of orphaning it, which puts them on the current queue and mute switch without a restart.

`./uninstall.sh` removes the hook entry, the installed files, the hotkey agent, any running voice server, and the state directory.

## Troubleshooting

<details>
<summary>It never speaks</summary>

```bash
say -v Samantha "test"                              # does macOS speech work?
~/.claude/hooks/claudesay.sh --mute-status          # muted?
python3 ~/.claude/hooks/claudesay-mic.py; echo $?   # 0 means a mic is live
jq '.hooks.Stop' ~/.claude/settings.json            # hook still wired?

LATEST=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
echo "{\"transcript_path\":\"$LATEST\",\"session_id\":\"debug\",\"stop_hook_active\":false}" \
  | CLAUDESAY_DEBUG=1 bash ~/.claude/hooks/claudesay.sh
```

Silence is normally correct: too short, filler, duplicate, inside the debounce window, or a live microphone. `CLAUDESAY_DEBUG=1` names the reason on every fire.

</details>

<details>
<summary>The neural voice won't start</summary>

```bash
command -v uv || brew install uv
CLAUDESAY_ENGINE=kokoro ~/.claude/hooks/claudesay.sh --test
cat "${TMPDIR}/claudesay-$(id -u)/voice.log"
curl -sS http://127.0.0.1:8787/health
```

The first `--test` after a quiet spell reports "cold" and speaks through `say`. That's the design. Wait 30s and run it again; if it's still cold the log says why, usually a missing `uv` or a failed model download.

</details>

<details>
<summary>settings.json got mangled, or the picker left the terminal weird</summary>

The installer backs up `settings.json` before touching it and refuses to edit invalid JSON.

```bash
cp "$(ls -t ~/.claude/settings.json.bak.* | head -1)" ~/.claude/settings.json
stty sane && tput cnorm
```

</details>

## Alternatives

Claude Code ships no native TTS ([#50720](https://github.com/anthropics/claude-code/issues/50720) is open), so there are a few options.

- **`say` straight in `settings.json`.** No transcript awareness, no debounce, no filler filter. You'll hear "Done" fifty times an hour.
- **[peon-ping](https://github.com/PeonPing/peon-ping).** Sound effects rather than speech.
- **[VoiceMode](https://github.com/mbailey/voicemode).** Two-way conversation over MCP and Whisper. Heavier. Take it if you want duplex.
- **[AgentVibes](https://github.com/paulpreibisch/AgentVibes).** 904 Piper voices, per-LLM routing, effects.
- **[claude-code-tts](https://github.com/ktaletsk/claude-code-tts).** Same model through a per-turn CLI, which pays model load on every turn.
- **[Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI).** A solid general-purpose Kokoro server, but you start the container and it stays resident.

claudesay is one bash file you can read in a sitting, costs nothing, and needs no key.

## Requirements

macOS with `jq` (`brew install jq`) and Claude Code 2.x, tested on 2.1.123. `python3` ships with macOS and covers the mic check using only the stdlib. The neural voice wants Apple Silicon and [`uv`](https://docs.astral.sh/uv/); Intel Macs stay on `say`.

Linux and Windows ports welcome. See `claudesay.sh` for the contract and swap the `say` call for `espeak-ng` or PowerShell's `SpeechSynthesizer`.

## Contributing

```bash
./tests.sh                              # 48 tests, silent
CLAUDESAY_AUDIBLE_TESTS=1 ./tests.sh    # let it use the speakers
```

The suite renders instead of playing, because an early version talked over a live meeting. [CONTRIBUTING.md](CONTRIBUTING.md) has the rest, and [AGENTS.md](AGENTS.md) covers coding agents.

## License

MIT, see [LICENSE](LICENSE).
