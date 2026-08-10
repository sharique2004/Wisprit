# human-v1 — the recording protocol

135 utterances across 13 files, read aloud by real people into the real
microphone path. This corpus is what closes spike S4: every accuracy number
Wisprit has published so far was measured on `say -v Samantha`, and a synthetic
voice is a plumbing check, not evidence.

Read this once before your first session. It takes four minutes and it is the
difference between a corpus and an hour of audio nobody can compare.

---

## The tool

    Wisprit eval record --script tools/eval/scripts/human-v1/01-proper-nouns.txt \
                        --speaker spk01 --mic internal

One line at a time. Return to arm, Return to stop, `space` Return to re-take,
`s` Return to skip, `q` Return to stop for now. It is **resumable**: every clip
is written to `manifest.jsonl` the moment it is kept, and a re-run skips
everything already there. Stopping halfway through a file costs nothing.

Then, once per speaker, review what you actually said:

    Wisprit eval verify --corpus human-v1 --speaker spk01

`verify` transcribes each clip and shows the reference next to the transcript.
Accept, fix the reference, or discard the take. This step is not optional and it
is not busywork — see "Why verify exists" below.

## Who reads it

**Three speakers minimum.** Two is not a corpus, it is two people. The variance
between speakers is larger than most of the differences we will be trying to
measure, and with two speakers there is no way to tell which of them is the
outlier.

Speaker ids are `spk01`, `spk02`, `spk03`, … — assigned in the order people
record, and **not** reused. Aim for a spread of accents and of pitch; if all
three speakers sound alike the corpus reports how the pipeline handles one voice
three times.

## The passes

Each speaker does **three passes** over the same 13 files:

| pass | `--mic` | conditions |
|---|---|---|
| 1 — internal | `internal` | the built-in microphone, quiet room, 20-30 cm |
| 2 — Bluetooth | e.g. `airpods-pro` | a Bluetooth headset, same quiet room, same distance |
| 3 — real conditions | e.g. `internal-cafe` | a **subset** (see below), deliberately hostile |

The mic label is part of every clip id (`spk01.airpods-pro.pn-01`), so a second
pass over a script the first pass already recorded produces new clips rather
than a duplicate-id error. That is the whole reason the id is shaped that way.

**Pass 2 is not optional.** The 2026-08-05 starvation incident — five
consecutive empty utterances, root-caused in `docs/research/spikes-s1.md` —
was a Bluetooth input becoming the default device mid-session and dropping the
sample rate from 48 kHz to 24 kHz. Bluetooth audio is a different signal, not
the same signal quieter, and a corpus without it cannot see that class of
failure at all.

**Pass 3 is the one that matters most, and it is the one that will be skipped.**
The competitive read on Wispr Flow is that their moat is not the acoustic model
— it is robustness in real conditions. Close-mic WER has converged at 2-3% for
everybody; the difference users feel is what happens at 60 cm with a café behind
them. A corpus recorded exclusively in a quiet room at 25 cm cannot measure the
thing we are actually competing on.

Pass 3, concretely:

- **Subset**: files 01, 02, 03, 04, 06, 11 and one long-form piece — roughly 70
  utterances. The homophones and the number formatting do not change with the
  room; the proper nouns, the product terms and the disfluent speech do.
- **Background**: music at conversational volume, or a café recording, or an
  actual café. Loud enough that you would raise your voice slightly on a phone
  call.
- **Distance**: about 60 cm — a laptop on a desk, not in your hands.
- **Pace**: faster than passes 1 and 2. Real dictation is quicker than reading.
- Label it so the condition is legible in the id: `internal-cafe`,
  `airpods-street`, `internal-60cm`.

## The dev / held split

**By speaker, and only by speaker.**

- `spk01` → `dev`
- everyone else → `held`

`Wisprit eval record` writes this into the manifest's `split` field
automatically (`EvalRecordPlan.split`). `--split dev|held` overrides it, which is
for a fourth speaker joining an existing side and for nothing else.

Thresholds get tuned on `dev`. Reports come from `held`. A held-out speaker is
released into tuning only when the thresholds it would inform are **frozen** —
after that, that speaker is dev too and a new one has to be recorded.

Why by speaker and not by utterance: an utterance-level split leaves the same
person's other 130 clips in the training half, and their acoustics — their
vowels, their microphone, their room — leak straight into the held set. The
result is a held number that looks honest and is not. Speaker-level is the only
split where the held set is genuinely a voice the tuning never heard.

Every threshold in the accuracy plan is a number tuned against a distribution:
the 0.62 phonetic floor for retro-correction, the 0.80 merge score, the 0.70
auto-learn bar, the plausibility band. All of them are exactly the kind of
number that fits itself to one speaker's voice if you let it.

## Why verify exists

A reader who says "not XML" where the script says "not YAML" has written a
permanent error into the reference. Every WER computed afterwards is measured
against a sentence nobody said, and it never goes away — it is a floor under
every number the corpus will ever produce, and nothing else in the harness can
detect it, because from the outside a reader error and an engine error look
identical.

So: `verify` shows you the reference against a real transcript, and you say
which side was wrong.

- **accept** — the reference is right, the engine was wrong. This is the normal
  answer and it is what the corpus is *for*.
- **fix** — you said something other than the script. The reference becomes what
  you actually said, not what the script asked for. A corpus of what people said
  is worth more than a corpus of what they were supposed to say.
- **discard** — the take is unusable: you coughed, the line got clipped, you read
  the wrong line. The manifest line goes and the audio is renamed `.discarded`
  rather than deleted, because it cannot be re-recorded from anything.

Accepted clips carry `verified: true`. A resumed pass picks up at the first clip
without it.

## Reading directions

Every script file opens with its own pace and distance notes and, in several
cases, with a warning about the specific way that category is easy to record
badly. Read them — they are at the top of the file, and `eval record` prints
them before the first line of each session so you do not have to.

The one rule that applies everywhere: **do not perform.** Say the lines the way
you would say them to a colleague. Careful diction, a helpful pause before a
proper noun, or a crisply articulated "um" all make the corpus easier than
reality, and a corpus that is easier than reality reports a number that will not
survive contact with a user.

## The line format

One utterance per line. `#` lines are comments; the first must be
`# category: <key>`. The line is what you say; optional `|key=value` suffixes are
stripped before it is used:

    Hi Sharique, please add this to the roadmap.|terms=Sharique
    Ship it to 1600 Pennsylvania Avenue Northwest.|bypass=has_address
    The payload is J-S-O-N, not YAML.|bypass=has_letter_run|ref=The payload is JSON, not YAML.

| key | what it does |
|---|---|
| `terms` | `expect.terms` — comma-separated terms that must survive into the final text. The metric that moves when ASR biasing lands. |
| `bypass` | `expect.refineBypass` — `has_address` or `has_letter_run`. Asserts the utterance left the AI cage untouched. |
| `ref` | the text the user wanted in their **document**, when it differs from what you read aloud. Only needed for spelled runs and disfluent speech; everywhere else the line is the reference. |

A bare `|` in a sentence is safe: a suffix is a directive only when it spells
`|<lowercase-word>=`, and a suffix with that shape whose key is not one of the
three is a parse error rather than text. Parsing lives in
`Sources/WispritMac/Eval/EvalScript.swift` and the shipped scripts are parsed by
the test suite, so a typo here fails `swift test` and not a recording session.

## The files

| file | category | lines | notes |
|---|---|---|---|
| `01-proper-nouns.txt` | `proper-nouns` | 10 | names that ARE in the eval dictionary |
| `02-control-names.txt` | `control-names` | 10 | names deliberately absent — the control arm |
| `03-product-terms.txt` | `product-terms` | 12 | Wisprit / InsForge / MeetingScribe / FluidAudio |
| `04-tech-jargon.txt` | `tech-jargon` | 12 | half in the dictionary, half not |
| `05-homophones.txt` | `homophones` | 12 | the acoustics carry no information |
| `06-addresses.txt` | `addresses` | 12 | emails and URLs, half of them must-NOT-join traps |
| `07-postal-address.txt` | `postal-address` | 6 | `has_address` bypass |
| `08-spelled-runs.txt` | `spelled-runs` | 12 | `has_letter_run`; J-S-O-N and K-R-Z-Y-S-Z-T-O-F |
| `09-numbers-dates.txt` | `numbers-dates` | 12 | the formatter's category |
| `10-spoken-commands.txt` | `spoken-commands` | 10 | the obedience traps |
| `11-disfluent-speech.txt` | `disfluent-speech` | 16 | how people actually talk; ds-13…ds-16 are the self-correction pairs |
| `12-long-form.txt` | `long-form` | 3 | 45-90 seconds each |
| `13-adversarial-quiet.txt` | `adversarial-quiet` | 8 | instructions buried in ordinary dictation |

**135 utterances.** One internal pass and one Bluetooth pass per speaker is 270
clips; three speakers plus the real-conditions subset is a little over 1000.
Budget about 25 minutes per full pass, plus 10 for `verify`.

## Where it lands

    tools/eval/corpus/human-v1/
      manifest.jsonl                        committed
      audio/spk01/spk01.internal.pn-01.wav  gitignored — the audio never lands in git

The audio directory is covered by `tools/eval/corpus/**/audio/` in `.gitignore`.
The manifest is committed and is the corpus: it carries every reference, every
sha256, the speaker, the microphone, the split and the verification state. The
sha256 is the ASR cache key, so a re-recorded take invalidates its own cached
transcript with nobody having to remember to clear anything.

Keep a backup of the audio somewhere outside the repo. It is the one artifact
here that cannot be regenerated.
