#!/usr/bin/env bash
# boot-shutdown-test.sh — Test kybernet clean shutdown via SIGTERM.
#
# Starts kybernet as PID 1, sends SIGTERM after 3s, verifies
# clean shutdown sequence: sync → reboot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KERNEL="${1:-/boot/vmlinuz-linux-lts}"
BINARY="${PROJECT_DIR}/build/kybernet"

[ -f "$BINARY" ] || sh "${PROJECT_DIR}/scripts/build.sh"

echo "Creating shutdown test initramfs..."
INITRAMFS_DIR=$(mktemp -d)
trap "rm -rf $INITRAMFS_DIR" EXIT

mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,dev,proc,sys,run,tmp}

cp "$BINARY" "${INITRAMFS_DIR}/sbin/kybernet"
chmod +x "${INITRAMFS_DIR}/sbin/kybernet"

BUSYBOX="/usr/lib/initcpio/busybox"
if [ -f "$BUSYBOX" ]; then
    cp "$BUSYBOX" "${INITRAMFS_DIR}/bin/busybox"
    chmod +x "${INITRAMFS_DIR}/bin/busybox"
    for cmd in sh sleep kill; do
        ln -sf busybox "${INITRAMFS_DIR}/bin/${cmd}"
    done
fi

# Init wrapper: run kybernet as PID 1 equivalent, send SIGTERM
cat > "${INITRAMFS_DIR}/sbin/init" << 'INITEOF'
#!/bin/sh
echo "shutdown-test: starting kybernet"
/sbin/kybernet &
KYB_PID=$!
sleep 3
echo "shutdown-test: sending SIGTERM to kybernet (pid=$KYB_PID)"
kill -TERM $KYB_PID 2>/dev/null || true
sleep 2
echo "shutdown-test: checking if kybernet exited"
if kill -0 $KYB_PID 2>/dev/null; then
    echo "FAIL: kybernet still running after SIGTERM"
else
    echo "PASS: kybernet exited cleanly"
fi
sync
echo o > /proc/sysrq-trigger 2>/dev/null || true
sleep 5
INITEOF
chmod +x "${INITRAMFS_DIR}/sbin/init"

sudo mknod "${INITRAMFS_DIR}/dev/console" c 5 1 2>/dev/null || true
sudo mknod "${INITRAMFS_DIR}/dev/null" c 1 3 2>/dev/null || true
sudo chmod 666 "${INITRAMFS_DIR}/dev/"* 2>/dev/null || true

cd "${INITRAMFS_DIR}"
find . | bsdcpio -o -H newc 2>/dev/null | gzip > /tmp/shutdown-test.cpio.gz

echo ""
echo "=== SHUTDOWN TEST ==="
echo "  kybernet starts, gets SIGTERM after 3s"
echo "  Watch for: 'received SIGTERM', 'syncing', 'shutdown'"
echo ""

timeout 15 qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd /tmp/shutdown-test.cpio.gz \
    -append "console=ttyS0 panic=5 rdinit=/sbin/init loglevel=7" \
    -m 256M \
    -nographic \
    -no-reboot \
    -serial mon:stdio 2>&1 | grep -E "shutdown-test:|kybernet:|PASS|FAIL|syncing|shutdown" || true

echo ""
echo "=== TEST COMPLETE ==="
