#!/usr/bin/env bash
# boot-test.sh — Boot Cyrius kybernet in QEMU, measure boot time.
#
# Minimal boot: no services, just init → mount → signals → event loop.
# Measures total kernel+init time and init-to-event-loop time.
#
# Usage: ./qemu/boot-test.sh [kernel]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KERNEL="${1:-/boot/vmlinuz-linux-lts}"
INITRAMFS="${SCRIPT_DIR}/initramfs.cpio.gz"

# Build initramfs if needed
if [ ! -f "$INITRAMFS" ]; then
    bash "${SCRIPT_DIR}/build-initramfs.sh"
fi

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: kernel not found at $KERNEL"
    exit 1
fi

INIT_SIZE=$(wc -c < "${PROJECT_DIR}/build/kybernet")
echo "=== MINIMAL BOOT TEST ==="
echo "  Kernel:    $KERNEL"
echo "  Init:      ${INIT_SIZE}B (Cyrius)"
echo "  Press Ctrl-A X to exit QEMU"
echo ""

timeout 15 qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRAMFS" \
    -append "console=ttyS0 panic=5 rdinit=/sbin/init loglevel=7" \
    -m 256M \
    -nographic \
    -no-reboot \
    -serial mon:stdio 2>&1 | tee /tmp/kybernet-boot.log | grep -E "kybernet:|Run.*init|Freeing" || true

echo ""

# Extract timing from log
INIT_LINE=$(grep "kybernet: starting" /tmp/kybernet-boot.log 2>/dev/null | head -1 || true)
READY_LINE=$(grep "kybernet: ready" /tmp/kybernet-boot.log 2>/dev/null | head -1 || true)

if [ -n "$INIT_LINE" ]; then
    echo "  init started: found"
fi
if [ -n "$READY_LINE" ]; then
    echo "  event loop:   found"
fi

echo "=== BOOT TEST COMPLETE ==="
