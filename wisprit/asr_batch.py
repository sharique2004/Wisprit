"""Batch ASR fallbacks: mlx-whisper (GPU) then faster-whisper (CPU).

Used by :class:`wisprit.asr.AsrManager` when the streaming ``apple_live`` helper
is unavailable or yields nothing — so dictation survives a helper crash or an OS
update that breaks SpeechAnalyzer. Both accept the retained full-utterance PCM
(int16 mono 16 kHz bytes) and return plain text.

Heavy imports (mlx_whisper / faster_whisper) are deferred into the functions so
importing this module — and the app — stays cheap when the fallbacks are never
needed.
"""

from __future__ import annotations

import logging

import numpy as np

log = logging.getLogger("wisprit.asr_batch")

_DEFAULT_MLX_MODEL = "mlx-community/whisper-large-v3-turbo"

# Cache the faster-whisper model across calls so the CPU tertiary path doesn't
# reload (and possibly re-download) the model on every fallback.
_faster_model = None


def _pcm_to_float32(pcm: bytes) -> np.ndarray:
    """int16 mono bytes → float32 [-1, 1] array at 16 kHz."""
    audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
    return audio


# Whisper models hallucinate these stock phrases on silence / near-silence
# (learned from YouTube captions). If the WHOLE output is one of these, it's
# almost certainly a hallucination on a silent clip, so we drop it — a silent
# push-to-talk must insert nothing, never a phantom "Thank you." Matched only
# against the entire trimmed output, so a real sentence containing "thank you"
# is untouched.
_HALLUCINATIONS = {
    "thank you", "thank you.", "thanks for watching", "thanks for watching.",
    "thanks for watching!", "thank you for watching", "thank you for watching.",
    "thank you very much", "thank you very much.", "you", "you.", ".", "bye",
    "bye.", "bye!", "please subscribe", "so", "so.", "okay", "okay.",
    "i'm sorry", "i'm sorry.", "subtitles by the amara.org community",
    "thanks", "thanks.", "thank you.thank you.", "уou",
}


def _drop_if_hallucinated(text: str) -> str:
    if text and text.strip().lower() in _HALLUCINATIONS:
        log.info("dropped likely silence-hallucination: %r", text)
        return ""
    return text


def transcribe_mlx(pcm: bytes, settings=None) -> str:
    """Transcribe with mlx-whisper (Apple GPU). Returns '' on any failure."""
    if not pcm:
        return ""
    model = _DEFAULT_MLX_MODEL
    if settings is not None:
        configured = settings.get("mlx_model")
        if configured:
            model = configured
    try:
        import mlx_whisper
    except Exception:
        log.exception("mlx_whisper unavailable")
        return ""
    try:
        audio = _pcm_to_float32(pcm)
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=model,
            language=(settings.get("locale").split("-")[0] if settings and settings.get("locale") else "en"),
            fp16=True,
        )
        return _drop_if_hallucinated((result.get("text") or "").strip())
    except Exception:
        log.exception("mlx-whisper transcription failed")
        return ""


def transcribe_faster(pcm: bytes, settings=None) -> str:
    """Transcribe with faster-whisper (CPU tertiary). Returns '' on failure."""
    if not pcm:
        return ""
    global _faster_model
    try:
        from faster_whisper import WhisperModel
    except Exception:
        log.exception("faster_whisper unavailable")
        return ""
    try:
        audio = _pcm_to_float32(pcm)
        if _faster_model is None:
            # small model keeps CPU latency tolerable; this is an emergency
            # path. local_files_only: NEVER download on the dictation path —
            # a mid-dictation HF download blocked a finalize for minutes until
            # the user ^C'd the app. bootstrap.prefetch_fallback_model()
            # (background, at app start) is the only place this may download.
            _faster_model = WhisperModel("small", device="cpu",
                                         compute_type="int8",
                                         local_files_only=True)
        model = _faster_model
        lang = "en"
        if settings and settings.get("locale"):
            lang = settings.get("locale").split("-")[0]
        segments, _ = model.transcribe(audio, language=lang)
        return _drop_if_hallucinated(
            " ".join(seg.text.strip() for seg in segments).strip())
    except Exception:
        log.exception("faster-whisper transcription failed")
        return ""
