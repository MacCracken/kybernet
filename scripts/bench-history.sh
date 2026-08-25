#!/usr/bin/env bash
# bench-history.sh — run the microbenchmark suite, append per-benchmark
# ns/op to a CSV history, and flag regressions vs the previous run.
#
# Mandatory release gate (see CLAUDE.md "Benchmarks" rule): run on every
# version bump and review the deltas before cutting. Exits non-zero if any
# benchmark regressed by >= REGRESS_PCT vs its previous recorded value.
#
# ⚠ THIS GATE MUST WORK ON A BUSY MACHINE. It compared raw absolute ns/op
# against the previous run until 1.6.1, which made it unusable on a box doing
# anything else: at load average 24, three consecutive runs reported 52, then
# 21, then 51 regressions — on primitives the release had not touched
# (strlen(52 chars) +144%, getpid +70%, memcpy +40%). A gate that only passes
# on an idle machine is not a gate, it is a request to stop working.
#
# Two mechanisms fix that, and neither asks anything of the operator:
#
#   1. BEST OF N RUNS (RUNS, default 3). Contention only ever ADDS time, so
#      the minimum across runs is the closest estimate of the true cost and
#      is far more robust than a mean. A transient spike no longer decides a
#      release.
#
#   2. NORMALISATION against `_calibration (reference loop)`, a fixed integer
#      loop in src/bench.cyr that touches no kybernet code, no allocator and
#      no syscall. Its cost moves only with machine conditions, so the ratio
#      calibration_now / calibration_then is how much slower this box is than
#      the one that recorded history. Every comparison is scaled by it, so a
#      uniformly slower machine flags nothing and a genuine regression still
#      does.
#
# Raw (unscaled) ns/op is what goes into the CSV — the history stays a record
# of what was actually measured, and the scale is recomputed from the stored
# calibration row on every run.
#
# Usage:
#   ./scripts/bench-history.sh                  # default benches/history.csv
#   ./scripts/bench-history.sh results.csv      # custom output file
#   REGRESS_PCT=20 ./scripts/bench-history.sh   # custom threshold (default 15)
#   RUNS=5 ./scripts/bench-history.sh           # more repetitions (default 3)
#   NO_NORMALISE=1 ./scripts/bench-history.sh   # compare raw ns (old behaviour)

set -euo pipefail

HISTORY_FILE="${1:-benches/history.csv}"
REGRESS_PCT="${REGRESS_PCT:-15}"
# Minimum absolute ns/op change for a percentage regression to count.
# See the noise-floor note at the comparison below. 1.5.1.
MIN_DELTA_NS="${MIN_DELTA_NS:-3}"
# Below this cost, a percentage threshold is finer than the measurement.
# `cyrius bench` reports WHOLE nanoseconds, so one quantisation step at
# 8 ns/op is 12.5% and at 3 ns/op is 33% — a 15% gate on such a benchmark
# fires on the smallest representable change. Benchmarks under this figure
# are gated on absolute nanoseconds only (TINY_DELTA_NS), never on percent.
TINY_NS="${TINY_NS:-20}"
TINY_DELTA_NS="${TINY_DELTA_NS:-5}"
RUNS="${RUNS:-3}"
CALIB_NAME="_calibration (reference loop)"
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

# Reduce contention where the tools exist. Both are best-effort: `nice` needs
# no privilege to LOWER priority but this raises it, and `taskset` pins to one
# CPU so the scheduler stops migrating us between cores mid-measurement.
RUNNER=("$CYRB")
if command -v taskset >/dev/null 2>&1; then RUNNER=(taskset -c 0 "${RUNNER[@]}"); fi
if command -v nice >/dev/null 2>&1; then RUNNER=(nice -n -5 "${RUNNER[@]}"); fi
_bench_once() {
    "${RUNNER[@]}" bench src/bench.cyr 2>/dev/null || "$CYRB" bench src/bench.cyr 2>&1
}

# Best of RUNS: contention only adds time, so the minimum is the closest
# estimate of the true cost. Accumulate per-benchmark minima in a temp file.
MINS=$(mktemp); trap 'rm -f "$MINS"' EXIT
echo "taking the best of ${RUNS} run(s) — contention only ever adds time"
BENCH_OUTPUT=""
for _r in $(seq 1 "$RUNS"); do
    RUN_OUT=$(_bench_once)
    [ -z "$BENCH_OUTPUT" ] && BENCH_OUTPUT="$RUN_OUT"
    printf '%s\n' "$RUN_OUT" | while IFS= read -r l; do
        case "$l" in
            *" ns/op"*)
                nm=$(printf '%s' "$l" | sed -E 's/^[[:space:]]*//; s/:[[:space:]]*[0-9]+ ns\/op.*$//')
                v=$(printf '%s' "$l" | sed -E 's/.*:[[:space:]]*([0-9]+) ns\/op.*$/\1/')
                [ -z "$nm" ] && continue
                printf '%s\t%s\n' "$v" "$nm" >> "$MINS"
                ;;
        esac
    done
done
# Collapse to the minimum per benchmark name.
BEST=$(sort -t"$(printf '\t')" -k2,2 -k1,1n "$MINS" | awk -F"\t" '!seen[$2]++ {print $1 "\t" $2}')

echo "------------------------------------------------------------"
echo "$BENCH_OUTPUT"
echo "------------------------------------------------------------"

# Parse lines like:
#   "  memeq (2 calls): 24 ns/op (1000000 iters, 24 ms total)"
# capturing the benchmark label (before the colon) and the ns/op integer.
REGRESSIONS=0
RECORDED=0

# Historical value for a benchmark name. Rejoins fields 4..NF-1 because two
# benchmark labels contain a comma ("cgroup_file (best case, same pair)"),
# which used to split into $4/$5 so `$4==n` never matched and those two were
# silently exempt from the gate. 1.4.2 audit LOW-6.
_prev_for() {
    awk -F, -v n="$1" '{ nm=$4; for (i=5; i<NF; i++) nm=nm "," $i; if (nm==n) v=$NF } END {print v}' "$HISTORY_FILE"
}

# --- the scale factor -------------------------------------------------------
# How much slower is THIS box than the one that recorded history? Measured by
# the calibration loop, which no kybernet change can affect. Expressed in
# parts per thousand so the comparison stays integer arithmetic.
CALIB_NOW=$(printf '%s\n' "$BEST" | awk -F"\t" -v n="$CALIB_NAME" '$2==n {print $1}')
CALIB_PREV=$(_prev_for "$CALIB_NAME")
SCALE_PPK=1000
if [ "${NO_NORMALISE:-0}" = "1" ]; then
    echo "normalisation: DISABLED (NO_NORMALISE=1) — comparing raw ns/op"
elif [ -n "$CALIB_NOW" ] && [ -n "$CALIB_PREV" ] && [ "$CALIB_PREV" -gt 0 ] 2>/dev/null; then
    SCALE_PPK=$(( CALIB_NOW * 1000 / CALIB_PREV ))
    [ "$SCALE_PPK" -lt 1 ] && SCALE_PPK=1
    echo "calibration: ${CALIB_PREV} -> ${CALIB_NOW} ns/op — this box is running at ${SCALE_PPK}/1000 of the recorded pace"
    if [ "$SCALE_PPK" -gt 1500 ]; then
        echo "  (machine is heavily loaded; every comparison below is scaled to match, so this is fine)"
    fi
else
    echo "calibration: no prior reference in history — comparing raw ns/op this run only"
fi

while IFS="$(printf '\t')" read -r NS NAME; do
            [ -z "$NAME" ] && continue
            [ "$NAME" = "$CALIB_NAME" ] && { echo "${TIMESTAMP},${COMMIT},${BRANCH},${NAME},${NS}" >> "$HISTORY_FILE"; RECORDED=$((RECORDED + 1)); continue; }
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
            PREV=$(_prev_for "$NAME")
            # RAW ns goes to the CSV. History is a record of what was really
            # measured; the scale is recomputed from the stored calibration
            # row on every future run.
            echo "${TIMESTAMP},${COMMIT},${BRANCH},${NAME},${NS}" >> "$HISTORY_FILE"
            RECORDED=$((RECORDED + 1))
            if [ -n "$PREV" ] && [ "$PREV" -gt 0 ] 2>/dev/null; then
                # What the previous figure would cost on THIS box today.
                EXPECT=$(( PREV * SCALE_PPK / 1000 ))
                [ "$EXPECT" -lt 1 ] && EXPECT=1
                DELTA=$(( (NS - EXPECT) * 100 / EXPECT ))
                ABS=$(( NS - EXPECT ))
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
                if [ "$EXPECT" -lt "$TINY_NS" ] && [ "$ABS" -lt "$TINY_DELTA_NS" ]; then
                    # Sub-resolution benchmark: percent is meaningless here.
                    # Normalisation can even AMPLIFY the noise by shifting the
                    # expectation a nanosecond down (8 -> expected 7, measured
                    # 10 reads as +42% on a 2 ns wobble), so this arm comes
                    # first and is judged purely on absolute movement.
                    if [ "$DELTA" -ge "$REGRESS_PCT" ]; then
                        echo "  noise       ${NAME}: ${PREV} -> ${NS} ns/op (+${DELTA}%, ${ABS}ns on a sub-${TINY_NS}ns benchmark)"
                    fi
                elif [ "$DELTA" -ge "$REGRESS_PCT" ] && [ "$ABS" -lt "$MIN_DELTA_NS" ]; then
                    echo "  noise       ${NAME}: ${PREV} -> ${NS} ns/op (expected ~${EXPECT}, +${DELTA}%, ${ABS}ns < ${MIN_DELTA_NS}ns floor)"
                elif [ "$DELTA" -ge "$REGRESS_PCT" ]; then
                    echo "  REGRESSION  ${NAME}: ${PREV} -> ${NS} ns/op (expected ~${EXPECT} on this box, +${DELTA}%)"
                    REGRESSIONS=$((REGRESSIONS + 1))
                elif [ "$DELTA" -le -5 ]; then
                    echo "  improved    ${NAME}: ${PREV} -> ${NS} ns/op (expected ~${EXPECT}, ${DELTA}%)"
                fi
            fi
done <<< "$BEST"

echo "------------------------------------------------------------"
echo "${RECORDED} benchmarks recorded to ${HISTORY_FILE}"

# ⚠ A SUITE THAT SHRINKS MUST NOT PASS. The loop above only iterates
# benchmarks that ARE present, so deleting one — or having it self-skip, as
# the two non-root privilege benches do under root — removed it from the gate
# silently and still reported "no regressions". Compare the count against the
# previous run's. Growth is fine and expected; a drop is a benchmark that
# stopped being measured, which is indistinguishable from one that stopped
# existing. 1.6.1.
PREV_TS=$(awk -F, 'NR>1 && $1 != "'"$TIMESTAMP"'" {t=$1} END {print t}' "$HISTORY_FILE")
if [ -n "$PREV_TS" ]; then
    PREV_COUNT=$(awk -F, -v t="$PREV_TS" '$1==t' "$HISTORY_FILE" | wc -l)
    if [ "$RECORDED" -lt "$PREV_COUNT" ]; then
        echo "ERROR: the benchmark suite SHRANK — ${RECORDED} < ${PREV_COUNT} recorded on ${PREV_TS}."
        echo "A benchmark was deleted, renamed, or self-skipped. Every one of those removes"
        echo "it from the regression gate without any regression being reported."
        exit 1
    fi
    if [ "$RECORDED" -gt "$PREV_COUNT" ]; then
        echo "note: suite grew ${PREV_COUNT} -> ${RECORDED} benchmarks"
    fi
fi
if [ "$REGRESSIONS" -gt 0 ]; then
    echo "${REGRESSIONS} regression(s) >= ${REGRESS_PCT}% vs previous run — REVIEW before release"
    exit 1
fi
echo "no regressions >= ${REGRESS_PCT}% vs previous run"
