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
#   CLAUDESAY_ENGINE   auto | say | kokoro      (default: auto)
#   CLAUDESAY_KOKORO_PORT   loopback port       (default: 8787)
#   CLAUDESAY_KOKORO_VOICE  Kokoro voice        (default: af_heart)
#   CLAUDESAY_KOKORO_IDLE   server idle-exit s  (default: 300)
#   CLAUDESAY_KOKORO_TIMEOUT synth timeout s    (default: 10)
#
#   CLAUDESAY_MUTE_WHEN_MIC  silence during calls (default: 1)
#   CLAUDESAY_MIC_TTL        mic-check cache secs (default: 8)
#   CLAUDESAY_QUEUE_WAIT     max queue wait secs  (default: 30)
#   CLAUDESAY_MUTE_FILE      mute switch path     (default: ~/.claude/…)
#   CLAUDESAY_SILENT         render, do not play  (default: unset)

set -u

CLAUDESAY_VERSION="0.6.2"

# Where this script lives — the optional voice server sits beside it.
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_DIR="."

# Mute lives outside the state dir on purpose. State is per-boot scratch under
# $TMPDIR; a mute you set before a meeting must survive a reboot, and — more
# importantly — must be visible to every session on the machine at once.
MUTE_FILE="${CLAUDESAY_MUTE_FILE:-$HOME/.claude/claudesay-muted}"

is_muted() {
    [[ -f "$MUTE_FILE" ]] || return 1
    local until; until=$(cat "$MUTE_FILE" 2>/dev/null)
    [[ "$until" == "forever" ]] && return 0
    if [[ "$until" =~ ^[0-9]+$ ]]; then
        (( $(date +%s) < until )) && return 0
        rm -f "$MUTE_FILE" 2>/dev/null   # expired — clear it so it self-heals
    fi
    return 1
}

mute_status() {
    if ! is_muted; then echo "claudesay: unmuted"; return 0; fi
    local until; until=$(cat "$MUTE_FILE" 2>/dev/null)
    if [[ "$until" == "forever" ]]; then
        echo "claudesay: muted (until you unmute)"
    else
        local mins=$(( (until - $(date +%s) + 59) / 60 ))
        echo "claudesay: muted for another ${mins}m"
    fi
}

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
    --mute)
        # `--mute` alone holds until you unmute; `--mute 45` is the meeting case
        # and expires on its own, because the mute you forget to lift is the one
        # that quietly makes the tool useless.
        mkdir -p "$(dirname "$MUTE_FILE")" 2>/dev/null
        if [[ "${2:-}" =~ ^[0-9]+$ ]] && (( $2 > 0 )); then
            printf '%s\n' "$(( $(date +%s) + $2 * 60 ))" >"$MUTE_FILE"
        else
            printf 'forever\n' >"$MUTE_FILE"
        fi
        mute_status
        # Silence anything already speaking — you pressed this to stop a voice.
        killall say afplay 2>/dev/null
        exit 0 ;;
    --unmute)
        rm -f "$MUTE_FILE" 2>/dev/null
        echo "claudesay: unmuted"
        exit 0 ;;
    --toggle-mute)
        mkdir -p "$(dirname "$MUTE_FILE")" 2>/dev/null
        if is_muted; then
            rm -f "$MUTE_FILE" 2>/dev/null
            echo "claudesay: unmuted"
        else
            printf 'forever\n' >"$MUTE_FILE"
            echo "claudesay: muted"
            killall say afplay 2>/dev/null
        fi
        exit 0 ;;
    --mute-status)
        mute_status
        exit 0 ;;
    --help|-h)
        cat <<USAGE
claudesay $CLAUDESAY_VERSION — Stop hook for Claude Code

Normal usage is invocation by Claude Code with stdin JSON. CLI helpers:
  --version, -V    Print version and exit
  --test           Speak a test sentence through the configured engine
  --mute [MIN]     Silence every session; optionally for MIN minutes
  --unmute         Resume speaking
  --toggle-mute    Flip mute — bind this to a global hotkey
  --mute-status    Report whether claudesay is muted
  --help, -h       This message

Mute is machine-wide and takes effect immediately, including in sessions
that are already running. It silences claudesay only, never system audio.

Engine is chosen for you: the local neural voice when this machine can run
it, the built-in voice otherwise. Force it with CLAUDESAY_ENGINE=say|kokoro.

See ~/.claude/settings.json for hook wiring; see env vars at the top of
$0 for tuning (CLAUDESAY_VOICE, CLAUDESAY_DEBOUNCE, CLAUDESAY_DEBUG, …).
USAGE
        exit 0 ;;
esac
TEST_MODE="${TEST_MODE:-}"

[[ -n "${CLAUDESAY_DISABLE:-}" ]] && exit 0

# Muted is a machine-wide, live switch — checked on every fire rather than read
# once at session start, so hitting the hotkey silences sessions that are
# already running. It mutes claudesay only; system audio is untouched.
if is_muted && [[ -z "${TEST_MODE:-}" ]]; then
    exit 0
fi

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

ENGINE="${CLAUDESAY_ENGINE:-auto}"
MUTE_WHEN_MIC="${CLAUDESAY_MUTE_WHEN_MIC:-1}"
SILENT="${CLAUDESAY_SILENT:-}"
MIC_TTL="${CLAUDESAY_MIC_TTL:-8}"
MIC_SCRIPT="${CLAUDESAY_MIC_SCRIPT:-$SELF_DIR/claudesay-mic.py}"
[[ "$MIC_TTL" =~ ^[0-9]+$ ]] || MIC_TTL=8
KOKORO_PORT="${CLAUDESAY_KOKORO_PORT:-8787}"
KOKORO_TIMEOUT="${CLAUDESAY_KOKORO_TIMEOUT:-10}"
VOICE_SCRIPT="${CLAUDESAY_VOICE_SCRIPT:-$SELF_DIR/claudesay-voice.py}"

# Unknown engine names degrade rather than going silent — a typo in
# settings.json should cost you a nicer voice, not every notification.
case "$ENGINE" in
    say|kokoro|auto) ;;
    *) ENGINE="auto" ;;
esac

# `auto` is the default because picking an engine is not a decision anyone
# wants to make. If the machine can run the neural voice, it runs it; if it
# can't, `say` covers it and nothing is announced or asked. The neural path
# already falls back per-utterance, so guessing wrong here costs nothing.
if [[ "$ENGINE" == "auto" ]]; then
    if [[ -f "$VOICE_SCRIPT" ]] \
        && command -v uv >/dev/null 2>&1 \
        && command -v afplay >/dev/null 2>&1 \
        && [[ "$(uname -m 2>/dev/null)" == "arm64" ]]; then
        ENGINE="kokoro"
    else
        ENGINE="say"
    fi
fi
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

# ─── Meeting detection ──────────────────────────────────────────────────────
# If a microphone is live, you are on a call, and a voice notification is the
# single worst thing this tool can do — it goes out to everyone listening, and
# you cannot take it back. So an active mic silences claudesay automatically.
#
# The probe reads CoreAudio's "is this device running somewhere" flag, the same
# signal behind the orange dot in the menu bar. It never opens a stream, so it
# captures nothing and never asks for microphone permission.
#
# The result is cached for MIC_TTL seconds: the hook fires on every turn and a
# python spawn per turn would eat the latency budget, while a meeting does not
# start and stop inside eight seconds.
mic_is_hot() {
    [[ "$MUTE_WHEN_MIC" == "1" ]] || return 1
    [[ -f "$MIC_SCRIPT" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 1

    local cache="$STATE_DIR/mic.cache" now ts val
    now=$(date +%s)
    if [[ -f "$cache" && ! -L "$cache" ]]; then
        read -r ts val <"$cache" 2>/dev/null || true
        if [[ "${ts:-}" =~ ^[0-9]+$ ]] && (( now - ts < MIC_TTL )); then
            [[ "${val:-}" == "hot" ]] && return 0
            return 1
        fi
    fi

    python3 "$MIC_SCRIPT" >/dev/null 2>&1
    local rc=$?
    # rc 0 = a mic is live. rc 1 = idle. rc 2 = could not tell — and "could not
    # tell" must mean speak, or a broken probe would mute you forever without
    # ever saying why.
    if (( rc == 0 )); then
        write_state "$cache" "$now hot"
        return 0
    fi
    write_state "$cache" "$now cold"
    return 1
}

if [[ -z "$TEST_MODE" ]] && mic_is_hot; then
    debug "skip: a microphone is live — you are probably on a call"
    exit 0
fi

# ─── Playback queue ─────────────────────────────────────────────────────────
# Barge-in is per session: a new utterance cuts off that session's previous one.
# But two *different* sessions ending at the same moment used to talk over each
# other, which is the one failure that makes voice notifications useless — you
# can re-read a screen, you cannot un-hear two overlapping sentences.
#
# So playback takes a machine-wide lock. Within a session the newest line still
# wins immediately; across sessions lines wait their turn. `mkdir` is the mutex
# because it is atomic on every filesystem we care about, needs no `flock`
# (macOS ships none), and leaves a directory we can stamp with the holder's PID.

LOCK_DIR="$STATE_DIR/play.lock"
QUEUE_WAIT="${CLAUDESAY_QUEUE_WAIT:-30}"
[[ "$QUEUE_WAIT" =~ ^[0-9]+$ ]] || QUEUE_WAIT=30

# The lock records the *player's* PID, not the holding shell's.
#
# A shell cannot portably learn its own PID inside `( … )`: `$$` still names the
# original shell, `$BASHPID` needs bash 4 (stock macOS ships 3.2), and
# `sh -c 'echo $PPID'` names the command-substitution subshell. Every one of
# those dies the instant the hook returns, so contenders would see a dead holder,
# break the lock, and all speak at once — the exact bug this queue prevents.
#
# `say`/`afplay` are real processes that live exactly as long as the speech, so
# they are the honest holder. The pid appears a beat after the directory does,
# which is what STALE_GRACE covers.
STALE_GRACE=5

acquire_play_lock() {
    local ticks=0 max=$((QUEUE_WAIT * 4)) holder at now
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        holder=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [[ "$holder" =~ ^[0-9]+$ ]]; then
            # A named holder that has exited leaves the lock free.
            if ! kill -0 "$holder" 2>/dev/null; then
                rm -rf "$LOCK_DIR" 2>/dev/null
                continue
            fi
        else
            # No pid yet: either the winner is a beat from writing one, or it
            # died between mkdir and starting its player. Age decides which.
            at=$(cat "$LOCK_DIR/at" 2>/dev/null)
            now=$(date +%s)
            if [[ ! "$at" =~ ^[0-9]+$ ]] || (( now - at > STALE_GRACE )); then
                rm -rf "$LOCK_DIR" 2>/dev/null
                continue
            fi
        fi
        # Give up rather than let a backlog build. Speech that arrives a minute
        # late describes work you have already moved on from.
        if (( ticks >= max )); then return 1; fi
        /bin/sleep 0.25
        ticks=$((ticks + 1))
    done
    date +%s >"$LOCK_DIR/at" 2>/dev/null
    return 0
}

# Run a player behind the queue. Sets the global JOB_PID rather than echoing it:
# capturing via $(...) would background the job inside a command-substitution
# subshell, and that job does not outlive the hook process — the speech would be
# cut off the instant the hook returned. Backgrounding from the main shell also
# lets `disown` actually find the job.
#
# The job records the real player PID into $PID_FILE once it wins the queue and
# starts speaking, which is the PID barge-in signals.
JOB_PID=""
play_queued() {
    (
        acquire_play_lock || exit 0
        # shellcheck disable=SC2064  # expand LOCK_DIR now, not at trap time
        trap "rm -rf '$LOCK_DIR' 2>/dev/null" EXIT
        "$@" </dev/null >/dev/null 2>&1 &
        player=$!
        # Publish the holder before anything else: contenders are waiting on it.
        printf '%s\n' "$player" >"$LOCK_DIR/pid" 2>/dev/null
        write_state "$PID_FILE" "$player"
        wait "$player"
    ) &
    JOB_PID=$!
    disown 2>/dev/null || true
}

# ─── Engines ────────────────────────────────────────────────────────────────
# Each engine hands its player to the queue and echoes the queue job's PID.
# Barge-in needs only PIDs, so it stays engine-agnostic.

speak_say() {
    local text="$1"
    # Dry run: render to a file instead of the speakers. Same `say` binary, same
    # queue, same PIDs — just no sound. This is what lets the test suite run on
    # a laptop that is also in a meeting, and it exists because a test run once
    # talked over a live call.
    if [[ -n "$SILENT" ]]; then
        play_queued say -v "$VOICE" -o "$STATE_DIR/$SAFE_KEY.render.aiff" "$text"
        return
    fi
    if [[ -n "$RATE" ]]; then
        play_queued say -r "$RATE" -v "$VOICE" "$text"
    else
        play_queued say -v "$VOICE" "$text"
    fi
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

    # Dry run stands in a real short-lived process so the queue still has
    # something to serialize on, without sending the audio anywhere.
    if [[ -n "$SILENT" ]]; then
        play_queued /bin/sleep 0.5
        return
    fi
    play_queued afplay "$wav"
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
    PID_FILE="$STATE_DIR/$SAFE_KEY.pid"
    JOB_FILE="$STATE_DIR/$SAFE_KEY.job"
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
    speak "Claudesay is wired correctly."
    write_state "$JOB_FILE" "$JOB_PID"
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
JOB_FILE="$STATE_DIR/$SAFE_KEY.job"

# Self-heal any planted symlinks. Removing a symlink with `rm -f` deletes
# the link itself, not its target. Subsequent writes go through `mv -f`
# (rename(2)) which atomically replaces a path even if a same-uid attacker
# re-symlinks it between this `rm` and the write — rename swaps the dest
# inode rather than following the link.
for f in "$LAST_FILE" "$HASH_FILE" "$PID_FILE" "$JOB_FILE" "$STATE_DIR/$SAFE_KEY.wav"; do
    [[ -L "$f" ]] && rm -f "$f"
done

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

# ─── Code is not speech ─────────────────────────────────────────────────────
# Claude Code renders inline code in violet because it is not prose, and it
# reads even worse than it looks: `events.team_id` comes out as "events dot
# team eye dee", a path is a stream of slashes, and by the time it finishes you
# have missed the sentence. So a code span becomes the *category* of thing it
# is — the file, that command, that setting — which is what you would say out
# loud anyway. The name is on your screen; the sentence is for your ears.
#
# This runs before the length, filler and dedupe checks on purpose. Those all
# ask questions about what you are going to hear, so they should be asked of
# the string you will actually hear.
strip_code() {
    awk '
    BEGIN {
        CMDS  = " npm yarn pnpm npx git bash sh zsh cd ls make cargo go rustc python python3 pip uv brew curl wget jq say node deno docker kubectl rm mv cp mkdir chmod chown sudo echo cat grep sed awk find ssh open swift swiftc xcodebuild pytest ruff eslint tsc terraform gh killall afplay shellcheck "
        ARTS  = " the a an this that these those its his her their our your my "
        NOUNS = " file files script scripts command commands setting settings variable variables function functions method methods module modules package folder directory path flag option key value field column table endpoint hook hooks test tests suite server port "
        EXTS  = "\\.(ts|tsx|js|jsx|mjs|cjs|py|sh|bash|zsh|go|rs|rb|java|c|h|cc|cpp|cs|swift|kt|php|sql|json|jsonl|ya?ml|toml|md|txt|css|scss|html|lock|plist|env|cfg|ini|log|wav|mp3|png)$"
    }
    function is_in(list, w) { return index(list, " " tolower(w) " ") > 0 }

    # What is this, said out loud? "" drops it, KEEP speaks it verbatim,
    # anything else is a noun that phrase() turns into words.
    function kind(t,   first) {
        sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
        if (t == "") return ""
        if (t ~ /^(https?:\/\/|www\.)/) return "link"
        if (t ~ /\(\)$/) return "function"
        if (t ~ /[[:space:]]/) {
            first = t; sub(/[[:space:]].*$/, "", first)
            if (is_in(CMDS, first) || first ~ /^\.\//) return "command"
            if (t ~ /(^|[[:space:]])-{1,2}[A-Za-z]/) return "command"
            return "KEEP"          # plain words in backticks are still prose
        }
        if (is_in(CMDS, t) || t ~ /^\.\//) return "command"
        if (t ~ /\//) return "file"
        if (t ~ EXTS) return "file"
        if (t ~ /^[A-Z][A-Z0-9_]{2,}$/) return "setting"
        if (t ~ /^[0-9]+([.,][0-9]+)?$/) return "KEEP"   # numbers read fine
        if (t ~ /^[A-Za-z]+$/) return "KEEP"             # `true`, `main`
        return "it"
    }
    function phrase(k) {
        if (k == "file")     return "the file"
        if (k == "link")     return "the link"
        if (k == "command")  return "that command"
        if (k == "setting")  return "that setting"
        if (k == "function") return "that function"
        return "it"
    }
    function bare(k) { return (k == "it") ? "value" : phrase(k) }

    function lastword(s) { sub(/[^A-Za-z0-9]+$/, "", s); sub(/^.*[^A-Za-z0-9]/, "", s); return s }
    function firstword(s) { sub(/^[^A-Za-z0-9]+/, "", s); sub(/[^A-Za-z0-9].*$/, "", s); return s }

    # The words on either side pick the article, so "the `auth.ts` file" comes
    # out as "the file" rather than "the the file file".
    function emit(k, before, after) {
        if (k == "" || k == "KEEP") return ""
        if (is_in(NOUNS, firstword(after))) return ""   # the noun after it already says this
        return is_in(ARTS, lastword(before)) ? bare(k) : phrase(k)
    }

    {
        line = $0
        gsub(/```[^`]*```/, " ", line)     # a fenced block has nothing to say
        # Split on backticks: odd fields are prose, even fields are the spans.
        # An unterminated trailing span is left alone rather than guessed at.
        n = split(line, part, "`")
        out = ""
        for (i = 1; i <= n; i++) {
            if (i % 2 == 1 || i == n) { out = out part[i]; continue }
            k = kind(part[i])
            if (k == "KEEP") { out = out part[i]; continue }
            out = out emit(k, out, part[i+1])
        }

        # Second pass for code that was never backticked. Only the unmistakable
        # shapes — a URL, a path, a name carrying a code extension — so that
        # ordinary prose and "and/or" and "e.g." are left alone.
        m = split(out, w, " ")
        res = ""
        for (i = 1; i <= m; i++) {
            core = w[i]; tail = ""; head = ""
            if (match(core, /[.,;:!?)"'"'"']+$/)) {
                tail = substr(core, RSTART); core = substr(core, 1, RSTART - 1)
            }
            if (match(core, /^[("'"'"']+/)) {
                head = substr(core, 1, RLENGTH); core = substr(core, RLENGTH + 1)
            }
            k = ""
            if (core ~ /^(https?:\/\/|www\.)/) k = "link"
            else if (core ~ /^\.?\/[A-Za-z0-9_.\/-]+$/) k = "file"
            else if (core ~ EXTS && core ~ /^[A-Za-z0-9_.\/-]+$/) k = "file"
            if (k != "") {
                said = emit(k, res, (i < m) ? w[i+1] : "")
                if (said == "") { if (tail != "") res = res " " tail; continue }
                core = said
            }
            res = res (res == "" ? "" : " ") head core tail
        }
        print res
    }
    '
}

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
' "$TRANSCRIPT" 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
  | strip_code | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

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

# Barge-in — cut off only this session's previous utterance, never another
# session's and never an unrelated process. Two PIDs are involved now: the
# player, and the queue job that may still be waiting its turn.
#
# Order matters. Kill the player first: its job is sitting in `wait`, so it
# wakes, runs its EXIT trap, and releases the lock for whoever is queued
# behind it. Killing the job first would strand the lock until the next
# caller noticed the holder was dead.
comm_of() {
    local c
    c=$(ps -p "$1" -o comm= 2>/dev/null)
    c="${c##*/}"; c="${c##[[:space:]]}"; c="${c%%[[:space:]]}"
    printf '%s' "$c"
}

if [[ -f "$PID_FILE" && ! -L "$PID_FILE" ]]; then
    OLD_PID=$(<"$PID_FILE")
    # PIDs recycle on macOS, so confirm identity before signalling.
    if [[ "$OLD_PID" =~ ^[0-9]+$ ]]; then
        case "$(comm_of "$OLD_PID")" in
            say|afplay) kill "$OLD_PID" 2>/dev/null || true ;;
        esac
    fi
fi

if [[ -f "$JOB_FILE" && ! -L "$JOB_FILE" ]]; then
    OLD_JOB=$(<"$JOB_FILE")
    # A job still queued has never started a player, so dropping it is how a
    # stale line gets cancelled instead of eventually being spoken.
    if [[ "$OLD_JOB" =~ ^[0-9]+$ && "$OLD_JOB" != "$$" ]]; then
        case "$(comm_of "$OLD_JOB")" in
            bash|sh) kill "$OLD_JOB" 2>/dev/null || true ;;
        esac
    fi
fi

debug "speak: engine=$ENGINE voice=$VOICE rate=${RATE:-default} text=\"${SPEAK:0:80}\""

# speak() sets JOB_PID; the player PID is written by the job itself once it
# wins the queue and actually starts speaking.
speak "$SPEAK"
write_state "$JOB_FILE" "$JOB_PID"
disown 2>/dev/null || true
exit 0
