#!/usr/bin/env python3
"""Is a microphone in use right now? Exit 0 = yes, 1 = no, 2 = can't tell.

This is the signal behind macOS's orange mic dot: CoreAudio's
kAudioDevicePropertyDeviceIsRunningSomewhere. It goes true whenever any process
holds an input stream — Zoom, Meet, Teams, Slack huddles, Granola, QuickTime —
so it needs no list of app names to keep up to date.

It asks *every* device that has input streams, not just the default one. That is
not defensiveness, it is required: measured on a MacBook Pro, opening the mic lit
up device 95/96 while the default input device was 90, so a default-only check
reported "idle" through a live capture.

Reading whether a device is running is not reading audio: this never prompts for
microphone permission and never captures anything.

Stdlib only, via ctypes against the system framework, so it adds no dependency
and runs on stock macOS python3.

    --verbose   list the input devices and which are running
"""

from __future__ import annotations

import ctypes
import ctypes.util
import struct
import sys

IN_USE, IDLE, UNKNOWN = 0, 1, 2


def _fourcc(code: str) -> int:
    return struct.unpack(">I", code.encode())[0]


K_SYSTEM_OBJECT = 1
K_GLOBAL = _fourcc("glob")
K_INPUT_SCOPE = _fourcc("inpt")
K_DEVICES = _fourcc("dev#")           # kAudioHardwarePropertyDevices
K_STREAMS = _fourcc("stm#")           # kAudioDevicePropertyStreams
K_RUNNING_SOMEWHERE = _fourcc("gone")  # kAudioDevicePropertyDeviceIsRunningSomewhere


class _Address(ctypes.Structure):
    _fields_ = [
        ("mSelector", ctypes.c_uint32),
        ("mScope", ctypes.c_uint32),
        ("mElement", ctypes.c_uint32),
    ]


class _CoreAudio:
    def __init__(self, lib):
        self.lib = lib

    def size_of(self, obj: int, selector: int, scope: int = K_GLOBAL):
        addr = _Address(selector, scope, 0)
        size = ctypes.c_uint32(0)
        rc = self.lib.AudioObjectGetPropertyDataSize(
            obj, ctypes.byref(addr), 0, None, ctypes.byref(size)
        )
        return None if rc != 0 else size.value

    def uint32(self, obj: int, selector: int, scope: int = K_GLOBAL):
        addr = _Address(selector, scope, 0)
        out = ctypes.c_uint32(0)
        size = ctypes.c_uint32(4)
        rc = self.lib.AudioObjectGetPropertyData(
            obj, ctypes.byref(addr), 0, None, ctypes.byref(size), ctypes.byref(out)
        )
        return None if rc != 0 else out.value

    def devices(self):
        size = self.size_of(K_SYSTEM_OBJECT, K_DEVICES)
        if not size:
            return []
        addr = _Address(K_DEVICES, K_GLOBAL, 0)
        count = size // ctypes.sizeof(ctypes.c_uint32)
        buf = (ctypes.c_uint32 * count)()
        got = ctypes.c_uint32(size)
        rc = self.lib.AudioObjectGetPropertyData(
            K_SYSTEM_OBJECT, ctypes.byref(addr), 0, None, ctypes.byref(got), buf
        )
        return [] if rc != 0 else list(buf)

    def is_input(self, device: int) -> bool:
        size = self.size_of(device, K_STREAMS, K_INPUT_SCOPE)
        return bool(size)


def mic_in_use(verbose: bool = False) -> int:
    lib_path = ctypes.util.find_library("CoreAudio")
    if not lib_path:
        return UNKNOWN
    ca = _CoreAudio(ctypes.cdll.LoadLibrary(lib_path))

    devices = ca.devices()
    if not devices:
        return UNKNOWN

    inputs = [d for d in devices if ca.is_input(d)]
    if not inputs:
        return IDLE  # a Mac with no input at all is genuinely not in a call

    hot, readable = [], False
    for device in inputs:
        running = ca.uint32(device, K_RUNNING_SOMEWHERE)
        if running is None:
            continue
        readable = True
        if running:
            hot.append(device)

    if verbose:
        print(f"input devices={inputs} running={hot}", file=sys.stderr)

    if not readable:
        return UNKNOWN
    return IN_USE if hot else IDLE


if __name__ == "__main__":
    try:
        sys.exit(mic_in_use("--verbose" in sys.argv))
    except Exception as exc:  # noqa: BLE001
        # A detector that fails must not decide policy. "Unknown" is a distinct
        # answer from "idle", and the hook treats unknown as "go ahead and speak"
        # so a broken probe can never silence you permanently.
        print(f"claudesay-mic: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(UNKNOWN)
