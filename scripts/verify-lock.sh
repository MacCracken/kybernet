#!/usr/bin/env bash
# verify-lock.sh — prove the COMMITTED cyrius.lock is what cyrius.cyml
# actually resolves to.
#
# ⚠ WHY THIS EXISTS: `cyrius deps --verify` CANNOT CATCH A STALE COMMITTED
# LOCK, because CI resolves first. The `Resolve dependencies` step runs
# `cyrius deps`, which REWRITES cyrius.lock from disk; the next step then runs
# `cyrius deps --verify` against the file it just wrote. That is tautological —
# it verifies the resolve against itself and reports "N verified, 0 failed" no
# matter what was committed.
#
# This is not hypothetical and it is not a hazard of one feature. kybernet
# 1.6.12 was first committed with cyrius.cyml at argonaut tag = "1.13.8" and a
# cyrius.lock still pinning 1.13.7's commit (7204b60), because the tag did not
# exist yet at commit time. Run against that exact tree, `cyrius deps` silently
# rewrote 7204b60 -> 8e98429 in place and verify still said "70 verified, 0
# failed". CI would have gone green. It took a second commit to correct.
#
# CLAUDE.md documents this shape for `path` overrides ("the lock is written
# from disk, so deps --verify can't catch it") — but it is a property of the
# STEP ORDER and applies to every release.
#
# TWO HALVES, both required:
#
#   1. OFFLINE (no network). Every git dep declared in cyrius.cyml must have a
#      `commit` line in the lock, and that line's TAG FIELD must equal the
#      manifest's tag. This alone catches the 1.6.12 case in milliseconds, and
#      it is also the only automated check of the `path`-override hazard —
#      a `path =` override makes git/tag inert AND DROPS that dep's commit line
#      from the lock entirely, so `deps --verify` cannot miss what is not there
#      (kybernet 1.5.4 shipped with no argonaut commit pin for exactly this).
#
#   2. RESOLVE (authoritative). Save the committed lock, resolve, compare,
#      restore. Catches a lock carrying the right tag with a wrong commit —
#      a moved tag, a hand-edit, or a hash line that drifted.
#
# ⚠ A NAIVE `diff` IS A FALSE POSITIVE AND MUST NOT BE SHIPPED. `cyrius deps`
# does not emit the lock's hash lines in a stable ORDER, so a byte diff reports
# drift on a perfectly correct lock. Compare SORTED. Verified to pass on the
# correct lock (twice, for ordering stability), fail on the stale one, and not
# false-positive.
#
# ⚠ THIS GATE IS NON-MUTATING, like `cyrius fmt --check`. Half 2 has to run a
# real resolve, which rewrites cyrius.lock — so the committed bytes are
# restored on EVERY exit path. A gate that reformats the tree underneath the
# steps that follow it is standing rule 11's mistake wearing a different hat.
#
# Usage:
#   bash scripts/verify-lock.sh          # both halves (release gate / CI)
#
# There is deliberately NO skip flag. If the resolve cannot run, this FAILS
# with the reason — a missing prerequisite must never pass quietly (rule 32),
# and a skip must never look like a pass (rule 33).

set -euo pipefail

cd "$(dirname "$0")/.."

MANIFEST="cyrius.cyml"
LOCK="cyrius.lock"

[ -f "$MANIFEST" ] || { echo "ERROR: no $MANIFEST here"; exit 1; }

if [ ! -f "$LOCK" ]; then
    echo "ERROR: $LOCK is missing."
    echo "  The lock is the dependency contract — lib/ is gitignored, so the"
    echo "  bytes on disk are not it. Run 'cyrius deps' and commit the result."
    exit 1
fi

fail=0

# ---------------------------------------------------------------------------
# Half 1 — offline: manifest tags vs lock commit lines.
# ---------------------------------------------------------------------------
# A lock commit line is TAB-separated:
#   commit <sha> <name> <url> <tag>
# Field 5 is the tag the commit was resolved FROM, which is exactly the field
# that goes stale when cyrius.cyml is bumped and the lock is not re-resolved.

echo "=== half 1: manifest tags vs committed lock pins (offline) ==="

# Enumerate the git deps declared in the manifest. `[deps]` (the stdlib list)
# has no `git =` line and is correctly excluded. A section whose `git` was
# neutered by a `path` override still declares git+tag here, which is the
# point: the lock must still carry the pin.
DECLARED=$(awk '
    /^\[/ {
        if (name != "" && git != "") print name "\t" tag
        name = ""; git = ""; tag = ""
        if ($0 ~ /^\[deps\./) { n = $0; sub(/^\[deps\./, "", n); sub(/\].*$/, "", n); name = n }
        next
    }
    /^[[:space:]]*git[[:space:]]*=/  { git = $0 }
    /^[[:space:]]*path[[:space:]]*=/ { path = $0 }
    /^[[:space:]]*tag[[:space:]]*=/  { t = $0; sub(/^[^"]*"/, "", t); sub(/".*$/, "", t); tag = t }
    END { if (name != "" && git != "") print name "\t" tag }
' "$MANIFEST")

if [ -z "$DECLARED" ]; then
    echo "ERROR: parsed ZERO git deps out of $MANIFEST."
    echo "  kybernet has four (sigil, agnostik, libro, argonaut). Zero means the"
    echo "  manifest shape changed and this gate can no longer read it — which"
    echo "  is a gate that cannot fail, not a manifest with no deps."
    echo "  (cyrius <= 6.5.27 also read only the first 4095 bytes of a manifest"
    echo "  and resolved a section past that window to zero deps, silently.)"
    exit 1
fi

NDECL=$(printf '%s\n' "$DECLARED" | wc -l)
echo "manifest declares $NDECL git dep(s)"

while IFS=$'\t' read -r name mtag; do
    [ -n "$name" ] || continue
    # Field 3 is the dep name; anchor on it so `sigil` cannot match a
    # hypothetical `sigil_tpm` line.
    ltag=$(awk -F'\t' -v n="$name" '$1 == "commit" && $3 == n { print $5; found = 1 }
                                    END { if (!found) print "" }' "$LOCK")
    lsha=$(awk -F'\t' -v n="$name" '$1 == "commit" && $3 == n { print $2 }' "$LOCK")
    if [ -z "$lsha" ]; then
        echo "  FAIL: $name — declared git+tag in $MANIFEST, but NO commit line in $LOCK."
        echo "        This is the 'path override' shape: git/tag go inert and the"
        echo "        commit pin is dropped, and 'deps --verify' reports success"
        echo "        because it cannot miss what is not there. kybernet 1.5.4"
        echo "        shipped with no argonaut pin for exactly this reason."
        fail=1
        continue
    fi
    if [ "$ltag" != "$mtag" ]; then
        echo "  FAIL: $name — $MANIFEST says tag '$mtag', $LOCK pins tag '$ltag' ($lsha)."
        echo "        The lock is STALE. Re-resolve and commit the result:"
        echo "          rm -rf lib && cyrius deps && cyrius deps --verify"
        fail=1
        continue
    fi
    echo "  OK: $name $mtag -> $lsha"
done <<< "$DECLARED"

if [ "$fail" -ne 0 ]; then
    echo
    echo "ERROR: the committed lock does not agree with the manifest."
    exit 1
fi

# ---------------------------------------------------------------------------
# Half 2 — resolve and compare. Authoritative; needs network.
# ---------------------------------------------------------------------------
echo
echo "=== half 2: resolve and compare against the committed lock ==="

TMPDIR_GATE=$(mktemp -d)
SAVED="$TMPDIR_GATE/committed.lock"
RESOLVED="$TMPDIR_GATE/resolved.lock"
DEPSLOG="$TMPDIR_GATE/deps.log"

cp "$LOCK" "$SAVED"

# ⚠ RESTORE ON EVERY EXIT PATH, including the failure ones. Half 2 rewrites
# cyrius.lock as a side effect of resolving; leaving the rewrite in place would
# make this gate silently "fix" the very drift it exists to report, and would
# hand the next CI step a file the commit never contained.
restore_lock() {
    if [ -f "$SAVED" ]; then cp "$SAVED" "$LOCK"; fi
    rm -rf "$TMPDIR_GATE"
}
trap restore_lock EXIT

if ! cyrius deps > "$DEPSLOG" 2>&1; then
    echo "  FAIL: 'cyrius deps' did not succeed, so there is nothing to compare"
    echo "        against — and a gate is not satisfied by a resolve that did not"
    echo "        happen. The resolver's own error follows."
    echo
    echo "        One expected cause is a lock pinning a DIFFERENT sha for the"
    echo "        SAME tag: cyrius refuses that itself, as a force-pushed or"
    echo "        repointed tag. Note it does NOT refuse a lock pinning a"
    echo "        different TAG — that is silently re-pinned, which is exactly"
    echo "        the 1.6.12 case and is what half 1 above is for."
    echo
    tail -20 "$DEPSLOG" || true
    exit 1
fi

cp "$LOCK" "$RESOLVED"

# ⚠ SORTED. `cyrius deps` does not emit the hash lines in a stable order, so an
# unsorted diff reports drift on a correct lock — a false positive that would
# get this gate disabled within a release.
if diff -q <(sort "$SAVED") <(sort "$RESOLVED") > /dev/null 2>&1; then
    NLINES=$(wc -l < "$SAVED" | tr -d ' ')
    echo "  OK: the committed lock is byte-identical (sorted) to a fresh resolve"
    echo "      ($NLINES lines, $NDECL commit pins)"
else
    echo "  FAIL: a fresh resolve does not match the committed $LOCK."
    echo
    echo "  '<' = only in the COMMITTED lock   '>' = only in the FRESH resolve"
    diff <(sort "$SAVED") <(sort "$RESOLVED") | head -40 || true
    echo
    echo "  The committed lock is stale. 'cyrius deps --verify' cannot report"
    echo "  this: CI resolves BEFORE it verifies, so it checks the resolve"
    echo "  against the file the resolve just wrote."
    echo
    echo "  Fix: rm -rf lib && cyrius deps && cyrius deps --verify, then commit"
    echo "       $LOCK in the same commit as $MANIFEST."
    exit 1
fi

echo
echo "lock verified: manifest tags match, and a fresh resolve reproduces the commit"
