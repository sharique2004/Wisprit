#!/bin/zsh
# P0-1 hear-phrase replay probe — see probe.swift for the method and kill bar.
#
#   tools/eval/scripts/p0-1-replay/run.sh [workdir]
#
# Read-only over the live state: the state dir (WISPRIT_STATE_DIR, default
# ~/.wisprit) is COPIED into the workdir first and only the copies are ever
# opened — the probe never touches the live files, and nothing it writes goes
# anywhere but the workdir. The probe binary is compiled here from the app's
# own WispritKit + WispritDictionary sources (read-only, intra-package import
# lines stripped for a flat single-module build), so applyCorrections and the
# learn merge are the real machinery.

set -e
set -u

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h:h:h}"
STATE_DIR="${WISPRIT_STATE_DIR:-$HOME/.wisprit}"
WORK="${1:-$(mktemp -d /tmp/p0-1-replay.XXXXXX)}"
mkdir -p "$WORK"

if [[ ! -f "$STATE_DIR/history.sqlite" ]]; then
    echo "error: $STATE_DIR/history.sqlite not found (history disabled, or" >&2
    echo "wrong WISPRIT_STATE_DIR) — the probe's supply caveat, not a bug" >&2
    exit 1
fi

# 1. Copy the state (including WAL/SHM so the snapshot is consistent).
cp "$STATE_DIR"/history.sqlite* "$WORK/" 2>/dev/null || true
cp "$STATE_DIR/dictionary.json" "$WORK/dictionary-v1.json"

# 2. Export the triples. `readonly` on the *copy*; json output.
sqlite3 -readonly "$WORK/history.sqlite" <<'SQL' > "$WORK/rows.json"
.mode json
SELECT id, raw, corrected, inserted, created FROM utterance_detail ORDER BY created, id;
SQL

# 3. Flat-compile the probe with the app's own sources (imports of sibling
#    package modules stripped — they are all in the same flat module here).
SRC="$WORK/src"
mkdir -p "$SRC"
for f in "$REPO_ROOT"/Sources/WispritKit/*.swift \
         "$REPO_ROOT"/Sources/WispritDictionary/DictionaryStore.swift \
         "$REPO_ROOT"/Sources/WispritDictionary/JSONValue.swift; do
    sed -E 's/^import Wisprit[A-Za-z]+$//' "$f" > "$SRC/$(basename "$f")"
done
xcrun swiftc -O -o "$WORK/probe" "$SCRIPT_DIR/probe.swift" "$SRC"/*.swift

# 4. Run.
"$WORK/probe" "$WORK/rows.json" "$WORK/dictionary-v1.json" "$WORK"
echo ""
echo "workdir: $WORK (scratch; delete freely)"
