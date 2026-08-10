#!/bin/zsh
# Synthesize the tts-samantha corpus and write its manifest.
#
#   tools/eval/corpus/tts-samantha/generate.sh [--force]
#
# The recipe is the spike-S1 probe recipe, unchanged, because that is what every
# latency and plumbing number in docs/research/ was measured against:
#
#   say -v Samantha -r 175 --file-format=WAVE --data-format=LEI16@16000
#
# LEI16@16000 is the pipeline format (PcmFormat.canonical), so the harness reads
# these files with a memcpy and no resampling — the audio the analyzer sees is
# byte-identical to what a 16 kHz microphone path would deliver.
#
# TTS audio validates the harness, NOT accuracy: every row it produces carries
# the scoreboard's TTS banner. Human speech is Phase 2 (spike S4).
#
# Existing WAVs are kept unless --force, so a re-run does not churn the sha256s
# and invalidate every cached transcript in docs/eval/runs/.

set -e
set -u

CORPUS_DIR="${0:A:h}"
REPO_ROOT="${CORPUS_DIR:h:h:h:h}"
SCRIPT="$REPO_ROOT/tools/eval/scripts/tts-v1.txt"
AUDIO_DIR="$CORPUS_DIR/audio"
MANIFEST="$CORPUS_DIR/manifest.jsonl"

VOICE="${WISPRIT_TTS_VOICE:-Samantha}"
RATE="${WISPRIT_TTS_RATE:-175}"
SPEAKER="tts-${VOICE:l}"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ ! -f "$SCRIPT" ]]; then
    echo "error: script not found: $SCRIPT" >&2
    exit 1
fi

mkdir -p "$AUDIO_DIR"
: > "$MANIFEST"

trim() { print -r -- "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' }

# The manifest is written with printf and nothing escapes JSON, so the two
# characters that would break it are rejected at the source. Failing here beats
# emitting a manifest the parser rejects with a line number.
reject_unquotable() {
    case "$1" in
        *'"'*|*'\'*)
            echo "error: line $2 field contains a quote or backslash: $1" >&2
            exit 1
            ;;
    esac
}

# "a;b" -> "a","b" (empty -> empty, so the terms array collapses to []).
json_terms() {
    local raw="$1" out="" part
    [[ -z "$raw" ]] && { print -r -- ""; return }
    for part in ${(s.;.)raw}; do
        part="$(trim "$part")"
        [[ -z "$part" ]] && continue
        [[ -n "$out" ]] && out="$out,"
        out="$out\"$part\""
    done
    print -r -- "$out"
}

count=0
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    stripped="$(trim "$line")"
    [[ -z "$stripped" || "$stripped" == \#* ]] && continue

    fields=("${(@s:|:)line}")
    if (( ${#fields} < 5 )); then
        echo "error: line $line_number needs 6 pipe-separated fields" >&2
        exit 1
    fi
    id="$(trim "${fields[1]}")"
    category="$(trim "${fields[2]}")"
    terms="$(trim "${fields[3]}")"
    bypass="$(trim "${fields[4]}")"
    spoken="$(trim "${fields[5]}")"
    ref="$(trim "${fields[6]:-}")"
    [[ -z "$ref" ]] && ref="$spoken"

    for field in "$id" "$category" "$terms" "$bypass" "$spoken" "$ref"; do
        reject_unquotable "$field" "$line_number"
    done

    wav="$AUDIO_DIR/$id.wav"
    if [[ ! -f "$wav" || $FORCE -eq 1 ]]; then
        say -v "$VOICE" -r "$RATE" -o "$wav" \
            --file-format=WAVE --data-format=LEI16@16000 "$spoken"
        printf '  synthesized %s\n' "$id"
    fi

    sha="$(shasum -a 256 "$wav" | cut -d' ' -f1)"
    # 16 kHz mono Int16 = 32000 bytes/second; the WAVE header is 44 bytes. Close
    # enough for a manifest field nobody scores on, and it needs no extra tool.
    bytes="$(stat -f%z "$wav")"
    duration_ms=$(( (bytes - 44) * 1000 / 32000 ))

    expect=""
    terms_json="$(json_terms "$terms")"
    if [[ -n "$terms_json" || -n "$bypass" ]]; then
        expect=",\"expect\":{\"terms\":[$terms_json]"
        [[ -n "$bypass" ]] && expect="$expect,\"refineBypass\":\"$bypass\""
        expect="$expect}"
    fi

    printf '{"id":"%s","audio":"audio/%s.wav","sha256":"%s","ref":"%s","category":"%s","speaker":"%s","source":"tts","mic":"none","script":"%s","durationMs":%d%s}\n' \
        "$id" "$id" "$sha" "$ref" "$category" "$SPEAKER" "$spoken" "$duration_ms" "$expect" \
        >> "$MANIFEST"
    count=$((count + 1))
done < "$SCRIPT"

echo "wrote $count clips to $MANIFEST"
echo "audio: $AUDIO_DIR (gitignored — regenerate with this script)"
echo "reminder: TTS rows are a plumbing check, never an accuracy claim."
