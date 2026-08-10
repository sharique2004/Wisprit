#!/usr/bin/env python3
"""Build FluidAudio custom-vocabulary JSON configs from Wisprit dictionaries.

Wisprit schema:    {"terms":[{"term": "...", "hear": ["...", ...]}, ...]}
FluidAudio schema: {"terms":[{"text": "...", "aliases": ["...", ...]}, ...]}
(CustomVocabularyConfig in CustomVocabularyContext.swift at pin 5390df97.)

Outputs (into this directory):
  vocab-eval9.json    the 9-term eval fixture dictionary, 1:1
  vocab-full.json     eval fixture terms + the user's live dictionary terms
                      (READ-ONLY source), deduplicated by canonical term —
                      exercises the >100-term "extra-large vocab" thresholds
"""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
EVAL_DICT = pathlib.Path("/Users/shariquekhatri/Wisprit/tools/eval/fixtures/eval-dictionary.json")
USER_DICT = pathlib.Path.home() / ".wisprit" / "dictionary.json"


def wisprit_terms(path):
    data = json.loads(path.read_text())
    out = []
    for t in data["terms"]:
        # Live dictionary entries may carry extra keys (source, pending, ...).
        # Only term + hear matter here; skip anything malformed.
        term = t.get("term")
        if not term:
            continue
        out.append({"text": term, "aliases": t.get("hear", [])})
    return out


def write(path, terms):
    path.write_text(json.dumps({"terms": terms}, indent=1) + "\n")
    print(f"{path.name}: {len(terms)} terms")


eval_terms = wisprit_terms(EVAL_DICT)
write(HERE / "vocab-eval9.json", eval_terms)

if USER_DICT.exists():
    seen = {t["text"].lower() for t in eval_terms}
    merged = list(eval_terms)
    for t in wisprit_terms(USER_DICT):
        if t["text"].lower() in seen:
            continue
        seen.add(t["text"].lower())
        merged.append(t)
    write(HERE / "vocab-full.json", merged)
else:
    print("user dictionary not found; vocab-full.json skipped", file=sys.stderr)
