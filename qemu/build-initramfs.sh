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

# Stage a real kybernet config with real services (1.5.0).
#
# This is what makes the harness prove the v1.5.0 property end to end:
# before 1.5.0 `load_config` never parsed the services array, so
# config_services() was always empty, resolve_service_waves short-circuited
# and start_services()'s wave-loop body had never once executed in a real
# boot. With this file present the harness boots, parses two services out
# of JSON, resolves them into dependency waves, and actually forks+execs
# them as PID 1 — and boot-test.sh asserts on the per-service markers.
#
# Both services are /bin/true oneshots so they start, exit 0 immediately,
# and get reaped through the normal SIGCHLD path. kyb-dep is a dependency
# of kyb-svc, so a correct wave resolution must start kyb-dep first.
#
# kyb-confined is the 1.5.2 proof. It carries a real security policy —
# drop every capability, set no_new_privs — and then reports its OWN
# /proc/self/status to the console, so the harness can assert the policy
# actually took effect in the child rather than trusting that kyb_pre_exec
# was called. It writes to /dev/console explicitly because argonaut
# redirects a service's stdout/stderr to /dev/null.
#
# This is also the privileged validation of drop_cap_sets() that the unit
# suite cannot do: under QEMU kybernet is genuinely PID 1 running as root,
# so capset(2) really executes instead of short-circuiting on the euid
# check.
#
# kyb-crash is the 1.5.4 proof. /bin/false exits 1 immediately, so argonaut
# raises a CRASH_RESTART with an exponential backoff and kybernet ENQUEUES it
# rather than relaunching inline; the reactor's 1 s restart tick performs the
# relaunch once the delay elapses. Only observable under
# `kybernet.harness=loop`, since the boot-only pass shuts down before the
# reactor starts. Pre-1.5.4 the backoff was passed as a stop timeout and
# discarded, so a crash-looping service was relaunched as fast as it could
# die until max_restarts tripped.
#
# kyb-live is the 1.5.3 proof. It is the only service here that stays
# RUNNING, so it is the only one that gets a cgroup at all: start_services
# creates and populates a cgroup for a live pid, while a completed oneshot
# correctly gets none. At shutdown the sweep must kill and rmdir it, which
# boot-test.sh asserts via the "removed service cgroups:" marker. Before
# 1.5.3 create_service_cgroup and move_to_cgroup were the only cgroup calls
# with production call sites, so the directory just accumulated.
#
# shutdown_timeout_ms is deliberately short. Now that services actually
# run, shutdown really does SIGTERM them and poll in 50 ms steps up to the
# timeout — the mode defaults include a long-lived shell (agnoshi -> busybox
# sh) that does not exit instantly. The pre-1.5.0 boot started nothing, so
# the 3000 ms budget was calibrated against a shutdown with no work to do.
# 400 ms keeps the graceful-stop path exercised without spending the budget
# waiting for it.
if [ -n "$BUSYBOX" ]; then
    mkdir -p "${INITRAMFS_DIR}/etc/kybernet"
    cat > "${INITRAMFS_DIR}/etc/kybernet/config.json" << 'CFGEOF'
{
  "boot_mode": "recovery",
  "log_to_console": true,
  "shutdown_timeout_ms": 400,
  "services": [
    {
      "name": "kyb-svc",
      "description": "harness service",
      "binary": "/bin/true",
      "type": "oneshot",
      "restart": "never",
      "depends_on": ["kyb-dep"]
    },
    {
      "name": "kyb-dep",
      "description": "harness dependency",
      "binary": "/bin/true",
      "type": "oneshot",
      "restart": "never"
    },
    {
      "name": "kyb-live",
      "description": "long-lived service: exercises cgroup create/move/teardown",
      "binary": "/bin/sleep",
      "args": ["30"],
      "type": "simple",
      "restart": "never"
    },
    {
      "name": "kyb-crash",
      "description": "always fails: exercises the deferred-restart queue",
      "binary": "/bin/false",
      "type": "simple",
      "restart": "on-failure"
    },
    {
      "name": "kyb-confined",
      "description": "reports its own confinement to the console",
      "binary": "/bin/sh",
      "args": ["-c", "grep -E '^(CapEff|NoNewPrivs)' /proc/self/status > /dev/console 2>&1"],
      "type": "oneshot",
      "restart": "never",
      "security": {
        "no_new_privs": true,
        "capabilities": []
      }
    }
  ]
}
CFGEOF
    echo "  staged /etc/kybernet/config.json (2 services, 1.5.0 harness)"
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
