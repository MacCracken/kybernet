#!/usr/bin/env bash
# boot-edge-test.sh — Edge boot: minimal footprint, single service, fast.
# Target: < 1s from init start to event loop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPOS="/home/macro/Repos"
KERNEL="${1:-/boot/vmlinuz-linux-lts}"
TARGET="x86_64-unknown-linux-musl"

INITRAMFS_DIR=$(mktemp -d)
trap "rm -rf $INITRAMFS_DIR" EXIT

mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc/argonaut,dev,proc,sys,run,tmp,usr/lib/agnos,lib64}
mkdir -p "${INITRAMFS_DIR}/var/log/agnos/services"

echo "=== Edge Boot Test ==="

# kybernet only + daimon (edge mode)
cp "${REPOS}/kybernet/target/${TARGET}/release/kybernet" "${INITRAMFS_DIR}/sbin/init"
strip "${INITRAMFS_DIR}/sbin/init"

cp "${REPOS}/daimon/target/${TARGET}/release/daimon" "${INITRAMFS_DIR}/usr/lib/agnos/agent_runtime"
strip "${INITRAMFS_DIR}/usr/lib/agnos/agent_runtime"

# agnoshi as emergency shell
cp "${REPOS}/agnoshi/target/${TARGET}/release/agnsh" "${INITRAMFS_DIR}/usr/lib/agnos/agnoshi"
strip "${INITRAMFS_DIR}/usr/lib/agnos/agnoshi"
mkdir -p "${INITRAMFS_DIR}/usr/bin"
ln -sf /usr/lib/agnos/agnoshi "${INITRAMFS_DIR}/usr/bin/agnoshi"

# Edge config — single service, no verification (no real block devices in QEMU)
cat > "${INITRAMFS_DIR}/etc/argonaut/config.json" << 'EOF'
{
  "boot_mode": "Edge",
  "services": [],
  "boot_timeout_ms": 10000,
  "shutdown_timeout_ms": 5000,
  "log_to_console": true,
  "verify_on_boot": false,
  "edge_boot": {
    "readonly_rootfs": false,
    "luks_enabled": false,
    "tpm_attestation": false,
    "max_boot_time_ms": 1000,
    "pcr_bindings": ""
  },
  "tmpfiles": []
}
EOF

cd "${INITRAMFS_DIR}"
find . | bsdcpio -o -H newc 2>/dev/null | gzip > /tmp/edge-test.cpio.gz
SIZE=$(du -h /tmp/edge-test.cpio.gz | cut -f1)

echo "  Binaries: kybernet + daimon + agnoshi"
echo "  Initramfs: ${SIZE}"
echo "  Target: < 1s init-to-event-loop"
echo ""

timeout 15 qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd /tmp/edge-test.cpio.gz \
    -append "console=ttyS0 panic=5 rdinit=/sbin/init loglevel=7" \
    -m 128M \
    -nographic \
    -no-reboot \
    -serial mon:stdio 2>&1 | grep -E "phase|starting service|service started|entering main|Run.*init"

echo ""
echo "=== EDGE BOOT COMPLETE ==="
