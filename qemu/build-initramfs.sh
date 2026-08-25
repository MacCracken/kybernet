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
# kyb-limited is the 1.5.5 proof, and it proves three things at once that
# the pre-1.5.5 tree could not have produced:
#   1. cgroup.subtree_control is enabled, so memory.max EXISTS at all.
#      Before 1.5.5 a service cgroup held only the core cgroup.* files and
#      every limit write would have returned ENOENT.
#   2. The values kybernet wrote are the values the KERNEL accepted —
#      read back from inside the service, not trusted from a kybernet log.
#   3. The service is in its cgroup BEFORE it runs. It is a ONESHOT
#      deliberately: argonaut waits for a oneshot inside init_start_service
#      and returns 0, so under the old post-start create->move there was no
#      surviving pid and a oneshot never got a cgroup at all. Its
#      /proc/self/cgroup resolving to kybernet.slice/kyb-limited is only
#      possible because the child joins itself in kyb_pre_exec.
# It also prints kyb-live's memory.max as a control: kyb-live carries no
# limits block, so that must read "max" while kyb-limited reads 67108864 —
# which distinguishes "kybernet wrote the value" from "the file happens to
# contain a default".
#
# kyb-live is the 1.5.3 proof: at shutdown the sweep must kill and rmdir
# every service cgroup, which boot-test.sh asserts via the "removed service
# cgroups:" marker. Before 1.5.3 create_service_cgroup and move_to_cgroup
# were the only cgroup calls with production call sites, so the directories
# just accumulated.
#
# NOTE the count changed at 1.5.5. It used to be 2 — only the services that
# stayed RUNNING got a cgroup, because creation happened after
# init_start_service returned a live pid and a completed oneshot had no
# surviving process to move. Now the cgroup is created BEFORE the fork and
# the child joins itself, so every service gets one and the sweep removes
# all 6.
#
# kyb-live doubles as the 1.5.5 control case: it carries no limits block, so
# its memory.max must read "max" while kyb-limited's reads 67108864.
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
      "name": "kyb-limited",
      "description": "reports its own cgroup limits to the console",
      "binary": "/bin/sh",
      "args": ["-c", "C=$(cut -d: -f3 /proc/self/cgroup); D=/sys/fs/cgroup$C; { echo LIMIT-cgroup=$C; echo LIMIT-memmax=$(cat $D/memory.max 2>&1); echo LIMIT-pidsmax=$(cat $D/pids.max 2>&1); echo LIMIT-cpuweight=$(cat $D/cpu.weight 2>&1); echo LIMIT-memhigh=$(cat $D/memory.high 2>&1); echo LIMIT-ctrl=$(cat /sys/fs/cgroup/kybernet.slice/cgroup.subtree_control 2>&1); echo LIMIT-unlimited=$(cat /sys/fs/cgroup/kybernet.slice/kyb-live/memory.max 2>&1); } > /dev/console 2>&1"],
      "type": "oneshot",
      "restart": "never",
      "limits": {
        "memory_max": 67108864,
        "memory_high": 50331648,
        "cpu_weight": 250,
        "pids_max": 32
      }
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

# ============================================================
# Edge-boot fixture (1.5.7) — a second initramfs for the edge pass.
#
# Built ONLY when veritysetup is available, and its absence is a SKIP, never
# a pass: boot-test.sh keys the edge pass on this file existing.
#
# Why a second image rather than a mode flag: edge boot only runs when
# boot_mode == BOOT_EDGE, and the main harness config is `recovery`. Baking
# a separate config keeps the 1.5.0-1.5.6 gates byte-for-byte unchanged.
#
# What this can and cannot prove. `veritysetup verify` walks the hash tree
# in PURE USERSPACE — no device-mapper, no kernel module, no /dev/mapper —
# so it runs in an initramfs where dm is a module nothing can load. That is
# the whole reason kybernet verifies with `verify` rather than `open`.
# It CANNOT prove `veritysetup open` or a LUKS unlock; those need a real dm
# stack and belong on hardware (roadmap v1.2.2).
#
# Verified unprivileged on the host before this was written: format emits a
# root hash, and verify returns 0 on a good pair, 1 on a wrong root hash,
# and 2 on corrupted data.
EDGE_DIR="${SCRIPT_DIR}/edge"
if command -v veritysetup >/dev/null 2>&1; then
    rm -rf "$EDGE_DIR"; mkdir -p "$EDGE_DIR"
    dd if=/dev/urandom of="${EDGE_DIR}/data.img" bs=1M count=4 status=none
    truncate -s 2M "${EDGE_DIR}/hash.img"
    EDGE_ROOT_HASH=$(veritysetup format "${EDGE_DIR}/data.img" "${EDGE_DIR}/hash.img" 2>/dev/null \
        | awk '/Root hash/{print $3}')

    if [ -n "$EDGE_ROOT_HASH" ] && [ ${#EDGE_ROOT_HASH} -eq 64 ]; then
        # Stage veritysetup and its whole shared-library closure. Same
        # approach the busybox block above uses for a dynamically linked
        # binary, just with more libraries.
        EDGE_STAGE="${SCRIPT_DIR}/initramfs-edge"
        rm -rf "$EDGE_STAGE"
        cp -a "${INITRAMFS_DIR}" "$EDGE_STAGE"
        mkdir -p "${EDGE_STAGE}/usr/bin" "${EDGE_STAGE}/usr/lib" "${EDGE_STAGE}/lib64"
        VS=$(command -v veritysetup)
        cp "$VS" "${EDGE_STAGE}/usr/bin/veritysetup"
        for lib in $(ldd "$VS" 2>/dev/null | awk '{print $3}' | grep '^/'); do
            cp -L "$lib" "${EDGE_STAGE}/usr/lib/" 2>/dev/null || true
        done
        LOADER=$(ldd "$VS" 2>/dev/null | awk '/ld-linux/{print $1}')
        if [ -n "$LOADER" ] && [ -f "$LOADER" ]; then
            mkdir -p "${EDGE_STAGE}$(dirname "$LOADER")"
            cp -L "$LOADER" "${EDGE_STAGE}${LOADER}" 2>/dev/null || true
        fi

        # boot_mode edge + a real device-backed dm-verity triple. The images
        # are attached as virtio disks by boot-test.sh; CONFIG_VIRTIO_BLK is
        # builtin on the harness kernel, so /dev/vda and /dev/vdb appear
        # with no modules, no udev and no losetup.
        cat > "${EDGE_STAGE}/etc/kybernet/config.json" << EDGECFG
{
  "boot_mode": "edge",
  "verify_boot": true,
  "shutdown_timeout_ms": 400,
  "edge": {
    "readonly_rootfs": true,
    "tpm_attestation": false,
    "luks_enabled": false,
    "max_boot_ms": 20000,
    "root_device": "/dev/vda",
    "hash_device": "/dev/vdb",
    "root_hash": "${EDGE_ROOT_HASH}"
  },
  "services": []
}
EDGECFG
        echo "$EDGE_ROOT_HASH" > "${EDGE_DIR}/root_hash.txt"

        ( cd "$EDGE_STAGE"
          if command -v bsdcpio >/dev/null 2>&1; then
              find . | bsdcpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs-edge.cpio.gz"
          else
              find . | cpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs-edge.cpio.gz"
          fi )
        echo "  staged edge fixture (root_hash=${EDGE_ROOT_HASH:0:16}...)"
    else
        echo "  WARNING: veritysetup format produced no root hash — edge pass will SKIP"
        rm -f "${SCRIPT_DIR}/initramfs-edge.cpio.gz"
    fi
else
    echo "  veritysetup not found — edge pass will SKIP (not a failure)"
    rm -f "${SCRIPT_DIR}/initramfs-edge.cpio.gz"
fi

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
