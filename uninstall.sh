#!/usr/bin/env bash
# claudesay uninstaller — removes the Stop hook entry and the script.

set -euo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
SCRIPT_PATH="$HOOKS_DIR/claudesay.sh"
LEGACY_PATH="$HOOKS_DIR/voice-notify.sh"
SETTINGS="$HOME/.claude/settings.json"

if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
    TMP=$(mktemp)
    jq --arg p "$SCRIPT_PATH" --arg lp "$LEGACY_PATH" '
        .hooks.Stop = (
          (.hooks.Stop // [])
          | map(. as $entry
              | $entry
              | .hooks = ((.hooks // []) | map(select(
                  ((.command // "") | contains($p)) | not
                  and (((.command // "") | contains($lp)) | not)
                )))
              | select((.hooks // []) | length > 0)
            )
        )
    ' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    echo "✓ removed Stop hook entry from $SETTINGS"
fi

rm -f "$SCRIPT_PATH"
echo "✓ removed $SCRIPT_PATH"

if [[ -f "$LEGACY_PATH" ]]; then
    echo "ℹ legacy hook found at $LEGACY_PATH — leaving in place; remove manually if unused"
fi
