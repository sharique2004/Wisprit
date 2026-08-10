#!/bin/zsh
# Re-run the whole Parakeet B-0 spike. See docs/research/spikes-parakeet.md
# in the Wisprit repo for what each run measures.
#
# Prereqs:
#   - TDT v3 CoreML models at $MODELS (already on this machine via
#     MeetingScribe's asr-ab; or let AsrModels.download fetch them by
#     pointing MODELS at an empty dir — needs network).
#   - CTC 110m models download to ~/Library/Application Support/FluidAudio/
#     on the first --vocab run (needs network, ~99 MB).
#   - Wisprit repo checked out (manifest + eval dictionary are read from it).
set -e
cd "${0:A:h}"

MODELS="${MODELS:-$HOME/MeetingScribe/native/asr-ab/models/parakeet-tdt-0.6b-v3}"
MANIFEST="/Users/shariquekhatri/Wisprit/tools/eval/corpus/tts-samantha/manifest.jsonl"
PROBE=.build/release/parakeet-probe

python3 make_vocab.py
swift build -c release

$PROBE --manifest "$MANIFEST" --models-dir "$MODELS" --out out-novocab.jsonl
$PROBE --manifest "$MANIFEST" --models-dir "$MODELS" --precision int4 --out out-novocab-int4.jsonl
$PROBE --manifest "$MANIFEST" --models-dir "$MODELS" --vocab vocab-eval9.json --evidence --out out-eval9.jsonl
$PROBE --manifest "$MANIFEST" --models-dir "$MODELS" --vocab vocab-eval9.json --evidence --no-rescue --out out-eval9-norescue.jsonl
$PROBE --manifest "$MANIFEST" --models-dir "$MODELS" --vocab vocab-full.json --evidence --no-rescue --out out-full138-norescue.jsonl
# extra 37 s long-form clip (synthesized by the command in spikes-parakeet.md;
# regenerate with `say` if extra/ is missing)
if [[ -f extra/manifest.jsonl ]]; then
    $PROBE --manifest extra/manifest.jsonl --models-dir "$MODELS" --out out-lf02-novocab.jsonl
    $PROBE --manifest extra/manifest.jsonl --models-dir "$MODELS" --vocab vocab-full.json --no-rescue --out out-lf02-full138.jsonl
fi

python3 score.py
