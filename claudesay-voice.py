# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["mlx-audio", "misaki[en]", "numpy"]
# ///
"""claudesay's optional neural voice — a small, idle-exiting Kokoro server.

Run by claudesay.sh only when CLAUDESAY_ENGINE=kokoro. It listens on loopback,
synthesizes one sentence per request, and *exits on its own* after a stretch of
silence so it costs nothing while you aren't being spoken to.

Why a server at all: Kokoro synthesis itself is fast (~0.8s for 11s of speech on
an M3 Pro), but importing mlx-audio + misaki and loading the model costs ~3s in a
cold process. Paying that once per turn is unusable; paying it once per work
session is not. Idle-exit is what keeps "warm" from meaning "resident forever."

    GET  /health  -> 200 "ok" once the model is loaded
    POST /speak   -> request body is UTF-8 text, response is a 24kHz mono WAV

Env:
    CLAUDESAY_KOKORO_PORT   loopback port         (default: 8787)
    CLAUDESAY_KOKORO_VOICE  Kokoro voice name     (default: af_heart)
    CLAUDESAY_KOKORO_IDLE   seconds before exit   (default: 300, 0 = never)
    CLAUDESAY_KOKORO_MODEL  HF repo id            (default: mlx-community/Kokoro-82M-bf16)
"""

from __future__ import annotations

import io
import os
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("CLAUDESAY_KOKORO_PORT", "8787"))
VOICE = os.environ.get("CLAUDESAY_KOKORO_VOICE", "af_heart")
IDLE = float(os.environ.get("CLAUDESAY_KOKORO_IDLE", "300"))
MODEL_ID = os.environ.get("CLAUDESAY_KOKORO_MODEL", "mlx-community/Kokoro-82M-bf16")
SAMPLE_RATE = 24000
MAX_CHARS = 2000

_model = None
_lock = threading.Lock()  # mlx generation is not reentrant; one synth at a time.
_last_used = time.monotonic()


def log(msg: str) -> None:
    print(f"[claudesay-voice] {msg}", file=sys.stderr, flush=True)


def synthesize(text: str) -> bytes:
    """Text -> 16-bit PCM WAV bytes. Serialized; callers may block briefly."""
    import numpy as np

    with _lock:
        segments = list(
            _model.generate(text=text, voice=VOICE, speed=1.0, lang_code="a")
        )
        if not segments:
            raise ValueError("model produced no audio")
        audio = np.concatenate(
            [np.asarray(s.audio).reshape(-1) for s in segments]
        )

    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2").tobytes()
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return buf.getvalue()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args) -> None:
        """Silence per-request logging; we log the things that matter ourselves."""

    def handle_one_request(self) -> None:
        """A client that hangs up is normal here, not an error.

        The hook probes /health with a short timeout while the model is still
        loading; curl gives up and resets the connection. Without this, every
        probe during startup dumps a traceback into the log.
        """
        try:
            super().handle_one_request()
        except (ConnectionResetError, BrokenPipeError, TimeoutError):
            self.close_connection = True

    def _send(self, code: int, body: bytes, ctype: str = "text/plain") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        global _last_used
        if self.path != "/health":
            self._send(404, b"not found")
            return
        _last_used = time.monotonic()
        self._send(200, b"ok")

    def do_POST(self) -> None:
        global _last_used
        if self.path != "/speak":
            self._send(404, b"not found")
            return

        _last_used = time.monotonic()
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400, b"bad Content-Length")
            return
        if length <= 0 or length > MAX_CHARS * 4:
            self._send(400, b"empty or oversized body")
            return

        text = self.rfile.read(length).decode("utf-8", "replace").strip()
        if not text:
            self._send(400, b"empty text")
            return

        try:
            wav = synthesize(text[:MAX_CHARS])
        except Exception as exc:  # noqa: BLE001 - the hook falls back to `say`
            log(f"synthesis failed: {type(exc).__name__}: {exc}")
            self._send(500, b"synthesis failed")
            return

        _last_used = time.monotonic()
        self._send(200, wav, "audio/wav")


def watch_idle() -> None:
    """Exit once nothing has asked for speech in IDLE seconds.

    Uses os._exit rather than a clean shutdown on purpose. mlx-audio, spaCy and
    tokenizers all leave non-daemon threads behind, so returning from main()
    leaves the interpreter alive holding the model — which would quietly turn
    "idle-exit" into "resident forever", the exact cost this server exists to
    avoid. os._exit is the only exit a stray thread cannot veto.
    """
    if IDLE <= 0:
        return
    while True:
        time.sleep(5)
        if time.monotonic() - _last_used <= IDLE:
            continue
        # Take the synthesis lock so we can never exit mid-utterance, then
        # re-check: a request may have landed while we waited for it.
        with _lock:
            if time.monotonic() - _last_used <= IDLE:
                continue
            log(f"idle {IDLE:.0f}s — exiting, freeing memory")
            sys.stderr.flush()
            sys.stdout.flush()
            os._exit(0)


def main() -> int:
    global _model, _last_used

    try:
        server = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as exc:
        # Another instance almost certainly won the race. That is success.
        log(f"not starting: {exc}")
        return 0

    log(f"loading {MODEL_ID} …")
    t0 = time.monotonic()
    try:
        from mlx_audio.tts.utils import load_model

        _model = load_model(MODEL_ID)
        # First generation compiles kernels; do it now so the first real
        # request is fast rather than merely warm.
        synthesize("Ready.")
    except Exception as exc:  # noqa: BLE001
        log(f"failed to load model: {type(exc).__name__}: {exc}")
        server.server_close()
        return 1

    _last_used = time.monotonic()
    log(f"ready on {HOST}:{PORT} in {time.monotonic() - t0:.1f}s "
        f"(voice={VOICE}, idle-exit={IDLE:.0f}s)")

    threading.Thread(target=watch_idle, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
