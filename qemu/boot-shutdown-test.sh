#!/usr/bin/env bash
# boot-shutdown-test.sh — Test clean shutdown sequence.
#
# Starts a "shutdown-trigger" service that sends SIGTERM to PID 1
# after 5 seconds, triggering clean shutdown.

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

cp "$BINARY" "${INITRAMFS_DIR}/sbin/init"
strip "${INITRAMFS_DIR}/sbin/init" 2>/dev/null || true

BUSYBOX="/usr/lib/initcpio/busybox"
if [ -f "$BUSYBOX" ]; then
    cp "$BUSYBOX" "${INITRAMFS_DIR}/bin/busybox"
    chmod +x "${INITRAMFS_DIR}/bin/busybox"
    ln -sf busybox "${INITRAMFS_DIR}/bin/sh"
    ln -sf busybox "${INITRAMFS_DIR}/bin/sleep"
    ln -sf busybox "${INITRAMFS_DIR}/bin/kill"
    ln -sf /bin/sh "${INITRAMFS_DIR}/usr/bin/agnoshi"
    for lib in $(ldd "$BUSYBOX" 2>/dev/null | grep -oP '/\S+'); do
        [ -f "$lib" ] && mkdir -p "${INITRAMFS_DIR}$(dirname "$lib")" && cp "$lib" "${INITRAMFS_DIR}${lib}"
    done
    [ -f /lib64/ld-linux-x86-64.so.2 ] && mkdir -p "${INITRAMFS_DIR}/lib64" && cp /lib64/ld-linux-x86-64.so.2 "${INITRAMFS_DIR}/lib64/"
fi

# Service that triggers shutdown after 5 seconds
cat > "${INITRAMFS_DIR}/usr/bin/shutdown-trigger.sh" << 'SVCEOF'
#!/bin/sh
echo "shutdown-trigger: waiting 5s then sending SIGTERM to PID 1"
sleep 5
echo "shutdown-trigger: sending SIGTERM to PID 1"
kill -TERM 1
sleep 3600
SVCEOF
chmod +x "${INITRAMFS_DIR}/usr/bin/shutdown-trigger.sh"

cat > "${INITRAMFS_DIR}/usr/bin/long-service.sh" << 'SVCEOF'
#!/bin/sh
echo "long-service: starting (pid=$$)"
while true; do sleep 60; done
SVCEOF
chmod +x "${INITRAMFS_DIR}/usr/bin/long-service.sh"

cat > "${INITRAMFS_DIR}/etc/argonaut/config.json" << 'EOF'
{
  "boot_mode": "Minimal",
  "services": [
    {
      "name": "long-svc",
      "description": "Long-running service",
      "binary_path": "/bin/sh",
      "args": ["/usr/bin/long-service.sh"],
      "environment": {}, "depends_on": [],
      "required_for_modes": ["Minimal"],
      "restart_policy": "Never",
      "restart_config": { "max_restarts": 0, "base_delay_ms": 1000, "max_delay_ms": 5000 },
      "health_check": null, "ready_check": null,
      "enabled": true, "service_type": "Simple",
      "environment_files": [], "pid_file": null,
      "resource_limits": null, "log_config": null,
      "socket_activation": null, "seccomp": null, "landlock": null, "capabilities": null
    },
    {
      "name": "shutdown-trigger",
      "description": "Sends SIGTERM to PID 1 after 5s",
      "binary_path": "/bin/sh",
      "args": ["/usr/bin/shutdown-trigger.sh"],
      "environment": {}, "depends_on": [],
      "required_for_modes": ["Minimal"],
      "restart_policy": "Never",
      "restart_config": { "max_restarts": 0, "base_delay_ms": 1000, "max_delay_ms": 5000 },
      "health_check": null, "ready_check": null,
      "enabled": true, "service_type": "Simple",
      "environment_files": [], "pid_file": null,
      "resource_limits": null, "log_config": null,
      "socket_activation": null, "seccomp": null, "landlock": null, "capabilities": null
    }
  ],
  "boot_timeout_ms": 30000, "shutdown_timeout_ms": 10000,
  "log_to_console": true, "verify_on_boot": false,
  "edge_boot": { "readonly_rootfs": false, "luks_enabled": false, "tpm_attestation": false, "max_boot_time_ms": 3000, "pcr_bindings": "" },
  "tmpfiles": []
}
EOF

cd "${INITRAMFS_DIR}"
find . | bsdcpio -o -H newc 2>/dev/null | gzip > /tmp/shutdown-test.cpio.gz

echo ""
echo "=== SHUTDOWN TEST ==="
echo "  shutdown-trigger service sends SIGTERM to PID 1 after 5 seconds"
echo "  Watch for: service stop, shutdown sequence, sync, reboot/exit"
echo ""

timeout 20 qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd /tmp/shutdown-test.cpio.gz \
    -append "console=ttyS0 panic=5 rdinit=/sbin/init loglevel=7" \
    -m 256M \
    -nographic \
    -no-reboot \
    -serial mon:stdio 2>&1 | grep -E "service started|entering main|shutdown|stopping|sync|reboot|Rebooting" || true

echo ""
echo "=== TEST COMPLETE ==="
