#!/usr/bin/env bash
# claudesay — tasteful voice notifications for Claude Code
# https://github.com/abryfs/claudesay  (placeholder until you push)
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

set -u

[[ -n "${CLAUDESAY_DISABLE:-}" ]] && exit 0

VOICE="${CLAUDESAY_VOICE:-Samantha}"
DEBOUNCE_SEC="${CLAUDESAY_DEBOUNCE:-4}"
MIN_LEN="${CLAUDESAY_MIN_LEN:-40}"
MAX_SPEAK="${CLAUDESAY_MAX:-220}"
RATE="${CLAUDESAY_RATE:-}"
STATE_DIR="${CLAUDESAY_STATE:-/tmp/claudesay}"

command -v jq >/dev/null 2>&1 || exit 0
command -v say >/dev/null 2>&1 || exit 0

mkdir -p "$STATE_DIR" 2>/dev/null

INPUT=$(cat)

# Loop guard — Stop can fire again if a previous hook forced continuation
if [[ "$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)" == "true" ]]; then
    exit 0
fi

TRANSCRIPT=$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null)
SESSION_ID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
[[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

KEY="${SESSION_ID:-default}"
LAST_FILE="$STATE_DIR/$KEY.last"
HASH_FILE="$STATE_DIR/$KEY.hash"

# Debounce — collapse rapid Stop events from the same session
NOW=$(date +%s)
if [[ -f "$LAST_FILE" ]]; then
    LAST_AT=$(<"$LAST_FILE")
    if [[ -n "$LAST_AT" && $((NOW - LAST_AT)) -lt $DEBOUNCE_SEC ]]; then
        exit 0
    fi
fi
echo "$NOW" >"$LAST_FILE"

# Last *text-bearing* assistant message in the .jsonl transcript.
# Tool-use-only assistant entries are skipped — we only speak prose.
MSG=$(jq -s -r '
    [ .[]
      | select(.type == "assistant")
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
# looks transitional.
if [[ ${#MSG} -lt 120 ]]; then
    shopt -s nocasematch
    case "$MSG" in
        "Let me "*|"I'll "*|"I will "*|"I'm going to "*|"I'm "*|"I am "*|\
        "Now "*|"Now I"*|"Now let me"*|\
        "Running "*|"Reading "*|"Checking "*|"Looking "*|"Searching "*|\
        "Going "*|"Let's "*|"Lets "*|"Trying "*|"Testing "*|\
        "One moment"*|"Hold on"*|"Hmm"*|"OK "*|"OK,"*|"Sure"*|"Got it"*|\
        "Done"*|"Got "*|"Yep"*|"Yes"*|"No,"*|"Actually"*)
            shopt -u nocasematch
            exit 0
            ;;
    esac
    shopt -u nocasematch
fi

# Dedupe — never repeat exactly the same message back to back
HASH=$(printf '%s' "$MSG" | md5)
if [[ -f "$HASH_FILE" && "$(<"$HASH_FILE")" == "$HASH" ]]; then
    exit 0
fi
echo "$HASH" >"$HASH_FILE"

# Pick the last meaningful sentence — questions and summaries both
# land there; first sentences are usually throat-clearing.
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

# Strip markdown so `say` doesn't read literal asterisks, backticks, etc.
SPEAK=$(printf '%s' "$SPEAK" | sed -E '
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

# Barge-in — kill anything currently speaking before we start
killall say 2>/dev/null

if [[ -n "$RATE" ]]; then
    say -r "$RATE" -v "$VOICE" "$SPEAK" &
else
    say -v "$VOICE" "$SPEAK" &
fi
disown 2>/dev/null
exit 0
