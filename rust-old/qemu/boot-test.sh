#!/usr/bin/env bash
# boot-test.sh — Boot kybernet in QEMU for testing.
#
# Usage: ./qemu/boot-test.sh [kernel]
#   kernel  Path to Linux kernel (default: /boot/vmlinuz-linux-lts)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL="${1:-/boot/vmlinuz-linux-lts}"
INITRAMFS="${SCRIPT_DIR}/initramfs.cpio.gz"

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: kernel not found at $KERNEL"
    exit 1
fi

if [ ! -f "$INITRAMFS" ]; then
    echo "ERROR: initramfs not found at $INITRAMFS"
    echo "Run: cargo build --release --target x86_64-unknown-linux-musl && ./qemu/build-initramfs.sh"
    exit 1
fi

echo "Booting kybernet in QEMU..."
echo "  Kernel:    $KERNEL"
echo "  Initramfs: $INITRAMFS"
echo "  Press Ctrl-A X to exit QEMU"
echo ""

exec qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRAMFS" \
    -append "console=ttyS0 panic=5 rdinit=/sbin/init loglevel=7" \
    -m 256M \
    -nographic \
    -no-reboot \
    -serial mon:stdio
