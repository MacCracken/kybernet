#!/usr/bin/env bash
# build-initramfs.sh — stage a minimal initramfs with kybernet as
# /sbin/init for the QEMU PID-1 boot harness.
#
# Builds kybernet via `cyrius build` (1.1.0 removed scripts/build.sh —
# do not reintroduce a wrapper, the manifest pin is the contract).
# Bundles busybox if found so the boot-shutdown/boot-crash variants
# that use shell-init wrappers still work; the primary harness path
# (boot-test.sh with kybernet.harness=1) doesn't need busybox.
#
# Output: qemu/initramfs.cpio.gz + qemu/initramfs/ staging tree.
#
# Usage:
#   qemu/build-initramfs.sh             # default — kybernet binary
#   qemu/build-initramfs.sh BINARY      # override the init binary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INITRAMFS_DIR="${SCRIPT_DIR}/initramfs"
BINARY="${1:-${PROJECT_DIR}/build/kybernet}"

# Build kybernet if the binary is missing or older than the manifest.
if [ ! -f "$BINARY" ] || [ "${PROJECT_DIR}/cyrius.cyml" -nt "$BINARY" ]; then
    echo "Building kybernet (CYRIUS_DCE=1)..."
    (cd "$PROJECT_DIR" && CYRIUS_DCE=1 cyrius build src/main.cyr "$BINARY" >/dev/null)
fi

[ -f "$BINARY" ] || { echo "ERROR: $BINARY not found after build"; exit 1; }

echo "Staging initramfs at ${INITRAMFS_DIR}..."

rm -rf "${INITRAMFS_DIR}"
mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,dev,proc,sys,run,tmp,etc,usr/bin,var/log}

# Install kybernet as /sbin/init — kernel rdinit hands off here.
cp "$BINARY" "${INITRAMFS_DIR}/sbin/init"
chmod +x "${INITRAMFS_DIR}/sbin/init"

# Bundle busybox for the auxiliary boot-shutdown/boot-crash tests that
# use shell-init wrappers. Harness mode (kybernet.harness=1) doesn't
# need busybox — kybernet runs PID 1 directly and self-shuts.
BUSYBOX=""
for cand in /usr/lib/initcpio/busybox /usr/bin/busybox /bin/busybox; do
    if [ -x "$cand" ]; then BUSYBOX="$cand"; break; fi
done
if [ -n "$BUSYBOX" ]; then
    cp "$BUSYBOX" "${INITRAMFS_DIR}/bin/busybox"
    chmod +x "${INITRAMFS_DIR}/bin/busybox"
    for cmd in sh ls cat mount ps kill sleep echo dmesg true false awk cut grep printf; do
        ln -sf busybox "${INITRAMFS_DIR}/bin/${cmd}"
    done
    # agnoshi alias for kybernet's emergency-shell drop path.
    ln -sf /bin/sh "${INITRAMFS_DIR}/usr/bin/agnoshi"
    echo "  bundled busybox from $BUSYBOX"

    # Arch ships busybox dynamically linked. If detected, copy
    # /lib64/ld-linux + the libc family into the initramfs so
    # shell-init wrappers can exec it. argonaut hit this same
    # wall at 1.6.2 and ships the same workaround — pattern lifted.
    if file "$BUSYBOX" 2>/dev/null | grep -q "dynamically linked"; then
        for lib in $(ldd "$BUSYBOX" 2>/dev/null | awk '/=>/ {print $3} /^\s*\//{print $1}'); do
            [ -n "$lib" ] || continue
            [ -f "$lib" ] || continue
            tgt_dir="${INITRAMFS_DIR}$(dirname "$lib")"
            mkdir -p "$tgt_dir"
            cp "$lib" "$tgt_dir/"
        done
        echo "  bundled dynamic-loader + libc (busybox is dynamically linked)"
    fi
else
    echo "  WARNING: busybox not found — boot-shutdown/boot-crash tests unavailable (harness mode unaffected)"
fi

# Minimal /etc/hosts so any resolver lookups during boot don't fail
# on missing localhost.
cat > "${INITRAMFS_DIR}/etc/hosts" << 'EOF'
127.0.0.1 localhost
::1       localhost
EOF

# Device nodes. kybernet mounts devtmpfs as phase-1, but the kernel
# needs /dev/console before that to route serial output; pre-create
# the minimum set. mknod requires CAP_MKNOD; skip silently otherwise.
sudo mknod "${INITRAMFS_DIR}/dev/console" c 5 1 2>/dev/null || true
sudo mknod "${INITRAMFS_DIR}/dev/null"    c 1 3 2>/dev/null || true
sudo mknod "${INITRAMFS_DIR}/dev/ttyS0"   c 4 64 2>/dev/null || true
sudo mknod "${INITRAMFS_DIR}/dev/kmsg"    c 1 11 2>/dev/null || true
sudo chmod 666 "${INITRAMFS_DIR}/dev/console" "${INITRAMFS_DIR}/dev/null" "${INITRAMFS_DIR}/dev/ttyS0" "${INITRAMFS_DIR}/dev/kmsg" 2>/dev/null || true

cd "${INITRAMFS_DIR}"
# Prefer bsdcpio (libarchive) where present; fall back to GNU cpio so the
# harness builds on stock CI runners that ship only `cpio`. Both emit the
# `newc` format the kernel's initramfs loader expects.
if command -v bsdcpio >/dev/null 2>&1; then
    find . | bsdcpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs.cpio.gz"
else
    find . | cpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs.cpio.gz"
fi

INIT_SIZE=$(wc -c < "${INITRAMFS_DIR}/sbin/init")
TOTAL_SIZE=$(du -h "${SCRIPT_DIR}/initramfs.cpio.gz" | cut -f1)
echo "Done: ${SCRIPT_DIR}/initramfs.cpio.gz (${TOTAL_SIZE}, init=${INIT_SIZE}B)"
