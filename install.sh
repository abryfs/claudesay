#!/usr/bin/env bash
# claudesay installer — wires the Stop hook into ~/.claude/settings.json,
# with an interactive voice picker that previews each voice on highlight.

set -euo pipefail

REPO_RAW="${CLAUDESAY_RAW:-https://raw.githubusercontent.com/abryfs/claudesay/main}"
HOOKS_DIR="$HOME/.claude/hooks"
SCRIPT_PATH="$HOOKS_DIR/claudesay.sh"
SETTINGS="$HOME/.claude/settings.json"

# Flags. --voice=<name> skips the picker (handy for non-TTY installs
# like `claude code` agents driving the install). --no-picker uses the
# default voice silently.
FLAG_VOICE=""
FLAG_NO_PICKER=""
for arg in "$@"; do
    case "$arg" in
        --voice=*)     FLAG_VOICE="${arg#--voice=}" ;;
        --no-picker)   FLAG_NO_PICKER=1 ;;
        -h|--help)
            cat <<'USAGE'
claudesay installer
  ./install.sh                       # interactive voice picker
  ./install.sh --voice=Daniel        # skip picker, set voice
  ./install.sh --no-picker           # skip picker, default Samantha
  CLAUDESAY_VOICE=Karen ./install.sh # env equivalent of --voice
USAGE
            exit 0 ;;
    esac
done
[[ -n "$FLAG_VOICE" ]] && export CLAUDESAY_VOICE="$FLAG_VOICE"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "claudesay v1 is macOS-only (uses /usr/bin/say). Aborting." >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }
command -v say >/dev/null 2>&1 || { echo "say not found — not on macOS?" >&2; exit 1; }

mkdir -p "$HOOKS_DIR"

# ─── 1. Install the hook script ──────────────────────────────────────────────
if [[ -f "$(dirname "$0")/claudesay.sh" ]]; then
    cp "$(dirname "$0")/claudesay.sh" "$SCRIPT_PATH"
else
    curl -fsSL "$REPO_RAW/claudesay.sh" -o "$SCRIPT_PATH"
fi
chmod +x "$SCRIPT_PATH"
echo "✓ installed $SCRIPT_PATH"

# ─── 2. Pick a voice (interactive arrow-key TUI with live preview) ───────────
SELECTED_VOICE=""
SELECTED_RATE=""

pick_voice() {
    # Honor a pre-set env override (skip the picker entirely)
    if [[ -n "${CLAUDESAY_VOICE:-}" ]]; then
        SELECTED_VOICE="$CLAUDESAY_VOICE"
        echo "✓ using preset CLAUDESAY_VOICE=$SELECTED_VOICE"
        return 0
    fi
    if [[ -n "$FLAG_NO_PICKER" ]]; then
        SELECTED_VOICE="Samantha"
        echo "✓ --no-picker → using default voice (Samantha)"
        return 0
    fi

    # The picker reads keystrokes from stdin. If we were piped (curl|bash),
    # stdin is the script — reattach to /dev/tty so the user can drive it.
    if [[ ! -t 0 ]]; then
        if [[ -r /dev/tty ]]; then
            exec </dev/tty
        else
            echo "Non-interactive shell — using default voice (Samantha)."
            SELECTED_VOICE="Samantha"
            return 0
        fi
    fi

    # Parse `say -v '?'`. Format is fixed-column:
    #   Samantha            en_US    # Hello! My name is Samantha.
    # Voice names can include spaces and parens, so we anchor on the locale.
    local NAMES=() LANGS=() SAMPLES=()
    local samantha_idx=0 idx=0
    # `say -v '?'` separates name and locale by 2+ spaces, e.g.:
    #   Samantha            en_US    # Hello! My name is Samantha.
    # Names can contain single spaces (e.g. "Bad News", "Eddy (English (US))").
    # macOS ships with bash 3.2 which has flaky `{n,}` quantifier support in
    # `[[ =~ ]]` regex, so we parse with awk anchored on the locale code.
    while IFS=$'\t' read -r nm lc sm; do
        [[ -z "$nm" ]] && continue
        NAMES+=("$nm")
        LANGS+=("$lc")
        SAMPLES+=("$sm")
        [[ "$nm" == "Samantha" && "$lc" == "en_US" ]] && samantha_idx=$idx
        ((idx++))
    done < <(say -v '?' 2>/dev/null | awk '
        match($0, /[a-z][a-z]_[A-Z][A-Z]/) {
            name = substr($0, 1, RSTART - 1)
            sub(/[[:space:]]+$/, "", name)
            sub(/^[[:space:]]+/, "", name)
            locale = substr($0, RSTART, RLENGTH)
            rest = substr($0, RSTART + RLENGTH)
            sub(/^[[:space:]]+/, "", rest)
            sub(/^#[[:space:]]*/, "", rest)
            if (locale ~ /^en_(US|GB|AU|IE|IN|ZA)$/) {
                print name "\t" locale "\t" rest
            }
        }
    ')

    local n=${#NAMES[@]}
    if [[ $n -eq 0 ]]; then
        SELECTED_VOICE="Samantha"
        return 0
    fi

    # Viewport setup
    local term_rows; term_rows=$(tput lines 2>/dev/null || echo 24)
    local rows=$((term_rows - 10))
    [[ $rows -lt 6 ]] && rows=6
    [[ $rows -gt $n ]] && rows=$n

    local cursor=$samantha_idx
    local viewport_start=0
    if [[ $cursor -ge $rows ]]; then
        viewport_start=$((cursor - rows + 1))
    fi

    local last_previewed=""

    cleanup() {
        tput cnorm 2>/dev/null || true
        killall say 2>/dev/null || true
        stty echo 2>/dev/null || true
    }
    trap 'cleanup; exit 130' INT TERM

    tput civis 2>/dev/null || true   # hide cursor
    stty -echo 2>/dev/null || true   # don't echo keystrokes

    redraw() {
        clear
        printf '\n  \033[1mPick a voice for claudesay\033[0m\n'
        printf '  \033[2m↑↓ navigate (auto-preview)   ⏎ select   r replay   a all/english   q default\033[0m\n\n'
        local end=$((viewport_start + rows))
        [[ $end -gt $n ]] && end=$n
        local i
        for ((i = viewport_start; i < end; i++)); do
            if [[ $i -eq $cursor ]]; then
                printf '  \033[7m▸ %-26s %-6s\033[0m\n' "${NAMES[i]}" "${LANGS[i]}"
            else
                printf '    %-26s %-6s\n' "${NAMES[i]}" "${LANGS[i]}"
            fi
        done
        printf '\n  \033[2m%s\033[0m\n' "${SAMPLES[cursor]}"
        printf '  \033[2m(%d of %d)\033[0m\n' $((cursor + 1)) $n
    }

    preview() {
        local force="${1:-}"
        if [[ "$force" == "force" || "${NAMES[cursor]}" != "$last_previewed" ]]; then
            killall say 2>/dev/null || true
            ( say -v "${NAMES[cursor]}" "${SAMPLES[cursor]}" >/dev/null 2>&1 & ) 2>/dev/null
            last_previewed="${NAMES[cursor]}"
        fi
    }

    redraw
    preview force

    local key rest
    while true; do
        IFS= read -rsn1 key || break
        case "$key" in
            $'\x1b')  # escape sequence (arrow keys)
                IFS= read -rsn2 -t 0.05 rest || rest=""
                case "$rest" in
                    '[A')  # up
                        if [[ $cursor -gt 0 ]]; then
                            ((cursor--))
                            [[ $cursor -lt $viewport_start ]] && viewport_start=$cursor
                            redraw; preview
                        fi ;;
                    '[B')  # down
                        if [[ $cursor -lt $((n - 1)) ]]; then
                            ((cursor++))
                            [[ $cursor -ge $((viewport_start + rows)) ]] && viewport_start=$((cursor - rows + 1))
                            redraw; preview
                        fi ;;
                    '[5')  # page up (consume the trailing ~)
                        IFS= read -rsn1 -t 0.01 _ || true
                        cursor=$((cursor - rows))
                        [[ $cursor -lt 0 ]] && cursor=0
                        viewport_start=$cursor
                        redraw; preview ;;
                    '[6')  # page down
                        IFS= read -rsn1 -t 0.01 _ || true
                        cursor=$((cursor + rows))
                        [[ $cursor -ge $n ]] && cursor=$((n - 1))
                        viewport_start=$((cursor - rows + 1))
                        [[ $viewport_start -lt 0 ]] && viewport_start=0
                        redraw; preview ;;
                esac ;;
            ''|$'\n')  # enter
                killall say 2>/dev/null || true
                SELECTED_VOICE="${NAMES[cursor]}"
                break ;;
            'r'|'R')   # replay current
                preview force ;;
            'q'|'Q')   # quit → use default
                killall say 2>/dev/null || true
                SELECTED_VOICE="Samantha"
                break ;;
        esac
    done

    cleanup
    clear
    echo "✓ voice: $SELECTED_VOICE"
}

pick_voice

# ─── 3. Wire the Stop hook in settings.json ──────────────────────────────────
if [[ ! -f "$SETTINGS" ]]; then
    echo '{}' > "$SETTINGS"
fi
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

# Self-healing: strip prior claudesay/voice-notify Stop entries, then add ours.
# Also persist the chosen voice into .env (merged, doesn't disturb other keys).
TMP=$(mktemp)
jq --arg p "$SCRIPT_PATH" --arg v "$SELECTED_VOICE" '
    .env //= {}
    | (if $v != "" and $v != "Samantha" then .env.CLAUDESAY_VOICE = $v else . end)
    | .hooks //= {}
    | .hooks.Stop = (
        (.hooks.Stop // [])
        | map(
            .hooks = ((.hooks // []) | map(select(
                ((.command // "") | test("claudesay\\.sh|voice-notify\\.sh")) | not
            )))
            | select((.hooks // []) | length > 0)
          )
      )
    | .hooks.Stop += [{
        "matcher": "*",
        "hooks": [{ "type": "command", "command": $p }]
      }]
' "$SETTINGS" > "$TMP"
mv "$TMP" "$SETTINGS"
echo "✓ wired Stop hook into $SETTINGS (backup at $SETTINGS.bak.*)"

cat <<EOF

Open a new Claude Code session and ask Claude something — when the
response ends, you'll hear the last sentence in $SELECTED_VOICE's voice.

Tweak via env in ~/.claude/settings.json:
  CLAUDESAY_VOICE     macOS voice (say -v '?' to list)
  CLAUDESAY_DEBOUNCE  seconds between fires (default 4)
  CLAUDESAY_MIN_LEN   skip shorter messages (default 40)
  CLAUDESAY_MAX       max chars to speak (default 220)
  CLAUDESAY_RATE      words per minute (default: system)
  CLAUDESAY_DISABLE   set to silence without uninstalling

Re-pick voice anytime: bash install.sh
Remove: bash uninstall.sh
EOF
