#!/usr/bin/env python3
import sys, json
sys.path.insert(0, "/private/tmp/claude-501/-Users-shariquekhatri-Wisprit/08bd5841-5936-4964-a20b-5f526dba0b52/scratchpad")
from spell_probe import run

UTT = [
    ("no_trigger",      "S. H. A. R. I. Q. U. E."),
    ("two_letter",      "the format is J. S. O. N."),
    ("capital",         "capital S. H. A. R. I. Q. U. E."),
    ("as_in",           "S as in Sam, H as in Harry, A as in apple"),
    ("hyphen_word",     "we deployed the T-Rex model to production"),
    ("covid",           "the COVID-19 dashboard is broken"),
    ("longer_name",     "correction, it's spelled K. R. Z. Y. S. Z. T. O. F."),
    ("mixed_sentence",  "email Sharique and tell him it's spelled S. H. A. R. I. Q. U. E. not the other way"),
    ("digits_letters",  "the code is A. B. 1. 2. C."),
    ("no_no_that",      "no no not Sharik, Sharique"),
]

for label, text in UTT:
    try:
        print(json.dumps(run(label, text), ensure_ascii=False), flush=True)
    except Exception as e:
        print(json.dumps({"label": label, "error": repr(e)}), flush=True)
