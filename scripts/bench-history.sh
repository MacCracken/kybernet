#!/usr/bin/env bash
# bench-history.sh — Boot time measurement placeholder.
#
# Kybernet is a PID 1 binary — benchmarks are boot-time measurements
# done in QEMU, not criterion microbenchmarks. This script records
# boot time results.
#
# Usage: ./scripts/bench-history.sh [label] [boot_time_ms]

set -euo pipefail

LABEL="${1:-manual}"
BOOT_MS="${2:-0}"
CSV="benches/history.csv"

mkdir -p benches

if [ ! -f "$CSV" ]; then
    echo "timestamp,label,boot_mode,boot_time_ms" > "$CSV"
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "${TIMESTAMP},${LABEL},desktop,${BOOT_MS}" >> "$CSV"
echo "Recorded: ${LABEL} = ${BOOT_MS}ms"
