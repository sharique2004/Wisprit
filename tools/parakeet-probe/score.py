#!/usr/bin/env python3
"""Score the Parakeet B-0 spike runs against the cached apple_live transcripts.

Inputs (all read-only):
  - Wisprit corpus manifest (refs + expected terms)
  - docs/eval/runs/asr.tts-samantha.apple_live.c1631849.cache.detail.jsonl
  - out-*.jsonl written by parakeet-probe

Term-hit rule replicates VocabularyChannel.termHits exactly: whole-word,
case-insensitive, multi-word terms matched with relaxed inter-word whitespace.
WER normalization is deliberately simple (lowercase, strip punctuation) — an
indicative number, not the Phase-0 .asr profile.
"""
import json
import re
import sys
import pathlib

MANIFEST = pathlib.Path("/Users/shariquekhatri/Wisprit/tools/eval/corpus/tts-samantha/manifest.jsonl")
APPLE = pathlib.Path("/Users/shariquekhatri/Wisprit/docs/eval/runs/asr.tts-samantha.apple_live.c1631849.cache.detail.jsonl")
HERE = pathlib.Path(__file__).resolve().parent


def term_hit(text, term):
    words = [re.escape(w) for w in term.split()]
    pattern = r"\b" + r"\s+".join(words) + r"\b"
    return re.search(pattern, text, re.IGNORECASE) is not None


def norm(text):
    text = text.lower()
    text = re.sub(r"[^\w\s]", " ", text)
    return text.split()


def wer_counts(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1):
        d[i][0] = i
    for j in range(len(h) + 1):
        d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            c = 0 if r[i - 1] == h[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + c)
    return d[len(r)][len(h)], len(r)


manifest = {}
for line in MANIFEST.read_text().splitlines():
    r = json.loads(line)
    manifest[r["id"]] = r

apple = {}
for line in APPLE.read_text().splitlines():
    r = json.loads(line)
    apple[r["id"]] = r["raw"]


def load_run(path):
    rows = {}
    summary = None
    for line in (HERE / path).read_text().splitlines():
        r = json.loads(line)
        if r["kind"] == "utt":
            rows[r["id"]] = r
        elif r["kind"] == "summary":
            summary = r
    return rows, summary


def texts_for(config, rows):
    """config: 'raw' or 'boosted'"""
    return {i: (r.get("boosted") if config == "boosted" else r["raw"]) or "" for i, r in rows.items()}


def score_terms(texts):
    hits, total, misses = 0, 0, []
    for uid, row in manifest.items():
        terms = row.get("expect", {}).get("terms", [])
        text = texts.get(uid)
        if text is None:
            continue
        for t in terms:
            total += 1
            if term_hit(text, t):
                hits += 1
            else:
                misses.append((uid, t))
    return hits, total, misses


def false_replacements(rows):
    """Applied replacements whose term is NOT expected in that clip."""
    fps = []
    for uid, r in rows.items():
        expected = set(manifest.get(uid, {}).get("expect", {}).get("terms", []))
        for rep in r.get("replacements", []):
            if rep.get("apply") and rep.get("repl") and rep["repl"] not in expected:
                fps.append((uid, rep["orig"], rep["repl"]))
    return fps


def corpus_wer(texts):
    e_sum, n_sum = 0, 0
    for uid, row in manifest.items():
        text = texts.get(uid)
        if text is None:
            continue
        e, n = wer_counts(row["ref"], text)
        e_sum += e
        n_sum += n
    return e_sum / n_sum if n_sum else 0


def casing_stats(texts):
    n = len(texts)
    cased = sum(1 for t in texts.values() if any(c.isupper() for c in t))
    starts_cap = sum(1 for t in texts.values() if t and t[0].isupper())
    terminal = sum(1 for t in texts.values() if t.rstrip().endswith((".", "?", "!")))
    comma = sum(1 for t in texts.values() if "," in t)
    return n, cased, starts_cap, terminal, comma


def show(label, texts, rows=None):
    h, t, misses = score_terms(texts)
    wer = corpus_wer(texts)
    line = f"{label:34s} term-recall {h:2d}/{t}  WER(indicative) {wer*100:5.1f}%"
    if rows is not None:
        fps = false_replacements(rows)
        line += f"  false-repl {len(fps):3d}"
    print(line)
    return misses, (false_replacements(rows) if rows is not None else [])


print("=" * 100)
print("APPLE (cached apple_live, c1631849) vs PARAKEET TDT v3 int8 (pin 5390df97)")
print("=" * 100)

apple_misses, _ = show("apple_live raw", apple)

nv, nv_sum = load_run("out-novocab.jsonl")
show("parakeet raw (no vocab)", texts_for("raw", nv))

e9, e9_sum = load_run("out-eval9.jsonl")
show("parakeet+eval9 DEFAULT rescue", texts_for("boosted", e9), e9)

e9n, e9n_sum = load_run("out-eval9-norescue.jsonl")
m, fp = show("parakeet+eval9 no-rescue", texts_for("boosted", e9n), e9n)

f138, f138_sum = load_run("out-full138-norescue.jsonl")
m138, fp138 = show("parakeet+full138 no-rescue", texts_for("boosted", f138), f138)

print()
print("--- misses: apple_live ---")
for uid, t in apple_misses:
    print(f"  {uid}: {t}  | {apple[uid]}")
print("--- misses: parakeet+eval9 no-rescue ---")
for uid, t in m:
    print(f"  {uid}: {t}  | {e9n[uid].get('boosted')}")
print("--- false replacements: parakeet+eval9 no-rescue ---")
for uid, o, r in fp:
    print(f"  {uid}: '{o}' -> '{r}'")
print("--- misses: parakeet+full138 no-rescue ---")
for uid, t in m138:
    print(f"  {uid}: {t}  | {f138[uid].get('boosted')}")
print("--- false replacements: parakeet+full138 no-rescue ---")
for uid, o, r in fp138:
    print(f"  {uid}: '{o}' -> '{r}'")

print()
print("--- casing / punctuation (44 clips) ---")
for label, texts in [("apple_live", apple), ("parakeet raw", texts_for("raw", nv))]:
    n, cased, sc, term, comma = casing_stats(texts)
    print(f"  {label:14s} any-uppercase {cased}/{n}  starts-capital {sc}/{n}  terminal-punct {term}/{n}  has-comma {comma}/{n}")

print()
print("--- latency (parakeet, batch decode over pre-loaded PCM) ---")
import statistics
dec = [r["decode_ms"] for r in nv.values()]
spot = [r.get("spot_ms") for r in f138.values() if r.get("spot_ms")]
resc = [r.get("rescore_ms") for r in f138.values() if r.get("rescore_ms") is not None]
print(f"  decode_ms  (44 clips, 2.0-9.7s audio): min {min(dec):.0f}  p50 {statistics.median(dec):.0f}  p90 {sorted(dec)[int(len(dec)*0.9)]:.0f}  max {max(dec):.0f}")
print(f"  spot_ms    (CTC pass, full138):        min {min(spot):.0f}  p50 {statistics.median(spot):.0f}  max {max(spot):.0f}")
print(f"  rescore_ms (rescorer, full138):        min {min(resc):.1f}  p50 {statistics.median(resc):.1f}  max {max(resc):.1f}")

print()
print("--- summaries ---")
for name, s in [("novocab", nv_sum), ("eval9", e9_sum), ("eval9-norescue", e9n_sum), ("full138-norescue", f138_sum)]:
    if s:
        print(f"  {name}: tdt_load {s['tdt_load_ms']:.0f}ms  ctc+vocab_load {s['ctc_vocab_load_ms']:.0f}ms  "
              f"rescorer {s['rescorer_create_ms']:.1f}ms  rss_end {s['rss_end_mb']:.0f}MB  peak {s['peak_rss_mb']:.0f}MB  "
              f"minSim {s.get('vocab_min_similarity')}  rescue {s.get('spotter_rescue')}")
