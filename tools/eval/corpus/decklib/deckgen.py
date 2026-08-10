#!/usr/bin/env python3
"""Generator for the robustness deck corpora (deck v1).

    tools/eval/corpus/tts-accents-v1/generate.sh [--force]
    tools/eval/corpus/tts-stress-v1/generate.sh  [--force]
    tools/eval/corpus/tts-corners-v1/generate.sh [--force]

Three corpora, one frozen cell list (measurement.md §6.1, FINAL-PLAN R3):

  tts-accents-v1  8 accent voices x the 50-line tts-v1 script pack, highest
                  installed tier per voice, tier recorded in `speaker`.
                  Manifest `category` = voice, so the existing per-category
                  scoreboard table is the accent axis.
  tts-stress-v1   Samantha x 13 conditions (category = condition):
                  g0, g-12, g-24, g-36, clip+6, wn20/wn10/wn5 (noise added to
                  the g-12 signal - the physically honest "quiet" cell),
                  bab10 (multi-voice babble on g-12), bandlimit8k (16k->8k->16k,
                  the Bluetooth starvation class), whisper-voice (the one
                  synthetic probe of low-energy phonation), r120, r240.
  tts-corners-v1  three worst-case corners: aman x g-24 x wn10,
                  aman x r240 x bab10, rishi x g-12 x wn5 (the stress corpus's
                  wn5 recipe under the second-worst en-IN voice).

Discipline, same contract as tts-samantha/generate.sh:
  * Existing WAVs are kept unless --force: regeneration must not churn sha256s
    or every cached transcript dies with them ("re-scoring is free" depends on
    this).
  * Every stochastic step (noise, babble offsets) is seeded per
    (corpus, condition, clip), so --force reproduces byte-identical audio.
  * TTS audio is a plumbing and direction-finding corpus, never an accuracy
    claim. Every row carries source "tts" and the scoreboard banners it.
  * Pure stdlib + `say`. No network, ever.

Voice tiers: the Enhanced/Premium tiers are a one-time download in System
Settings -> Accessibility -> Spoken Content -> Manage Voices (plan item H2).
This script uses the highest tier actually installed at generation time and
records it in `speaker` (e.g. `tts-daniel-enhanced`); after installing better
tiers, re-run with --force and re-run `eval asr` (~2 min) to re-baseline.
Override auto-detection per voice with WISPRIT_DECK_VOICE_<NAME>, e.g.
    WISPRIT_DECK_VOICE_AMAN="Aman (Premium) (English (India))"
"""

import argparse
import hashlib
import json
import math
import os
import random
import re
import struct
import subprocess
import sys
import wave
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SAMPLE_RATE = 16000
SAY_RATE = 175  # words/min; the spike-S1 recipe every published number used

# name -> `say -v` argument (bare names are unambiguous; the en-IN voices need
# their full display names because Siri variants shadow the bare name).
VOICES = {
    "samantha": "Samantha",   # en_US - the reference voice
    "daniel": "Daniel",       # en_GB
    "karen": "Karen",         # en_AU
    "moira": "Moira",         # en_IE
    "rishi": "Rishi",         # en_IN
    "aman": "Aman (English (India))",   # en_IN
    "tara": "Tara (English (India))",   # en_IN
    "tessa": "Tessa",         # en_ZA
}
WHISPER_VOICE = "Whisper"     # novelty, but genuinely whisper-mode phonation
BABBLE_VOICES = ["daniel", "karen", "rishi"]  # the pilot's cafe-proxy sources


# ---------------------------------------------------------------- script pack

def parse_scripts(path):
    """The tts-v1.txt six-field format: id|category|terms|bypass|spoken|ref."""
    entries = []
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = [f.strip() for f in raw.split("|")]
        if len(fields) < 5:
            sys.exit(f"error: {path}:{number}: needs 6 pipe-separated fields")
        entry = {
            "id": fields[0],
            "category": fields[1],
            "terms": [t.strip() for t in fields[2].split(";") if t.strip()],
            "bypass": fields[3],
            "spoken": fields[4],
            "ref": fields[5] if len(fields) > 5 and fields[5] else fields[4],
        }
        entries.append(entry)
    if not entries:
        sys.exit(f"error: {path}: no script lines")
    return entries


# ---------------------------------------------------------------- voice tiers

def installed_voices():
    out = subprocess.run(["say", "-v", "?"], capture_output=True, text=True,
                         check=True).stdout
    names = []
    for line in out.splitlines():
        # voice-name column ends before the locale column (xx_YY).
        match = re.match(r"^(.*?)\s+[a-z]{2}[_-][A-Z]{2}\s", line)
        if match:
            names.append(match.group(1).strip())
    return names

def best_tier(name, say_arg, inventory):
    """Highest installed tier of a voice: (say argument, tier slug)."""
    override = os.environ.get(f"WISPRIT_DECK_VOICE_{name.upper()}")
    if override:
        tier = "premium" if "(Premium)" in override else \
               "enhanced" if "(Enhanced)" in override else "compact"
        return override, tier
    # "Daniel (Enhanced)" or, for display names that already carry a locale
    # suffix, "Aman (Premium) (English (India))".
    stem, suffix = say_arg, ""
    if " (English" in say_arg:
        cut = say_arg.index(" (English")
        stem, suffix = say_arg[:cut], say_arg[cut:]
    for tier in ("Premium", "Enhanced"):
        candidate = f"{stem} ({tier}){suffix}"
        if candidate in inventory:
            return candidate, tier.lower()
    return say_arg, "compact"


# ---------------------------------------------------------------- audio ops

def synthesize(say_arg, rate, text, path):
    subprocess.run(
        ["say", "-v", say_arg, "-r", str(rate), "-o", str(path),
         "--file-format=WAVE", "--data-format=LEI16@16000", text],
        check=True)

def read_wav(path):
    with wave.open(str(path), "rb") as f:
        assert f.getframerate() == SAMPLE_RATE and f.getnchannels() == 1 \
            and f.getsampwidth() == 2, f"{path}: not LEI16@16000 mono"
        return list(struct.unpack(f"<{f.getnframes()}h", f.readframes(f.getnframes())))

def write_wav(path, samples):
    clamped = [max(-32768, min(32767, int(round(s)))) for s in samples]
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SAMPLE_RATE)
        f.writeframes(struct.pack(f"<{len(clamped)}h", *clamped))

def rms(samples):
    return math.sqrt(sum(s * s for s in samples) / len(samples)) if samples else 0.0

def gain_db(samples, db):
    factor = 10.0 ** (db / 20.0)
    return [s * factor for s in samples]

def white_noise_at_snr(samples, snr_db, rng):
    """Gaussian noise mixed at RMS-SNR vs the signal as given (whole-clip RMS,
    silences included - comparability, not speech-active SNR)."""
    signal = rms(samples)
    noise_rms = signal / (10.0 ** (snr_db / 20.0))
    return [s + rng.gauss(0.0, noise_rms) for s in samples]

def mix_at_snr(samples, track, offset, snr_db):
    """Tile `track` from `offset` and mix onto `samples` at RMS-SNR."""
    signal = rms(samples)
    track_rms = rms(track)
    if track_rms == 0:
        return list(samples)
    factor = (signal / (10.0 ** (snr_db / 20.0))) / track_rms
    n = len(track)
    return [s + track[(offset + i) % n] * factor for i, s in enumerate(samples)]

def bandlimit_8k(samples):
    """16k -> 8k -> 16k: pair-averaged decimation, linear reconstruction - the
    HFP-like band-limiting cell (crude anti-aliasing is deliberate; a real HFP
    chain is not a textbook filter either)."""
    down = [(samples[i] + samples[min(i + 1, len(samples) - 1)]) / 2.0
            for i in range(0, len(samples), 2)]
    up = []
    for i, value in enumerate(down):
        nxt = down[min(i + 1, len(down) - 1)]
        up.append(value)
        up.append((value + nxt) / 2.0)
    return up[:len(samples)]

def seeded_rng(corpus, condition, clip_id):
    material = f"{corpus}|{condition}|{clip_id}".encode()
    return random.Random(int.from_bytes(hashlib.sha256(material).digest()[:8], "big"))


# ---------------------------------------------------------------- manifest

def manifest_line(clip_id, rel_audio, sha, entry, category, speaker):
    record = {
        "id": clip_id,
        "audio": rel_audio,
        "sha256": sha,
        "ref": entry["ref"],
        "category": category,
        "speaker": speaker,
        "source": "tts",
        "mic": "none",
        "script": entry["spoken"],
        "durationMs": None,  # filled by caller
    }
    return record

def finish_record(record, wav_path):
    record["durationMs"] = int((wav_path.stat().st_size - 44) * 1000 / 32000)
    record["sha256"] = hashlib.sha256(wav_path.read_bytes()).hexdigest()
    entry_expect = record.pop("_expect", None)
    if entry_expect:
        record["expect"] = entry_expect
    return record

def expect_of(entry):
    expect = {}
    if entry["terms"]:
        expect["terms"] = entry["terms"]
    if entry["bypass"]:
        if "terms" not in expect:
            expect["terms"] = []
        expect["refineBypass"] = entry["bypass"]
    return expect or None


# ---------------------------------------------------------------- corpora

def synth_pass(jobs, force):
    """jobs: [(say_arg, rate, text, path)] - threaded x6, skip existing."""
    todo = [j for j in jobs if force or not j[3].exists()]
    def run(job):
        say_arg, rate, text, path = job
        synthesize(say_arg, rate, text, path)
        print(f"  synthesized {path.name}")
    with ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(run, todo))
    return len(todo)

def babble_track(corpus_dir, scripts, inventory, force):
    """Multi-voice babble sources; per-target-clip tracks are 12 other-script
    clips (4 per voice), so the babble is always *different* text from the
    target and always longer than it. Selection is drawn from the caller's
    seeded rng, so --force reproduces the same track byte for byte."""
    src = corpus_dir / "audio" / "_babble"
    src.mkdir(parents=True, exist_ok=True)
    jobs = []
    for voice in BABBLE_VOICES:
        say_arg, _ = best_tier(voice, VOICES[voice], inventory)
        for entry in scripts:
            jobs.append((say_arg, SAY_RATE, entry["spoken"],
                         src / f"{voice}-{entry['id']}.wav"))
    synth_pass(jobs, force)
    def track_for(exclude_id, rng):
        track = []
        others = [e["id"] for e in scripts if e["id"] != exclude_id]
        for voice in BABBLE_VOICES:
            for script_id in rng.sample(others, 4):
                track.extend(read_wav(src / f"{voice}-{script_id}.wav"))
        return track
    return track_for

def generate_accents(corpus_dir, scripts, inventory, force):
    audio = corpus_dir / "audio"
    audio.mkdir(parents=True, exist_ok=True)
    jobs, records = [], []
    tiers = {name: best_tier(name, arg, inventory) for name, arg in VOICES.items()}
    for name, (say_arg, tier) in tiers.items():
        print(f"voice {name}: '{say_arg}' ({tier})")
    for name, (say_arg, tier) in tiers.items():
        for entry in scripts:
            clip_id = f"{name}-{entry['id']}"
            path = audio / f"{clip_id}.wav"
            jobs.append((say_arg, SAY_RATE, entry["spoken"], path))
            record = manifest_line(clip_id, f"audio/{clip_id}.wav", "", entry,
                                   category=name, speaker=f"tts-{name}-{tier}")
            record["_expect"] = expect_of(entry)
            records.append((record, path))
    synth_pass(jobs, force)
    return records

def generate_stress(corpus_dir, scripts, inventory, force):
    audio = corpus_dir / "audio"
    base = audio / "_base"
    base.mkdir(parents=True, exist_ok=True)
    samantha, samantha_tier = best_tier("samantha", VOICES["samantha"], inventory)
    whisper, whisper_tier = best_tier("whisper", WHISPER_VOICE, inventory)

    # Synthesis cells: the g0 base every PCM variant derives from, fresh r120 /
    # r240 syntheses, and the whisper voice.
    jobs = []
    for entry in scripts:
        jobs.append((samantha, SAY_RATE, entry["spoken"], base / f"{entry['id']}.wav"))
        jobs.append((samantha, 120, entry["spoken"], base / f"r120-{entry['id']}.wav"))
        jobs.append((samantha, 240, entry["spoken"], base / f"r240-{entry['id']}.wav"))
        jobs.append((whisper, SAY_RATE, entry["spoken"], base / f"whisper-{entry['id']}.wav"))
    synth_pass(jobs, force)
    track_for = babble_track(corpus_dir, scripts, inventory, force)

    speaker = f"tts-samantha-{samantha_tier}"
    conditions = ["g0", "g-12", "g-24", "g-36", "clip+6", "wn20", "wn10", "wn5",
                  "bab10", "bandlimit8k", "whisper-voice", "r120", "r240"]
    records = []
    for condition in conditions:
        for entry in scripts:
            clip_id = f"{condition}-{entry['id']}"
            path = audio / f"{clip_id}.wav"
            spk = f"tts-whisper-{whisper_tier}" if condition == "whisper-voice" else speaker
            record = manifest_line(clip_id, f"audio/{clip_id}.wav", "", entry,
                                   category=condition, speaker=spk)
            record["_expect"] = expect_of(entry)
            records.append((record, path))
            if path.exists() and not force:
                continue
            rng = seeded_rng(corpus_dir.name, condition, entry["id"])
            if condition == "whisper-voice":
                out = read_wav(base / f"whisper-{entry['id']}.wav")
            elif condition in ("r120", "r240"):
                out = read_wav(base / f"{condition}-{entry['id']}.wav")
            else:
                g0 = read_wav(base / f"{entry['id']}.wav")
                if condition == "g0":
                    out = g0
                elif condition in ("g-12", "g-24", "g-36"):
                    out = gain_db(g0, int(condition[1:]))
                elif condition == "clip+6":
                    out = [s * 2.0 for s in g0]  # write_wav clamps: hard clip
                elif condition.startswith("wn"):
                    out = white_noise_at_snr(gain_db(g0, -12), int(condition[2:]), rng)
                elif condition == "bab10":
                    track = track_for(entry["id"], rng)
                    out = mix_at_snr(gain_db(g0, -12), track,
                                     rng.randrange(len(track)), 10)
                elif condition == "bandlimit8k":
                    out = bandlimit_8k(g0)
            write_wav(path, out)
            print(f"  generated {clip_id}.wav")
    return records

def generate_corners(corpus_dir, scripts, inventory, force):
    audio = corpus_dir / "audio"
    base = audio / "_base"
    base.mkdir(parents=True, exist_ok=True)
    aman, aman_tier = best_tier("aman", VOICES["aman"], inventory)
    rishi, rishi_tier = best_tier("rishi", VOICES["rishi"], inventory)

    jobs = []
    for entry in scripts:
        jobs.append((aman, SAY_RATE, entry["spoken"], base / f"aman-{entry['id']}.wav"))
        jobs.append((aman, 240, entry["spoken"], base / f"aman-r240-{entry['id']}.wav"))
        jobs.append((rishi, SAY_RATE, entry["spoken"], base / f"rishi-{entry['id']}.wav"))
    synth_pass(jobs, force)
    track_for = babble_track(corpus_dir, scripts, inventory, force)

    # (condition, base clip stem, speaker, transform)
    cells = [
        # worst accent, quiet, real noise floor: gain -24 then white @ SNR 10
        ("aman-g-24-wn10", "aman-{id}", f"tts-aman-{aman_tier}",
         lambda pcm, rng, track: white_noise_at_snr(gain_db(pcm, -24), 10, rng)),
        # worst accent, fast, cafe babble @ SNR 10
        ("aman-r240-bab10", "aman-r240-{id}", f"tts-aman-{aman_tier}",
         lambda pcm, rng, track: mix_at_snr(pcm, track, rng.randrange(len(track)), 10)),
        # second en-IN voice under the stress corpus's wn5 recipe (g-12 + SNR 5)
        ("rishi-g-12-wn5", "rishi-{id}", f"tts-rishi-{rishi_tier}",
         lambda pcm, rng, track: white_noise_at_snr(gain_db(pcm, -12), 5, rng)),
    ]
    records = []
    for condition, stem, speaker, transform in cells:
        for entry in scripts:
            clip_id = f"{condition}-{entry['id']}"
            path = audio / f"{clip_id}.wav"
            record = manifest_line(clip_id, f"audio/{clip_id}.wav", "", entry,
                                   category=condition, speaker=speaker)
            record["_expect"] = expect_of(entry)
            records.append((record, path))
            if path.exists() and not force:
                continue
            rng = seeded_rng(corpus_dir.name, condition, entry["id"])
            pcm = read_wav(base / (stem.format(id=entry["id"]) + ".wav"))
            track = track_for(entry["id"], rng) if "bab" in condition else []
            write_wav(path, transform(pcm, rng, track))
            print(f"  generated {clip_id}.wav")
    return records


# ---------------------------------------------------------------- main

GENERATORS = {
    "tts-accents-v1": generate_accents,
    "tts-stress-v1": generate_stress,
    "tts-corners-v1": generate_corners,
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", choices=sorted(GENERATORS))
    parser.add_argument("--force", action="store_true",
                        help="regenerate existing WAVs (churns sha256s and every "
                             "cached transcript - deliberate acts only)")
    args = parser.parse_args()

    here = Path(__file__).resolve().parent          # tools/eval/corpus/decklib
    repo = here.parent.parent.parent.parent          # repo root
    corpus_dir = here.parent / args.corpus
    scripts = parse_scripts(repo / "tools/eval/scripts/tts-v1.txt")
    inventory = installed_voices()

    records = GENERATORS[args.corpus](corpus_dir, scripts, inventory, args.force)

    manifest = corpus_dir / "manifest.jsonl"
    with manifest.open("w") as out:
        for record, wav_path in records:
            if not wav_path.exists():
                sys.exit(f"error: {wav_path} was not generated")
            out.write(json.dumps(finish_record(record, wav_path),
                                 ensure_ascii=False) + "\n")
    print(f"wrote {len(records)} clips to {manifest}")
    print(f"audio: {corpus_dir}/audio (gitignored - regenerate with this script)")
    print("reminder: TTS rows are a plumbing/tripwire check, never an accuracy claim.")

if __name__ == "__main__":
    main()
