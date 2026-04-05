#!/usr/bin/env bash
# boot-crash-test.sh — Boot kybernet with a crashing service.
#
# Tests: service start → crash → SIGCHLD → reap → delayed restart
# Expected: "crasher" restarts 3 times then gives up.
# Expected: "stable-svc" stays running throughout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KERNEL="${1:-/boot/vmlinuz-linux-lts}"
BINARY="${PROJECT_DIR}/target/x86_64-unknown-linux-musl/release/kybernet"

echo "Building kybernet..."
cargo build --release --target x86_64-unknown-linux-musl --manifest-path "${PROJECT_DIR}/Cargo.toml" 2>&1 | tail -1

echo "Creating test initramfs..."
INITRAMFS_DIR=$(mktemp -d)
trap "rm -rf $INITRAMFS_DIR" EXIT

mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc/argonaut,dev,proc,sys,run,tmp,var/log/agnos/services,usr/bin,usr/lib,lib64}

# Install kybernet
cp "$BINARY" "${INITRAMFS_DIR}/sbin/init"
strip "${INITRAMFS_DIR}/sbin/init" 2>/dev/null || true

# Install busybox + libs
BUSYBOX="/usr/lib/initcpio/busybox"
if [ -f "$BUSYBOX" ]; then
    cp "$BUSYBOX" "${INITRAMFS_DIR}/bin/busybox"
    chmod +x "${INITRAMFS_DIR}/bin/busybox"
    ln -sf busybox "${INITRAMFS_DIR}/bin/sh"
    ln -sf busybox "${INITRAMFS_DIR}/bin/sleep"
    ln -sf busybox "${INITRAMFS_DIR}/bin/echo"
    ln -sf /bin/sh "${INITRAMFS_DIR}/usr/bin/agnoshi"
    for lib in $(ldd "$BUSYBOX" 2>/dev/null | grep -oP '/\S+'); do
        [ -f "$lib" ] && mkdir -p "${INITRAMFS_DIR}$(dirname "$lib")" && cp "$lib" "${INITRAMFS_DIR}${lib}"
    done
    [ -f /lib64/ld-linux-x86-64.so.2 ] && mkdir -p "${INITRAMFS_DIR}/lib64" && cp /lib64/ld-linux-x86-64.so.2 "${INITRAMFS_DIR}/lib64/"
fi

# Install test service scripts
# Create test service scripts inline
cat > "${INITRAMFS_DIR}/usr/bin/test-service.sh" << 'SVCEOF'
#!/bin/sh
echo "test-service: starting (pid=$$)"
sleep 2
echo "test-service: crashing (exit 1)"
exit 1
SVCEOF

cat > "${INITRAMFS_DIR}/usr/bin/stable-service.sh" << 'SVCEOF'
#!/bin/sh
echo "stable-service: starting (pid=$$)"
while true; do sleep 60; done
SVCEOF
chmod +x "${INITRAMFS_DIR}/usr/bin/"*.sh

# Install crash test config
cp "${SCRIPT_DIR}/configs/crash-test.json" "${INITRAMFS_DIR}/etc/argonaut/config.json"

# Create initramfs
cd "${INITRAMFS_DIR}"
find . | bsdcpio -o -H newc 2>/dev/null | gzip > /tmp/crash-test.cpio.gz

echo ""
echo "=== CRASH RECOVERY TEST ==="
echo "  Watch for: crasher starts, crashes, restarts (3x), then gives up"
echo "  Watch for: stable-svc stays running"
echo "  Will run for 30 seconds"
echo ""

timeout 30 qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd /tmp/crash-test.cpio.gz \
    -append "console=ttyS0 panic=5 rdinit=/sbin/init loglevel=7" \
    -m 256M \
    -nographic \
    -no-reboot \
    -serial mon:stdio

echo ""
echo "=== TEST COMPLETE ==="
