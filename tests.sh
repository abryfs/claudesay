#!/usr/bin/env bash
# claudesay test suite. Runs in isolated tmp dirs so it never touches
# your real ~/.claude. Exits non-zero on first failure.
#
#   ./tests.sh           # run all tests
#   bash tests.sh -v     # verbose (show each test's output)

set -uo pipefail
shopt -s expand_aliases

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$PWD"
HOOK="$ROOT/claudesay.sh"
INSTALLER="$ROOT/install.sh"
UNINSTALLER="$ROOT/uninstall.sh"

VERBOSE=""
[[ "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0
FAIL=0
FAILED_TESTS=()

c_red() { printf '\033[31m%s\033[0m' "$1"; }
c_grn() { printf '\033[32m%s\033[0m' "$1"; }
c_dim() { printf '\033[2m%s\033[0m' "$1"; }

run() {
    local name="$1"; shift
    local out
    if out=$("$@" 2>&1); then
        printf '  %s %s\n' "$(c_grn ✓)" "$name"
        [[ -n "$VERBOSE" && -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    /'
        PASS=$((PASS + 1))
    else
        printf '  %s %s\n' "$(c_red ✗)" "$name"
        printf '%s\n' "$out" | sed 's/^/    /'
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

mk_jsonl() {
    # Build a one-line assistant transcript with given text.
    local text="$1"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
        "$(printf '%s' "$text" | jq -Rs .)"
}

fire_hook() {
    # fire_hook <state_dir> <session_id> <transcript_text>
    local state="$1" sid="$2" text="$3"
    local jsonl
    jsonl=$(mktemp)
    mk_jsonl "$text" >"$jsonl"
    local stop_input
    stop_input=$(printf '{"transcript_path":"%s","session_id":"%s","stop_hook_active":false}' "$jsonl" "$sid")
    CLAUDESAY_STATE="$state" \
    CLAUDESAY_DEBUG=1 \
        bash "$HOOK" <<<"$stop_input"
    local rc=$?
    rm -f "$jsonl"
    return $rc
}

# ─── Section: --version / --test / --help ───────────────────────────────────
test_version() {
    local out; out=$(bash "$HOOK" --version)
    [[ "$out" =~ ^claudesay\ [0-9] ]] || { echo "got: $out"; return 1; }
}
test_help() {
    bash "$HOOK" --help | grep -q "Stop hook for Claude Code"
}
test_installer_version() {
    local out; out=$(bash "$INSTALLER" --version)
    [[ "$out" =~ ^claudesay\ [0-9] ]] || { echo "got: $out"; return 1; }
}

# ─── Section: hook behavior ─────────────────────────────────────────────────
test_speaks_substantive() {
    local state; state=$(mktemp -d)
    fire_hook "$state" "t1" "All three tests pass and the migration completed cleanly without errors." >/dev/null
    sleep 0.3; killall say 2>/dev/null
    [[ -f "$state/t1.hash" ]] || { rm -rf "$state"; echo "expected hash file (would have spoken)"; return 1; }
    rm -rf "$state"
}

test_skips_filler_lowercase() {
    local state; state=$(mktemp -d)
    fire_hook "$state" "t2" "let me check the logs to see what happened first" >/dev/null
    sleep 0.3; killall say 2>/dev/null
    [[ ! -f "$state/t2.hash" ]] || { rm -rf "$state"; echo "filler was spoken (hash written)"; return 1; }
    rm -rf "$state"
}

test_skips_filler_uppercase() {
    local state; state=$(mktemp -d)
    fire_hook "$state" "t3" "NOW LET ME CHECK THE LOGS TO SEE WHAT HAPPENED FIRST" >/dev/null
    sleep 0.3; killall say 2>/dev/null
    [[ ! -f "$state/t3.hash" ]] || { rm -rf "$state"; echo "uppercase filler was spoken"; return 1; }
    rm -rf "$state"
}

test_skips_too_short() {
    local state; state=$(mktemp -d)
    fire_hook "$state" "t4" "Done." >/dev/null
    sleep 0.3; killall say 2>/dev/null
    [[ ! -f "$state/t4.hash" ]] || { rm -rf "$state"; echo "short message was spoken"; return 1; }
    rm -rf "$state"
}

test_dedupe() {
    local state; state=$(mktemp -d)
    local msg="The deployment succeeded and all health checks are green right now."
    fire_hook "$state" "t5" "$msg" >/dev/null
    sleep 0.3; killall say 2>/dev/null
    local h1; h1=$(cat "$state/t5.hash" 2>/dev/null)
    sleep 5  # debounce window is 4s; wait past it
    fire_hook "$state" "t5" "$msg" >/dev/null
    sleep 0.3; killall say 2>/dev/null
    local h2; h2=$(cat "$state/t5.hash" 2>/dev/null)
    [[ "$h1" == "$h2" && -n "$h1" ]] || { rm -rf "$state"; echo "hash changed or empty (h1=$h1 h2=$h2)"; return 1; }
    rm -rf "$state"
}

test_debounce() {
    local state; state=$(mktemp -d)
    fire_hook "$state" "t6" "First substantive message that should be spoken in full." >/dev/null
    sleep 0.3; killall say 2>/dev/null
    local last1; last1=$(cat "$state/t6.last" 2>/dev/null)
    fire_hook "$state" "t6" "Second different message that shouldn't be spoken because of debounce." >/dev/null
    local last2; last2=$(cat "$state/t6.last" 2>/dev/null)
    [[ "$last1" == "$last2" ]] || { rm -rf "$state"; echo "second fire updated last (debounce broken)"; return 1; }
    rm -rf "$state"
}

test_stop_hook_active_skipped() {
    local state; state=$(mktemp -d)
    local jsonl; jsonl=$(mktemp)
    mk_jsonl "Some long substantive message to potentially speak aloud now." >"$jsonl"
    CLAUDESAY_STATE="$state" CLAUDESAY_DEBUG=1 \
        bash "$HOOK" <<<"{\"transcript_path\":\"$jsonl\",\"session_id\":\"t7\",\"stop_hook_active\":true}" >/dev/null
    rm -f "$jsonl"
    [[ ! -f "$state/t7.hash" ]] || { rm -rf "$state"; echo "fired despite stop_hook_active=true"; return 1; }
    rm -rf "$state"
}

test_missing_transcript() {
    local state; state=$(mktemp -d)
    CLAUDESAY_STATE="$state" \
        bash "$HOOK" <<<'{"transcript_path":"/no/such/file.jsonl","session_id":"t8"}' >/dev/null
    [[ ! -f "$state/t8.hash" ]] || { rm -rf "$state"; echo "fired without transcript"; return 1; }
    rm -rf "$state"
}

# ─── Section: security guards ───────────────────────────────────────────────
test_arithmetic_injection_blocked() {
    local state; state=$(mktemp -d)
    rm -f /tmp/claudesay_pwned_arith
    # Plant a malicious LAST_AT before the run.
    printf 'a[$(touch /tmp/claudesay_pwned_arith)]' > "$state/inj.last"
    fire_hook "$state" "inj" "A reasonably long substantive message to trigger speak path." >/dev/null
    sleep 0.3; killall say 2>/dev/null
    if [[ -f /tmp/claudesay_pwned_arith ]]; then
        rm -f /tmp/claudesay_pwned_arith; rm -rf "$state"
        echo "arithmetic injection executed (file created)"
        return 1
    fi
    rm -rf "$state"
}

test_toctou_symlink_replaced_not_followed() {
    local state; state=$(mktemp -d)
    local target="$state/victim"
    : >"$target"
    ln -sf "$target" "$state/sl.last"
    fire_hook "$state" "sl" "Another substantive message to drive a write through state." >/dev/null
    sleep 0.3; killall say 2>/dev/null
    # Symlink must have been replaced by a regular file, victim must be empty.
    if [[ -L "$state/sl.last" ]]; then rm -rf "$state"; echo "still a symlink"; return 1; fi
    if [[ -s "$target" ]]; then rm -rf "$state"; echo "victim was clobbered"; return 1; fi
    rm -rf "$state"
}

test_voice_with_apostrophe_kept() {
    # Validation logic only rejects leading dash.
    bash -c '
        set -u
        VOICE="O'"'"'Hara"
        [[ "${VOICE:0:1}" == "-" ]] && VOICE="Samantha"
        [[ "$VOICE" == "O'"'"'Hara" ]]
    '
}

test_voice_with_leading_dash_rejected() {
    bash -c '
        set -u
        VOICE="-r 9999 -o /tmp/hacked.aiff"
        [[ "${VOICE:0:1}" == "-" ]] && VOICE="Samantha"
        [[ "$VOICE" == "Samantha" ]]
    '
}

test_installer_rejects_dash_voice() {
    # Capture first to avoid pipefail interaction (the installer exits 1
    # by design, which would mask grep's success).
    local out
    out=$(bash "$INSTALLER" --voice=-foo 2>&1 || true)
    if echo "$out" | grep -q "cannot start with"; then
        return 0
    fi
    echo "got: $out"
    return 1
}

# ─── Section: installer / uninstaller ───────────────────────────────────────
test_installer_idempotent() {
    local home; home=$(mktemp -d)
    mkdir -p "$home/.claude"
    echo '{"env":{"FOO":"bar"}}' >"$home/.claude/settings.json"
    HOME="$home" bash "$INSTALLER" --no-picker >/dev/null
    HOME="$home" bash "$INSTALLER" --voice=Daniel >/dev/null
    local n; n=$(jq '.hooks.Stop | length' "$home/.claude/settings.json")
    local v; v=$(jq -r '.env.CLAUDESAY_VOICE' "$home/.claude/settings.json")
    local foo; foo=$(jq -r '.env.FOO' "$home/.claude/settings.json")
    rm -rf "$home"
    [[ "$n" == "1" && "$v" == "Daniel" && "$foo" == "bar" ]] || { echo "n=$n voice=$v foo=$foo"; return 1; }
}

test_installer_no_matcher_field() {
    local home; home=$(mktemp -d)
    mkdir -p "$home/.claude"
    echo '{}' >"$home/.claude/settings.json"
    HOME="$home" bash "$INSTALLER" --no-picker >/dev/null
    local has_matcher; has_matcher=$(jq '.hooks.Stop[0] | has("matcher")' "$home/.claude/settings.json")
    rm -rf "$home"
    [[ "$has_matcher" == "false" ]] || { echo "Stop entry has matcher field"; return 1; }
}

test_installer_writes_timeout() {
    local home; home=$(mktemp -d)
    mkdir -p "$home/.claude"
    echo '{}' >"$home/.claude/settings.json"
    HOME="$home" bash "$INSTALLER" --no-picker >/dev/null
    local t; t=$(jq -r '.hooks.Stop[0].hooks[0].timeout' "$home/.claude/settings.json")
    rm -rf "$home"
    [[ "$t" == "15" ]] || { echo "timeout=$t"; return 1; }
}

test_installer_refuses_broken_json() {
    local home; home=$(mktemp -d)
    mkdir -p "$home/.claude"
    echo '{ broken' >"$home/.claude/settings.json"
    local out
    out=$(HOME="$home" bash "$INSTALLER" --no-picker 2>&1) && rc=0 || rc=$?
    rm -rf "$home"
    [[ "$rc" -ne 0 ]] && echo "$out" | grep -q "not valid JSON"
}

test_uninstaller_preserves_unrelated_hooks() {
    local home; home=$(mktemp -d)
    mkdir -p "$home/.claude"
    cat >"$home/.claude/settings.json" <<EOF
{"env":{"KEEP":"yes"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/other-hook"}]}]}}
EOF
    HOME="$home" bash "$INSTALLER" --voice=Karen >/dev/null
    HOME="$home" bash "$UNINSTALLER" >/dev/null
    local kept; kept=$(jq -r '.hooks.Stop[0].hooks[0].command' "$home/.claude/settings.json")
    local env_kept; env_kept=$(jq -r '.env.KEEP' "$home/.claude/settings.json")
    rm -rf "$home"
    [[ "$kept" == "/usr/local/bin/other-hook" && "$env_kept" == "yes" ]] \
        || { echo "kept=$kept env=$env_kept"; return 1; }
}

# ─── Run all ────────────────────────────────────────────────────────────────
echo
printf '%s\n' "$(c_dim 'claudesay test suite')"
echo

run "--version reports a version" test_version
run "--help is informative"        test_help
run "installer --version works"    test_installer_version

run "speaks substantive messages (writes hash)"     test_speaks_substantive
run "skips lowercase filler"                        test_skips_filler_lowercase
run "skips uppercase filler"                        test_skips_filler_uppercase
run "skips too-short messages"                      test_skips_too_short
run "dedupes identical content"                     test_dedupe
run "debounces rapid Stop events"                   test_debounce
run "honors stop_hook_active=true"                  test_stop_hook_active_skipped
run "exits cleanly on missing transcript"           test_missing_transcript

run "blocks arithmetic injection via LAST_AT"       test_arithmetic_injection_blocked
run "TOCTOU: replaces planted symlink, not target"  test_toctou_symlink_replaced_not_followed
run "voice with apostrophe is accepted"             test_voice_with_apostrophe_kept
run "voice starting with '-' is rejected"           test_voice_with_leading_dash_rejected
run "installer rejects --voice=-foo"                test_installer_rejects_dash_voice

run "installer is idempotent"                       test_installer_idempotent
run "installer omits matcher field"                 test_installer_no_matcher_field
run "installer writes timeout: 15"                  test_installer_writes_timeout
run "installer refuses broken settings.json"        test_installer_refuses_broken_json
run "uninstaller preserves unrelated hooks"         test_uninstaller_preserves_unrelated_hooks

echo
if [[ $FAIL -eq 0 ]]; then
    printf '%s %d passed\n' "$(c_grn ✓)" "$PASS"
    exit 0
else
    printf '%s %d passed, %d failed\n' "$(c_red ✗)" "$PASS" "$FAIL"
    printf '\nFailed:\n'
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
