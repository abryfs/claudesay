#!/usr/bin/env bash
# claudesay uninstaller — removes the Stop hook entry, the script, and state.

set -euo pipefail

HOOKS_DIR="$HOME/.claude/hooks"
SCRIPT_PATH="$HOOKS_DIR/claudesay.sh"
LEGACY_PATH="$HOOKS_DIR/voice-notify.sh"
SETTINGS="$HOME/.claude/settings.json"

if [[ -f "$SETTINGS" ]]; then
    if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
        echo "⚠ $SETTINGS is not valid JSON — leaving it alone." >&2
        exit 1
    fi

    cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

    # Atomic write: tmp file in the same dir → mv is rename(2).
    TMP=$(mktemp "$SETTINGS.tmp.XXXXXX")
    trap 'rm -f "$TMP"' EXIT

    # Match commands by exact equality (or trailing-component match) rather
    # than substring `contains`, so we don't accidentally strip an unrelated
    # user hook whose path happens to contain "claudesay.sh" as a substring.
    if ! jq --arg p "$SCRIPT_PATH" --arg lp "$LEGACY_PATH" '
        def is_target(c):
            c == $p or c == $lp
            or (c | endswith("/claudesay.sh"))
            or (c | endswith("/voice-notify.sh"));
        .hooks //= {}
        | .hooks.Stop = (
            ( if (.hooks.Stop | type) == "array" then .hooks.Stop else [] end )
            | map(
                .hooks = ((.hooks // []) | map(select(is_target(.command // "") | not)))
                | select((.hooks // []) | length > 0)
              )
          )
    ' "$SETTINGS" >"$TMP"; then
        echo "⚠ jq failed to update $SETTINGS — backup at $SETTINGS.bak.*" >&2
        exit 1
    fi

    mv "$TMP" "$SETTINGS"
    trap - EXIT
    echo "✓ removed Stop hook entry from $SETTINGS"
fi

rm -f "$SCRIPT_PATH"
echo "✓ removed $SCRIPT_PATH"

# Clean up state files. Both default state-dir layouts are removed:
# the per-user one (TMPDIR-based) and the v0.1 one under /tmp.
DEFAULT_STATE="${TMPDIR:-/tmp}/claudesay-$(id -u 2>/dev/null || echo nobody)"
DEFAULT_STATE="${DEFAULT_STATE%/}"
[[ -d "$DEFAULT_STATE" ]] && rm -rf "$DEFAULT_STATE" && echo "✓ removed $DEFAULT_STATE"
[[ -d /tmp/claudesay ]] && rm -rf /tmp/claudesay && echo "✓ removed /tmp/claudesay"

if [[ -f "$LEGACY_PATH" ]]; then
    echo "ℹ legacy hook still present at $LEGACY_PATH — remove manually if unused"
fi
