#!/usr/bin/env bash
# build-initramfs.sh — Build test initramfs for QEMU boot testing.
#
# Uses the Cyrius kybernet binary (build/kybernet) as /sbin/init.
# No argonaut dependency — kybernet runs standalone.
#
# Usage: ./qemu/build-initramfs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INITRAMFS_DIR="${SCRIPT_DIR}/initramfs"
BINARY="${PROJECT_DIR}/build/kybernet"

# Build if needed
if [ ! -f "$BINARY" ]; then
    echo "Building kybernet..."
    sh "${PROJECT_DIR}/scripts/build.sh"
fi

echo "Creating initramfs..."

# Clean and recreate
rm -rf "${INITRAMFS_DIR}"
mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,dev,proc,sys,run,tmp,usr/bin}

# Install kybernet as /sbin/init
cp "$BINARY" "${INITRAMFS_DIR}/sbin/init"
chmod +x "${INITRAMFS_DIR}/sbin/init"

# Install busybox for test services and emergency shell
BUSYBOX="/usr/lib/initcpio/busybox"
if [ -f "$BUSYBOX" ]; then
    cp "$BUSYBOX" "${INITRAMFS_DIR}/bin/busybox"
    chmod +x "${INITRAMFS_DIR}/bin/busybox"
    for cmd in sh ls cat mount ps kill sleep echo dmesg; do
        ln -sf busybox "${INITRAMFS_DIR}/bin/${cmd}"
    done
    ln -sf /bin/sh "${INITRAMFS_DIR}/usr/bin/agnoshi"
    echo "  Included busybox for test services"
else
    echo "  WARNING: busybox not found at $BUSYBOX"
fi

# Create essential device nodes
sudo mknod "${INITRAMFS_DIR}/dev/console" c 5 1 2>/dev/null || true
sudo mknod "${INITRAMFS_DIR}/dev/null" c 1 3 2>/dev/null || true
sudo mknod "${INITRAMFS_DIR}/dev/ttyS0" c 4 64 2>/dev/null || true
sudo chmod 666 "${INITRAMFS_DIR}/dev/console" "${INITRAMFS_DIR}/dev/null" "${INITRAMFS_DIR}/dev/ttyS0" 2>/dev/null || true

# Create initramfs cpio
cd "${INITRAMFS_DIR}"
find . | bsdcpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs.cpio.gz"

INIT_SIZE=$(wc -c < "${INITRAMFS_DIR}/sbin/init")
TOTAL_SIZE=$(du -h "${SCRIPT_DIR}/initramfs.cpio.gz" | cut -f1)
echo "Done: ${SCRIPT_DIR}/initramfs.cpio.gz (${TOTAL_SIZE}, init=${INIT_SIZE}B)"
