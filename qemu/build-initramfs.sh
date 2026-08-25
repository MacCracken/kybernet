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

# ⚠ BOTH AUTH FIXTURES ARE BUILT INSIDE THE EDGE BLOCK, so any path that
# abandons the edge staging must drop them too. It used to drop only
# initramfs-edge.cpio.gz — so losing veritysetup between runs left the two auth
# cpios behind carrying the PREVIOUS run's /sbin/init, and boot-test.sh keys
# those gates on file existence alone. The auth passes would then report OK for
# a binary that is not the one being cut, which is the worst kind of green.
_drop_stale_fixtures() {
    rm -f "${SCRIPT_DIR}/initramfs-edge.cpio.gz" \
          "${SCRIPT_DIR}/initramfs-auth.cpio.gz" \
          "${SCRIPT_DIR}/initramfs-auth-kdf.cpio.gz"
    echo "  dropped stale edge/auth fixtures (${1:-reason unstated}) — those passes will SKIP"
}


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
# kyb-seccomp is the 1.6.0 proof, and it is the fixture whose absence let a
# fatal defect ship for three releases. `"seccomp": "basic"` did not merely
# fail to confine — it KILLED every service it was applied to, because the
# 37-syscall allowlist had no `execve` and the filter's default action was
# SECCOMP_RET_KILL_PROCESS. seccomp_apply's only production call site is
# kyb_pre_exec, and argonaut execs on the very next line, so the service died
# with SIGSYS before running one instruction. No harness service had ever set
# the key, so `seccomp_apply` had never executed in a release gate on either
# arch.
#
# This service reports its OWN /proc/self/status Seccomp fields to the
# console, so the gate asserts the filter was really loaded IN THE CHILD
# (Seccomp: 2 = filter mode, Seccomp_filters: 1) rather than trusting that
# kyb_pre_exec was reached — the same shape as kyb-confined above. That it
# produces output at all is the other half: it proves the profile no longer
# kills what it confines.
#
# It works without any fork because `sh -c '<simple command>'` execs the
# command directly. Process creation is deliberately NOT on the basic
# allowlist, so a fixture with two commands or a pipeline would be denied.
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
    },
    {
      "name": "kyb-seccomp",
      "description": "reports its own seccomp state from under the basic profile",
      "binary": "/bin/sh",
      "args": ["-c", "grep -E '^(Seccomp|Seccomp_filters)' /proc/self/status > /dev/console 2>&1"],
      "type": "oneshot",
      "restart": "never",
      "security": {
        "seccomp": "basic",
        "no_new_privs": true
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
    # 1 MiB, not 4: CI runners have no KVM, so the edge passes run under
    # TCG where every hashed block is emulated. 1 MiB is still a real
    # Merkle tree over 256 blocks — the round trip is genuine, just cheap.
    dd if=/dev/urandom of="${EDGE_DIR}/data.img" bs=1M count=1 status=none
    truncate -s 1M "${EDGE_DIR}/hash.img"
    EDGE_ROOT_HASH=$(veritysetup format "${EDGE_DIR}/data.img" "${EDGE_DIR}/hash.img" 2>/dev/null \
        | awk '/Root hash/{print $3}')

    if [ -n "$EDGE_ROOT_HASH" ] && [ ${#EDGE_ROOT_HASH} -eq 64 ]; then
        # Stage veritysetup and its whole shared-library closure. Same
        # approach the busybox block above uses for a dynamically linked
        # binary, just with more libraries.
        EDGE_STAGE="${SCRIPT_DIR}/initramfs-edge"
        rm -rf "$EDGE_STAGE"
        mkdir -p "$EDGE_STAGE"
        # Copy everything EXCEPT ./dev. The device nodes were created by the
        # `sudo mknod` block above, and recreating them needs CAP_MKNOD —
        # `cp -a` of a character device fails with EPERM for an unprivileged
        # user, which under `set -e` killed the whole build on CI. They are
        # re-made below with the same best-effort pattern the main tree uses.
        tar -cf - -C "${INITRAMFS_DIR}" --exclude=./dev . | tar -xf - -C "$EDGE_STAGE"
        mkdir -p "${EDGE_STAGE}/dev" "${EDGE_STAGE}/usr/bin" "${EDGE_STAGE}/usr/lib" "${EDGE_STAGE}/lib64"
        sudo mknod "${EDGE_STAGE}/dev/console" c 5 1 2>/dev/null || true
        sudo mknod "${EDGE_STAGE}/dev/null"    c 1 3 2>/dev/null || true
        sudo mknod "${EDGE_STAGE}/dev/ttyS0"   c 4 64 2>/dev/null || true
        sudo mknod "${EDGE_STAGE}/dev/kmsg"    c 1 11 2>/dev/null || true
        sudo chmod 666 "${EDGE_STAGE}/dev/console" "${EDGE_STAGE}/dev/null" \
            "${EDGE_STAGE}/dev/ttyS0" "${EDGE_STAGE}/dev/kmsg" 2>/dev/null || true
        VS=$(command -v veritysetup)
        cp "$VS" "${EDGE_STAGE}/usr/bin/veritysetup"
        # Stage every shared object at its ORIGINAL absolute path, not into
        # a single /usr/lib. There is no ld.so.cache in the initramfs, so the
        # loader falls back to its compiled-in defaults — which on a
        # multiarch distro (Ubuntu, as CI runs) are
        # /lib/x86_64-linux-gnu and /usr/lib/x86_64-linux-gnu, NOT /usr/lib.
        # Flattening them worked on Arch and would have silently produced an
        # unrunnable veritysetup on the runner.
        for lib in $(ldd "$VS" 2>/dev/null | awk '{print $3}' | grep '^/'); do
            mkdir -p "${EDGE_STAGE}$(dirname "$lib")"
            cp -L "$lib" "${EDGE_STAGE}${lib}" 2>/dev/null || true
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

        # Emergency-auth fixture (1.5.8) — the same tree with a password
        # configured. Built as its own cpio so the edge gate above keeps
        # asserting the NO-password refusal path unchanged.
        #
        # Reuses the edge tree because an edge refusal is the cheapest way to
        # reach drop_to_emergency, and 1.5.7 forces require_auth there when a
        # hash is present. The password is sha256("hunter2") — the legacy
        # unsalted digest format the gate accepts today.
        AUTH_STAGE="${SCRIPT_DIR}/initramfs-auth"
        rm -rf "$AUTH_STAGE"
        mkdir -p "$AUTH_STAGE"
        tar -cf - -C "$EDGE_STAGE" --exclude=./dev . | tar -xf - -C "$AUTH_STAGE"
        mkdir -p "${AUTH_STAGE}/dev"
        sudo mknod "${AUTH_STAGE}/dev/console" c 5 1 2>/dev/null || true
        sudo mknod "${AUTH_STAGE}/dev/null"    c 1 3 2>/dev/null || true
        sudo mknod "${AUTH_STAGE}/dev/ttyS0"   c 4 64 2>/dev/null || true
        sudo mknod "${AUTH_STAGE}/dev/kmsg"    c 1 11 2>/dev/null || true
        sudo chmod 666 "${AUTH_STAGE}/dev/console" "${AUTH_STAGE}/dev/null" \
            "${AUTH_STAGE}/dev/ttyS0" "${AUTH_STAGE}/dev/kmsg" 2>/dev/null || true

        AUTH_HASH=$(printf 'hunter2' | sha256sum | awk '{print $1}')
        python3 - "$AUTH_STAGE" "$AUTH_HASH" << 'AUTHPY'
import sys, json, pathlib
p = pathlib.Path(sys.argv[1]) / 'etc/kybernet/config.json'
c = json.loads(p.read_text())
c['emergency_require_auth'] = True
c['emergency_password_hash'] = sys.argv[2]
p.write_text(json.dumps(c, indent=2))
AUTHPY
        ( cd "$AUTH_STAGE"
          if command -v bsdcpio >/dev/null 2>&1; then
              find . | bsdcpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs-auth.cpio.gz"
          else
              find . | cpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs-auth.cpio.gz"
          fi )
        echo "  staged emergency-auth fixture (legacy SHA-256)"

        # Emergency-auth fixture, KDF format (1.5.9). A THIRD cpio, not a
        # replacement: the legacy fixture above must keep booting green for as
        # long as 1.5.9 promises the deprecated format still works, and a
        # migration claim that is not gated is a claim nobody checked.
        #
        # The credential is generated by scripts/mkcred.sh — the tool this
        # release ships for operators — so the gate proves the generator and
        # the verifier agree under a real PID 1, not merely that two constants
        # in src/test.cyr match each other.
        KDF_STAGE="${SCRIPT_DIR}/initramfs-auth-kdf"
        rm -rf "$KDF_STAGE"
        mkdir -p "$KDF_STAGE"
        tar -cf - -C "$AUTH_STAGE" --exclude=./dev . | tar -xf - -C "$KDF_STAGE"
        mkdir -p "${KDF_STAGE}/dev"
        sudo mknod "${KDF_STAGE}/dev/console" c 5 1 2>/dev/null || true
        sudo mknod "${KDF_STAGE}/dev/null"    c 1 3 2>/dev/null || true
        sudo mknod "${KDF_STAGE}/dev/ttyS0"   c 4 64 2>/dev/null || true
        sudo mknod "${KDF_STAGE}/dev/kmsg"    c 1 11 2>/dev/null || true
        sudo chmod 666 "${KDF_STAGE}/dev/console" "${KDF_STAGE}/dev/null" \
            "${KDF_STAGE}/dev/ttyS0" "${KDF_STAGE}/dev/kmsg" 2>/dev/null || true

        # ALLOW_WEAK because the gate's password is "hunter2" — deliberately
        # the same string the legacy fixture uses, so the two boots differ in
        # exactly one variable: the stored credential format. mkcred.sh
        # otherwise refuses anything under 12 characters, which is the right
        # default for a real board and the wrong one for a test vector.
        if ! KDF_REC=$(ALLOW_WEAK=1 KYB_PASSWORD='hunter2' \
                bash "${SCRIPT_DIR}/../scripts/mkcred.sh" 2>/dev/null); then
            echo "  WARNING: mkcred.sh failed (openssl 3.2+ with ARGON2ID needed)"
            echo "  WARNING: skipping the KDF emergency-auth fixture"
            KDF_REC=""
        fi
        if [ -n "$KDF_REC" ]; then
            python3 - "$KDF_STAGE" "$KDF_REC" << 'KDFPY'
import sys, json, pathlib
p = pathlib.Path(sys.argv[1]) / 'etc/kybernet/config.json'
c = json.loads(p.read_text())
c['emergency_require_auth'] = True
c['emergency_password_hash'] = sys.argv[2]
p.write_text(json.dumps(c, indent=2))
KDFPY
            ( cd "$KDF_STAGE"
              if command -v bsdcpio >/dev/null 2>&1; then
                  find . | bsdcpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs-auth-kdf.cpio.gz"
              else
                  find . | cpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs-auth-kdf.cpio.gz"
              fi )
            echo "  staged emergency-auth fixture (argon2id v1)"
        else
            rm -f "${SCRIPT_DIR}/initramfs-auth-kdf.cpio.gz"
        fi

        ( cd "$EDGE_STAGE"
          if command -v bsdcpio >/dev/null 2>&1; then
              find . | bsdcpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs-edge.cpio.gz"
          else
              find . | cpio -o -H newc 2>/dev/null | gzip > "${SCRIPT_DIR}/initramfs-edge.cpio.gz"
          fi )
        echo "  staged edge fixture (root_hash=${EDGE_ROOT_HASH:0:16}...)"
    else
        echo "  WARNING: veritysetup format produced no root hash — edge pass will SKIP"
        _drop_stale_fixtures "veritysetup format produced no root hash"
    fi
else
    echo "  veritysetup not found — edge pass will SKIP (not a failure)"
    _drop_stale_fixtures "veritysetup not found"
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
