#!/usr/bin/env bash
# build-initramfs.sh — Build the test initramfs for QEMU boot testing.
#
# Requires: cargo build --release --target x86_64-unknown-linux-musl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INITRAMFS_DIR="${SCRIPT_DIR}/initramfs"
BINARY="${PROJECT_DIR}/target/x86_64-unknown-linux-musl/release/kybernet"

if [ ! -f "$BINARY" ]; then
    echo "Building kybernet (musl static)..."
    cargo build --release --target x86_64-unknown-linux-musl --manifest-path "${PROJECT_DIR}/Cargo.toml"
fi

echo "Creating initramfs..."

# Clean and recreate
rm -rf "${INITRAMFS_DIR}"
mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc/argonaut,dev,proc,sys,run,tmp,var/log/agnos/services,usr/bin,usr/lib,lib64}

# Install kybernet as /sbin/init
cp "$BINARY" "${INITRAMFS_DIR}/sbin/init"
strip "${INITRAMFS_DIR}/sbin/init" 2>/dev/null || true
chmod +x "${INITRAMFS_DIR}/sbin/init"

# Install busybox + required libs for emergency shell
BUSYBOX="/usr/lib/initcpio/busybox"
if [ -f "$BUSYBOX" ]; then
    cp "$BUSYBOX" "${INITRAMFS_DIR}/bin/busybox"
    chmod +x "${INITRAMFS_DIR}/bin/busybox"
    # Create shell symlinks
    ln -sf busybox "${INITRAMFS_DIR}/bin/sh"
    ln -sf busybox "${INITRAMFS_DIR}/bin/ls"
    ln -sf busybox "${INITRAMFS_DIR}/bin/cat"
    ln -sf busybox "${INITRAMFS_DIR}/bin/mount"
    ln -sf busybox "${INITRAMFS_DIR}/bin/ps"
    ln -sf busybox "${INITRAMFS_DIR}/bin/kill"
    ln -sf busybox "${INITRAMFS_DIR}/bin/sleep"
    ln -sf busybox "${INITRAMFS_DIR}/bin/echo"
    ln -sf busybox "${INITRAMFS_DIR}/bin/dmesg"
    # Symlink agnoshi -> busybox sh (kybernet looks for /usr/bin/agnoshi)
    ln -sf /bin/sh "${INITRAMFS_DIR}/usr/bin/agnoshi"

    # Copy required shared libraries
    for lib in $(ldd "$BUSYBOX" 2>/dev/null | grep -oP '/\S+'); do
        if [ -f "$lib" ]; then
            dir="${INITRAMFS_DIR}$(dirname "$lib")"
            mkdir -p "$dir"
            cp "$lib" "${INITRAMFS_DIR}${lib}"
        fi
    done
    # Dynamic linker
    if [ -f /lib64/ld-linux-x86-64.so.2 ]; then
        mkdir -p "${INITRAMFS_DIR}/lib64"
        cp /lib64/ld-linux-x86-64.so.2 "${INITRAMFS_DIR}/lib64/"
    fi
    echo "  Included busybox + libs for emergency shell"
else
    echo "  WARNING: busybox not found, no emergency shell available"
fi

# Create essential device nodes (required before devtmpfs mount)
sudo mknod "${INITRAMFS_DIR}/dev/console" c 5 1 2>/dev/null || true
sudo mknod "${INITRAMFS_DIR}/dev/null" c 1 3 2>/dev/null || true
sudo mknod "${INITRAMFS_DIR}/dev/ttyS0" c 4 64 2>/dev/null || true
sudo chmod 666 "${INITRAMFS_DIR}/dev/console" "${INITRAMFS_DIR}/dev/null" "${INITRAMFS_DIR}/dev/ttyS0" 2>/dev/null || true

# Minimal config
cat > "${INITRAMFS_DIR}/etc/argonaut/config.json" <<'EOF'
{
  "boot_mode": "Minimal",
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

# Create initramfs cpio
cd "${INITRAMFS_DIR}"
find . | bsdcpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs.cpio.gz"

SIZE=$(du -h "${SCRIPT_DIR}/initramfs.cpio.gz" | cut -f1)
echo "Done: ${SCRIPT_DIR}/initramfs.cpio.gz (${SIZE})"
