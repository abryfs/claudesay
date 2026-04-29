#!/usr/bin/env bash
# claudesay — tasteful voice notifications for Claude Code
# https://github.com/abryfs/claudesay
#
# Wired as a Stop hook. Speaks the meaningful end of Claude's reply
# (usually the final sentence — questions, summaries, decisions land
# there) and stays silent on filler/mid-pipeline pauses, duplicates,
# and trivial "OK / Done" responses. Pure macOS `say`. No API keys,
# no daemon, no per-call cost.
#
# Configure via env (set in ~/.claude/settings.json -> env):
#   CLAUDESAY_VOICE     macOS voice name        (default: Samantha)
#   CLAUDESAY_DEBOUNCE  seconds between fires   (default: 4)
#   CLAUDESAY_MIN_LEN   skip if shorter         (default: 40)
#   CLAUDESAY_MAX       max chars to speak      (default: 220)
#   CLAUDESAY_RATE      words/min               (default: system)
#   CLAUDESAY_DISABLE   any value silences      (default: unset)
#   CLAUDESAY_STATE     state directory         (default: per-user TMPDIR)

set -u

[[ -n "${CLAUDESAY_DISABLE:-}" ]] && exit 0

VOICE="${CLAUDESAY_VOICE:-Samantha}"
DEBOUNCE_SEC="${CLAUDESAY_DEBOUNCE:-4}"
MIN_LEN="${CLAUDESAY_MIN_LEN:-40}"
MAX_SPEAK="${CLAUDESAY_MAX:-220}"
RATE="${CLAUDESAY_RATE:-}"

# Validate VOICE/RATE — these become argv to `say`. Reject anything that
# could be parsed as a flag (starting with `-`) or that contains shell-
# unfriendly chars. macOS voice names match [A-Za-z][A-Za-z0-9 ()]*.
if ! [[ "$VOICE" =~ ^[A-Za-z][A-Za-z0-9\ \(\)]*$ ]]; then
    VOICE="Samantha"
fi
if [[ -n "$RATE" ]] && ! [[ "$RATE" =~ ^[0-9]+$ ]]; then
    RATE=""
fi

# State dir defaults to a per-user, mode-0700 path under $TMPDIR (which
# macOS sets to a private /var/folders/... per session) to avoid the
# /tmp/claudesay symlink/race surface that's exposed when /tmp is shared.
DEFAULT_STATE="${TMPDIR:-/tmp}/claudesay-$(id -u 2>/dev/null || echo nobody)"
DEFAULT_STATE="${DEFAULT_STATE%/}"
STATE_DIR="${CLAUDESAY_STATE:-$DEFAULT_STATE}"

command -v jq >/dev/null 2>&1 || exit 0
command -v say >/dev/null 2>&1 || exit 0

mkdir -p "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null || true

INPUT=$(cat)

# Loop guard — Stop can fire again if a previous hook forced continuation.
if [[ "$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)" == "true" ]]; then
    exit 0
fi

TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null)
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
[[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

# Sanitize session_id for use as a filename component.
SAFE_KEY=$(printf '%s' "${SESSION_ID:-default}" | tr -c 'A-Za-z0-9._-' '_')
LAST_FILE="$STATE_DIR/$SAFE_KEY.last"
HASH_FILE="$STATE_DIR/$SAFE_KEY.hash"
PID_FILE="$STATE_DIR/$SAFE_KEY.pid"

# Refuse to follow symlinks for state files — defense-in-depth even with
# a private state dir.
for f in "$LAST_FILE" "$HASH_FILE" "$PID_FILE"; do
    [[ -L "$f" ]] && exit 0
done

# Debounce — collapse rapid Stop events from the same session.
NOW=$(date +%s)
if [[ -f "$LAST_FILE" ]]; then
    LAST_AT=$(<"$LAST_FILE")
    if [[ -n "$LAST_AT" && $((NOW - LAST_AT)) -lt $DEBOUNCE_SEC ]]; then
        exit 0
    fi
fi
printf '%s\n' "$NOW" >"$LAST_FILE"

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

[[ -z "$MSG" || "$MSG" == "null" ]] && exit 0
[[ ${#MSG} -lt $MIN_LEN ]] && exit 0

# Filter mid-pipeline filler. A long message starting with "Now" is
# probably a real summary — only filter if the message is short AND
# looks transitional. The U+2019 variant (’) catches smart-quoted "I'll".
if [[ ${#MSG} -lt 120 ]]; then
    shopt -s nocasematch
    case "$MSG" in
        "Let me "*|"I'll "*|"I"$'\xe2\x80\x99'"ll "*|\
        "I will "*|"I'm going to "*|"I"$'\xe2\x80\x99'"m going to "*|\
        "I'm "*|"I"$'\xe2\x80\x99'"m "*|"I am "*|\
        "Now "*|"Now I"*|"Now let me"*|\
        "Running "*|"Reading "*|"Checking "*|"Looking "*|"Searching "*|\
        "Going "*|"Let's "*|"Let"$'\xe2\x80\x99'"s "*|"Lets "*|\
        "Trying "*|"Testing "*|\
        "One moment"*|"Hold on"*|"Hmm"*|"OK "*|"OK,"*|"Sure"*|"Got it"*|\
        "Done"*|"Got "*|"Yep"*|"Yes"*|"No,"*|"Actually"*)
            shopt -u nocasematch
            exit 0
            ;;
    esac
    shopt -u nocasematch
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
if [[ -f "$HASH_FILE" && "$(<"$HASH_FILE")" == "$HASH" ]]; then
    exit 0
fi
printf '%s\n' "$HASH" >"$HASH_FILE"

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

# Barge-in — kill only this session's previous `say` (PID-tracked), not
# every `say` on the user's machine.
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(<"$PID_FILE")
    if [[ -n "$OLD_PID" && "$OLD_PID" =~ ^[0-9]+$ ]]; then
        kill "$OLD_PID" 2>/dev/null || true
    fi
fi

if [[ -n "$RATE" ]]; then
    say -r "$RATE" -v "$VOICE" "$SPEAK" </dev/null >/dev/null 2>&1 &
else
    say -v "$VOICE" "$SPEAK" </dev/null >/dev/null 2>&1 &
fi
SAY_PID=$!
printf '%s\n' "$SAY_PID" >"$PID_FILE"
disown 2>/dev/null || true
exit 0
