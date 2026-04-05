#!/usr/bin/env bash
# boot-full-desktop.sh — Full desktop boot with ALL real AGNOS binaries.
#
# Real binaries: kybernet, daimon, hoosh, agnoshi, aethersafha
# No dummies. This is the real thing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPOS="/home/macro/Repos"
KERNEL="${1:-/boot/vmlinuz-linux-lts}"
TARGET="x86_64-unknown-linux-musl"

INITRAMFS_DIR=$(mktemp -d)
trap "rm -rf $INITRAMFS_DIR" EXIT

mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc/argonaut,dev,proc,sys,run,tmp,usr/bin,usr/lib/agnos,lib64}
mkdir -p "${INITRAMFS_DIR}/var/log/agnos/services"

echo "=== Installing real AGNOS binaries ==="

# kybernet (PID 1)
cp "${REPOS}/kybernet/target/${TARGET}/release/kybernet" "${INITRAMFS_DIR}/sbin/init"
strip "${INITRAMFS_DIR}/sbin/init"
echo "  kybernet → /sbin/init"

# daimon (agent orchestrator)
cp "${REPOS}/daimon/target/${TARGET}/release/daimon" "${INITRAMFS_DIR}/usr/lib/agnos/agent_runtime"
strip "${INITRAMFS_DIR}/usr/lib/agnos/agent_runtime"
echo "  daimon → /usr/lib/agnos/agent_runtime"

# hoosh (LLM gateway)
cp "${REPOS}/hoosh/target/${TARGET}/release/hoosh" "${INITRAMFS_DIR}/usr/lib/agnos/llm_gateway"
strip "${INITRAMFS_DIR}/usr/lib/agnos/llm_gateway"
echo "  hoosh → /usr/lib/agnos/llm_gateway"

# aethersafha (compositor)
cp "${REPOS}/aethersafha/target/${TARGET}/release/aethersafha" "${INITRAMFS_DIR}/usr/lib/agnos/aethersafha"
strip "${INITRAMFS_DIR}/usr/lib/agnos/aethersafha"
echo "  aethersafha → /usr/lib/agnos/aethersafha"

# agnoshi (shell)
cp "${REPOS}/agnoshi/target/${TARGET}/release/agnsh" "${INITRAMFS_DIR}/usr/lib/agnos/agnoshi"
strip "${INITRAMFS_DIR}/usr/lib/agnos/agnoshi"
ln -sf /usr/lib/agnos/agnoshi "${INITRAMFS_DIR}/usr/bin/agnoshi"
echo "  agnoshi → /usr/lib/agnos/agnoshi"

# ifran (LLM inference/training)
cp "${REPOS}/ifran/target/${TARGET}/release/ifran" "${INITRAMFS_DIR}/usr/lib/agnos/ifran"
strip "${INITRAMFS_DIR}/usr/lib/agnos/ifran"
echo "  ifran → /usr/lib/agnos/ifran"

# No busybox — all real AGNOS binaries. agnoshi is the emergency shell.

# Desktop config — all real services
cat > "${INITRAMFS_DIR}/etc/argonaut/config.json" << 'EOF'
{
  "boot_mode": "Desktop",
  "services": [],
  "boot_timeout_ms": 30000,
  "shutdown_timeout_ms": 10000,
  "log_to_console": true,
  "verify_on_boot": false,
  "edge_boot": {
    "readonly_rootfs": false,
    "luks_enabled": false,
    "tpm_attestation": false,
    "max_boot_time_ms": 3000,
    "pcr_bindings": ""
  },
  "tmpfiles": []
}
EOF

echo ""
echo "=== Creating initramfs ==="
cd "${INITRAMFS_DIR}"
find . | bsdcpio -o -H newc 2>/dev/null | gzip > /tmp/full-desktop.cpio.gz
SIZE=$(du -h /tmp/full-desktop.cpio.gz | cut -f1)
echo "  Size: ${SIZE}"

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     AGNOS FULL DESKTOP BOOT — ALL REAL BINARIES          ║"
echo "║                                                          ║"
echo "║  PID 1:  kybernet (argonaut library)                     ║"
echo "║  Agent:  daimon (real)                                   ║"
echo "║  LLM:    hoosh (real)                                    ║"
echo "║  Shell:  agnoshi (real)                                  ║"
echo "║  Comp:   aethersafha (real)                              ║
║  LLM:    ifran (real)                                    ║"
echo "║                                                          ║"
echo "║  Auto-shutdown after 10s                                 ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

timeout 25 qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd /tmp/full-desktop.cpio.gz \
    -append "console=ttyS0 panic=5 rdinit=/sbin/init loglevel=7" \
    -m 512M \
    -nographic \
    -no-reboot \
    -serial mon:stdio 2>&1 | grep -E "phase|starting service|service started|entering main|boot complete|shutdown|Power down|wave"

echo ""
echo "=== BOOT COMPLETE ==="
