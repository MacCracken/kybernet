#!/usr/bin/env bash
# bench-history.sh — run the microbenchmark suite, append per-benchmark
# ns/op to a CSV history, and flag regressions vs the previous run.
#
# Mandatory release gate (see CLAUDE.md "Benchmarks" rule): run on every
# version bump and review the deltas before cutting. Exits non-zero if any
# benchmark regressed by >= REGRESS_PCT vs its previous recorded value.
#
# Mirrors agnosys/scripts/bench-history.sh (per-benchmark ns tracking),
# adapted to kybernet's `cyrius bench` "N ns/op" output format.
#
# Usage:
#   ./scripts/bench-history.sh                  # default benches/history.csv
#   ./scripts/bench-history.sh results.csv      # custom output file
#   REGRESS_PCT=20 ./scripts/bench-history.sh   # custom threshold (default 15)

set -euo pipefail

HISTORY_FILE="${1:-benches/history.csv}"
REGRESS_PCT="${REGRESS_PCT:-15}"
# Minimum absolute ns/op change for a percentage regression to count.
# See the noise-floor note at the comparison below. 1.5.1.
MIN_DELTA_NS="${MIN_DELTA_NS:-3}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# Locate the cyrius toolchain
CYRB="${CYRB:-}"
if [ -z "$CYRB" ]; then
    if command -v cyrius >/dev/null 2>&1; then CYRB=cyrius
    elif [ -x "$HOME/.cyrius/bin/cyrius" ]; then CYRB="$HOME/.cyrius/bin/cyrius"
    else echo "ERROR: cyrius not found"; exit 1; fi
fi

mkdir -p "$(dirname "$HISTORY_FILE")"
if [ ! -f "$HISTORY_FILE" ]; then
    echo "timestamp,commit,branch,benchmark,ns_per_op" > "$HISTORY_FILE"
fi

echo "kybernet benchmarks — commit ${COMMIT} (${BRANCH}) @ ${TIMESTAMP}"
echo "regression threshold: +${REGRESS_PCT}% vs previous run"
echo "------------------------------------------------------------"
BENCH_OUTPUT=$("$CYRB" bench src/bench.cyr 2>&1)
echo "$BENCH_OUTPUT"
echo "------------------------------------------------------------"

# Parse lines like:
#   "  memeq (2 calls): 24 ns/op (1000000 iters, 24 ms total)"
# capturing the benchmark label (before the colon) and the ns/op integer.
REGRESSIONS=0
RECORDED=0
while IFS= read -r line; do
    case "$line" in
        *" ns/op"*)
            NAME=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*//; s/:[[:space:]]*[0-9]+ ns\/op.*$//')
            NS=$(printf '%s' "$line" | sed -E 's/.*:[[:space:]]*([0-9]+) ns\/op.*$/\1/')
            [ -z "$NAME" ] && continue
            # Previous value for this benchmark = last matching row already
            # in the file (rows from this run are appended below, after the
            # lookup, so we always compare against the prior run).
            # Reconstruct the label across commas: two benchmark names
            # contain one ("cgroup_file (best case, same pair)"), which
            # split into $4/$5 and made `$4==n` never match — so those two
            # were silently exempt from the regression gate. Rejoin fields
            # 4..NF-1 and read ns/op from $NF. Comma-free rows (NF=5) hit
            # the loop zero times and behave exactly as before.
            # 1.4.2 audit LOW-6.
            PREV=$(awk -F, -v n="$NAME" '{ nm=$4; for (i=5; i<NF; i++) nm=nm "," $i; if (nm==n) v=$NF } END {print v}' "$HISTORY_FILE")
            echo "${TIMESTAMP},${COMMIT},${BRANCH},${NAME},${NS}" >> "$HISTORY_FILE"
            RECORDED=$((RECORDED + 1))
            if [ -n "$PREV" ] && [ "$PREV" -gt 0 ] 2>/dev/null; then
                DELTA=$(( (NS - PREV) * 100 / PREV ))
                ABS=$(( NS - PREV ))
                # Noise floor. `cyrius bench` reports whole nanoseconds, so
                # a benchmark at 2-5 ns/op moves >=15% whenever it moves AT
                # ALL — one ns on a 3 ns measurement is 33%. Three releases
                # running, the only flagged "regressions" were 1-2 ns wobbles
                # on sub-10 ns benchmarks in code the release never touched
                # (classify_signal, cgroup_file, Ok+is_ok), each of which
                # came back as an "improvement" the following release. A
                # gate that cries wolf every time gets ignored, which is
                # worse than no gate.
                #
                # So a regression must be BOTH >= REGRESS_PCT and at least
                # MIN_DELTA_NS in absolute terms. That leaves real
                # regressions on meaningful benchmarks fully covered — a
                # 15% regression on anything above ~20 ns/op still trips —
                # while sub-nanosecond quantisation noise no longer does.
                if [ "$DELTA" -ge "$REGRESS_PCT" ] && [ "$ABS" -lt "$MIN_DELTA_NS" ]; then
                    echo "  noise       ${NAME}: ${PREV} -> ${NS} ns/op (+${DELTA}%, ${ABS}ns < ${MIN_DELTA_NS}ns floor)"
                elif [ "$DELTA" -ge "$REGRESS_PCT" ]; then
                    echo "  REGRESSION  ${NAME}: ${PREV} -> ${NS} ns/op (+${DELTA}%)"
                    REGRESSIONS=$((REGRESSIONS + 1))
                elif [ "$DELTA" -le -5 ]; then
                    echo "  improved    ${NAME}: ${PREV} -> ${NS} ns/op (${DELTA}%)"
                fi
            fi
            ;;
    esac
done <<< "$BENCH_OUTPUT"

echo "------------------------------------------------------------"
echo "${RECORDED} benchmarks recorded to ${HISTORY_FILE}"
if [ "$REGRESSIONS" -gt 0 ]; then
    echo "${REGRESSIONS} regression(s) >= ${REGRESS_PCT}% vs previous run — REVIEW before release"
    exit 1
fi
echo "no regressions >= ${REGRESS_PCT}% vs previous run"
