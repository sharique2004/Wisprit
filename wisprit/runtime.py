"""Shared constants and paths for Wisprit. Every module imports from here —
never hardcode a path or magic number that belongs in this file or config.
"""

from pathlib import Path

APP_NAME = "Wisprit"
VERSION = "0.1.0"

# --- Filesystem layout -------------------------------------------------------
HOME = Path.home()
STATE_DIR = HOME / ".wisprit"                 # created by bootstrap.ensure_state_dir()
CONFIG_PATH = STATE_DIR / "config.json"
DICTIONARY_PATH = STATE_DIR / "dictionary.json"
HISTORY_DB_PATH = STATE_DIR / "history.sqlite"
METRICS_LOG_PATH = STATE_DIR / "metrics.log"
LOG_PATH = STATE_DIR / "wisprit.log"
BIN_DIR = STATE_DIR / "bin"                   # compiled helpers owned by Wisprit

# --- Reused MeetingScribe assets ---------------------------------------------
# The streaming SpeechAnalyzer helper already compiled by MeetingScribe.
MEETINGSCRIBE_BIN = HOME / ".meetingscribe" / "bin"
APPLE_LIVE_BIN = MEETINGSCRIBE_BIN / "apple_live"
APPLE_LIVE_SRC = HOME / "MeetingScribe" / "tools" / "apple_live.swift"
# Python interpreter this app must run under (has pyobjc, sounddevice, mlx).
VENV_PYTHON = HOME / ".meetingscribe" / "venv" / "bin" / "python"

# --- Audio -------------------------------------------------------------------
SAMPLE_RATE = 16_000          # Hz, mono int16 — what we feed apple_live
CHANNELS = 1
DTYPE = "int16"
CHUNK_FRAMES = 1_600          # 100 ms per callback chunk

# --- Hotkey ------------------------------------------------------------------
KVK_FUNCTION = 63             # kVK_Function keycode seen on flagsChanged
KVK_RIGHT_OPTION = 61
KVK_ESCAPE = 53
FN_FLAG_MASK = 0x800000       # kCGEventFlagMaskSecondaryFn

# --- Insertion ---------------------------------------------------------------
KVK_ANSI_V = 9
DEFAULT_TERMINAL_BUNDLE_IDS = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.github.wez.wezterm",
    "net.kovidgoyal.kitty",
    "io.alacritty",
    "com.mitchellh.ghostty",
]
