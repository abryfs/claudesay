#!/usr/bin/env bash
# claudesay — tasteful voice notifications for Claude Code
# https://github.com/abryfs/claudesay
#
# Wired as a Stop hook. Speaks the meaningful end of Claude's reply
# (usually the final sentence — questions, summaries, decisions land
# there) and stays silent on filler/mid-pipeline pauses, duplicates,
# and trivial "OK / Done" responses. Pure macOS `say` by default. No
# API keys, no daemon, no per-call cost.
#
# Optionally speaks in a neural voice instead (CLAUDESAY_ENGINE=kokoro),
# which adds a local, idle-exiting Kokoro server — still no API key and
# still $0. The `say` path stays the default and the fallback: if the
# voice server is cold or broken, this turn is spoken by `say` while the
# server warms in the background, so a turn is never delayed by TTS.
#
# Configure via env (set in ~/.claude/settings.json -> env):
#   CLAUDESAY_VOICE     macOS voice name        (default: Samantha)
#   CLAUDESAY_DEBOUNCE  seconds between fires   (default: 4)
#   CLAUDESAY_MIN_LEN   skip if shorter         (default: 40)
#   CLAUDESAY_MAX       max chars to speak      (default: 220)
#   CLAUDESAY_RATE      words/min               (default: system)
#   CLAUDESAY_DISABLE   any value silences      (default: unset)
#   CLAUDESAY_STATE     state directory         (default: per-user TMPDIR)
#
#   CLAUDESAY_ENGINE        say | kokoro        (default: say)
#   CLAUDESAY_KOKORO_PORT   loopback port       (default: 8787)
#   CLAUDESAY_KOKORO_VOICE  Kokoro voice        (default: af_heart)
#   CLAUDESAY_KOKORO_IDLE   server idle-exit s  (default: 300)
#   CLAUDESAY_KOKORO_TIMEOUT synth timeout s    (default: 10)

set -u

CLAUDESAY_VERSION="0.4.0"

# Where this script lives — the optional voice server sits beside it.
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR="."

# CLI flags. The hook is normally invoked with stdin JSON and no args,
# but --version / --test let users sanity-check the install without
# waiting for a real Claude Code turn.
case "${1:-}" in
    --version|-V)
        echo "claudesay $CLAUDESAY_VERSION"
        exit 0 ;;
    --test)
        # Handled below, once the engines are defined — a test that bypassed
        # the engine layer would happily pass on a broken kokoro setup.
        TEST_MODE=1 ;;
    --help|-h)
        cat <<USAGE
claudesay $CLAUDESAY_VERSION — Stop hook for Claude Code

Normal usage is invocation by Claude Code with stdin JSON. CLI helpers:
  --version, -V    Print version and exit
  --test           Speak a test sentence through the configured engine
  --help, -h       This message

Engines: CLAUDESAY_ENGINE=say (default, instant, built-in) or =kokoro
(neural, local, needs uv; first use warms a server and falls back to say).

See ~/.claude/settings.json for hook wiring; see env vars at the top of
$0 for tuning (CLAUDESAY_VOICE, CLAUDESAY_DEBOUNCE, CLAUDESAY_DEBUG, …).
USAGE
        exit 0 ;;
esac
TEST_MODE="${TEST_MODE:-}"

[[ -n "${CLAUDESAY_DISABLE:-}" ]] && exit 0

# Optional verbose tracing — set CLAUDESAY_DEBUG=1 (or in settings.json env)
# to log every decision the hook makes. Helps diagnose "why didn't it speak?"
if [[ -n "${CLAUDESAY_DEBUG:-}" ]]; then
    debug() { printf 'claudesay: %s\n' "$*" >&2; }
else
    debug() { :; }
fi

VOICE="${CLAUDESAY_VOICE:-Samantha}"
DEBOUNCE_SEC="${CLAUDESAY_DEBOUNCE:-4}"
MIN_LEN="${CLAUDESAY_MIN_LEN:-40}"
MAX_SPEAK="${CLAUDESAY_MAX:-220}"
RATE="${CLAUDESAY_RATE:-}"

# Validate VOICE/RATE — these become argv to `say`. The only real risk
# is a value that starts with `-` being parsed as a flag (CLAUDESAY_VOICE
# could otherwise be set to something like '-r 1000 -o /tmp/x.aiff').
# Don't be stricter than that — real macOS voice names include apostrophes
# (O'Hara), accents (Amélie), spaces (Bad News), and parens.
if [[ "${VOICE:0:1}" == "-" ]]; then
    VOICE="Samantha"
fi
if [[ -n "$RATE" ]] && ! [[ "$RATE" =~ ^[0-9]+$ ]]; then
    RATE=""
fi

ENGINE="${CLAUDESAY_ENGINE:-say}"
KOKORO_PORT="${CLAUDESAY_KOKORO_PORT:-8787}"
KOKORO_TIMEOUT="${CLAUDESAY_KOKORO_TIMEOUT:-10}"
VOICE_SCRIPT="${CLAUDESAY_VOICE_SCRIPT:-$SELF_DIR/claudesay-voice.py}"

# Unknown engine names degrade to `say` rather than going silent — a typo in
# settings.json should cost you a nicer voice, not every notification.
case "$ENGINE" in
    say|kokoro) ;;
    *) ENGINE="say" ;;
esac
# Both of these are numbers that end up in a URL and a curl timeout.
[[ "$KOKORO_PORT" =~ ^[0-9]+$ ]] || KOKORO_PORT="8787"
[[ "$KOKORO_TIMEOUT" =~ ^[0-9]+$ ]] || KOKORO_TIMEOUT="10"

# State dir defaults to a per-user, mode-0700 path under $TMPDIR (which
# macOS sets to a private /var/folders/... per session) to avoid the
# /tmp/claudesay symlink/race surface that's exposed when /tmp is shared.
DEFAULT_STATE="${TMPDIR:-/tmp}/claudesay-$(id -u 2>/dev/null || echo nobody)"
DEFAULT_STATE="${DEFAULT_STATE%/}"
STATE_DIR="${CLAUDESAY_STATE:-$DEFAULT_STATE}"

# `say` is required for every engine — it is the fallback path, not just the
# default one. jq is checked later: it is only needed to parse a Stop payload,
# and `--test` should still work without it.
command -v say >/dev/null 2>&1 || exit 0

mkdir -p "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null || true

# ─── Engines ────────────────────────────────────────────────────────────────
# Each engine backgrounds a player and echoes that player's PID. Barge-in only
# ever needs the PID, so it stays engine-agnostic.

speak_say() {
    local text="$1"
    if [[ -n "$RATE" ]]; then
        say -r "$RATE" -v "$VOICE" "$text" </dev/null >/dev/null 2>&1 &
    else
        say -v "$VOICE" "$text" </dev/null >/dev/null 2>&1 &
    fi
    printf '%s' "$!"
}

kokoro_is_warm() {
    curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$KOKORO_PORT/health" 2>/dev/null
}

# Start the voice server detached. It binds before it loads, so a second
# instance loses the port race and exits 0 — safe to call from concurrent
# sessions without a lock.
kokoro_warm_up() {
    [[ -f "$VOICE_SCRIPT" ]] || { debug "kokoro: no voice script at $VOICE_SCRIPT"; return 1; }
    command -v uv >/dev/null 2>&1 || { debug "kokoro: uv not installed"; return 1; }
    debug "kokoro: starting voice server (first load takes ~30s)"
    nohup uv run --quiet "$VOICE_SCRIPT" >>"$STATE_DIR/voice.log" 2>&1 &
    disown 2>/dev/null || true
}

speak_kokoro() {
    local text="$1" wav="$STATE_DIR/$SAFE_KEY.wav"

    # Same discipline as the other state files: `curl -o` and `afplay` would
    # both follow a planted symlink, so remove the link itself first (rm -f on
    # a symlink deletes the link, never its target).
    if [[ -L "$wav" ]]; then rm -f "$wav"; fi
    if [[ -L "$wav.part" ]]; then rm -f "$wav.part"; fi

    if ! kokoro_is_warm; then
        # Never make the user wait on a cold model. Warm it for next time and
        # let `say` carry this turn.
        kokoro_warm_up
        speak_say "$text"
        return
    fi

    # `--data-binary @-` from stdin, never from an argument: curl treats a
    # leading `@` in an inline value as "read this file", which would let a
    # reply beginning with "@/etc/…" pull a local file into the request.
    if ! printf '%s' "$text" | curl -fsS --max-time "$KOKORO_TIMEOUT" \
            -H 'Content-Type: text/plain; charset=utf-8' \
            --data-binary @- -o "$wav.part" \
            "http://127.0.0.1:$KOKORO_PORT/speak" 2>/dev/null; then
        debug "kokoro: synth failed or timed out — falling back to say"
        rm -f "$wav.part"
        speak_say "$text"
        return
    fi

    if ! mv -f "$wav.part" "$wav" 2>/dev/null; then
        rm -f "$wav.part"
        speak_say "$text"
        return
    fi

    afplay "$wav" </dev/null >/dev/null 2>&1 &
    printf '%s' "$!"
}

speak() {
    if [[ "$ENGINE" == "kokoro" ]] && command -v afplay >/dev/null 2>&1; then
        speak_kokoro "$1"
    else
        speak_say "$1"
    fi
}

# --test: exercise the real engine path, so a broken kokoro setup shows up here
# rather than silently degrading for weeks.
if [[ -n "$TEST_MODE" ]]; then
    SAFE_KEY="test"
    if [[ "$ENGINE" == "kokoro" ]]; then
        if kokoro_is_warm; then
            echo "claudesay: engine=kokoro (voice server warm, voice '${CLAUDESAY_KOKORO_VOICE:-af_heart}')"
        else
            echo "claudesay: engine=kokoro but the voice server is cold."
            echo "           Speaking this one with say and warming the server now;"
            echo "           re-run --test in ~30s to hear the neural voice."
        fi
    else
        echo "claudesay: engine=say (voice '$VOICE')"
    fi
    speak "Claudesay is wired correctly." >/dev/null
    disown 2>/dev/null || true
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)

# Loop guard — Stop can fire again if a previous hook forced continuation.
if [[ "$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)" == "true" ]]; then
    debug "skip: stop_hook_active=true (avoiding loop)"
    exit 0
fi

TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null)
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
    debug "skip: missing or unreadable transcript_path ($TRANSCRIPT)"
    exit 0
fi

# Sanitize session_id for use as a filename component.
SAFE_KEY=$(printf '%s' "${SESSION_ID:-default}" | tr -c 'A-Za-z0-9._-' '_')
LAST_FILE="$STATE_DIR/$SAFE_KEY.last"
HASH_FILE="$STATE_DIR/$SAFE_KEY.hash"
PID_FILE="$STATE_DIR/$SAFE_KEY.pid"

# Self-heal any planted symlinks. Removing a symlink with `rm -f` deletes
# the link itself, not its target. Subsequent writes go through `mv -f`
# (rename(2)) which atomically replaces a path even if a same-uid attacker
# re-symlinks it between this `rm` and the write — rename swaps the dest
# inode rather than following the link.
for f in "$LAST_FILE" "$HASH_FILE" "$PID_FILE" "$STATE_DIR/$SAFE_KEY.wav"; do
    [[ -L "$f" ]] && rm -f "$f"
done

# Atomic state writer — used for every state file so a TOCTOU symlink
# can't make us write through a planted target.
write_state() {
    local target="$1"
    local value="$2"
    local tmp="$target.$$.tmp"
    if printf '%s\n' "$value" >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp"
    fi
}

# Debounce — collapse rapid Stop events from the same session. Validate
# LAST_AT is numeric before arithmetic context: bash recursively evaluates
# variables in `$(( … ))`, so a planted `LAST_AT='a[$(id)]'` could execute.
NOW=$(date +%s)
LAST_AT=""
# `$(<file)` is bash's no-fork "fast read"; appending `2>/dev/null` would
# break the special form and return empty, so the `-f && ! -L` check
# above is what guards the read.
if [[ -f "$LAST_FILE" && ! -L "$LAST_FILE" ]]; then
    LAST_AT=$(<"$LAST_FILE")
fi
if [[ ! "$LAST_AT" =~ ^[0-9]+$ ]]; then
    LAST_AT=""
fi
if [[ -n "$LAST_AT" && $((NOW - LAST_AT)) -lt $DEBOUNCE_SEC ]]; then
    debug "skip: debounced (last fire $((NOW - LAST_AT))s ago, threshold ${DEBOUNCE_SEC}s)"
    exit 0
fi
write_state "$LAST_FILE" "$NOW"

# Last *text-bearing* assistant message in the .jsonl transcript.
# - Tool-use, thinking, redacted_thinking blocks are skipped (we only speak prose).
# - Compaction summary entries are skipped (those describe Claude's own context
#   rotation, not the latest user-facing reply).
MSG=$(jq -s -r '
    [ .[]
      | select(.type == "assistant" and (.isCompactSummary != true))
      | (
          if .message.content | type == "array"
          then [.message.content[] | select(.type == "text") | .text] | join(" ")
          else (.message.content // "")
          end
        )
      | select(. != null and (. | tostring | length) > 0)
    ] | last // ""
' "$TRANSCRIPT" 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

if [[ -z "$MSG" || "$MSG" == "null" ]]; then
    debug "skip: no text-bearing assistant message (tool-use only?)"
    exit 0
fi
if [[ ${#MSG} -lt $MIN_LEN ]]; then
    debug "skip: too short (${#MSG} < $MIN_LEN chars): ${MSG:0:60}"
    exit 0
fi

# Filter mid-pipeline filler. A long message starting with "Now" is
# probably a real summary — only filter if the message is short AND
# looks transitional. We lowercase the prefix before matching because
# bash 3.2 (default on macOS) ignores `shopt -s nocasematch` inside
# `case` statements; pre-lowercasing is portable.
if [[ ${#MSG} -lt 120 ]]; then
    PREFIX_LOWER=$(printf '%s' "${MSG:0:30}" | tr '[:upper:]' '[:lower:]')
    case "$PREFIX_LOWER" in
        "let me "*|"i'll "*|"i"$'\xe2\x80\x99'"ll "*|\
        "i will "*|"i'm going to "*|"i"$'\xe2\x80\x99'"m going to "*|\
        "i'm "*|"i"$'\xe2\x80\x99'"m "*|"i am "*|\
        "now "*|\
        "running "*|"reading "*|"checking "*|"looking "*|"searching "*|\
        "going "*|"let's "*|"let"$'\xe2\x80\x99'"s "*|"lets "*|\
        "trying "*|"testing "*|\
        "one moment"*|"hold on"*|"hmm"*|"ok "*|"ok,"*|"sure"*|"got it"*|\
        "done"*|"got "*|"yep"*|"yes"*|"no,"*|"actually"*)
            debug "skip: filler (\"${MSG:0:40}…\")"
            exit 0
            ;;
    esac
fi

# Dedupe — never repeat exactly the same message back to back. md5 is BSD
# on macOS, md5sum is GNU; cksum is POSIX and always present.
hash_string() {
    if command -v md5 >/dev/null 2>&1; then
        printf '%s' "$1" | md5
    elif command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$1" | md5sum | cut -d' ' -f1
    else
        printf '%s' "$1" | cksum | tr -d ' '
    fi
}
HASH=$(hash_string "$MSG")
EXISTING_HASH=""
if [[ -f "$HASH_FILE" && ! -L "$HASH_FILE" ]]; then
    EXISTING_HASH=$(<"$HASH_FILE")
fi
if [[ "$EXISTING_HASH" == "$HASH" ]]; then
    debug "skip: deduped (same content as previous fire)"
    exit 0
fi
write_state "$HASH_FILE" "$HASH"

# Pick the last meaningful sentence — questions and summaries both land
# there; first sentences are usually throat-clearing.
SPEAK=$(awk '
{
    s = $0
    gsub(/[.!?]+[[:space:]]+/, "&\n", s)
    n = split(s, lines, "\n")
    for (i = n; i >= 1; i--) {
        sub(/^[[:space:]]+/, "", lines[i])
        sub(/[[:space:]]+$/, "", lines[i])
        if (length(lines[i]) >= 15) { print lines[i]; exit }
    }
}' <<<"$MSG")

[[ -z "$SPEAK" ]] && SPEAK="${MSG:0:$MAX_SPEAK}"
if [[ ${#SPEAK} -gt $MAX_SPEAK ]]; then
    SPEAK="${SPEAK:0:$((MAX_SPEAK - 3))}..."
fi

# Strip markdown + ANSI so `say` doesn't read literal asterisks, backticks,
# escape sequences, etc.
SPEAK=$(printf '%s' "$SPEAK" | sed -E '
    s/'$'\x1b''\[[0-9;]*[A-Za-z]//g;
    s/```[^`]*```//g;
    s/`+//g;
    s/\*+//g;
    s/\[([^]]+)\]\([^)]+\)/\1/g;
    s/[#>_~|]//g;
    s/[[:space:]]+/ /g;
    s/^[[:space:]]+//;
    s/[[:space:]]+$//;
')

[[ -z "$SPEAK" ]] && exit 0

# Refuse to speak a $SPEAK that begins with `-` so `say` can't reinterpret it
# as a flag (e.g. text starting with "- list item" after markdown stripping).
[[ "${SPEAK:0:1}" == "-" ]] && SPEAK=" $SPEAK"

# Barge-in — kill only this session's previous player (PID-tracked), not
# every `say`/`afplay` on the user's machine. Verify the PID is still one
# of our player commands before sending SIGTERM: macOS PIDs recycle, and
# we don't want to kill an unrelated process that inherited the PID.
if [[ -f "$PID_FILE" && ! -L "$PID_FILE" ]]; then
    OLD_PID=$(<"$PID_FILE")
    if [[ "$OLD_PID" =~ ^[0-9]+$ ]]; then
        OLD_COMM=$(ps -p "$OLD_PID" -o comm= 2>/dev/null)
        OLD_COMM="${OLD_COMM##*/}"
        OLD_COMM="${OLD_COMM##[[:space:]]}"
        OLD_COMM="${OLD_COMM%%[[:space:]]}"
        if [[ "$OLD_COMM" == "say" || "$OLD_COMM" == "afplay" ]]; then
            kill "$OLD_PID" 2>/dev/null || true
        fi
    fi
fi

debug "speak: engine=$ENGINE voice=$VOICE rate=${RATE:-default} text=\"${SPEAK:0:80}\""

PLAYER_PID=$(speak "$SPEAK")
write_state "$PID_FILE" "$PLAYER_PID"
disown 2>/dev/null || true
exit 0
