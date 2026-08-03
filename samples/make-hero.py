# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["pillow", "numpy"]
# ///
"""Render the README hero banner.

Deliberately generated from data rather than drawn by hand or by an image model:
the waveform is the *actual* Kokoro sample in samples/2-kokoro-af-heart.mp3, so
the picture on the README is the thing the README is about. Re-run it after
changing the sample and the banner stays honest.

    uv run samples/make-hero.py
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE / "hero.png"
AUDIO = HERE / "2-kokoro-af-heart.mp3"

W, H = 1200, 630
SCALE = 2  # supersample, then downscale — cheap antialiasing for the bars

# claudesay's own palette — deliberately cool. A voice tool's accent should read
# as a signal light, not as warm paper; it also keeps this visually distinct from
# other projects in the author's shelf.
CANVAS = (10, 12, 15)      # #0a0c0f  cool near-black
INK = (242, 244, 243)      # #f2f4f3
INK_DIM = (124, 133, 142)  # #7c858e
INK_FAINT = (74, 82, 90)   # #4a525a
SIGNAL = (95, 227, 179)    # #5fe3b3  luminous mint — used only on the spoken part
SIGNAL_HOT = (168, 245, 214)  # #a8f5d6  the peak core

FONT_CANDIDATES = [
    "/tmp/fonts/DMSans.ttf",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/System/Library/Fonts/Helvetica.ttc",
]


def load_font(size: int, weight: int | None = None) -> ImageFont.FreeTypeFont:
    for path in FONT_CANDIDATES:
        if pathlib.Path(path).exists():
            font = ImageFont.truetype(path, size)
            if weight is not None:
                # DM Sans is a variable font, so the weight axis can be pinned.
                # A static fallback face (Helvetica) has no axes and raises —
                # its single weight is then simply what we get.
                try:
                    font.set_variation_by_axes([14.0, float(weight)])
                except OSError:
                    pass
            return font
    return ImageFont.load_default()


def envelope(path: pathlib.Path, buckets: int) -> np.ndarray:
    """Peak envelope of the real sample, normalized to 0..1."""
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-f", "s16le",
         "-ac", "1", "-ar", "8000", "-"],
        capture_output=True, check=True,
    ).stdout
    samples = np.frombuffer(raw, dtype="<i2").astype(np.float32)
    if samples.size == 0:
        raise SystemExit("no audio decoded — is ffmpeg installed?")
    # Trim leading/trailing near-silence so the waveform fills the width.
    loud = np.abs(samples) > (np.abs(samples).max() * 0.02)
    if loud.any():
        samples = samples[np.argmax(loud): len(loud) - np.argmax(loud[::-1])]
    chunks = np.array_split(samples, buckets)
    peaks = np.array([np.abs(c).max() if c.size else 0.0 for c in chunks])
    return peaks / (peaks.max() or 1.0)


def main() -> int:
    img = Image.new("RGB", (W * SCALE, H * SCALE), CANVAS)
    d = ImageDraw.Draw(img)
    s = SCALE

    bars = 96
    env = envelope(AUDIO, bars)

    # Waveform band, centered.
    band_cy = int(H * 0.605) * s
    max_h = int(H * 0.135) * s   # keep the band clear of both text lines
    left, right = int(W * 0.10) * s, int(W * 0.90) * s
    step = (right - left) / bars
    bar_w = max(2 * s, int(step * 0.42))

    # The idea, not decoration: the whole reply is the dim waveform; only the
    # stretch claudesay actually speaks is lit. That is the product in one image.
    spoken_lo, spoken_hi = int(bars * 0.34), int(bars * 0.78)

    for i, v in enumerate(env):
        spoken = spoken_lo <= i <= spoken_hi
        # Ease the lit region in and out so it reads as emphasis, not a crop.
        if spoken:
            edge = min(i - spoken_lo, spoken_hi - i)
            lit = min(1.0, edge / max(1.0, bars * 0.06))
        else:
            lit = 0.0

        h = max(2 * s, int(max_h * (0.10 + 0.90 * v) * (0.42 + 0.58 * (0.35 + 0.65 * lit))))
        x = int(left + i * step)

        base = INK_FAINT
        target = tuple(int(SIGNAL[c] + (SIGNAL_HOT[c] - SIGNAL[c]) * v) for c in range(3))
        color = tuple(int(base[c] + (target[c] - base[c]) * lit) for c in range(3))

        d.rounded_rectangle(
            [x, band_cy - h, x + bar_w, band_cy + h],
            radius=bar_w // 2, fill=color,
        )

    # Wordmark. The period takes the signal colour — the one mark that speaks.
    f_mark = load_font(76 * s, weight=700)
    mark_x, mark_y = int(W * 0.10) * s, int(H * 0.155) * s
    d.text((mark_x, mark_y), "claudesay", font=f_mark, fill=INK)
    mark_w = d.textlength("claudesay", font=f_mark)
    d.text((mark_x + mark_w, mark_y), ".", font=f_mark, fill=SIGNAL)

    # One line of promise, and one of mechanism.
    f_sub = load_font(30 * s, weight=500)
    d.text((mark_x, mark_y + int(96 * s)),
           "Claude Code tells you the one sentence that matters.",
           font=f_sub, fill=INK_DIM)

    f_meta = load_font(21 * s, weight=400)
    d.text((mark_x, int(H * 0.845) * s),
           "local neural voice  ·  silent while you're on a call  ·  $0",
           font=f_meta, fill=INK_FAINT)

    img.resize((W, H), Image.LANCZOS).save(OUT, optimize=True)
    print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB, {W}x{H})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
