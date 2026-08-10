#!/bin/zsh
# Synthesize the tts-stress-v1 robustness-deck corpus and write its manifest.
#
#   tools/eval/corpus/tts-stress-v1/generate.sh [--force]
#
# Deck v1 recipe, cell list and discipline: tools/eval/corpus/decklib/deckgen.py
# (existing WAVs are kept unless --force, so re-runs never churn sha256s and the
# sha-keyed ASR cache survives). TTS audio is a plumbing/tripwire corpus and is
# never an accuracy claim.
set -e
set -u
exec python3 "${0:A:h:h}/decklib/deckgen.py" "tts-stress-v1" "$@"
