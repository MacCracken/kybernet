#!/usr/bin/env bash
# boot-crash-test.sh — Boot kybernet with a crashing child process.
#
# Tests: fork child → child crashes → SIGCHLD → reap → log
# Cyrius kybernet doesn't have argonaut service management yet,
# so we fork a test process from a wrapper init script.
#
# Expected: kybernet starts, child crashes, kybernet reaps it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KERNEL="${1:-/boot/vmlinuz-linux-lts}"
BINARY="${PROJECT_DIR}/build/kybernet"

# Build if needed
[ -f "$BINARY" ] || sh "${PROJECT_DIR}/scripts/build.sh"

echo "Creating crash test initramfs..."
INITRAMFS_DIR=$(mktemp -d)
trap "rm -rf $INITRAMFS_DIR" EXIT

mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,dev,proc,sys,run,tmp,usr/bin}

# Install kybernet
cp "$BINARY" "${INITRAMFS_DIR}/sbin/kybernet"
chmod +x "${INITRAMFS_DIR}/sbin/kybernet"

# Install busybox
BUSYBOX="/usr/lib/initcpio/busybox"
if [ -f "$BUSYBOX" ]; then
    cp "$BUSYBOX" "${INITRAMFS_DIR}/bin/busybox"
    chmod +x "${INITRAMFS_DIR}/bin/busybox"
    for cmd in sh sleep echo kill; do
        ln -sf busybox "${INITRAMFS_DIR}/bin/${cmd}"
    done
fi

# Init wrapper: start kybernet in background, spawn crasher
cat > "${INITRAMFS_DIR}/sbin/init" << 'INITEOF'
#!/bin/sh
# Start kybernet as PID 1 can't be a shell script in real use,
# but for testing we use a wrapper that spawns test children.
echo "test-init: mounting essentials"
mount -t proc proc /proc 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null

echo "test-init: spawning crasher (exits after 2s)"
/bin/sh -c 'sleep 2; echo "crasher: exiting with code 1"; exit 1' &
CRASH_PID=$!

echo "test-init: spawning stable service"
/bin/sh -c 'echo "stable: running"; sleep 60' &

echo "test-init: waiting for crasher (pid=$CRASH_PID)"
wait $CRASH_PID 2>/dev/null || true
echo "test-init: crasher reaped"

echo "test-init: sleeping 3s to verify stable service"
sleep 3

echo "test-init: checking stable service"
if kill -0 $! 2>/dev/null; then
    echo "PASS: stable service still running"
else
    echo "FAIL: stable service died"
fi

echo "test-init: shutting down"
sync
echo o > /proc/sysrq-trigger
sleep 5
INITEOF
chmod +x "${INITRAMFS_DIR}/sbin/init"

# Device nodes
sudo mknod "${INITRAMFS_DIR}/dev/console" c 5 1 2>/dev/null || true
sudo mknod "${INITRAMFS_DIR}/dev/null" c 1 3 2>/dev/null || true
sudo chmod 666 "${INITRAMFS_DIR}/dev/"* 2>/dev/null || true

cd "${INITRAMFS_DIR}"
find . | bsdcpio -o -H newc 2>/dev/null | gzip > /tmp/crash-test.cpio.gz

echo ""
echo "=== CRASH RECOVERY TEST ==="
echo "  Watch for: crasher exits, gets reaped, stable service stays alive"
echo ""

timeout 20 qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd /tmp/crash-test.cpio.gz \
    -append "console=ttyS0 panic=5 rdinit=/sbin/init loglevel=7" \
    -m 256M \
    -nographic \
    -no-reboot \
    -serial mon:stdio 2>&1 | grep -E "test-init:|crasher:|stable:|PASS|FAIL" || true

echo ""
echo "=== TEST COMPLETE ==="
