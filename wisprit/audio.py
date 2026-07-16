"""Microphone capture: int16 mono 16 kHz via sounddevice.

Streams PCM chunks to a callback (for the ASR helper) while retaining the full
utterance in memory (for the batch fallback, which needs the whole buffer). A
running ``level`` (0–1) feeds the pill's input meter.

Privacy: the input stream is fully closed on ``stop()`` so the macOS orange
microphone indicator goes dark between utterances — the mic is only live while
the hotkey is held.
"""

from __future__ import annotations

import logging
import threading
from typing import Callable

import numpy as np

from wisprit import runtime

log = logging.getLogger("wisprit.audio")


class AudioCapture:
    """Push-to-talk microphone capture.

    ``on_chunk`` receives int16 mono 16 kHz **bytes** for each block, from the
    sounddevice callback thread — it must be non-blocking (the ASR feed is).
    """

    def __init__(self, on_chunk: Callable[[bytes], None]):
        self._on_chunk = on_chunk
        self.level: float = 0.0
        self._stream = None
        self._buffers: list[bytes] = []
        self._lock = threading.Lock()
        self._active = False

    def _callback(self, indata, frames, time_info, status):  # sounddevice thread
        if status:
            log.debug("audio status: %s", status)
        try:
            # indata is an (frames, 1) int16 ndarray (dtype set on the stream).
            pcm = bytes(indata)
            with self._lock:
                if not self._active:
                    return
                self._buffers.append(pcm)
            # Level meter: normalized RMS of this block.
            samples = np.frombuffer(pcm, dtype=np.int16)
            if samples.size:
                rms = float(np.sqrt(np.mean((samples.astype(np.float32) / 32768.0) ** 2)))
                # Light compression so quiet speech still moves the meter.
                self.level = min(1.0, rms * 4.0)
            try:
                self._on_chunk(pcm)
            except Exception:
                log.exception("on_chunk callback raised")
        except Exception:
            log.exception("audio callback error")

    def start(self) -> bool:
        """Open and start the input stream. Returns False on failure (e.g. mic
        permission denied); the session then aborts the utterance cleanly."""
        import sounddevice as sd

        with self._lock:
            self._buffers = []
            self._active = True
        self.level = 0.0
        try:
            self._stream = sd.InputStream(
                samplerate=runtime.SAMPLE_RATE,
                channels=runtime.CHANNELS,
                dtype=runtime.DTYPE,
                blocksize=runtime.CHUNK_FRAMES,
                callback=self._callback,
            )
            self._stream.start()
            return True
        except Exception:
            log.exception("could not start audio input (mic permission?)")
            with self._lock:
                self._active = False
            self._stream = None
            return False

    def stop(self) -> bytes:
        """Stop capture, fully close the stream (mic goes dark), return the
        complete utterance PCM."""
        with self._lock:
            self._active = False
        stream = self._stream
        self._stream = None
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except Exception:
                log.exception("error closing audio stream")
        self.level = 0.0
        with self._lock:
            return b"".join(self._buffers)

    def is_active(self) -> bool:
        with self._lock:
            return self._active
