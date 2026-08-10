#!/usr/bin/env python3
"""Cue-bleed check (FINAL-PLAN A-6, gate for B-5's default-on-when-hidden).

    python3 tools/eval/scripts/cue-bleed/check.py <cue.wav> \
        [--gain-db -25] [--cells g0,g-12,wn10] [--limit 18] [--keep]

Question: can the mic-open sound cue, coupled from the speakers into the mic
at realistic levels, change what the engine hears at the head of an
utterance? The bar is binary and pre-registered: ZERO transcript delta across
every checked cell, or sounds do not go default-on-when-hidden.

Method: takes clips from the generated `tts-stress-v1` cells (run its
generate.sh first), mixes the cue asset over each clip's head at `--gain-db`
dBFS peak (default -25 - a low-gain UI cue through laptop speakers arriving
well under speech level; B-5's owner should re-run with a measured coupling
level once the asset exists), builds a clean and a mixed corpus in a
disposable fake eval root (WISPRIT_EVAL_ROOT - the repo tree is never
touched), transcribes both with the repo's own harness, and diffs the raw
transcripts per clip.

Zero-network, local `say`-derived audio only, nothing written outside the
fake root.
"""

import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

SAMPLE_RATE = 16000

def read_wav(path):
    with wave.open(str(path), "rb") as f:
        if f.getframerate() != SAMPLE_RATE or f.getnchannels() != 1 or f.getsampwidth() != 2:
            sys.exit(f"error: {path}: cue must be LEI16@16000 mono "
                     "(afconvert -f WAVE -d LEI16@16000 -c 1 in out)")
        return list(struct.unpack(f"<{f.getnframes()}h", f.readframes(f.getnframes())))

def write_wav(path, samples):
    clamped = [max(-32768, min(32767, int(round(s)))) for s in samples]
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(SAMPLE_RATE)
        f.writeframes(struct.pack(f"<{len(clamped)}h", *clamped))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cue", help="the B-5 cue asset (LEI16@16000 mono wav)")
    parser.add_argument("--gain-db", type=float, default=-25.0,
                        help="peak level (dBFS) to mix the cue at (default -25)")
    parser.add_argument("--cells", default="g0,g-12,wn10",
                        help="tts-stress-v1 cells to sample (default g0,g-12,wn10)")
    parser.add_argument("--limit", type=int, default=18,
                        help="clips per cell (default 18)")
    parser.add_argument("--keep", action="store_true", help="keep the fake root")
    args = parser.parse_args()

    here = Path(__file__).resolve().parent
    repo = here.parent.parent.parent.parent
    binary = repo / ".build/debug/WispritMac"
    for candidate in sorted(repo.glob(".build*/debug/WispritMac")):
        binary = candidate
    if not binary.exists():
        sys.exit("error: build the harness first (swift build --product WispritMac)")
    stress = repo / "tools/eval/corpus/tts-stress-v1"
    if not (stress / "manifest.jsonl").exists():
        sys.exit("error: generate tts-stress-v1 first "
                 "(tools/eval/corpus/tts-stress-v1/generate.sh)")

    cue = read_wav(Path(args.cue))
    if len(cue) > SAMPLE_RATE:  # B-5 spec: <=100 ms; tolerate up to 1 s
        sys.exit("error: that cue is over a second long - wrong asset?")
    peak = max(1, max(abs(s) for s in cue))
    scale = (32767 * (10 ** (args.gain_db / 20.0))) / peak

    # Fake eval root: Package.swift + tools/eval is the isCheckout contract.
    root = Path(tempfile.mkdtemp(prefix="cue-bleed-"))
    (root / "Package.swift").write_text("// fake eval root for cue-bleed check\n")
    wanted = args.cells.split(",")
    picked = {}
    for line in (stress / "manifest.jsonl").read_text().splitlines():
        entry = json.loads(line)
        if entry["category"] in wanted and len(picked.get(entry["category"], [])) < args.limit:
            picked.setdefault(entry["category"], []).append(entry)
    corpora = {"cue-clean": lambda pcm: pcm,
               "cue-mixed": lambda pcm: [
                   s + cue[i] * scale if i < len(cue) else s
                   for i, s in enumerate(pcm)]}
    for corpus, transform in corpora.items():
        audio = root / "tools/eval/corpus" / corpus / "audio"
        audio.mkdir(parents=True)
        with (root / "tools/eval/corpus" / corpus / "manifest.jsonl").open("w") as out:
            for cell in wanted:
                for entry in picked.get(cell, []):
                    pcm = read_wav(stress / entry["audio"])
                    wav = audio / f"{entry['id']}.wav"
                    write_wav(wav, transform(pcm))
                    record = dict(entry)
                    record["audio"] = f"audio/{entry['id']}.wav"
                    record["sha256"] = hashlib.sha256(wav.read_bytes()).hexdigest()
                    out.write(json.dumps(record, ensure_ascii=False) + "\n")
    (root / "tools/eval/fixtures").mkdir(parents=True)
    shutil.copy(repo / "tools/eval/fixtures/eval-dictionary.json",
                root / "tools/eval/fixtures/eval-dictionary.json")

    env = dict(os.environ, WISPRIT_EVAL_ROOT=str(root))
    raw = {}
    for corpus in corpora:
        subprocess.run([str(binary), "eval", "asr", "--corpus", corpus],
                       env=env, check=True, capture_output=True)
        detail = next((root / "docs/eval/runs").glob(f"asr.{corpus}.*.detail.jsonl"))
        raw[corpus] = {json.loads(l)["id"]: json.loads(l)["raw"]
                       for l in detail.read_text().splitlines() if l.strip()}

    deltas = [(i, raw["cue-clean"][i], raw["cue-mixed"][i])
              for i in raw["cue-clean"] if raw["cue-clean"][i] != raw["cue-mixed"][i]]
    total = len(raw["cue-clean"])
    print(f"cue-bleed check: {total} clips x ({args.cells}) at {args.gain_db} dBFS peak")
    if deltas:
        print(f"FAIL - {len(deltas)} transcript deltas; sounds must NOT default on:")
        for clip_id, clean, mixed in deltas[:10]:
            print(f"  {clip_id}:\n    clean: {clean}\n    mixed: {mixed}")
    else:
        print("PASS - zero transcript delta; the default-on-when-hidden gate is open.")
    if not args.keep:
        shutil.rmtree(root)
    else:
        print(f"fake root kept: {root}")
    sys.exit(1 if deltas else 0)

if __name__ == "__main__":
    main()
