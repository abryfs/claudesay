#!/usr/bin/env bash
# claudesay installer — wires the Stop hook into ~/.claude/settings.json,
# with an interactive voice picker that previews each voice on highlight.

set -euo pipefail

CLAUDESAY_VERSION="0.4.0"

REPO_RAW="${CLAUDESAY_RAW:-https://raw.githubusercontent.com/abryfs/claudesay/main}"
HOOKS_DIR="$HOME/.claude/hooks"
SCRIPT_PATH="$HOOKS_DIR/claudesay.sh"
VOICE_PATH="$HOOKS_DIR/claudesay-voice.py"
SETTINGS="$HOME/.claude/settings.json"
HOOK_TIMEOUT_SEC=15

# Flags. --voice=<name> skips the picker (handy for non-TTY installs
# like `claude code` agents driving the install). --no-picker uses the
# default voice silently.
FLAG_VOICE=""
FLAG_NO_PICKER=""
for arg in "$@"; do
    case "$arg" in
        --voice=*)     FLAG_VOICE="${arg#--voice=}" ;;
        --no-picker)   FLAG_NO_PICKER=1 ;;
        --version|-V)
            echo "claudesay $CLAUDESAY_VERSION"
            exit 0 ;;
        -h|--help)
            cat <<USAGE
claudesay $CLAUDESAY_VERSION — installer

  ./install.sh                       # interactive voice picker
  ./install.sh --voice=Daniel        # skip picker, set voice
  ./install.sh --no-picker           # skip picker, default Samantha
  ./install.sh --version, -V         # print version and exit
  ./install.sh --help, -h            # this message
  CLAUDESAY_VOICE=Karen ./install.sh # env equivalent of --voice
USAGE
            exit 0 ;;
    esac
done
# Reject --voice values that would be parsed as a flag by `say`. The hook
# itself validates again at runtime, but catching it here gives a clean
# error instead of silently writing a bad voice into settings.json.
if [[ -n "$FLAG_VOICE" ]]; then
    if [[ "${FLAG_VOICE:0:1}" == "-" ]]; then
        echo "✗ --voice cannot start with '-' (would be parsed as a say(1) flag)" >&2
        exit 1
    fi
    export CLAUDESAY_VOICE="$FLAG_VOICE"
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "claudesay v1 is macOS-only (uses /usr/bin/say). Aborting." >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }
command -v say >/dev/null 2>&1 || { echo "say not found — not on macOS?" >&2; exit 1; }

mkdir -p "$HOOKS_DIR"

# ─── 1. Install the hook script ──────────────────────────────────────────────
# Prefer a sibling claudesay.sh from the repo checkout; fall back to curl
# when running via `curl … | bash`. Use BASH_SOURCE rather than $0 because
# under pipe-to-bash $0 is the literal string "bash" and dirname yields ".".
SELF_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
fi

if [[ -n "$SELF_DIR" && -f "$SELF_DIR/claudesay.sh" ]]; then
    cp "$SELF_DIR/claudesay.sh" "$SCRIPT_PATH"
else
    curl -fsSL "$REPO_RAW/claudesay.sh" -o "$SCRIPT_PATH"
fi
chmod +x "$SCRIPT_PATH"
echo "✓ installed $SCRIPT_PATH"

# The optional neural voice server ships alongside the hook, which looks for it
# as a sibling. It is inert unless CLAUDESAY_ENGINE=kokoro, so installing it
# always costs nothing and saves a second install step for anyone who opts in.
if [[ -n "$SELF_DIR" && -f "$SELF_DIR/claudesay-voice.py" ]]; then
    cp "$SELF_DIR/claudesay-voice.py" "$VOICE_PATH"
else
    curl -fsSL "$REPO_RAW/claudesay-voice.py" -o "$VOICE_PATH" || true
fi
if [[ -s "$VOICE_PATH" ]]; then
    chmod +x "$VOICE_PATH"
    echo "✓ installed $VOICE_PATH (neural voice — set CLAUDESAY_ENGINE=kokoro to use)"
else
    rm -f "$VOICE_PATH"
    echo "  (skipped the optional neural voice server — say engine works regardless)"
fi

# ─── 2. Pick a voice (interactive arrow-key TUI with live preview) ───────────
SELECTED_VOICE=""

pick_voice() {
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
    # stdin is the script text — reattach to /dev/tty so the user can drive it.
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
    # macOS bash 3.2 has flaky `{n,}` support inside `[[ =~ ]]`, so we anchor
    # on the locale code via awk and use explicit array indexing (bash 3.2's
    # `arr+=()` can leave NAMES[0] unset).
    local NAMES=() LANGS=() SAMPLES=()
    local samantha_idx=0 idx=0
    while IFS=$'\t' read -r nm lc sm; do
        [[ -z "$nm" ]] && continue
        NAMES[idx]="$nm"
        LANGS[idx]="$lc"
        SAMPLES[idx]="$sm"
        [[ "$nm" == "Samantha" && "$lc" == "en_US" ]] && samantha_idx=$idx
        idx=$((idx + 1))
    done < <(say -v '?' 2>/dev/null | awk '
        match($0, /[a-z][a-z]_[A-Z][A-Z]/) {
            name = substr($0, 1, RSTART - 1)
            sub(/[[:space:]]+$/, "", name); sub(/^[[:space:]]+/, "", name)
            locale = substr($0, RSTART, RLENGTH)
            rest = substr($0, RSTART + RLENGTH)
            sub(/^[[:space:]]+/, "", rest); sub(/^#[[:space:]]*/, "", rest)
            if (locale ~ /^en_(US|GB|AU|IE|IN|ZA)$/) print name "\t" locale "\t" rest
        }
    ')

    local n=${#NAMES[@]}
    if [[ $n -eq 0 ]]; then
        SELECTED_VOICE="Samantha"
        return 0
    fi

    local rows
    local cursor=$samantha_idx
    local viewport_start=0
    local last_previewed=""
    local preview_pid=""

    # Recompute viewport size — picks up terminal resize between keystrokes.
    recompute_rows() {
        local term_rows
        term_rows=$(tput lines 2>/dev/null || echo 24)
        rows=$((term_rows - 10))
        [[ $rows -lt 6 ]] && rows=6
        [[ $rows -gt $n ]] && rows=$n
        # Re-clamp viewport_start in case terminal shrank below current cursor.
        if [[ $cursor -ge $((viewport_start + rows)) ]]; then
            viewport_start=$((cursor - rows + 1))
            [[ $viewport_start -lt 0 ]] && viewport_start=0
        fi
    }
    recompute_rows
    [[ $cursor -ge $rows ]] && viewport_start=$((cursor - rows + 1))

    # Verify-then-kill — a stored PID may have been recycled.
    kill_if_say() {
        local pid="$1"
        [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && return 0
        local comm
        comm=$(ps -p "$pid" -o comm= 2>/dev/null)
        comm="${comm##*/}"
        comm="${comm##[[:space:]]}"
        comm="${comm%%[[:space:]]}"
        [[ "$comm" == "say" ]] && kill "$pid" 2>/dev/null || true
    }

    cleanup() {
        tput cnorm 2>/dev/null || true
        stty echo 2>/dev/null || true
        kill_if_say "$preview_pid"
    }
    # Run cleanup on any normal exit AND on every fatal signal we can trap.
    # Without EXIT, an early `read` failure (broken TTY, terminal close)
    # would leave the cursor hidden and stty in -echo state.
    trap 'cleanup' EXIT
    trap 'cleanup; exit 130' INT TERM HUP QUIT

    tput civis 2>/dev/null || true
    stty -echo 2>/dev/null || true

    redraw() {
        recompute_rows
        clear
        printf '\n  \033[1mPick a voice for claudesay\033[0m\n'
        printf '  \033[2m↑↓ navigate (auto-preview)   ⏎ select   r replay   q default\033[0m\n\n'
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
        if [[ "$force" != "force" && "${NAMES[cursor]}" == "$last_previewed" ]]; then
            return
        fi
        kill_if_say "$preview_pid"
        say -v "${NAMES[cursor]}" "${SAMPLES[cursor]}" </dev/null >/dev/null 2>&1 &
        preview_pid=$!
        last_previewed="${NAMES[cursor]}"
    }

    redraw
    preview force

    local key rest
    while true; do
        IFS= read -rsn1 key || break
        case "$key" in
            $'\x1b')
                IFS= read -rsn2 -t 0.05 rest || rest=""
                case "$rest" in
                    '[A')
                        if [[ $cursor -gt 0 ]]; then
                            cursor=$((cursor - 1))
                            [[ $cursor -lt $viewport_start ]] && viewport_start=$cursor
                            redraw; preview
                        fi ;;
                    '[B')
                        if [[ $cursor -lt $((n - 1)) ]]; then
                            cursor=$((cursor + 1))
                            [[ $cursor -ge $((viewport_start + rows)) ]] && viewport_start=$((cursor - rows + 1))
                            redraw; preview
                        fi ;;
                    '[5')
                        IFS= read -rsn1 -t 0.01 _ || true
                        cursor=$((cursor - rows))
                        [[ $cursor -lt 0 ]] && cursor=0
                        viewport_start=$cursor
                        redraw; preview ;;
                    '[6')
                        IFS= read -rsn1 -t 0.01 _ || true
                        cursor=$((cursor + rows))
                        [[ $cursor -ge $n ]] && cursor=$((n - 1))
                        viewport_start=$((cursor - rows + 1))
                        [[ $viewport_start -lt 0 ]] && viewport_start=0
                        redraw; preview ;;
                esac ;;
            ''|$'\n')
                SELECTED_VOICE="${NAMES[cursor]}"
                break ;;
            'r'|'R')
                preview force ;;
            'q'|'Q')
                SELECTED_VOICE="Samantha"
                break ;;
        esac
    done

    # cleanup runs via EXIT trap; clear it now so the success print is visible.
    trap - EXIT
    cleanup
    clear
    echo "✓ voice: $SELECTED_VOICE"
}

pick_voice

# Defensive: if the picker somehow returned without setting a voice, default.
if [[ -z "$SELECTED_VOICE" ]]; then
    SELECTED_VOICE="Samantha"
fi

# ─── 3. Wire the Stop hook in settings.json ──────────────────────────────────
if [[ ! -f "$SETTINGS" ]]; then
    echo '{}' >"$SETTINGS"
fi

# Validate existing JSON before touching it.
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    echo "⚠ $SETTINGS is not valid JSON — leaving it alone." >&2
    echo "  Fix the file or move it aside, then re-run install.sh." >&2
    exit 1
fi

cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

# Atomic update: mktemp in the SAME directory so `mv` is rename(2).
# Falling back to a cross-device mv risks a truncated settings.json mid-copy
# if the disk fills up — we don't want to brick Claude Code.
TMP=$(mktemp "$SETTINGS.tmp.XXXXXX")
trap 'rm -f "$TMP"' EXIT

# Self-healing: strip prior claudesay/voice-notify Stop entries, then add the
# canonical one. Type-coerce .hooks.Stop in case the user's existing config
# has it as an object — without coercion jq would error and `set -e` would
# abort mid-install with the hook script copied but settings unwired.
if ! jq --arg p "$SCRIPT_PATH" \
        --arg v "$SELECTED_VOICE" \
        --argjson t "$HOOK_TIMEOUT_SEC" '
    .env //= {}
    | (if $v != "" and $v != "Samantha" then .env.CLAUDESAY_VOICE = $v else . end)
    | .hooks //= {}
    | .hooks.Stop = (
        ( if (.hooks.Stop | type) == "array" then .hooks.Stop else [] end )
        | map(
            .hooks = ((.hooks // []) | map(select(
                ((.command // "") | test("claudesay\\.sh|voice-notify\\.sh")) | not
            )))
            | select((.hooks // []) | length > 0)
          )
      )
    | .hooks.Stop += [{
        "hooks": [{ "type": "command", "command": $p, "timeout": $t }]
      }]
' "$SETTINGS" >"$TMP"; then
    echo "⚠ jq failed to update $SETTINGS." >&2
    echo "  Backup is at $SETTINGS.bak.*" >&2
    exit 1
fi

mv "$TMP" "$SETTINGS"
trap - EXIT
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
