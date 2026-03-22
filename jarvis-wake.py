#!/usr/bin/env python3
"""
jarvis-wake — background wake-word listener for JarvisOS

Listens for "Hey Jarvis" via Vosk (offline STT) using the PipeWire audio
session and opens the user's default terminal with `jarvis chat` when the
wake phrase is detected.

Must run as the logged-in user (systemd --user) so it has access to the
PipeWire session.  Requires /dev/jarvis to be present (linux-jarvisos kernel).
"""

import sys
import os
import json
import subprocess
import shutil
import time

VOSK_MODEL   = "/var/lib/jarvis/models/vosk/vosk-model-small-en-us-0.15"
WAKE_PHRASES = ["hey jarvis", "hi jarvis", "okay jarvis", "ok jarvis"]
COOLDOWN     = 5.0   # seconds between terminal opens — prevents double-open

# Inner command run inside the launched terminal
JARVIS_CMD = (
    "source /var/lib/jarvis/venv/bin/activate && "
    "export PYTHONPATH=/usr/lib && "
    "export LOG_LEVEL=WARNING && "
    "jarvis chat; "
    "echo; read -rp 'Press Enter to close...'"
)


def guard():
    """Exit cleanly if not running on linux-jarvisos."""
    if not os.path.exists("/dev/jarvis"):
        print("[jarvis-wake] /dev/jarvis not found — not on linux-jarvisos kernel. Exiting.")
        sys.exit(0)


def find_terminal():
    for t in ["konsole", "alacritty", "kitty", "wezterm",
              "xfce4-terminal", "gnome-terminal", "xterm"]:
        if shutil.which(t):
            return t
    return None


def open_jarvis_terminal():
    term = find_terminal()
    if not term:
        print("[jarvis-wake] No terminal emulator found", file=sys.stderr)
        return

    env = os.environ.copy()

    if term == "konsole":
        args = ["konsole", "--title", "JARVIS", "-e", "bash", "-c", JARVIS_CMD]
    elif term == "alacritty":
        args = ["alacritty", "--title", "JARVIS", "-e", "bash", "-c", JARVIS_CMD]
    elif term == "kitty":
        args = ["kitty", "--title", "JARVIS", "bash", "-c", JARVIS_CMD]
    elif term == "wezterm":
        args = ["wezterm", "start", "--title", "JARVIS", "--", "bash", "-c", JARVIS_CMD]
    elif term == "xfce4-terminal":
        args = ["xfce4-terminal", "--title=JARVIS", "-e", f"bash -c '{JARVIS_CMD}'"]
    elif term == "gnome-terminal":
        args = ["gnome-terminal", "--title=JARVIS", "--", "bash", "-c", JARVIS_CMD]
    else:
        args = [term, "-e", "bash", "-c", JARVIS_CMD]

    subprocess.Popen(args, env=env)
    print(f"[jarvis-wake] Opened {term} with JARVIS chat", flush=True)


def main():
    guard()

    try:
        from vosk import Model, KaldiRecognizer
        import sounddevice as sd
    except ImportError as exc:
        print(f"[jarvis-wake] Missing dependency: {exc}", file=sys.stderr)
        sys.exit(1)

    if not os.path.isdir(VOSK_MODEL):
        print(f"[jarvis-wake] Vosk model not found at {VOSK_MODEL}", file=sys.stderr)
        sys.exit(1)

    print("[jarvis-wake] Loading Vosk model...", flush=True)
    model = Model(VOSK_MODEL)
    rec   = KaldiRecognizer(model, 16000)

    print("[jarvis-wake] Listening for 'Hey Jarvis'...", flush=True)

    last_open = 0.0

    def callback(indata, frames, time_info, status):
        nonlocal last_open
        if status:
            return
        if rec.AcceptWaveform(bytes(indata)):
            text = json.loads(rec.Result()).get("text", "").lower().strip()
            if text and any(w in text for w in WAKE_PHRASES):
                now = time.monotonic()
                if now - last_open > COOLDOWN:
                    last_open = now
                    print(f"[jarvis-wake] Wake phrase detected: '{text}'", flush=True)
                    open_jarvis_terminal()

    with sd.RawInputStream(
        samplerate=16000,
        blocksize=4000,
        dtype="int16",
        channels=1,
        callback=callback,
    ):
        while True:
            time.sleep(0.1)


if __name__ == "__main__":
    main()
