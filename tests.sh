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
    local state="$1" sid="$2" text="$3"; shift 3
    local jsonl; jsonl=$(mktemp)
    mk_jsonl "$text" >"$jsonl"
    env CLAUDESAY_STATE="$state" CLAUDESAY_DEBUG=1 "$@" \
        bash "$HOOK" <<<"$(printf '{"transcript_path":"%s","session_id":"%s","stop_hook_active":false}' "$jsonl" "$sid")"
    local rc=$?
    rm -f "$jsonl"
    return $rc
}

test_engine_defaults_to_say() {
    local state; state=$(mktemp -d)
    local out; out=$(fire_engine "$state" "e1" "A substantive sentence that should be spoken aloud now." 2>&1)
    /bin/sleep 0.3; killall say 2>/dev/null
    rm -rf "$state"
    echo "$out" | grep -q "engine=say" || { echo "got: $out"; return 1; }
}

test_unknown_engine_falls_back_to_say() {
    local state; state=$(mktemp -d)
    local out; out=$(fire_engine "$state" "e2" "A substantive sentence that should be spoken aloud now." \
        CLAUDESAY_ENGINE=nonsense 2>&1)
    /bin/sleep 0.3; killall say 2>/dev/null
    rm -rf "$state"
    echo "$out" | grep -q "engine=say" || { echo "got: $out"; return 1; }
}

# Assert the tracked PID is a *live* player of the expected command. Checking
# only that the .pid file exists is vacuous: a hook that speaks nothing still
# writes an empty one, so such a test passes against broken fallback code.
assert_live_player() {
    # assert_live_player <pid-file> <expected comm>
    local pid_file="$1" want="$2" pid="" comm=""
    [[ -f "$pid_file" ]] || { echo "no pid file"; return 1; }
    pid=$(cat "$pid_file" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] || { echo "pid file empty or non-numeric: '$pid'"; return 1; }
    comm=$(ps -p "$pid" -o comm= 2>/dev/null)
    comm="${comm##*/}"
    [[ "$comm" == "$want" ]] || { echo "pid $pid is '${comm:-dead}', expected '$want'"; return 1; }
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
    local pid=""; [[ -f "$state/e4.pid" ]] && pid=$(cat "$state/e4.pid" 2>/dev/null)
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
    # The load-bearing assertion: a real `say` must be speaking. The debug line
    # alone proves only that we noticed the failure, not that we recovered.
    local err; err=$(assert_live_player "$state/e6.pid" say) || {
        killall say 2>/dev/null; rm -rf "$state"; echo "$err; hook said: $out"; return 1
    }
    killall say 2>/dev/null; rm -rf "$state"
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

run "engine defaults to say"                        test_engine_defaults_to_say
run "unknown engine falls back to say"              test_unknown_engine_falls_back_to_say
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
