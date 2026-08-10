# P0-1 hear-phrase replay probe

`run.sh` answers Gate 3's question (FINAL-PLAN R8/G3): would the hear-phrase
miner have produced new catches on this user's own history? Method and kill
bar in `probe.swift`'s header. Read-only over copies of the state dir
(`WISPRIT_STATE_DIR`, default `~/.wisprit`); the live files are never opened.

## Run record

| date | rows (mine/replay) | dict terms | candidates (≥2-utt) | new catches | per 100 |
|---|---|---|---|---|---|
| 2026-08-10 | 4 (2/2) | 136 | 0 (0) | 0/2 | 0.0 |

**2026-08-10 verdict: underpowered, not a kill.** `utterance_detail` landed
recently — the history DB holds 289 transcripts but only 4 triples, so the
probe cannot decide the gate either way (the plan priced n≈300 as
"acceptable-but-underpowered"; n=4 is no evidence at all). Supply caveats,
noted per the plan: triples exist only while history is enabled, and the
store caps at 1000 rows. Re-run is free; at ~14 utterances/day a meaningful
n exists in a few weeks. The machinery itself is validated: on a synthetic
fixture the probe mines `'sharik' → 'Sharique'` from two utterances, promotes
it through the real `DictionaryStore.add` merge, and catches the third
occurrence on the replay half (50/100 on the fixture).

Gate 3 (R25, the full miner + promotion UX) therefore stays **closed pending
supply**, not closed-dead: re-run when the triple count clears a few hundred.
