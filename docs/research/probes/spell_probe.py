#!/usr/bin/env python3
"""Feed say-synthesized utterances through apple_live and dump the NDJSON."""
import json, os, subprocess, sys, tempfile, time, shutil

BIN = os.path.expanduser("~/.meetingscribe/bin/apple_live")
SR = 16000

UTTERANCES = [
    # (label, text-for-say, optional voice-rate)
    ("plain_name",      "Hi Sharique, how are you"),
    ("spell_spaced",    "actually it's S. H. A. R. I. Q. U. E."),
    ("spell_dashes",    "no no it's spelled S-H-A-R-I-Q-U-E"),
    ("spell_short",     "that's spelled J. O. H. N."),
    ("nato",            "actually it's sierra hotel alfa romeo india quebec uniform echo"),
    ("initialism",      "send it to the U. R. L. for the A. P. I."),
    ("email_letters",   "my email is S. K. at gmail dot com"),
    ("spell_slow",      "spell that. C. A. E. L. U. M."),
]


def synth(text, path, rate=None):
    cmd = ["say", "-v", "Samantha", "--data-format=LEI16@16000", "-o", path]
    if rate:
        cmd += ["-r", str(rate)]
    cmd += [text]
    subprocess.run(cmd, check=True)


def to_raw(aiff, raw):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", aiff,
                    "-f", "s16le", "-ar", str(SR), "-ac", "1", raw], check=True)


def run(label, text, rate=None):
    d = tempfile.mkdtemp()
    wav = os.path.join(d, "a.wav")
    raw = os.path.join(d, "a.raw")
    synth(text, wav, rate)
    to_raw(wav, raw)
    pcm = open(raw, "rb").read()
    proc = subprocess.Popen([BIN, "en-US", str(SR), "1"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, bufsize=0)
    chunk = SR // 10 * 2  # 100 ms of int16 mono
    t0 = time.time()
    for i in range(0, len(pcm), chunk):
        proc.stdin.write(pcm[i:i + chunk])
        time.sleep(0.1)
    proc.stdin.close()
    out = proc.stdout.read().decode("utf-8", "replace")
    proc.wait(timeout=10)
    finals, partials = [], []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("t") == "final":
            finals.append(ev.get("text", ""))
        elif ev.get("t") == "partial":
            partials.append(ev.get("text", ""))
    shutil.rmtree(d, ignore_errors=True)
    return {"label": label, "said": text,
            "final": " ".join(f.strip() for f in finals).strip(),
            "last_partial": partials[-1] if partials else "",
            "n_partials": len(partials), "n_finals": len(finals),
            "secs": round(time.time() - t0, 2)}


if __name__ == "__main__":
    results = []
    for label, text in UTTERANCES:
        try:
            r = run(label, text)
        except Exception as e:
            r = {"label": label, "said": text, "error": repr(e)}
        results.append(r)
        print(json.dumps(r, ensure_ascii=False), flush=True)
    print("\n=== SUMMARY ===")
    for r in results:
        print(f"{r['label']:16s} SAID: {r.get('said')}\n{'':16s} GOT : {r.get('final') or r.get('error')}")
