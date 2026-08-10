#!/usr/bin/env python3
"""Import locally downloaded public real-speech corpora into eval manifests.

    python3 tools/eval/import/import_realspeech.py librispeech \
        --root ~/Datasets/LibriSpeech/test-clean --corpus ls-test-clean
    python3 tools/eval/import/import_realspeech.py l2arctic \
        --root ~/Datasets/l2arctic_release_v5 --corpus l2arctic-hindi --l1 hindi
    python3 tools/eval/import/import_realspeech.py commonvoice \
        --root ~/Datasets/cv-corpus/en --corpus cv-en-india --accent India

THE HARNESS NEVER DOWNLOADS. The zero-network rule covers tooling: you download
the corpus yourself (acquisition, licenses and exact subsets are documented in
tools/eval/import/README.md), and this script only reads the local files you
point it at. If `--root` does not exist, that is your acquisition step, not a
bug here.

What it does: selects a deterministic subset, converts audio to the pipeline
format (LEI16@16000 mono WAVE, via the system `afconvert` - flac and mp3 both
decode), and writes `tools/eval/corpus/<corpus>/{audio/,manifest.jsonl}` with
`source: "librispeech"` - the manifest marker for *public real-speech corpus*
(read speech, clean mics, verbatim refs; score raw stage with the `.asr`
profile only; term recall inapplicable). These rungs exist to check that
synthetic orderings survive contact with real speech - they are never quoted
as Wisprit accuracy claims; human-v1 owns that.

Same cache discipline as every generator here: existing WAVs are kept unless
--force, so re-runs never churn sha256s and cached transcripts survive.
"""

import argparse
import csv
import hashlib
import json
import random
import subprocess
import sys
import wave
from pathlib import Path

# L2-ARCTIC v5 speaker -> L1 (verify against the release README when a new
# version lands). 24 speakers, 6 L1 backgrounds.
L2_ARCTIC_L1 = {
    "ABA": "arabic", "SKA": "arabic", "YBAA": "arabic", "ZHAA": "arabic",
    "BWC": "mandarin", "LXC": "mandarin", "NCC": "mandarin", "TXHC": "mandarin",
    "ASI": "hindi", "RRBI": "hindi", "SVBI": "hindi", "TNI": "hindi",
    "HJK": "korean", "HKK": "korean", "YDCK": "korean", "YKWK": "korean",
    "EBVS": "spanish", "ERMS": "spanish", "MBMPS": "spanish", "NJS": "spanish",
    "HQTV": "vietnamese", "PNV": "vietnamese", "THV": "vietnamese", "TLV": "vietnamese",
}


def convert(src, dst):
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                    str(src), str(dst)],
                   check=True, capture_output=True)

def duration_ms(path):
    with wave.open(str(path), "rb") as f:
        return int(f.getnframes() * 1000 / f.getframerate())


# ------------------------------------------------------------- source walkers
# Each yields (clip_id, source_audio_path, ref, category, speaker).

def walk_librispeech(root, args):
    for trans in sorted(root.rglob("*.trans.txt")):
        for line in trans.read_text().splitlines():
            utt, _, text = line.partition(" ")
            if not text:
                continue
            flac = trans.parent / f"{utt}.flac"
            if not flac.exists():
                continue
            speaker = utt.split("-")[0]
            yield (f"ls-{utt}", flac, text.strip().lower(),
                   args.subset or root.name, f"ls-{speaker}")

def walk_l2arctic(root, args):
    wanted = {s for s, l1 in L2_ARCTIC_L1.items()
              if not args.l1 or l1 == args.l1.lower()}
    for speaker_dir in sorted(root.iterdir()):
        speaker = speaker_dir.name.upper()
        if not speaker_dir.is_dir() or speaker not in wanted:
            continue
        l1 = L2_ARCTIC_L1[speaker]
        for wav in sorted((speaker_dir / "wav").glob("*.wav")):
            transcript = speaker_dir / "transcript" / (wav.stem + ".txt")
            if not transcript.exists():
                continue
            yield (f"l2-{speaker.lower()}-{wav.stem}", wav,
                   transcript.read_text().strip(), f"{l1}-l1",
                   f"l2-{speaker.lower()}")

def walk_commonvoice(root, args):
    tsv = root / args.tsv
    if not tsv.exists():
        sys.exit(f"error: {tsv} not found - point --root at the cv-corpus-*/en "
                 "directory (which holds validated.tsv and clips/)")
    with tsv.open(newline="") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            accent = row.get("accents") or row.get("accent") or ""
            if args.accent and args.accent.lower() not in accent.lower():
                continue
            clip = root / "clips" / row["path"]
            if not clip.exists():
                continue
            stem = Path(row["path"]).stem
            label = (args.accent or "any").lower().replace(" ", "-")
            yield (f"cv-{stem[-16:]}", clip, row["sentence"].strip(),
                   f"cv-{label}", f"cv-{row['client_id'][:12]}")

WALKERS = {
    "librispeech": walk_librispeech,
    "l2arctic": walk_l2arctic,
    "commonvoice": walk_commonvoice,
}


# ------------------------------------------------------------------- import

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=sorted(WALKERS))
    parser.add_argument("--root", required=True,
                        help="local corpus root (you downloaded it; this "
                             "script never will)")
    parser.add_argument("--corpus", required=True,
                        help="output corpus id under tools/eval/corpus/")
    parser.add_argument("--limit", type=int, default=200,
                        help="clips to import (deterministic seeded sample; "
                             "default 200)")
    parser.add_argument("--seed", type=int, default=7,
                        help="sample seed - part of the subset's identity, "
                             "record it if you change it")
    parser.add_argument("--l1", help="l2arctic: keep only this L1 "
                                     "(hindi, arabic, mandarin, korean, "
                                     "spanish, vietnamese)")
    parser.add_argument("--accent", help="commonvoice: substring match on the "
                                         "self-reported accent label, e.g. "
                                         "'India'")
    parser.add_argument("--subset", help="librispeech: category label "
                                         "(default: the root dir name)")
    parser.add_argument("--tsv", default="validated.tsv",
                        help="commonvoice: which tsv to read (default: "
                             "validated.tsv)")
    parser.add_argument("--force", action="store_true",
                        help="reconvert existing WAVs (churns sha256s and the "
                             "ASR cache - deliberate acts only)")
    args = parser.parse_args()

    root = Path(args.root).expanduser()
    if not root.exists():
        sys.exit(f"error: {root} does not exist. Download the corpus first - "
                 "see tools/eval/import/README.md. This importer never "
                 "downloads anything.")

    here = Path(__file__).resolve().parent
    corpus_dir = here.parent / "corpus" / args.corpus
    audio = corpus_dir / "audio"
    audio.mkdir(parents=True, exist_ok=True)

    clips = list(WALKERS[args.kind](root, args))
    if not clips:
        sys.exit("error: nothing matched - wrong --root layout, or the filter "
                 "matched no rows")
    if args.limit and len(clips) > args.limit:
        clips = random.Random(args.seed).sample(sorted(clips), args.limit)
        clips.sort()

    manifest = corpus_dir / "manifest.jsonl"
    converted = 0
    with manifest.open("w") as out:
        for clip_id, src, ref, category, speaker in clips:
            wav = audio / f"{clip_id}.wav"
            if args.force or not wav.exists():
                convert(src, wav)
                converted += 1
            record = {
                "id": clip_id,
                "audio": f"audio/{clip_id}.wav",
                "sha256": hashlib.sha256(wav.read_bytes()).hexdigest(),
                "ref": ref,
                "category": category,
                "speaker": speaker,
                "source": "librispeech",
                "mic": "corpus",
                "durationMs": duration_ms(wav),
            }
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
    print(f"wrote {len(clips)} clips ({converted} converted) to {manifest}")
    print("score raw stage, .asr profile only; never quote these as Wisprit "
          "accuracy - they are the ordering check between TTS and human-v1.")

if __name__ == "__main__":
    main()
