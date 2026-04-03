#!/usr/bin/env bash
# boot-desktop-test.sh — Desktop boot with real daimon + dummy services.
#
# Tests wave-based parallel startup with multiple services.
# Target: < 3s from init start to boot complete.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KERNEL="${1:-/boot/vmlinuz-linux-lts}"
KYBERNET="${PROJECT_DIR}/target/x86_64-unknown-linux-musl/release/kybernet"
DAIMON="/home/macro/Repos/daimon/target/x86_64-unknown-linux-musl/release/daimon"

echo "Building kybernet..."
cargo build --release --target x86_64-unknown-linux-musl --manifest-path "${PROJECT_DIR}/Cargo.toml" 2>&1 | tail -1

INITRAMFS_DIR=$(mktemp -d)
trap "rm -rf $INITRAMFS_DIR" EXIT

mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc/argonaut,dev,proc,sys,run,tmp,var/log/agnos/services,usr/bin,usr/lib/agnos,lib64}

# Install kybernet
cp "$KYBERNET" "${INITRAMFS_DIR}/sbin/init"
strip "${INITRAMFS_DIR}/sbin/init" 2>/dev/null || true

# Install real daimon
if [ -f "$DAIMON" ]; then
    cp "$DAIMON" "${INITRAMFS_DIR}/usr/lib/agnos/agent_runtime"
    strip "${INITRAMFS_DIR}/usr/lib/agnos/agent_runtime" 2>/dev/null || true
    echo "  Included real daimon binary"
fi

# Busybox for shell + dummy services
BUSYBOX="/usr/lib/initcpio/busybox"
if [ -f "$BUSYBOX" ]; then
    cp "$BUSYBOX" "${INITRAMFS_DIR}/bin/busybox"
    chmod +x "${INITRAMFS_DIR}/bin/busybox"
    for cmd in sh sleep echo kill cat; do
        ln -sf busybox "${INITRAMFS_DIR}/bin/$cmd"
    done
    ln -sf /bin/sh "${INITRAMFS_DIR}/usr/bin/agnoshi"
    for lib in $(ldd "$BUSYBOX" 2>/dev/null | grep -oP '/\S+'); do
        [ -f "$lib" ] && mkdir -p "${INITRAMFS_DIR}$(dirname "$lib")" && cp "$lib" "${INITRAMFS_DIR}${lib}"
    done
    [ -f /lib64/ld-linux-x86-64.so.2 ] && mkdir -p "${INITRAMFS_DIR}/lib64" && cp /lib64/ld-linux-x86-64.so.2 "${INITRAMFS_DIR}/lib64/"
fi

# Dummy service scripts for services that don't have static builds
for svc in postgres redis llm-gateway aethersafha synapse; do
    cat > "${INITRAMFS_DIR}/usr/bin/${svc}-dummy.sh" << SVCEOF
#!/bin/sh
echo "${svc}: starting (pid=\$\$)"
while true; do sleep 3600; done
SVCEOF
    chmod +x "${INITRAMFS_DIR}/usr/bin/${svc}-dummy.sh"
done

# Shutdown trigger after 10s
cat > "${INITRAMFS_DIR}/usr/bin/shutdown-after.sh" << 'SVCEOF'
#!/bin/sh
sleep 10
kill -TERM 1
SVCEOF
chmod +x "${INITRAMFS_DIR}/usr/bin/shutdown-after.sh"

# Desktop config with full service stack
cat > "${INITRAMFS_DIR}/etc/argonaut/config.json" << 'EOF'
{
  "boot_mode": "Desktop",
  "services": [
    {
      "name": "postgres",
      "description": "PostgreSQL (dummy)",
      "binary_path": "/bin/sh",
      "args": ["/usr/bin/postgres-dummy.sh"],
      "environment": {},
      "depends_on": [],
      "required_for_modes": ["Desktop"],
      "restart_policy": "OnFailure",
      "restart_config": { "max_restarts": 3, "base_delay_ms": 1000, "max_delay_ms": 5000 },
      "health_check": null, "ready_check": null,
      "enabled": true, "service_type": "Simple",
      "environment_files": [], "pid_file": null,
      "resource_limits": null, "log_config": null,
      "socket_activation": null, "seccomp": null, "landlock": null, "capabilities": null
    },
    {
      "name": "redis",
      "description": "Redis (dummy)",
      "binary_path": "/bin/sh",
      "args": ["/usr/bin/redis-dummy.sh"],
      "environment": {},
      "depends_on": [],
      "required_for_modes": ["Desktop"],
      "restart_policy": "OnFailure",
      "restart_config": { "max_restarts": 3, "base_delay_ms": 1000, "max_delay_ms": 5000 },
      "health_check": null, "ready_check": null,
      "enabled": true, "service_type": "Simple",
      "environment_files": [], "pid_file": null,
      "resource_limits": null, "log_config": null,
      "socket_activation": null, "seccomp": null, "landlock": null, "capabilities": null
    },
    {
      "name": "daimon",
      "description": "Daimon agent orchestrator",
      "binary_path": "/usr/lib/agnos/agent_runtime",
      "args": ["--port", "8090"],
      "environment": {},
      "depends_on": ["postgres", "redis"],
      "required_for_modes": ["Desktop"],
      "restart_policy": "Always",
      "restart_config": { "max_restarts": 5, "base_delay_ms": 1000, "max_delay_ms": 10000 },
      "health_check": null, "ready_check": null,
      "enabled": true, "service_type": "Simple",
      "environment_files": [], "pid_file": null,
      "resource_limits": null, "log_config": null,
      "socket_activation": null, "seccomp": null, "landlock": null, "capabilities": null
    },
    {
      "name": "llm-gateway",
      "description": "Hoosh LLM gateway (dummy)",
      "binary_path": "/bin/sh",
      "args": ["/usr/bin/llm-gateway-dummy.sh"],
      "environment": {},
      "depends_on": ["daimon"],
      "required_for_modes": ["Desktop"],
      "restart_policy": "OnFailure",
      "restart_config": { "max_restarts": 3, "base_delay_ms": 1000, "max_delay_ms": 5000 },
      "health_check": null, "ready_check": null,
      "enabled": true, "service_type": "Simple",
      "environment_files": [], "pid_file": null,
      "resource_limits": null, "log_config": null,
      "socket_activation": null, "seccomp": null, "landlock": null, "capabilities": null
    },
    {
      "name": "aethersafha",
      "description": "Compositor (dummy)",
      "binary_path": "/bin/sh",
      "args": ["/usr/bin/aethersafha-dummy.sh"],
      "environment": {},
      "depends_on": ["daimon"],
      "required_for_modes": ["Desktop"],
      "restart_policy": "Always",
      "restart_config": { "max_restarts": 3, "base_delay_ms": 1000, "max_delay_ms": 5000 },
      "health_check": null, "ready_check": null,
      "enabled": true, "service_type": "Simple",
      "environment_files": [], "pid_file": null,
      "resource_limits": null, "log_config": null,
      "socket_activation": null, "seccomp": null, "landlock": null, "capabilities": null
    },
    {
      "name": "shutdown-trigger",
      "description": "Auto-shutdown after 10s",
      "binary_path": "/bin/sh",
      "args": ["/usr/bin/shutdown-after.sh"],
      "environment": {},
      "depends_on": [],
      "required_for_modes": ["Desktop"],
      "restart_policy": "Never",
      "restart_config": { "max_restarts": 0, "base_delay_ms": 1000, "max_delay_ms": 5000 },
      "health_check": null, "ready_check": null,
      "enabled": true, "service_type": "Simple",
      "environment_files": [], "pid_file": null,
      "resource_limits": null, "log_config": null,
      "socket_activation": null, "seccomp": null, "landlock": null, "capabilities": null
    }
  ],
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

cd "${INITRAMFS_DIR}"
find . | bsdcpio -o -H newc 2>/dev/null | gzip > /tmp/desktop-test.cpio.gz
SIZE=$(du -h /tmp/desktop-test.cpio.gz | cut -f1)

echo ""
echo "=== DESKTOP BOOT TEST ($SIZE initramfs) ==="
echo "  Services: postgres, redis → daimon (real) → llm-gateway, aethersafha"
echo "  Wave startup, auto-shutdown after 10s"
echo ""

timeout 25 qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd /tmp/desktop-test.cpio.gz \
    -append "console=ttyS0 panic=5 rdinit=/sbin/init loglevel=7" \
    -m 512M \
    -nographic \
    -no-reboot \
    -serial mon:stdio 2>&1 | grep -E "starting service|service started|entering main|boot complete|wave|shutdown|Power down|phase" || true

echo ""
echo "=== TEST COMPLETE ==="
