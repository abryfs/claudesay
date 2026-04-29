#!/usr/bin/env bash
# claudesay installer — wires the Stop hook into ~/.claude/settings.json
# Idempotent. Backs up your settings.json before touching it.

set -euo pipefail

REPO_RAW="${CLAUDESAY_RAW:-https://raw.githubusercontent.com/abryfs/claudesay/main}"
HOOKS_DIR="$HOME/.claude/hooks"
SCRIPT_PATH="$HOOKS_DIR/claudesay.sh"
SETTINGS="$HOME/.claude/settings.json"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "claudesay v1 is macOS-only (uses /usr/bin/say). Aborting." >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required (brew install jq)" >&2; exit 1; }
command -v say >/dev/null 2>&1 || { echo "say not found — not on macOS?" >&2; exit 1; }

mkdir -p "$HOOKS_DIR"

# 1. Place the hook script. Prefer a local copy from the repo checkout;
#    fall back to curl if running via `curl … | bash`.
if [[ -f "$(dirname "$0")/claudesay.sh" ]]; then
    cp "$(dirname "$0")/claudesay.sh" "$SCRIPT_PATH"
else
    curl -fsSL "$REPO_RAW/claudesay.sh" -o "$SCRIPT_PATH"
fi
chmod +x "$SCRIPT_PATH"
echo "✓ installed $SCRIPT_PATH"

# 2. Wire the Stop hook in settings.json. Idempotent — won't add a
#    duplicate entry if claudesay is already wired.
if [[ ! -f "$SETTINGS" ]]; then
    echo '{}' > "$SETTINGS"
fi

cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

# Self-healing: strip any existing claudesay or legacy voice-notify
# Stop entries first, then add the canonical one. Prevents double-fire.
TMP=$(mktemp)
jq --arg p "$SCRIPT_PATH" '
    .hooks //= {}
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

Done. Open a new Claude Code session and ask Claude something — when
the response ends, you'll hear the last sentence spoken.

Tweak via env vars in ~/.claude/settings.json:
  CLAUDESAY_VOICE=Daniel        # macOS voice (say -v '?' to list)
  CLAUDESAY_DEBOUNCE=4          # seconds between fires
  CLAUDESAY_MIN_LEN=40          # skip messages shorter than this
  CLAUDESAY_MAX=220             # max chars to speak
  CLAUDESAY_RATE=200            # words per minute
  CLAUDESAY_DISABLE=1           # silence without uninstalling

To remove: ./uninstall.sh   (or curl … | bash on the URL)
EOF
