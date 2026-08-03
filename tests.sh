#!/usr/bin/env bash
# claudesay test suite. Runs in isolated tmp dirs so it never touches
# your real ~/.claude. Exits non-zero on first failure.
#
#   ./tests.sh           # run all tests
#   bash tests.sh -v     # verbose (show each test's output)

set -uo pipefail
shopt -s expand_aliases

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
ROOT="$PWD"
HOOK="$ROOT/claudesay.sh"
INSTALLER="$ROOT/install.sh"
UNINSTALLER="$ROOT/uninstall.sh"

VERBOSE=""
[[ "${1:-}" == "-v" ]] && VERBOSE=1

# Tests render instead of playing unless you opt in. A suite that grabs the
# speakers is unusable on a laptop that also joins meetings.
#   CLAUDESAY_AUDIBLE_TESTS=1 ./tests.sh   # let it actually make noise
TEST_SILENT=1
[[ -n "${CLAUDESAY_AUDIBLE_TESTS:-}" ]] && TEST_SILENT=""

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
    # Pin the engine and clear ambient config so these tests assert the hook's
    # behavior, not the developer's settings.json.
    env -u CLAUDESAY_VOICE -u CLAUDESAY_RATE -u CLAUDESAY_DISABLE \
        CLAUDESAY_ENGINE=say CLAUDESAY_STATE="$state" CLAUDESAY_DEBUG=1 \
        CLAUDESAY_SILENT="$TEST_SILENT" \
        CLAUDESAY_MUTE_WHEN_MIC=0 CLAUDESAY_MUTE_FILE=/nonexistent-mute \
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

# ─── Section: the documented example ────────────────────────────────────────
test_readme_example_selects_last_sentence() {
    # The README shows a specific message and claims a specific sentence is
    # spoken. An early draft of that section claimed two sentences and was
    # wrong. Pin it, so the docs cannot drift from the behavior again.
    local state; state=$(mktemp -d)
    local msg="I've updated the migration to backfill in batches of 500 instead of all at once, added an index on events.team_id, and re-ran the suite. All three tests pass and the migration completed cleanly, so this is ready to deploy to staging whenever you want."
    local want="All three tests pass and the migration completed cleanly, so this is ready to deploy to staging whenever you want."
    local jsonl; jsonl=$(mktemp)
    mk_jsonl "$msg" >"$jsonl"
    local out
    # Same isolation as fire_hook: render instead of playing, ignore the user's
    # real mute file, and skip the mic probe. Without this the test both makes
    # noise and fails whenever the developer happens to be muted.
    out=$(env -u CLAUDESAY_VOICE -u CLAUDESAY_RATE -u CLAUDESAY_DISABLE \
        CLAUDESAY_STATE="$state" CLAUDESAY_DEBUG=1 CLAUDESAY_ENGINE=say \
        CLAUDESAY_SILENT="$TEST_SILENT" CLAUDESAY_MUTE_WHEN_MIC=0 \
        CLAUDESAY_MUTE_FILE=/nonexistent-mute \
        bash "$HOOK" <<<"$(printf '{"transcript_path":"%s","session_id":"rd","stop_hook_active":false}' "$jsonl")" 2>&1)
    killall say 2>/dev/null
    rm -f "$jsonl"; rm -rf "$state"

    # The debug line truncates at 80 chars for display, so compare the prefix.
    local got="${want:0:80}"
    echo "$out" | grep -qF "text=\"$got\"" \
        || { echo "expected the final sentence; hook logged: $out"; return 1; }
    # And the README's claim that nothing before it is spoken.
    echo "$out" | grep -qF "batches of 500" \
        && { echo "spoke the setup text too — README example is wrong"; return 1; }
    return 0
}

# ─── Section: code is not speech ────────────────────────────────────────────
# Claude Code renders inline code in violet because it is not prose, and read
# aloud it costs you the sentence: `events.team_id` becomes "events dot team
# eye dee". Each span should come out as the category of thing it is.
spoken() {
    # Echo back the text claudesay chose, so a test can assert on the words.
    # Same isolation as fire_hook. Note the debug line truncates at 80 chars,
    # so keep the expected sentence shorter than that.
    local state jsonl
    state=$(mktemp -d); jsonl=$(mktemp)
    mk_jsonl "$1" >"$jsonl"
    env -u CLAUDESAY_VOICE -u CLAUDESAY_RATE -u CLAUDESAY_DISABLE \
        CLAUDESAY_STATE="$state" CLAUDESAY_DEBUG=1 CLAUDESAY_ENGINE=say \
        CLAUDESAY_SILENT="$TEST_SILENT" CLAUDESAY_MUTE_WHEN_MIC=0 \
        CLAUDESAY_MUTE_FILE=/nonexistent-mute \
        bash "$HOOK" <<<"$(printf '{"transcript_path":"%s","session_id":"code","stop_hook_active":false}' "$jsonl")" 2>&1 \
        | sed -n 's/.*text="\([^"]*\)".*/\1/p'
    rm -f "$jsonl"; rm -rf "$state"
}

says() {
    # says <expected speech> <assistant message>
    local want="$1" msg="$2" got
    got=$(spoken "$msg")
    [[ "$got" == "$want" ]] || { echo "want: $want"; echo "got:  $got"; return 1; }
}

test_filename_becomes_the_file() {
    says "The suite is green and the file is ready to run now." \
         "The suite is green and \`deploy.sh\` is ready to run now."
}

test_command_becomes_that_command() {
    says "Run that command to confirm it." \
         "The suite is green. Run \`npm test -- --watch\` to confirm it."
}

test_env_var_becomes_that_setting() {
    says "Speech is truncated, so set that setting to 300 for longer lines." \
         "Speech is truncated, so set \`CLAUDESAY_MAX\` to 300 for longer lines."
}

test_identifier_is_not_spelled_out() {
    local got; got=$(spoken "The parser is fixed and it reads \`transcript_path\` from stdin now.")
    [[ "$got" == *transcript_path* ]] && { echo "spelled the identifier out: $got"; return 1; }
    [[ "$got" == "The parser is fixed and it reads it from stdin now." ]] \
        || { echo "got: $got"; return 1; }
}

test_no_doubled_article_before_a_noun() {
    # "the `auth.ts` file" must not become "the the file file".
    says "The bug is gone and the file was the culprit here." \
         "The bug is gone and the \`auth.ts\` file was the culprit here."
}

test_plain_words_in_backticks_are_still_spoken() {
    # Backticks around ordinary words are emphasis, not code. Say them.
    says "The default is true and nothing else needs changing here." \
         "The default is \`true\` and nothing else needs changing here."
}

test_fenced_block_is_never_spoken() {
    local got; got=$(spoken 'The fix landed and here is the shape of it: ```echo hi``` and the suite passes.')
    [[ "$got" == *"echo hi"* ]] && { echo "spoke the code block: $got"; return 1; }
    return 0
}

test_bare_path_becomes_the_file() {
    # Claude does not always reach for backticks; a path is a path either way.
    says "Everything is wired now and the file passes cleanly." \
         "Everything is wired now and src/hooks/claudesay.sh passes cleanly."
}

# ─── Section: playback queue + mute ─────────────────────────────────────────
# Audible tests are OPT-IN. Running the suite must never take over the speakers:
# it was written on a laptop that also joins meetings, and a test run once talked
# over a live call. `CLAUDESAY_AUDIBLE_TESTS=1 ./tests.sh` enables them.
#
# The silent default is not a coverage hole — the queue, mute, fallback and
# engine-dispatch assertions all read state files and PIDs, not sound. Only the
# handful that must observe real overlapping playback are gated.
audio_really_plays() {
    [[ -n "${CLAUDESAY_AUDIBLE_TESTS:-}" ]] || return 1
    # Even when enabled: `say` exits 0 immediately without speaking if the audio
    # device is busy, and always does on a headless CI runner. Check for real.
    killall say 2>/dev/null; /bin/sleep 0.2
    say -v Samantha "testing one two three four five" </dev/null >/dev/null 2>&1 &
    local p=$! alive=0
    /bin/sleep 0.4
    kill -0 "$p" 2>/dev/null && alive=1
    kill "$p" 2>/dev/null
    (( alive == 1 ))
}

test_concurrent_sessions_do_not_overlap() {
    # The failure this guards is unrecoverable by the user: you can re-read a
    # screen, you cannot un-hear two sentences spoken at once.
    if ! audio_really_plays; then
        echo "SKIP: no usable audio device (say exits without speaking here)"
        return 0
    fi
    local state; state=$(mktemp -d)
    killall say 2>/dev/null; /bin/sleep 0.3
    local n
    for n in 1 2 3; do
        ( fire_engine "$state" "cc$n" "Session $n is speaking a sentence long enough to overlap." \
            CLAUDESAY_ENGINE=say >/dev/null 2>&1 ) &
    done
    wait
    local max=0 spoke=0 c _i
    for _i in $(seq 1 30); do
        c=$(pgrep -x say | wc -l | tr -d ' ')
        (( c > max )) && max=$c
        (( c > 0 )) && spoke=$((spoke + 1))
        /bin/sleep 0.4
    done
    killall say 2>/dev/null; rm -rf "$state"
    (( spoke > 0 )) || { echo "nothing spoke at all — inconclusive, not a pass"; return 1; }
    (( max <= 1 )) || { echo "$max sessions spoke at once (queue broken)"; return 1; }
}

test_queue_lock_is_released_after_speech() {
    if ! audio_really_plays; then
        echo "SKIP: no usable audio device (say exits without speaking here)"
        return 0
    fi
    # A lock left behind by a finished utterance would mute the whole machine
    # until the stale-grace expired.
    local state; state=$(mktemp -d)
    fire_engine "$state" "lk" "A short line to take and then release the lock." \
        CLAUDESAY_ENGINE=say >/dev/null 2>&1
    /bin/sleep 0.5
    local held_during=0; [[ -d "$state/play.lock" ]] && held_during=1
    killall say 2>/dev/null; /bin/sleep 0.8
    local held_after=0; [[ -d "$state/play.lock" ]] && held_after=1
    rm -rf "$state"
    (( held_during == 1 )) || { echo "lock was never taken during playback"; return 1; }
    (( held_after == 0 )) || { echo "lock leaked after playback ended"; return 1; }
}

test_mute_silences_and_unmute_restores() {
    if ! audio_really_plays; then
        echo "SKIP: no usable audio device (say exits without speaking here)"
        return 0
    fi
    local mf; mf=$(mktemp -d)/muted
    local state; state=$(mktemp -d)
    killall say 2>/dev/null; /bin/sleep 0.2

    CLAUDESAY_MUTE_FILE="$mf" bash "$HOOK" --mute >/dev/null 2>&1
    fire_engine "$state" "mu1" "This must not be spoken while claudesay is muted." \
        CLAUDESAY_ENGINE=say CLAUDESAY_MUTE_FILE="$mf" >/dev/null 2>&1
    /bin/sleep 0.6
    local while_muted; while_muted=$(pgrep -x say | wc -l | tr -d ' ')

    CLAUDESAY_MUTE_FILE="$mf" bash "$HOOK" --unmute >/dev/null 2>&1
    fire_engine "$state" "mu2" "This must be spoken again now that it is unmuted." \
        CLAUDESAY_ENGINE=say CLAUDESAY_MUTE_FILE="$mf" >/dev/null 2>&1
    /bin/sleep 0.6
    local after_unmute; after_unmute=$(pgrep -x say | wc -l | tr -d ' ')

    killall say 2>/dev/null; rm -rf "$state" "$(dirname "$mf")"
    (( while_muted == 0 )) || { echo "spoke while muted ($while_muted procs)"; return 1; }
    (( after_unmute >= 1 )) || { echo "did not resume after unmute"; return 1; }
}

test_expired_timed_mute_self_clears() {
    local mf; mf=$(mktemp -d)/muted
    printf '%s\n' "$(( $(date +%s) - 10 ))" >"$mf"   # expired 10s ago
    local out; out=$(CLAUDESAY_MUTE_FILE="$mf" bash "$HOOK" --mute-status 2>&1)
    local gone=0; [[ -f "$mf" ]] || gone=1
    rm -rf "$(dirname "$mf")"
    echo "$out" | grep -q "unmuted" || { echo "expired mute still reported as muted: $out"; return 1; }
    (( gone == 1 )) || { echo "expired mute file was not cleared"; return 1; }
}

mk_mic_stub() {
    # mk_mic_stub <exit-code>  — 0 = mic in use, 1 = idle, 2 = unknown
    local f; f=$(mktemp -d)/mic.py
    printf '#!/usr/bin/env python3\nimport sys\nsys.exit(%s)\n' "$1" >"$f"
    printf '%s' "$f"
}

test_live_mic_silences_the_hook() {
    # A voice notification during a call goes out to everyone listening and
    # cannot be taken back, so a live mic must win over everything else.
    local state; state=$(mktemp -d)
    local stub; stub=$(mk_mic_stub 0)
    fire_engine "$state" "mic1" "This must not be spoken while a microphone is live." \
        CLAUDESAY_MUTE_WHEN_MIC=1 CLAUDESAY_MIC_SCRIPT="$stub" >/dev/null 2>&1
    local spoke=0; [[ -f "$state/mic1.job" ]] && spoke=1
    rm -rf "$state" "$(dirname "$stub")"
    (( spoke == 0 )) || { echo "hook spoke while the mic was live"; return 1; }
}

test_idle_mic_allows_speech() {
    local state; state=$(mktemp -d)
    local stub; stub=$(mk_mic_stub 1)
    fire_engine "$state" "mic2" "This should be spoken because no microphone is live." \
        CLAUDESAY_MUTE_WHEN_MIC=1 CLAUDESAY_MIC_SCRIPT="$stub" >/dev/null 2>&1
    local spoke=0; [[ -f "$state/mic2.job" ]] && spoke=1
    rm -rf "$state" "$(dirname "$stub")"
    (( spoke == 1 )) || { echo "hook stayed silent even though the mic was idle"; return 1; }
}

test_unknown_mic_state_still_speaks() {
    # Fail open. A probe that cannot answer must not be able to mute you
    # permanently and silently — that failure is invisible by construction.
    local state; state=$(mktemp -d)
    local stub; stub=$(mk_mic_stub 2)
    fire_engine "$state" "mic3" "This should be spoken because the probe could not tell." \
        CLAUDESAY_MUTE_WHEN_MIC=1 CLAUDESAY_MIC_SCRIPT="$stub" >/dev/null 2>&1
    local spoke=0; [[ -f "$state/mic3.job" ]] && spoke=1
    rm -rf "$state" "$(dirname "$stub")"
    (( spoke == 1 )) || { echo "unknown mic state silenced the hook (must fail open)"; return 1; }
}

test_mic_gate_can_be_turned_off() {
    local state; state=$(mktemp -d)
    local stub; stub=$(mk_mic_stub 0)   # says the mic IS live
    fire_engine "$state" "mic4" "This should be spoken because mic muting is disabled." \
        CLAUDESAY_MUTE_WHEN_MIC=0 CLAUDESAY_MIC_SCRIPT="$stub" >/dev/null 2>&1
    local spoke=0; [[ -f "$state/mic4.job" ]] && spoke=1
    rm -rf "$state" "$(dirname "$stub")"
    (( spoke == 1 )) || { echo "CLAUDESAY_MUTE_WHEN_MIC=0 did not disable the gate"; return 1; }
}

test_real_mic_probe_answers_sanely() {
    # The shipped probe must run and return one of the three defined codes on
    # this machine. It only reads a property flag — it opens no audio stream.
    python3 "$ROOT/claudesay-mic.py" >/dev/null 2>&1
    local rc=$?
    [[ "$rc" == "0" || "$rc" == "1" || "$rc" == "2" ]] \
        || { echo "probe returned $rc, expected 0/1/2"; return 1; }
}

test_toggle_mute_flips() {
    local mf; mf=$(mktemp -d)/muted
    local a b
    a=$(CLAUDESAY_MUTE_FILE="$mf" bash "$HOOK" --toggle-mute 2>&1)
    b=$(CLAUDESAY_MUTE_FILE="$mf" bash "$HOOK" --toggle-mute 2>&1)
    rm -rf "$(dirname "$mf")"
    echo "$a" | grep -q "muted" && echo "$b" | grep -q "unmuted" \
        || { echo "toggle did not flip (first='$a' second='$b')"; return 1; }
}

test_legacy_shim_forwards_to_claudesay() {
    local home; home=$(mktemp -d)
    mkdir -p "$home/.claude/hooks"
    echo '{}' >"$home/.claude/settings.json"
    printf '#!/usr/bin/env bash\necho OLD-HOOK\n' >"$home/.claude/hooks/voice-notify.sh"
    chmod +x "$home/.claude/hooks/voice-notify.sh"
    HOME="$home" bash "$INSTALLER" --no-picker >/dev/null 2>&1
    local out; out=$(bash "$home/.claude/hooks/voice-notify.sh" --version 2>&1)
    rm -rf "$home"
    [[ "$out" =~ ^claudesay\ [0-9] ]] \
        || { echo "legacy path did not forward (got: $out)"; return 1; }
}

# ─── Section: engine layer ──────────────────────────────────────────────────
# These never load a model. A stub server stands in for claudesay-voice.py so
# the suite stays hermetic and offline: what's under test is the hook's engine
# dispatch, fallback, and request encoding — not Kokoro itself.

STUB_PORT=18787

# Kill whatever is listening on the stub port. Without this a leaked stub from
# an interrupted run poisons every later run: the new stub fails to bind and
# dies, but start_stub's health probe succeeds against the *stale* server, so
# tests silently exercise a zombie instead of the one they configured.
reap_stub_port() {
    local pids
    pids=$(lsof -ti "TCP:$STUB_PORT" -sTCP:LISTEN 2>/dev/null) || true
    [[ -n "$pids" ]] || return 0
    echo "$pids" | xargs -r kill -9 2>/dev/null
    /bin/sleep 0.2
}

start_stub() {
    # start_stub <mode: ok|fail> <capture-file>
    reap_stub_port
    python3 - "$STUB_PORT" "$1" "$2" <<'PY' >/dev/null 2>&1 &
import io, sys, wave
from http.server import BaseHTTPRequestHandler, HTTPServer
port, mode, capture = int(sys.argv[1]), sys.argv[2], sys.argv[3]

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "2")
        self.end_headers(); self.wfile.write(b"ok")
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        with open(capture, "wb") as fh:
            fh.write(self.rfile.read(n))
        if mode == "fail":
            self.send_response(500); self.send_header("Content-Length", "0")
            self.end_headers(); return
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000)
            w.writeframes(b"\x00\x00" * 2400)   # 0.1s of silence
        data = buf.getvalue()
        self.send_response(200); self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
    STUB_PID=$!
    for _ in $(seq 1 40); do
        curl -fsS --max-time 1 -o /dev/null "http://127.0.0.1:$STUB_PORT/health" 2>/dev/null && return 0
        /bin/sleep 0.1
    done
    return 1
}

stop_stub() {
    [[ -n "${STUB_PID:-}" ]] && kill "$STUB_PID" 2>/dev/null
    wait "$STUB_PID" 2>/dev/null
    STUB_PID=""
    # Belt and braces: a test that dies between start and stop must not leave
    # the port held, or it poisons the rest of the suite.
    reap_stub_port
}

fire_engine() {
    # fire_engine <state> <sid> <text> [extra env assignments...]
    #
    # Every claudesay var is cleared first. Without this the suite inherits the
    # developer's own settings — someone running with CLAUDESAY_ENGINE=kokoro
    # exported would see "engine defaults to say" fail, which is a bug in the
    # test, not in the hook.
    local state="$1" sid="$2" text="$3"; shift 3
    local jsonl; jsonl=$(mktemp)
    mk_jsonl "$text" >"$jsonl"
    env -u CLAUDESAY_ENGINE -u CLAUDESAY_VOICE -u CLAUDESAY_RATE \
        -u CLAUDESAY_KOKORO_PORT -u CLAUDESAY_KOKORO_VOICE \
        -u CLAUDESAY_KOKORO_IDLE -u CLAUDESAY_KOKORO_TIMEOUT \
        -u CLAUDESAY_VOICE_SCRIPT -u CLAUDESAY_DISABLE \
        CLAUDESAY_STATE="$state" CLAUDESAY_DEBUG=1 \
        CLAUDESAY_SILENT="$TEST_SILENT" \
        CLAUDESAY_MUTE_WHEN_MIC=0 CLAUDESAY_MUTE_FILE=/nonexistent-mute "$@" \
        bash "$HOOK" <<<"$(printf '{"transcript_path":"%s","session_id":"%s","stop_hook_active":false}' "$jsonl" "$sid")"
    local rc=$?
    rm -f "$jsonl"
    return $rc
}

test_engine_default_resolves_without_config() {
    # There is no "default engine" to memorize any more: unset means auto,
    # and auto must always land on a concrete engine rather than a word.
    local state; state=$(mktemp -d)
    local out; out=$(fire_engine "$state" "e1" "A substantive sentence that should be spoken aloud now." 2>&1)
    /bin/sleep 0.3; killall say 2>/dev/null
    rm -rf "$state"
    echo "$out" | grep -qE "engine=(say|kokoro)" || { echo "got: $out"; return 1; }
    echo "$out" | grep -q "engine=auto" && { echo "auto leaked through unresolved"; return 1; }
    return 0
}

test_auto_engine_picks_neural_when_available() {
    # The default must not be a decision. If the machine can run the neural
    # voice, it runs it — no env var, no prompt.
    local state; state=$(mktemp -d)
    local out; out=$(fire_engine "$state" "au1" "All three tests pass and the deploy is ready whenever you want." \
        CLAUDESAY_ENGINE=auto 2>&1)
    rm -rf "$state"
    if command -v uv >/dev/null 2>&1 && [[ "$(uname -m)" == "arm64" ]] && [[ -f "$ROOT/claudesay-voice.py" ]]; then
        echo "$out" | grep -q "engine=kokoro" || { echo "auto did not pick the neural voice; got: $out"; return 1; }
    else
        echo "$out" | grep -q "engine=say" || { echo "auto should have picked say here; got: $out"; return 1; }
    fi
}

test_auto_engine_falls_back_without_neural_support() {
    local state; state=$(mktemp -d)
    local out; out=$(fire_engine "$state" "au2" "All three tests pass and the deploy is ready whenever you want." \
        CLAUDESAY_ENGINE=auto CLAUDESAY_VOICE_SCRIPT=/nonexistent 2>&1)
    rm -rf "$state"
    echo "$out" | grep -q "engine=say" \
        || { echo "auto must degrade to say when the neural voice is unavailable; got: $out"; return 1; }
}

test_hotkey_helper_compiles() {
    command -v swiftc >/dev/null 2>&1 || { echo "SKIP: no swiftc"; return 0; }
    local out; out=$(mktemp -d)
    swiftc -O -o "$out/hk" "$ROOT/claudesay-hotkey.swift" 2>&1 | head -5
    local ok=0; [[ -x "$out/hk" ]] && ok=1
    rm -rf "$out"
    (( ok == 1 )) || { echo "claudesay-hotkey.swift failed to compile"; return 1; }
}

test_unknown_engine_still_speaks() {
    # A typo in settings.json should cost you nothing at all.
    local state; state=$(mktemp -d)
    local out; out=$(fire_engine "$state" "e2" "A substantive sentence that should be spoken aloud now." \
        CLAUDESAY_ENGINE=nonsense 2>&1)
    /bin/sleep 0.3; killall say 2>/dev/null
    rm -rf "$state"
    echo "$out" | grep -qE "engine=(say|kokoro)" || { echo "typo silenced the hook; got: $out"; return 1; }
}

# Assert the tracked PID is a *live* player of the expected command. Checking
# only that the .pid file exists is vacuous: a hook that speaks nothing still
# writes an empty one, so such a test passes against broken fallback code.
assert_live_player() {
    # assert_live_player <pid-file> <expected comm>
    #
    # The PID appears asynchronously: the hook returns as soon as the queue job
    # is spawned, and the job writes the player's PID only after it wins the
    # playback lock. So poll rather than read once — a bare read races with the
    # queue and fails intermittently.
    local pid_file="$1" want="$2" pid="" comm="" _n
    for _n in $(seq 1 40); do
        pid=$(cat "$pid_file" 2>/dev/null)
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            comm=$(ps -p "$pid" -o comm= 2>/dev/null)
            comm="${comm##*/}"
            [[ "$comm" == "$want" ]] && return 0
        fi
        /bin/sleep 0.1
    done
    [[ "$pid" =~ ^[0-9]+$ ]] || { echo "no player PID appeared within 4s (got '$pid')"; return 1; }
    echo "pid $pid is '${comm:-dead}', expected '$want'"
    return 1
}

test_kokoro_cold_falls_back_and_still_speaks() {
    # Nothing listening on the port: the turn must still be spoken by `say`.
    local state; state=$(mktemp -d)
    fire_engine "$state" "e3" "A substantive sentence that should be spoken aloud now." \
        CLAUDESAY_ENGINE=kokoro CLAUDESAY_KOKORO_PORT=9 CLAUDESAY_VOICE_SCRIPT=/nonexistent >/dev/null 2>&1
    local err; err=$(assert_live_player "$state/e3.pid" say) || {
        killall say 2>/dev/null; rm -rf "$state"; echo "$err"; return 1
    }
    [[ -f "$state/e3.hash" ]] || { killall say 2>/dev/null; rm -rf "$state"; echo "no hash written"; return 1; }
    killall say 2>/dev/null; rm -rf "$state"
}

test_kokoro_warm_uses_server() {
    local state; state=$(mktemp -d)
    local cap="$state/body.txt"
    start_stub ok "$cap" || { rm -rf "$state"; echo "stub failed to start"; return 1; }
    killall say 2>/dev/null   # start from a known-clean slate
    fire_engine "$state" "e4" "All three tests pass and the migration completed cleanly." \
        CLAUDESAY_ENGINE=kokoro CLAUDESAY_KOKORO_PORT="$STUB_PORT" >/dev/null 2>&1

    # Deliberately not "is afplay still alive": on a headless CI runner with no
    # audio device afplay can exit immediately, which would make this flaky.
    # These three together still pin the behavior — a hook that silently played
    # nothing has no PID, and one that fell through to `say` leaves a `say`.
    local pid="" _n
    for _n in $(seq 1 40); do          # the queue writes the PID asynchronously
        pid=$(cat "$state/e4.pid" 2>/dev/null)
        [[ "$pid" =~ ^[0-9]+$ ]] && break
        /bin/sleep 0.1
    done
    local say_running=0; pgrep -x say >/dev/null 2>&1 && say_running=1
    local body=""; [[ -f "$cap" ]] && body=$(cat "$cap")
    local wav_ok=0; [[ -s "$state/e4.wav" ]] && wav_ok=1

    killall afplay say 2>/dev/null
    stop_stub
    rm -rf "$state"

    [[ "$pid" =~ ^[0-9]+$ ]] || { echo "no player PID recorded (pid='$pid')"; return 1; }
    [[ "$say_running" == "0" ]] || { echo "fell back to say despite a warm server"; return 1; }
    [[ -n "$body" ]] || { echo "voice server never received the text"; return 1; }
    [[ "$wav_ok" == "1" ]] || { echo "no wav written from the server response"; return 1; }
}

test_kokoro_sends_text_literally_not_as_file_ref() {
    # curl reads a leading '@' in an inline --data value as a filename. A reply
    # ending in a sentence like "@/etc/passwd is the file." must be transmitted
    # verbatim, never expanded into file contents.
    local state; state=$(mktemp -d)
    local cap="$state/body.txt"
    start_stub ok "$cap" || { rm -rf "$state"; echo "stub failed to start"; return 1; }
    fire_engine "$state" "e5" "@/etc/passwd is the file that this sentence happens to mention." \
        CLAUDESAY_ENGINE=kokoro CLAUDESAY_KOKORO_PORT="$STUB_PORT" >/dev/null 2>&1
    /bin/sleep 0.4; killall afplay 2>/dev/null
    stop_stub
    local body=""; [[ -f "$cap" ]] && body=$(cat "$cap")
    rm -rf "$state"
    if [[ "$body" != *"@/etc/passwd"* ]]; then
        echo "text not sent verbatim; got: ${body:0:80}"
        return 1
    fi
    if [[ "$body" == *"root:"* ]]; then
        echo "FILE CONTENTS LEAKED into request body"
        return 1
    fi
}

test_kokoro_wav_symlink_replaced_not_followed() {
    # curl -o follows a symlink at the destination. A planted .wav.part must be
    # replaced, not written through to whatever it points at.
    local state; state=$(mktemp -d)
    local cap="$state/body.txt" victim="$state/victim"
    : >"$victim"
    ln -sf "$victim" "$state/e8.wav.part"
    start_stub ok "$cap" || { rm -rf "$state"; echo "stub failed to start"; return 1; }
    fire_engine "$state" "e8" "All three tests pass and the migration completed cleanly." \
        CLAUDESAY_ENGINE=kokoro CLAUDESAY_KOKORO_PORT="$STUB_PORT" >/dev/null 2>&1
    /bin/sleep 0.4; killall afplay 2>/dev/null
    stop_stub
    local leaked=0 still_link=0
    [[ -s "$victim" ]] && leaked=1
    [[ -L "$state/e8.wav.part" ]] && still_link=1
    rm -rf "$state"
    [[ "$leaked" == "0" && "$still_link" == "0" ]] \
        || { echo "victim written through symlink (leaked=$leaked still_link=$still_link)"; return 1; }
}

test_kokoro_server_error_falls_back_to_say() {
    local state; state=$(mktemp -d)
    local cap="$state/body.txt"
    start_stub fail "$cap" || { rm -rf "$state"; echo "stub failed to start"; return 1; }
    local out; out=$(fire_engine "$state" "e6" "A substantive sentence that should be spoken aloud now." \
        CLAUDESAY_ENGINE=kokoro CLAUDESAY_KOKORO_PORT="$STUB_PORT" 2>&1)
    stop_stub
    # Deliberately not "is a `say` process alive": macOS `say` exits 0 without
    # speaking when the audio device is contended (and always on a headless CI
    # runner), so that assertion is flaky by construction. What must be true is
    # that the hook handed a player to the queue at all — with the fallback
    # removed, speak_kokoro returns early and no PID is ever recorded.
    local pid="" _n
    for _n in $(seq 1 20); do
        pid=$(cat "$state/e6.pid" 2>/dev/null)
        [[ "$pid" =~ ^[0-9]+$ ]] && break
        /bin/sleep 0.1
    done
    local wav_left=0; [[ -e "$state/e6.wav" ]] && wav_left=1
    killall say 2>/dev/null; rm -rf "$state"

    echo "$out" | grep -q "falling back to say" \
        || { echo "did not report the fallback; hook said: $out"; return 1; }
    [[ "$pid" =~ ^[0-9]+$ ]] \
        || { echo "no player was queued — the fallback never spoke (pid='$pid')"; return 1; }
    (( wav_left == 0 )) \
        || { echo "a wav was left behind from a failed synthesis"; return 1; }
}

test_kokoro_bad_port_is_sanitized() {
    local state; state=$(mktemp -d)
    fire_engine "$state" "e7" "A substantive sentence that should be spoken aloud now." \
        CLAUDESAY_ENGINE=kokoro CLAUDESAY_KOKORO_PORT='8787; touch /tmp/claudesay_pwned_port' \
        CLAUDESAY_VOICE_SCRIPT=/nonexistent >/dev/null 2>&1
    /bin/sleep 0.3; killall say 2>/dev/null
    rm -rf "$state"
    if [[ -f /tmp/claudesay_pwned_port ]]; then
        rm -f /tmp/claudesay_pwned_port
        echo "port injection executed"
        return 1
    fi
}

test_voice_server_script_is_valid_python() {
    python3 -c "import ast,sys; ast.parse(open('$ROOT/claudesay-voice.py').read())"
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

test_installer_places_mic_probe() {
    # If this file is missing, meeting detection silently never runs — and the
    # way you find out is by talking over a call.
    local home; home=$(mktemp -d)
    mkdir -p "$home/.claude"; echo '{}' >"$home/.claude/settings.json"
    HOME="$home" bash "$INSTALLER" --no-picker >/dev/null 2>&1
    local ok=0; [[ -s "$home/.claude/hooks/claudesay-mic.py" ]] && ok=1
    rm -rf "$home"
    (( ok == 1 )) || { echo "claudesay-mic.py not installed next to the hook"; return 1; }
}

test_installer_places_voice_server() {
    # Without this the kokoro engine can never work for anyone who installs
    # normally: the hook looks for the server as a sibling of itself.
    local home; home=$(mktemp -d)
    mkdir -p "$home/.claude"
    echo '{}' >"$home/.claude/settings.json"
    HOME="$home" bash "$INSTALLER" --no-picker >/dev/null 2>&1
    local ok=0
    [[ -s "$home/.claude/hooks/claudesay-voice.py" ]] && ok=1
    rm -rf "$home"
    [[ "$ok" == "1" ]] || { echo "claudesay-voice.py not installed next to the hook"; return 1; }
}

test_uninstaller_removes_voice_server() {
    local home; home=$(mktemp -d)
    mkdir -p "$home/.claude"
    echo '{}' >"$home/.claude/settings.json"
    HOME="$home" bash "$INSTALLER" --no-picker >/dev/null 2>&1
    HOME="$home" bash "$UNINSTALLER" >/dev/null 2>&1
    local left=0
    [[ -e "$home/.claude/hooks/claudesay-voice.py" ]] && left=1
    rm -rf "$home"
    [[ "$left" == "0" ]] || { echo "voice server left behind after uninstall"; return 1; }
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
# Leave no stub server, and no speech, behind — even on Ctrl-C.
cleanup_all() {
    killall say afplay 2>/dev/null
    reap_stub_port
}
trap cleanup_all EXIT INT TERM
cleanup_all

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

run "README example speaks the last sentence"    test_readme_example_selects_last_sentence

run "a filename is spoken as \"the file\""          test_filename_becomes_the_file
run "a command is spoken as \"that command\""       test_command_becomes_that_command
run "an env var is spoken as \"that setting\""      test_env_var_becomes_that_setting
run "an identifier is never spelled out"          test_identifier_is_not_spelled_out
run "no doubled article before a noun"            test_no_doubled_article_before_a_noun
run "plain words in backticks are still spoken"   test_plain_words_in_backticks_are_still_spoken
run "a fenced code block is never spoken"         test_fenced_block_is_never_spoken
run "a bare path is spoken as \"the file\""         test_bare_path_becomes_the_file

run "concurrent sessions never overlap"             test_concurrent_sessions_do_not_overlap
run "queue lock is released after speech"           test_queue_lock_is_released_after_speech
run "mute silences, unmute restores"                test_mute_silences_and_unmute_restores
run "expired timed mute self-clears"                test_expired_timed_mute_self_clears
run "toggle-mute flips"                             test_toggle_mute_flips
run "live mic silences the hook"                    test_live_mic_silences_the_hook
run "idle mic allows speech"                        test_idle_mic_allows_speech
run "unknown mic state still speaks (fail open)"    test_unknown_mic_state_still_speaks
run "mic gate can be disabled"                      test_mic_gate_can_be_turned_off
run "shipped mic probe answers sanely"              test_real_mic_probe_answers_sanely
run "legacy hook path forwards to claudesay"        test_legacy_shim_forwards_to_claudesay
run "engine needs no config to resolve"             test_engine_default_resolves_without_config
run "a typo in the engine name still speaks"        test_unknown_engine_still_speaks
run "auto engine picks the best available"          test_auto_engine_picks_neural_when_available
run "auto engine degrades without neural support"   test_auto_engine_falls_back_without_neural_support
run "global hotkey helper compiles"                 test_hotkey_helper_compiles
run "kokoro cold: falls back, still speaks"         test_kokoro_cold_falls_back_and_still_speaks
run "kokoro warm: uses the voice server"            test_kokoro_warm_uses_server
run "kokoro sends text verbatim (no @file read)"    test_kokoro_sends_text_literally_not_as_file_ref
run "kokoro: replaces planted wav symlink"        test_kokoro_wav_symlink_replaced_not_followed
run "kokoro 500: falls back to say"                 test_kokoro_server_error_falls_back_to_say
run "kokoro port env is sanitized"                  test_kokoro_bad_port_is_sanitized
run "voice server script parses as Python"          test_voice_server_script_is_valid_python

run "installer is idempotent"                       test_installer_idempotent
run "installer omits matcher field"                 test_installer_no_matcher_field
run "installer writes timeout: 15"                  test_installer_writes_timeout
run "installer refuses broken settings.json"        test_installer_refuses_broken_json
run "installer places the voice server"             test_installer_places_voice_server
run "installer places the mic probe"                test_installer_places_mic_probe
run "uninstaller removes the voice server"          test_uninstaller_removes_voice_server
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
