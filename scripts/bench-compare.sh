#!/bin/sh
# bench-compare.sh — Cyrius vs Rust benchmark comparison
# Builds both benchmark binaries, runs both, and shows side-by-side results.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CYRIUS_CC:-${ROOT}/../cyrius/build/cc2}"

echo "=== Building ==="

# Build Cyrius benchmark
if [ ! -x "$CC" ]; then
    echo "ERROR: Cyrius compiler not found at $CC" >&2
    exit 1
fi
mkdir -p "$ROOT/build"
cd "$ROOT"
cat src/bench.cyr | "$CC" > build/kybernet_bench 2>/dev/null
chmod +x build/kybernet_bench
CYR_SZ=$(wc -c < build/kybernet_bench)
echo "  Cyrius:  build/kybernet_bench ($CYR_SZ bytes)"

# Build Rust benchmark
rustc -O -o build/kybernet_bench_rs benches/rust_compare.rs 2>/dev/null
RS_SZ=$(wc -c < build/kybernet_bench_rs)
echo "  Rust:    build/kybernet_bench_rs ($RS_SZ bytes)"
echo ""

# Run both and capture output
CYR_OUT=$(build/kybernet_bench 2>/dev/null)
RS_OUT=$(build/kybernet_bench_rs 2>/dev/null)

# Parse results into comparison table
echo "╔═══════════════════════════════════════════════════════════════════════╗"
echo "║              kybernet benchmark — Cyrius vs Rust                    ║"
echo "╠═══════════════════════════════════════════════════════════════════════╣"
printf "║  %-28s %12s %12s %9s ║\n" "Operation" "Cyrius" "Rust" "Ratio"
echo "╠═══════════════════════════════════════════════════════════════════════╣"

# Extract ns/op values and compare
echo "$CYR_OUT" | grep "ns/op" | while IFS= read -r cyr_line; do
    # Parse name and ns/op from Cyrius line
    cyr_name=$(echo "$cyr_line" | sed 's/^  //; s/:.*$//')
    cyr_ns=$(echo "$cyr_line" | sed 's/.*: //; s/ ns\/op.*//')

    # Find matching Rust line (use fgrep for literal matching)
    rs_line=$(echo "$RS_OUT" | grep -F "  ${cyr_name}:" 2>/dev/null || true)
    if [ -z "$rs_line" ]; then
        printf "║  %-28s %10s ns %12s %9s ║\n" "$cyr_name" "$cyr_ns" "—" "—"
        continue
    fi
    rs_ns=$(echo "$rs_line" | sed 's/.*: //; s/ ns\/op.*//')

    # Compute ratio (Cyrius / Rust), handling zeros
    if [ "$rs_ns" -gt 0 ] 2>/dev/null && [ "$cyr_ns" -gt 0 ] 2>/dev/null; then
        # Integer ratio * 100 for 2 decimal places
        ratio_x100=$((cyr_ns * 100 / rs_ns))
        ratio_major=$((ratio_x100 / 100))
        ratio_minor=$((ratio_x100 % 100))
        ratio_str=$(printf "%d.%02dx" "$ratio_major" "$ratio_minor")
    else
        ratio_str="—"
    fi

    printf "║  %-28s %10s ns %10s ns %8s ║\n" "$cyr_name" "$cyr_ns" "$rs_ns" "$ratio_str"
done

echo "╠═══════════════════════════════════════════════════════════════════════╣"
RS_RATIO=$(awk "BEGIN{printf \"%.1f\", ${RS_SZ}/${CYR_SZ}}")
printf "║  %-28s %12s %12s %8sx ║\n" "Binary size" "${CYR_SZ}B" "${RS_SZ}B" "${RS_RATIO}"
echo "╚═══════════════════════════════════════════════════════════════════════╝"
