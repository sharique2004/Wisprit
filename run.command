#!/bin/zsh
# Wisprit launcher — double-click in Finder or run from a terminal.
#
# Runs Wisprit under the MeetingScribe venv python (the interpreter that has
# pyobjc, sounddevice, numpy, mlx-whisper installed AND holds the TCC grants
# for Accessibility / Input Monitoring — see README.md "Permissions").
# Any arguments are forwarded, so `./run.command doctor` works too.

set -e
set -u

REPO_DIR="${0:A:h}"                              # absolute dir of this script
PY="$HOME/.meetingscribe/venv/bin/python"

if [[ ! -x "$PY" ]]; then
    echo "error: expected interpreter not found or not executable:" >&2
    echo "  $PY" >&2
    echo "Wisprit reuses the MeetingScribe venv (pyobjc, sounddevice, numpy," >&2
    echo "mlx-whisper, faster-whisper). Restore that venv, then re-run." >&2
    echo "NOTE: recreating the venv resets TCC grants — see README.md." >&2
    exit 1
fi

cd "$REPO_DIR"
exec "$PY" -m wisprit "$@"
