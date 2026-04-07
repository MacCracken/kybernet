#!/bin/sh
# Benchmark kybernet — build and run bench suite
# Usage: sh scripts/bench.sh [--history]
#   --history  Append results to benches/history.csv
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CYRIUS_CC:-${ROOT}/../cyrius/build/cc2}"

if [ ! -x "$CC" ]; then
    echo "ERROR: Cyrius compiler not found at $CC" >&2
    echo "Set CYRIUS_CC or build: cd ../cyrius && sh bootstrap/bootstrap.sh" >&2
    exit 1
fi

mkdir -p "$ROOT/build"

echo "Building kybernet_bench..."
cd "$ROOT"
cat src/bench.cyr | "$CC" > build/kybernet_bench
chmod +x build/kybernet_bench
SZ=$(wc -c < build/kybernet_bench)
echo "  -> build/kybernet_bench ($SZ bytes)"
echo ""

# Run benchmarks
build/kybernet_bench
BENCH_EXIT=$?

# Optionally append to history
if [ "$1" = "--history" ]; then
    mkdir -p "$ROOT/benches"
    HIST="$ROOT/benches/history.csv"

    # Also build main to get binary size
    cat src/main.cyr | "$CC" > build/kybernet 2>/dev/null
    chmod +x build/kybernet
    MAIN_SZ=$(wc -c < build/kybernet)

    # Get compiler version
    CC_VER=$(cat "${ROOT}/../cyrius/VERSION" 2>/dev/null || echo "unknown")

    TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    BRANCH=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    echo "${TS},${COMMIT},${BRANCH},cc2-${CC_VER},${MAIN_SZ},${SZ}" >> "$HIST"
    echo ""
    echo "  -> appended to benches/history.csv (main=${MAIN_SZ}B bench=${SZ}B cc2=${CC_VER})"
fi

exit $BENCH_EXIT
