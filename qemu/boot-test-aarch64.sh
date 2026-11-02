#!/usr/bin/env bash
# qemu/boot-test-aarch64.sh — EXECUTE kybernet-aarch64 as PID 1. (1.6.19)
#
# WHY THIS EXISTS
# ---------------
# ⚠ Standing rule 44 says an architecture you ship is one you must EXECUTE, and
# until this file kybernet only satisfied half of it. `scripts/aarch64-exec-gate.sh`
# runs the unit suite and probes boot-critical syscalls under `qemu-user` — but
# that is a PROCESS, not a BOOT. Nothing had ever run `kybernet-aarch64` as PID 1:
# no mounts, no cgroups, no signalfd reactor, no shutdown. Every property
# `qemu/boot-test.sh` asserts was asserted on x86_64 only, and the aarch64
# artifact shipped on a cross-build exiting 0 plus a syscall probe.
#
# That was defensible only while the boot was IMPOSSIBLE. From 1.6.13 to 1.6.19
# it was: cyrius emitted an x86-compat translation ladder where SYS_SIGNALFD4=74
# collided with the `74 -> 82` fsync row, so `sys_signalfd()` issued `fsync(-1)`,
# `setup_signals` returned Err(EBADF), phase 4 took its FATAL arm and the board
# powered off before loading config. cyrius 6.5.36 moved it to the >=1000
# private-alias band (SYS_SIGNALFD4=1074) and the boot became possible.
#
# ⚠ SO PHASE 4 IS THIS GATE'S SENTINEL. If `phase 4: signals ready` ever stops
# appearing, CRITICAL-1 is back, and no syscall probe would tell you — the probe
# tests signalfd in isolation, this tests it inside init's real startup.
#
# SCOPE, STATED HONESTLY
# ----------------------
# From 1.6.19 to 1.7.1 this booted with NO services: most of the x86 harness's
# fixtures exec busybox applets, and an aarch64 busybox is a build-host capability
# standing rule 33 forbids assuming. Since 1.7.2 it stages 19 services built only
# from this repo's Cyrius fixtures, and asserts on aarch64 what the x86 harness
# asserts about services: cgroup placement and limits, capabilities and
# no_new_privs, the uid drop, capabilities kept across a uid drop, seccomp `basic`
# with its control arm, Landlock, prerequisite blocking, restart backoff, the
# health check and watchdog, orphan reaping, and sd_notify.
#
# Since 1.7.3 it also runs the x86 harness's other three passes on aarch64: the
# edge pass (dm-verity verification, refusal, and the permissive and off escape
# hatches), the emergency-auth passes (both credential formats, and a refused
# credential file that must not fall back to the config key), and the quiet pass.
# Two things stand in for what the x86 images copy from the build host, both built
# from this repo:
#
#   - qemu/verity-fixture.cyr is /usr/sbin/veritysetup. There is no aarch64
#     veritysetup on either build host. Its images are written by the host's real
#     `veritysetup format`, and before any boot it must agree with the host's real
#     `veritysetup verify`, exit code for exit code, on five cases.
#   - qemu/preinit-fixture.cyr gives the board its disks. The pinned kernel builds
#     every virtio, nvme, scsi and mtd driver as a module, so the x86 pass's virtio
#     disks never appear; it builds the RAM disk driver in, so the pre-init copies
#     the image and its hash tree into /dev/ram0 and /dev/ram1 and execs kybernet.
#
# So the edge pass proves kybernet's half on aarch64: the edge config, the exec,
# the verdict drawn from the exit code, the refusal and the escape hatches. It does
# NOT prove that the real veritysetup runs on aarch64.
#
# Pass 7 (1.11.1) does: the TPM board, with Debian's arm64 veritysetup, cryptsetup,
# tpm2-tools and systemd's token plugin, on Debian's kernel and firmware, all pinned
# in qemu/tpm-board-aarch64.pins. It is the only pass that boots anything but the
# Alpine kernel; its header says why.
#
# ⚠ One x86 fixture has no counterpart here, deliberately: the busybox `kyb-seccomp`,
# a glibc shell run under `seccomp: basic`. The `kyb-seccomp-on`/`-off` pair below
# already asserts that the filter loads (`SC[2]-MODE=2`), and it does so on the static,
# libc-free binary shape AGNOS services actually have (standing rule 48).
#
# ⚠ TCG, NOT KVM. An x86_64 host cannot accelerate aarch64, so this runs
# emulated and wall time is meaningless as a budget (standing rule 37 —
# "a gate must measure the code, not the machine it runs on"). The budget is
# KYB_MS, the span between kybernet's own first and last serial lines; wall time
# survives only as a loose liveness ceiling.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${PROJECT_DIR}/build/kybernet-aarch64"
CACHE="${SCRIPT_DIR}/.cache"
KERNEL="${CACHE}/vmlinuz-aarch64"

# ⚠ PINNED AND CHECKSUMMED. Standing rule 33: a gate's inputs come from the repo
# or from something CI installs — never from an unchecked host capability. An
# amd64 runner has no arm64 kernel package, so this is a declared dependency
# with a sha256, not "whatever the mirror serves today". A changed checksum is a
# failure, not a silent re-download.
#
# ⚠ THE URL MUST NAME A POINT RELEASE, AND THE CHECK BELOW ENFORCES IT. 1.7.0.
# This pinned the checksum of `.../v3.21/releases/aarch64/netboot/vmlinuz-lts`,
# and Alpine OVERWRITES the unversioned `netboot/` directory on every 3.21.x point
# release. When 3.21.8 landed (2026-09-17) the download changed under an unchanged
# pin, and CI failed with a checksum mismatch, which was correct. Every local run
# stayed green only because `.cache/` still held the 3.21.7 bytes, so the gate
# could not see the drift from a warm dev box (standing rule 39). A checksum on a
# moving URL is a tripwire, not a pin. `netboot-3.21.7/` is immutable, and it
# serves the exact bytes this gate has always booted (verified: same sha256).
# Moving to a newer kernel is a deliberate change of BOTH lines below.
KERNEL_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot-3.21.7/vmlinuz-lts"
KERNEL_SHA256="330dd0a88d18930dac4e425fad50f2947901a1c2bf782e72f58fef25ada4902a"
case "$KERNEL_URL" in
    */netboot/*)
        echo "ERROR: KERNEL_URL points at Alpine's UNVERSIONED netboot/ directory,"
        echo "       which every point release overwrites. Pin a netboot-X.Y.Z/ path."
        exit 1
        ;;
esac

# Wall-clock liveness ceiling only — NOT the performance budget. See KYB_BUDGET_MS.
TIMEOUT_S="${A64_TIMEOUT_S:-240}"
# The real budget: kybernet's own span, in ms, from its first to last serial line.
KYB_BUDGET_MS="${A64_KYB_BUDGET_MS:-4000}"

fail=0

# --- prerequisites: fail with a reason, never pass quietly (rule 32) ----------
if ! command -v qemu-system-aarch64 > /dev/null 2>&1; then
    if [ "${ALLOW_A64_BOOT_SKIP:-0}" = "1" ]; then
        echo "SKIP: qemu-system-aarch64 not installed (ALLOW_A64_BOOT_SKIP=1)."
        echo "      ⚠ This gate executed NOTHING. A skip is not a pass."
        exit 0
    fi
    echo "ERROR: qemu-system-aarch64 is not installed, so this gate cannot run."
    echo "       A missing prerequisite must FAIL with a reason, never pass"
    echo "       quietly (standing rule 32). Install it, or set"
    echo "       ALLOW_A64_BOOT_SKIP=1 to acknowledge the gate did not execute."
    exit 1
fi

if [ ! -f "$BIN" ]; then
    echo "ERROR: $BIN is missing."
    echo "       run: CYRIUS_DCE=1 cyrius build --aarch64 src/main.cyr build/kybernet-aarch64"
    exit 1
fi

# ⚠ Standing rule 43: never grade a stale binary. This script does not build —
# a second build path could drift from the documented one, and the gate whose
# job is to notice staleness must not also paper over it.
newest=""
for f in "${PROJECT_DIR}"/src/*.cyr "${PROJECT_DIR}"/src/lib/*.cyr "${PROJECT_DIR}/cyrius.cyml"; do
    [ -e "$f" ] || continue
    [ "$f" -nt "$BIN" ] && newest="$f"
done
if [ -n "$newest" ]; then
    echo "ERROR: $BIN is STALE — source has changed since it was built."
    echo "       newer: ${newest#$PROJECT_DIR/}"
    echo "       this script does not build; it would have tested the OLD binary"
    echo "       and reported a green for code that was never compiled."
    echo "       run: CYRIUS_DCE=1 cyrius build --aarch64 src/main.cyr build/kybernet-aarch64"
    exit 1
fi
# The same rule for agnos-init (1.7.6), which the kybernet package also ships and the
# image runs as a oneshot from /usr/lib/agnos/agnos-init.
AI_BIN="${PROJECT_DIR}/build/agnos-init-aarch64"
ai_newest=""
for f in "${PROJECT_DIR}"/src/*.cyr "${PROJECT_DIR}"/src/lib/*.cyr "${PROJECT_DIR}/cyrius.cyml"; do
    [ -e "$f" ] || continue
    [ -f "$AI_BIN" ] && [ "$f" -nt "$AI_BIN" ] && ai_newest="$f"
done
if [ ! -f "$AI_BIN" ] || [ -n "$ai_newest" ]; then
    echo "ERROR: $AI_BIN is missing or STALE${ai_newest:+ (newer: ${ai_newest#$PROJECT_DIR/})}."
    echo "       run: CYRIUS_DCE=1 cyrius build --aarch64 src/agnos_init.cyr build/agnos-init-aarch64"
    exit 1
fi

# The edge and auth passes (1.7.3) FORMAT their dm-verity image with the host's real
# veritysetup, and check the in-guest stand-in against it. Without it they cannot
# run, and a gate that cannot run a pass must fail with the reason (standing rule
# 32), not report the pass as green. ALLOW_A64_EDGE_SKIP=1 acknowledges it; the
# boot, reactor and quiet passes still run.
A64_EDGE=1
if ! command -v veritysetup > /dev/null 2>&1; then
    if [ "${ALLOW_A64_EDGE_SKIP:-0}" = "1" ]; then
        A64_EDGE=0
    else
        echo "ERROR: veritysetup is not installed (Debian/Ubuntu: cryptsetup-bin), so the"
        echo "       aarch64 edge and emergency-auth passes cannot run. An environment"
        echo "       failure, not a kybernet defect. Install it, or set"
        echo "       ALLOW_A64_EDGE_SKIP=1 to acknowledge those passes did not execute."
        exit 1
    fi
fi

# --- the kernel: pinned, checksummed, cached ---------------------------------
mkdir -p "$CACHE"
_kernel_ok() {
    [ -f "$KERNEL" ] || return 1
    [ "$(sha256sum "$KERNEL" | cut -d' ' -f1)" = "$KERNEL_SHA256" ]
}
if ! _kernel_ok; then
    echo "fetching pinned aarch64 kernel ..."
    if ! curl -sSf -L -o "$KERNEL.tmp" "$KERNEL_URL"; then
        rm -f "$KERNEL.tmp"
        if [ "${ALLOW_A64_BOOT_SKIP:-0}" = "1" ]; then
            echo "SKIP: could not fetch the aarch64 kernel (ALLOW_A64_BOOT_SKIP=1)."
            echo "      ⚠ This gate executed NOTHING. A skip is not a pass."
            exit 0
        fi
        echo "ERROR: could not fetch $KERNEL_URL and no cached copy is valid."
        exit 1
    fi
    got="$(sha256sum "$KERNEL.tmp" | cut -d' ' -f1)"
    if [ "$got" != "$KERNEL_SHA256" ]; then
        rm -f "$KERNEL.tmp"
        echo "ERROR: kernel checksum mismatch."
        echo "       expected $KERNEL_SHA256"
        echo "       got      $got"
        echo "       The pin exists so the gate tests the same kernel every"
        echo "       time. Update KERNEL_SHA256 deliberately, with review."
        exit 1
    fi
    mv "$KERNEL.tmp" "$KERNEL"
fi

# --- initramfs: kybernet IS pid 1 --------------------------------------------
ROOT="${CACHE}/root-a64"
CPIO="${CACHE}/initramfs-a64.cpio.gz"
rm -rf "$ROOT"
mkdir -p "$ROOT"/{bin,sbin,dev,proc,sys,run,tmp,etc/kybernet,usr/bin,var/log}
cp "$BIN" "$ROOT/init"
cp "$BIN" "$ROOT/sbin/init"
chmod +x "$ROOT/init" "$ROOT/sbin/init"

# --- service fixtures: Cyrius binaries only (1.7.2) ---------------------------
# ⚠ WHY ONLY CYRIUS. Most of the x86 harness's fixtures are busybox applets, and an
# aarch64 busybox is a build-host capability standing rule 33 forbids assuming, so
# from 1.6.19 to 1.7.1 this gate booted with NO services at all. These four are
# built from this repo, link no libc and need no loader, so the same source runs on
# both arches (rule 48). qemu/svc-fixture.cyr stands in for the x86 harness's
# /bin/true, /bin/false, /bin/sleep and `sh -c "grep ... /proc/self/status"`
# one-liners; the other three are the fixtures the x86 harness already uses.
# verity and preinit are the edge board's (1.7.3); they go only into the edge
# images staged below, not into this one.
#
# Built on every run, like the initramfs, so a stale fixture cannot be graded.
if ! command -v cyrius > /dev/null 2>&1; then
    echo "ERROR: cyrius is not on PATH, so the service fixtures cannot be cross-built."
    echo "       An environment failure, not a kybernet defect."
    exit 1
fi
FIX_DIR="${CACHE}/fixtures-a64"
rm -rf "$FIX_DIR"
mkdir -p "$FIX_DIR"
for fx in svc landlock seccomp notify verity preinit; do
    if ! (cd "$PROJECT_DIR" && cyrius build --aarch64 "qemu/${fx}-fixture.cyr" "${FIX_DIR}/kyb-${fx}-fixture" > /dev/null); then
        echo "ERROR: could not cross-build qemu/${fx}-fixture.cyr for aarch64 (compiler output above)"
        exit 1
    fi
    # An x86 fixture in this image would fail execve with ENOEXEC, and every service
    # built on it would read as a kybernet defect. Check the ELF machine, not the name.
    fxm="$(od -An -tx1 -j18 -N2 "${FIX_DIR}/kyb-${fx}-fixture" | tr -d ' \n')"
    if [ "$fxm" != "b700" ]; then
        echo "ERROR: kyb-${fx}-fixture has e_machine=$fxm, expected b700 (aarch64)"
        exit 1
    fi
done
for fx in svc landlock seccomp notify; do
    cp "${FIX_DIR}/kyb-${fx}-fixture" "$ROOT/usr/bin/"
    chmod 755 "$ROOT/usr/bin/kyb-${fx}-fixture"
done
# The Landlock truncate probe's victim: outside the rule set, 16 known bytes.
printf '0123456789abcdef' > "$ROOT/etc/kyb-landlock-victim"

# agnos-init (1.7.6) at its production path, and the users it looks up. user 1000's
# primary gid is 1001 so a gid read from passwd differs from one assumed from the uid.
aim="$(od -An -tx1 -j18 -N2 "$AI_BIN" | tr -d ' \n')"
if [ "$aim" != "b700" ]; then
    echo "ERROR: $AI_BIN has e_machine=$aim, expected b700 (aarch64)"
    exit 1
fi
mkdir -p "$ROOT/usr/lib/agnos"
cp "$AI_BIN" "$ROOT/usr/lib/agnos/agnos-init"
chmod 755 "$ROOT/usr/lib/agnos/agnos-init"
cat > "$ROOT/etc/passwd" << 'PWEOF'
root:x:0:0:root:/root:/bin/sh
agnos:x:900:900:AGNOS Agent Runtime:/var/lib/agnos:/usr/sbin/nologin
agnos-llm:x:901:901:AGNOS LLM Gateway:/var/lib/agnos/models:/usr/sbin/nologin
user:x:1000:1001:AGNOS User:/home/user:/bin/sh
PWEOF

# ⚠ EVERY SERVICE BELOW IS ASSERTED ON. The roadmap item this closes said "do not
# close this by adding services that do not assert anything", and a service with
# no assertion is exactly that. Each mirrors the x86 fixture of the same name; the
# differences are the binaries, and that kyb-limited's control case is
# kyb-confined's own unlimited memory.max rather than a read of kyb-live's cgroup.
# Adding or removing one means updating the `services parsed` and `removed service
# cgroups` markers below (standing rule 27).
cat > "$ROOT/etc/kybernet/config.json" << 'CFGEOF'
{
  "boot_mode": "recovery",
  "log_to_console": true,
  "shutdown_timeout_ms": 3000,
  "services": [
    { "name": "kyb-dep", "binary": "/usr/bin/kyb-svc-fixture", "args": ["true"],
      "type": "oneshot", "restart": "never" },
    { "name": "kyb-svc", "binary": "/usr/bin/kyb-svc-fixture", "args": ["true"],
      "type": "oneshot", "restart": "never", "depends_on": ["kyb-dep"] },
    { "name": "kyb-live", "binary": "/usr/bin/kyb-svc-fixture", "args": ["sleep", "30"],
      "type": "simple", "restart": "never" },
    { "name": "kyb-crash", "binary": "/usr/bin/kyb-svc-fixture", "args": ["false"],
      "type": "simple", "restart": "on-failure" },
    { "name": "kyb-limited", "binary": "/usr/bin/kyb-svc-fixture", "args": ["status"],
      "type": "oneshot", "restart": "never",
      "limits": { "memory_max": 67108864, "memory_high": 50331648, "cpu_weight": 250,
                  "pids_max": 32, "cpu_max_us": 50000 } },
    { "name": "kyb-confined", "binary": "/usr/bin/kyb-svc-fixture", "args": ["status"],
      "type": "oneshot", "restart": "never",
      "security": { "no_new_privs": true, "capabilities": [] } },
    { "name": "kyb-orphan", "binary": "/usr/bin/kyb-svc-fixture", "args": ["orphan"],
      "type": "oneshot", "restart": "never" },
    { "name": "kyb-health", "binary": "/usr/bin/kyb-svc-fixture", "args": ["sleep", "600"],
      "type": "simple", "restart": "on-failure",
      "health_check": { "type": "tcp", "target": "127.0.0.1", "port": 9,
                        "interval_ms": 1000, "timeout_ms": 200, "retries": 10 } },
    { "name": "kyb-wdog", "binary": "/usr/bin/kyb-svc-fixture", "args": ["sleep", "600"],
      "type": "simple", "restart": "on-failure",
      "health_check": { "type": "tcp", "target": "127.0.0.1", "port": 9,
                        "interval_ms": 1000, "timeout_ms": 200, "retries": 1 } },
    { "name": "kyb-hc-conf", "binary": "/usr/bin/kyb-svc-fixture", "args": ["sleep", "600"],
      "type": "simple", "restart": "never",
      "security": { "seccomp": "basic", "no_new_privs": true, "capabilities": [] },
      "health_check": { "type": "command", "target": "/usr/bin/kyb-svc-fixture status",
                        "interval_ms": 1000, "timeout_ms": 800, "retries": 10 } },
    { "name": "kyb-hup", "binary": "/usr/bin/kyb-svc-fixture", "args": ["hup", "12", "/etc/kybernet/reload-a.json", "/etc/kybernet/reload-b.json"],
      "type": "simple", "restart": "never" },
    { "name": "kyb-nonroot", "binary": "/usr/bin/kyb-svc-fixture", "args": ["status"],
      "type": "oneshot", "restart": "never",
      "security": { "uid": 65534, "gid": 65534, "no_new_privs": true } },
    { "name": "kyb-nonroot-read", "binary": "/usr/bin/kyb-svc-fixture",
      "args": ["relay", "/dev/shm/kyb-st-kyb-nonroot.txt"],
      "type": "oneshot", "restart": "never", "depends_on": ["kyb-nonroot"] },
    { "name": "kyb-prereq-fail", "binary": "/usr/bin/kyb-does-not-exist",
      "type": "oneshot", "restart": "never" },
    { "name": "kyb-prereq-dep", "binary": "/usr/bin/kyb-svc-fixture", "args": ["status"],
      "type": "oneshot", "restart": "never", "depends_on": ["kyb-prereq-fail"] },
    { "name": "kyb-capuid", "binary": "/usr/bin/kyb-svc-fixture", "args": ["status"],
      "type": "oneshot", "restart": "never",
      "security": { "capabilities": ["cap_net_bind_service"], "uid": 65534, "gid": 65534,
                    "no_new_privs": true } },
    { "name": "kyb-capuid-read", "binary": "/usr/bin/kyb-svc-fixture",
      "args": ["relay", "/dev/shm/kyb-st-kyb-capuid.txt"],
      "type": "oneshot", "restart": "never", "depends_on": ["kyb-capuid"] },
    { "name": "kyb-landlock", "binary": "/usr/bin/kyb-landlock-fixture",
      "type": "oneshot", "restart": "never",
      "security": { "landlock": [ {"path": "/usr", "access": "read-exec"},
                                  {"path": "/dev", "access": "read-write"} ],
                    "landlock_optional": false, "no_new_privs": true } },
    { "name": "kyb-notify", "binary": "/usr/bin/kyb-notify-fixture",
      "type": "notify", "watchdog_ms": 30000, "restart": "never" },
    { "name": "kyb-seccomp-on", "binary": "/usr/bin/kyb-seccomp-fixture",
      "type": "oneshot", "restart": "never",
      "security": { "seccomp": "basic", "no_new_privs": true } },
    { "name": "kyb-seccomp-off", "binary": "/usr/bin/kyb-seccomp-fixture",
      "type": "oneshot", "restart": "never" },
    { "name": "kyb-env", "binary": "/usr/bin/kyb-svc-fixture", "args": ["status"],
      "type": "oneshot", "restart": "never",
      "environment": { "KYB_FROM_CONFIG": "config value", "KYB_OVERRIDDEN": "from config" },
      "env_files": ["/etc/kybernet/kyb-env.env"] },
    { "name": "kyb-envgen", "binary": "/usr/bin/kyb-svc-fixture",
      "args": ["write", "/run/kyb-late.env", "KYB_LATE=written at boot"],
      "type": "oneshot", "restart": "never" },
    { "name": "kyb-env-late", "binary": "/usr/bin/kyb-svc-fixture", "args": ["status"],
      "type": "oneshot", "restart": "never", "depends_on": ["kyb-envgen"],
      "env_files": ["/run/kyb-late.env"] },
    { "name": "kyb-env-gone", "binary": "/usr/bin/kyb-svc-fixture", "args": ["status"],
      "type": "oneshot", "restart": "never", "env_files": ["/run/kyb-never-written.env"] },
    { "name": "kyb-env-bad", "binary": "/usr/bin/kyb-svc-fixture", "args": ["status"],
      "type": "oneshot", "restart": "never", "env_files": ["/etc/kybernet/kyb-env-bad.env"] },
    { "name": "kyb-mode-in", "binary": "/usr/bin/kyb-svc-fixture", "args": ["status"],
      "type": "oneshot", "restart": "never", "required_for_modes": ["server", "recovery"] },
    { "name": "kyb-mode-out", "binary": "/usr/bin/kyb-svc-fixture", "args": ["status"],
      "type": "oneshot", "restart": "never", "required_for_modes": ["edge"] },
    { "name": "kyb-ready-ok", "binary": "/usr/bin/kyb-svc-fixture", "args": ["sleep", "30"],
      "type": "simple", "restart": "never",
      "ready_check": { "type": "process-alive", "timeout_ms": 2000, "retries": 3, "retry_delay_ms": 100 } },
    { "name": "kyb-ready-fail", "binary": "/usr/bin/kyb-svc-fixture", "args": ["sleep", "30"],
      "type": "simple", "restart": "never",
      "ready_check": { "type": "tcp", "target": "127.0.0.1", "port": 9,
                       "timeout_ms": 500, "retries": 2, "retry_delay_ms": 50 } },
    { "name": "kyb-mknod-in", "binary": "/usr/bin/kyb-svc-fixture",
      "args": ["mknod", "/dev/input/event90", "13", "154"], "type": "oneshot", "restart": "never" },
    { "name": "kyb-mknod-fb", "binary": "/usr/bin/kyb-svc-fixture",
      "args": ["mknod", "/dev/fb0", "29", "0"], "type": "oneshot", "restart": "never" },
    { "name": "agnos-init", "binary": "/usr/lib/agnos/agnos-init",
      "type": "oneshot", "restart": "never", "depends_on": ["kyb-mknod-in", "kyb-mknod-fb"] },
    { "name": "kyb-agnos-dirs", "binary": "/usr/bin/kyb-svc-fixture",
      "args": ["stat", "/run/agnos/agents", "/run/agnos/plugins", "/run/user/1000",
               "/var/lib/agnos/agents", "/var/lib/agnos/agent-memory", "/var/lib/agnos/models",
               "/var/log/agnos", "/dev/input/event90", "/dev/fb0", "/sys/fs/cgroup/kybernet.slice"],
      "type": "oneshot", "restart": "never", "depends_on": ["agnos-init"] },
    { "name": "kyb-grant", "binary": "/usr/bin/kyb-svc-fixture",
      "args": ["open", "/dev/input/event90", "/dev/fb0"], "type": "oneshot", "restart": "never",
      "depends_on": ["agnos-init"], "security": { "uid": 900, "gid": 900, "groups": [44, 104] } },
    { "name": "kyb-nogrant", "binary": "/usr/bin/kyb-svc-fixture",
      "args": ["open", "/dev/input/event90", "/dev/fb0"], "type": "oneshot", "restart": "never",
      "depends_on": ["agnos-init"], "security": { "uid": 900, "gid": 900 } },
    { "name": "kyb-deleg", "binary": "/usr/bin/kyb-svc-fixture", "args": ["cgdelegate"],
      "type": "oneshot", "restart": "never", "security": { "uid": 900, "gid": 900, "delegate": true } },
    { "name": "kyb-nodeleg", "binary": "/usr/bin/kyb-svc-fixture", "args": ["cgdelegate"],
      "type": "oneshot", "restart": "never", "security": { "uid": 900, "gid": 900 } },
    { "name": "kyb-id-relay", "binary": "/usr/bin/kyb-svc-fixture",
      "args": ["relay", "/dev/shm/kyb-st-kyb-grant.txt", "/dev/shm/kyb-st-kyb-nogrant.txt",
               "/dev/shm/kyb-st-kyb-deleg.txt", "/dev/shm/kyb-st-kyb-nodeleg.txt"],
      "type": "oneshot", "restart": "never",
      "depends_on": ["kyb-grant", "kyb-nogrant", "kyb-deleg", "kyb-nodeleg"] }
  ]
}
CFGEOF
# ⚠ PADDED PAST THE OLD 16 KiB LIMIT (1.7.8), as the x86 image is: kybernet refused any
# config.json over 16,384 bytes until 1.7.8, so pass 1 (and the quiet pass, whose root
# is a copy of this one) boots a larger one, and pass 1 checks the size kybernet
# reports. kybernet ignores top-level keys it does not know; "comment" is one.
_PAD="$(printf 'kybernet ignores this key; it makes this file larger than 16 KiB. %.0s' $(seq 1 200))"
sed -i "1a\\  \"comment\": \"${_PAD}\"," "$ROOT/etc/kybernet/config.json"
# The two configs kyb-hup rotates between (1.9.0): this one plus a credential, identical
# but for the tag, so both parse to the same shape. No KDF runs at load, and nothing
# here requires the credential. Since 1.10.0 they also carry everything else a reload
# keeps, an edge block with baselines (a recovery board parses it and acts on none of
# it), and b's start_timeout_ms is one a reload must reject, leaving a's in force.
_HUP_REC='v1$1$8192$1$00112233445566778899aabbccddeeff$'
_HUP_D="$(printf 'd%.0s' $(seq 1 64))"
_HUP_E="$(printf 'e%.0s' $(seq 1 64))"
_HUP_F="$(printf 'f%.0s' $(seq 1 64))"
_HUP_EDGE="\"edge\": {\"pcr_bindings\": \"0+7\", \"root_device\": \"/dev/vda\", \"hash_device\": \"/dev/vdb\", \"root_hash\": \"${_HUP_D}\", \"expected_pcrs\": [\"${_HUP_E}\", \"${_HUP_F}\"]}"
for _v in a b; do
    _TAG="$(printf "${_v}%.0s" $(seq 1 64))"
    _TMO=120000
    [ "$_v" = "b" ] && _TMO=90
    sed "1a\\  \"emergency_password_hash\": \"${_HUP_REC}${_TAG}\", \"start_timeout_ms\": ${_TMO}, ${_HUP_EDGE}," \
        "$ROOT/etc/kybernet/config.json" > "$ROOT/etc/kybernet/reload-${_v}.json"
done
# kyb-env's env_files entry (1.7.5), the same file the x86 image stages.
cat > "$ROOT/etc/kybernet/kyb-env.env" << 'ENVEOF'
# kyb-env's environment file
KYB_FROM_FILE="file value"
KYB_OVERRIDDEN=from file
ENVEOF
# kyb-env-bad's env_files entry (1.10.0). `export` makes the name "export KYB_BAD".
cat > "$ROOT/etc/kybernet/kyb-env-bad.env" << 'ENVEOF'
export KYB_BAD=1
ENVEOF
# ⚠ DO NOT DISCARD cpio's STDERR, AND DO NOT ASSUME cpio EXISTS. The first
# version was `cpio ... 2> /dev/null`, which turns a missing or failing archiver
# into an empty initramfs — QEMU then boots a kernel with no `/init`, every
# marker is absent, and the gate reports a wall of kybernet failures for a
# missing package. Same shape as the romfile problem above: one environmental
# cause wearing another subsystem's name. In CI `cpio` comes only from the x86
# harness JOB, on a different runner, so its presence here is not something to
# take on faith (standing rule 39).
if ! command -v cpio > /dev/null 2>&1; then
    echo "ERROR: cpio is not installed, so the initramfs cannot be built."
    echo "       In CI this step installs it; the x86 harness job's copy is on another runner."
    exit 1
fi
if ! ( cd "$ROOT" && find . -print0 | cpio --null -o -H newc | gzip -9 > "$CPIO" ); then
    echo "ERROR: building the aarch64 initramfs failed (cpio/gzip output above)."
    exit 1
fi
# A valid image is ~500 KB (a statically linked PID 1). Anything tiny means the
# archive was produced but is empty — the silent case the guard above exists for.
CPIO_SZ="$(stat -c%s "$CPIO" 2> /dev/null || echo 0)"
if [ "$CPIO_SZ" -lt 100000 ]; then
    echo "ERROR: the aarch64 initramfs is only ${CPIO_SZ} bytes — it cannot contain"
    echo "       a statically linked PID 1. Refusing to boot an empty image and"
    echo "       report the result as kybernet's."
    exit 1
fi

# Archive a staged tree with the same guards as the main image above.
# $1 = tree, $2 = output .cpio.gz
_mk_cpio() {
    if ! ( cd "$1" && find . -print0 | cpio --null -o -H newc | gzip -9 > "$2" ); then
        echo "ERROR: archiving $1 failed (cpio/gzip output above)."
        exit 1
    fi
    local sz
    sz="$(stat -c%s "$2" 2> /dev/null || echo 0)"
    if [ "$sz" -lt 100000 ]; then
        echo "ERROR: $2 is only ${sz} bytes, too small to hold a PID 1. Refusing to boot it."
        exit 1
    fi
}

# --- pass 5's image: the same tree with console logging off (1.7.3) -----------
# Built from the tree pass 1 boots, so the two differ in exactly one config key.
QROOT="${CACHE}/root-a64-quiet"
QCPIO="${CACHE}/initramfs-a64-quiet.cpio.gz"
rm -rf "$QROOT"
cp -a "$ROOT" "$QROOT"
sed -i 's/"log_to_console": true/"log_to_console": false/' "$QROOT/etc/kybernet/config.json"
if ! grep -q '"log_to_console": false' "$QROOT/etc/kybernet/config.json"; then
    echo "ERROR: could not switch log_to_console off in the quiet image's config."
    exit 1
fi
_mk_cpio "$QROOT" "$QCPIO"

# --- pass 6's image: a config of its own, for start_timeout_ms (1.10.0) --------
# The timeout is one value for the whole board and its floor is a second, so in pass
# 1's config it would cut every slow fixture short.
SROOT="${CACHE}/root-a64-slow"
SCPIO="${CACHE}/initramfs-a64-slow.cpio.gz"
rm -rf "$SROOT"
cp -a "$ROOT" "$SROOT"
cat > "$SROOT/etc/kybernet/config.json" << 'SLOWEOF'
{
  "boot_mode": "recovery",
  "start_timeout_ms": 2000,
  "services": [
    { "name": "kyb-start-fast", "binary": "/usr/bin/kyb-svc-fixture", "args": ["true"],
      "type": "oneshot", "restart": "never" },
    { "name": "kyb-start-slow", "binary": "/usr/bin/kyb-svc-fixture", "args": ["sleep", "600"],
      "type": "oneshot", "restart": "never" },
    { "name": "kyb-start-after", "binary": "/usr/bin/kyb-svc-fixture", "args": ["true"],
      "type": "oneshot", "restart": "never", "depends_on": ["kyb-start-slow"] }
  ]
}
SLOWEOF
_mk_cpio "$SROOT" "$SCPIO"

# --- passes 3 and 4: the edge board (1.7.3) -----------------------------------
# One dm-verity image, formatted by the host's REAL veritysetup, and a copy with
# nine bytes overwritten inside its first data block. Every edge and auth image
# below carries one of the two, and the pre-init copies it into /dev/ram0.
EDGE_WORK="${CACHE}/edge-a64"
XCHECK_OK=1
if [ "$A64_EDGE" = "1" ]; then
    rm -rf "$EDGE_WORK"
    mkdir -p "$EDGE_WORK"
    dd if=/dev/urandom of="$EDGE_WORK/data.img" bs=1M count=1 status=none
    truncate -s 1M "$EDGE_WORK/hash.img"
    ROOT_HASH="$(veritysetup format "$EDGE_WORK/data.img" "$EDGE_WORK/hash.img" 2> "$EDGE_WORK/format.err" \
        | awk '/Root hash/{print $3}' || true)"
    if [ "${#ROOT_HASH}" -ne 64 ]; then
        echo "ERROR: veritysetup format produced no root hash, so there is no edge fixture."
        sed 's/^/       /' "$EDGE_WORK/format.err" | head -5 || true
        exit 1
    fi
    cp "$EDGE_WORK/data.img" "$EDGE_WORK/data-corrupt.img"
    printf 'CORRUPTED' | dd of="$EDGE_WORK/data-corrupt.img" bs=1 seek=2000 conv=notrunc status=none

    # ⚠ THE STAND-IN IS CHECKED AGAINST THE REAL TOOL BEFORE IT IS TRUSTED. Its host
    # build and the host's veritysetup verify the same five cases, and every exit
    # code must match. Agreement alone is not enough: two programs that both fail
    # to open a file agree too. So veritysetup's own answers must also be the
    # expected ones, or the environment is broken and nothing below means anything.
    if ! (cd "$PROJECT_DIR" && cyrius build qemu/verity-fixture.cyr "$EDGE_WORK/verity-host" > /dev/null); then
        echo "ERROR: could not build qemu/verity-fixture.cyr for the host (compiler output above)"
        exit 1
    fi
    cp "$EDGE_WORK/hash.img" "$EDGE_WORK/hash-corrupt.img"
    # FLIPPED, NOT OVERWRITTEN (1.12.0). Byte 4100 is inside the first digest of a tree
    # over random data, so writing a fixed `X` there changed nothing whenever the byte
    # already was `X`: about 1 run in 256, veritysetup verified the "corrupted" tree and
    # the stand-in check failed. Its complement always differs.
    _hb="$(od -An -tu1 -j4100 -N1 "$EDGE_WORK/hash-corrupt.img" | tr -d ' ')"
    printf "$(printf '\\%03o' $((_hb ^ 255)))" | dd of="$EDGE_WORK/hash-corrupt.img" bs=1 seek=4100 conv=notrunc status=none
    truncate -s 1M "$EDGE_WORK/zero.img"
    case "$ROOT_HASH" in 0*) WRONG_HASH="1${ROOT_HASH#?}" ;; *) WRONG_HASH="0${ROOT_HASH#?}" ;; esac

    echo "=== stand-in check: qemu/verity-fixture.cyr against the host's veritysetup ==="
    # $1 = case, $2 = the exit code veritysetup must give, $3 data, $4 hash, $5 root
    _vcase() {
        local want got
        want=0; veritysetup verify "$3" "$4" "$5" > /dev/null 2>&1 || want=$?
        got=0; "$EDGE_WORK/verity-host" verify "$3" "$4" "$5" > /dev/null 2>&1 || got=$?
        if [ "$want" != "$2" ]; then
            echo "  FAIL: [$1] veritysetup itself exited $want, expected $2. The host tool"
            echo "        or the images are broken, so the stand-in cannot be judged."
            XCHECK_OK=0
        elif [ "$got" != "$want" ]; then
            echo "  FAIL: [$1] the stand-in exited $got where veritysetup exited $want"
            XCHECK_OK=0
        else
            echo "  OK: [$1] the stand-in and veritysetup both exit $got"
        fi
    }
    _vcase "intact image" 0 "$EDGE_WORK/data.img" "$EDGE_WORK/hash.img" "$ROOT_HASH"
    _vcase "corrupted data block" 2 "$EDGE_WORK/data-corrupt.img" "$EDGE_WORK/hash.img" "$ROOT_HASH"
    _vcase "corrupted hash tree" 2 "$EDGE_WORK/data.img" "$EDGE_WORK/hash-corrupt.img" "$ROOT_HASH"
    _vcase "wrong root hash" 1 "$EDGE_WORK/data.img" "$EDGE_WORK/hash.img" "$WRONG_HASH"
    _vcase "no superblock" 1 "$EDGE_WORK/data.img" "$EDGE_WORK/zero.img" "$ROOT_HASH"
    if [ "$XCHECK_OK" != "1" ]; then fail=1; fi

    # The credentials, made the way the x86 fixtures make them: the legacy digest
    # of "hunter2", and an Argon2id record minted by sigil (qemu/mkcred-fixture.cyr),
    # which runs on the host. A record is text, so it does not care which arch
    # verifies it.
    if ! (cd "$PROJECT_DIR" && cyrius build qemu/mkcred-fixture.cyr "$EDGE_WORK/mkcred-host" > /dev/null); then
        echo "ERROR: could not build qemu/mkcred-fixture.cyr for the host (compiler output above)"
        exit 1
    fi
    if ! KDF_REC="$("$EDGE_WORK/mkcred-host")"; then
        echo "ERROR: mkcred-fixture failed to mint a credential"
        exit 1
    fi
    case "$KDF_REC" in
        'v1$'*) ;;
        *) echo "ERROR: mkcred-fixture emitted something that is not a v1 record: $KDF_REC"; exit 1 ;;
    esac
    if ! bash "${PROJECT_DIR}/scripts/mkcred.sh" --check "$KDF_REC" > /dev/null; then
        echo "ERROR: mkcred-fixture emitted a record scripts/mkcred.sh --check rejects"
        exit 1
    fi
    IFS='$' read -r _kv _kt _km _kp KDF_SALT KDF_TAG <<< "$KDF_REC"
    # The decoy has the real record's parameters and salt and an all-zero tag: a
    # valid shape that no password can match (the x86 fixture's decoy, see
    # qemu/build-initramfs.sh).
    KDF_DECOY="v1\$${_kt}\$${_km}\$${_kp}\$${KDF_SALT}\$$(printf '%*s' "${#KDF_TAG}" '' | tr ' ' 0)"
    LEGACY_HASH="$(printf 'hunter2' | sha256sum | awk '{print $1}')"

    # $1 = image name, $2 = data image, $3 = the password-hash config value ("" for
    # the edge images, which configure no credential), $4 = emergency.cred's mode
    # ("" for no file), $5 = the record emergency.cred holds.
    _stage_edge() {
        local r="${EDGE_WORK}/root-$1"
        local auth=""
        rm -rf "$r"
        mkdir -p "$r"/{sbin,dev,proc,sys,run,tmp,etc/kybernet,usr/bin,usr/sbin,var/log,kyb-board}
        cp "$BIN" "$r/sbin/init"
        cp "${FIX_DIR}/kyb-preinit-fixture" "$r/kyb-preinit"
        cp "${FIX_DIR}/kyb-verity-fixture" "$r/usr/sbin/veritysetup"
        chmod 755 "$r/sbin/init" "$r/kyb-preinit" "$r/usr/sbin/veritysetup"
        cp "$2" "$r/kyb-board/data.img"
        cp "$EDGE_WORK/hash.img" "$r/kyb-board/hash.img"
        if [ -n "$3" ]; then
            # The emergency shell kybernet execs after a correct password. It reports
            # what it was handed and exits, and the board powers off.
            cp "${FIX_DIR}/kyb-svc-fixture" "$r/usr/bin/agnoshi"
            chmod 755 "$r/usr/bin/agnoshi"
            auth="
  \"emergency_require_auth\": true,
  \"emergency_password_hash\": \"$3\","
        fi
        cat > "$r/etc/kybernet/config.json" << EDGECFG
{
  "boot_mode": "edge",
  "verify_boot": true,
  "shutdown_timeout_ms": 400,${auth}
  "edge": {
    "readonly_rootfs": true,
    "tpm_attestation": false,
    "luks_enabled": false,
    "max_boot_ms": 20000,
    "root_device": "/dev/ram0",
    "hash_device": "/dev/ram1",
    "root_hash": "${ROOT_HASH}"
  },
  "services": []
}
EDGECFG
        if [ -n "$4" ]; then
            printf '%s\n' "$5" > "$r/etc/kybernet/emergency.cred"
            chmod "$4" "$r/etc/kybernet/emergency.cred"
        fi
        _mk_cpio "$r" "${EDGE_WORK}/$1.cpio.gz"
    }
    # Each mirrors the x86 image of the same role (qemu/build-initramfs.sh). The auth
    # images carry the CORRUPTED data, because an edge refusal is how phase 6c
    # reaches the prompt.
    _stage_edge edge-good "$EDGE_WORK/data.img" "" "" ""
    _stage_edge edge-corrupt "$EDGE_WORK/data-corrupt.img" "" "" ""
    _stage_edge auth-legacy "$EDGE_WORK/data-corrupt.img" "$LEGACY_HASH" "" ""
    _stage_edge auth-kdf "$EDGE_WORK/data-corrupt.img" "$KDF_DECOY" 600 "$KDF_REC"
    _stage_edge auth-refused "$EDGE_WORK/data-corrupt.img" "$KDF_REC" 644 "$KDF_REC"
fi

# ⚠ `-nic none` IS LOAD-BEARING, AND ITS ABSENCE WAS AN ENVIRONMENT-ONLY
# FAILURE. `-M virt` instantiates a DEFAULT virtio NIC, whose option ROM
# (`efi-virtio.rom`) ships in Ubuntu's `ipxe-qemu` — a package apt lists as
# *Recommended*, which `--no-install-recommends` drops. QEMU then refuses to
# start at all: `failed to find romfile "efi-virtio.rom"`.
#
# Standing rule 39: prefer the input that CANNOT be absent. This gate boots a
# kernel and an initramfs directly and touches no network, so the correct fix is
# to never create the device rather than to install a ROM package for a NIC
# nothing uses. That also makes the gate independent of which QEMU the host
# has — 8.2 adds the default NIC, 11.1 does not, which is precisely why this
# passed on the dev box and failed on CI.
#
# ⚠ `dtb-randomness=off` MAKES THIS AN ENTROPY-STARVED BOARD, ON PURPOSE. 1.7.2.
# By default `-M virt` hands the guest a random seed in the device tree, so the
# kernel logs `random: crng init done` at 0.000000 and nothing in the boot ever waits
# for entropy. A board without a hardware RNG has no such seed, and PID 1 does block
# on it: the stdlib's hashmap seed (lib/hashseed.cyr) is `getrandom(…, 0)`, drawn on
# the first map operation, which is in argonaut_init_new at phase 6, before the
# reactor exists. Turning the seed off makes every run exercise that wait, and pass
# 1 asserts that it really happened (the CRNG seeded AFTER kybernet started) and
# that the span budget still holds. Needs QEMU >= 7.2; older ones are named as an
# environment failure below rather than as missing kybernet markers.
_check_qemu_env() {
    # ⚠ NAME AN ENVIRONMENT FAILURE AS ONE. When QEMU cannot start, every
    # marker is absent and the gate reports a wall of missing-marker failures
    # that read like kybernet regressions — one environmental cause presented
    # as eight code defects. That happened, and it is standing rule 38's
    # principle: a gate must not report one subsystem's cause under another's
    # name.
    if grep -aq 'failed to find romfile' "$1"; then
        echo "  FAIL: QEMU could not start — a missing option ROM, not a kybernet defect."
        grep -a 'failed to find romfile' "$1" | head -2 || true
        echo "        This gate passes -nic none precisely so no ROM is needed;"
        echo "        seeing this means a device is being created that should not be."
        fail=1
    fi
    if grep -aqE "dtb-randomness.*(not found|invalid)|Property .*dtb-randomness" "$1"; then
        echo "  FAIL: this QEMU has no virt 'dtb-randomness' property (needs >= 7.2) — an"
        echo "        environment failure, not a kybernet defect."
        grep -a 'dtb-randomness' "$1" | head -2 || true
        fail=1
    fi
}

# One non-interactive boot. $1 = initramfs, $2 = kernel command line, $3 = output file
_boot_img() {
    timeout "$TIMEOUT_S" qemu-system-aarch64 \
        -M virt,dtb-randomness=off -cpu cortex-a57 -m 512M -smp 1 \
        -nic none \
        -kernel "$KERNEL" -initrd "$1" \
        -append "$2" \
        -nographic -no-reboot -serial mon:stdio > "$3" 2>&1 || true
    _check_qemu_env "$3"
}

# $1 = harness mode, $2 = output file
_boot() {
    _boot_img "$CPIO" "console=ttyAMA0 kybernet.harness=$1 panic=1" "$2"
}

# Ceilings for the interactive boots, not budgets: each loop below ends as soon as
# the thing it waits for happens.
PROMPT_WAIT_S="${A64_PROMPT_WAIT_S:-120}"
AUTH_TIMEOUT_S="${A64_AUTH_TIMEOUT_S:-180}"
# How long a rejected boot must stay up, after its verdict, to count as halted.
HALT_OBSERVE_S="${A64_HALT_OBSERVE_S:-5}"

# One emergency-auth boot, typing on the serial console the way an operator would.
# $1 = initramfs, $2 = password ("" types nothing), $3 = output file.
#
# ⚠ DRIVEN BY THE PROMPT, NOT BY A CLOCK. The x86 pass types after a fixed 8 s,
# which is safe under KVM. Under TCG the prompt's arrival varies with the host, so
# this waits until `Password: ` is in the log and types 2 s later. kybernet writes
# the prompt and then turns echo off, and the 2 s cover that step: typing before
# echo is off would print the password, and the gate would fail correct code.
#
# Sets AUTH_PROMPT_SEEN (a prompt appeared) and AUTH_HALTED (the VM was still up
# HALT_OBSERVE_S seconds after an AUTHENTICATION FAILED verdict, i.e. it halted
# rather than rebooting or powering off).
_auth_boot() {
    local fifo="${3}.fifo"
    local qpid t verdict_t
    rm -f "$fifo" "$3"
    mkfifo "$fifo"
    timeout "$AUTH_TIMEOUT_S" qemu-system-aarch64 \
        -M virt,dtb-randomness=off -cpu cortex-a57 -m 512M -smp 1 \
        -nic none \
        -kernel "$KERNEL" -initrd "$1" \
        -append "console=ttyAMA0 rdinit=/kyb-preinit kybernet.harness=1 panic=1" \
        -nographic -no-reboot -monitor none -serial stdio < "$fifo" > "$3" 2>&1 &
    qpid=$!
    # Holding the write end open is what keeps QEMU's stdin from reaching EOF.
    exec 7> "$fifo"
    AUTH_PROMPT_SEEN=0
    AUTH_HALTED=0
    t=0
    while [ "$t" -lt "$PROMPT_WAIT_S" ] && kill -0 "$qpid" 2> /dev/null; do
        if grep -aqF 'Password: ' "$3"; then
            AUTH_PROMPT_SEEN=1
            break
        fi
        sleep 1
        t=$((t + 1))
    done
    if [ "$AUTH_PROMPT_SEEN" = "1" ] && [ -n "$2" ]; then
        sleep 2
        printf '%s\n' "$2" >&7
    fi
    verdict_t=-1
    t=0
    while [ "$t" -lt "$AUTH_TIMEOUT_S" ] && kill -0 "$qpid" 2> /dev/null; do
        if [ "$verdict_t" -lt 0 ] && grep -aqF 'AUTHENTICATION FAILED' "$3"; then
            verdict_t=$t
        fi
        if [ "$verdict_t" -ge 0 ] && [ $((t - verdict_t)) -ge "$HALT_OBSERVE_S" ]; then
            AUTH_HALTED=1
            break
        fi
        sleep 1
        t=$((t + 1))
    done
    exec 7>&-
    kill "$qpid" 2> /dev/null || true
    wait "$qpid" 2> /dev/null || true
    rm -f "$fifo"
    _check_qemu_env "$3"
}

_has() { grep -aqF "$1" "$2"; }

# ⚠ EVERY boot capture asserts it did not panic. Standing rule 38: eight of the
# x86 harness's ten boots never grepped for this, and an init that dies takes
# the kernel with it — the most important negative there is.
_assert_no_panic() {
    if grep -aqE 'Attempted to kill init|Kernel panic' "$1"; then
        echo "  FAIL: [$2] the kernel panicked or init died"
        grep -aE 'Attempted to kill init|Kernel panic' "$1" | head -3 || true
        fail=1
    else
        echo "  OK: [$2] no panic, init stayed alive"
    fi
}

# One property. $1 = what it proves, $2 = an ERE that must match in log $3, and $4 an
# optional ERE whose matching lines are printed when it does not. Serial lines end in
# CR, so a value is bounded with `([^0-9]|$)` rather than anchored with `$` (the same
# trap the x86 harness documents at its seccomp EPERM assertion).
_prop() {
    if grep -aqE "$2" "$3"; then
        echo "  OK: $1"
    else
        echo "  FAIL: $1"
        echo "        no line matching: $2"
        if [ -n "${4:-}" ]; then grep -aE "$4" "$3" | head -4 | sed 's/^/        /' || true; fi
        fail=1
    fi
}

# The mirror: $2 must NOT match in $3.
_prop_absent() {
    if grep -aqE "$2" "$3"; then
        echo "  FAIL: $1"
        grep -aE "$2" "$3" | head -3 | sed 's/^/        /' || true
        fail=1
    else
        echo "  OK: $1"
    fi
}

echo "=== pass 1: aarch64 boot to shutdown (kybernet.harness=1) ==="
OUT1="${CACHE}/a64-boot.log"
_boot 1 "$OUT1"

# ⚠ PHASE 4 IS THE CRITICAL-1 SENTINEL — see the header. Listed first because
# it is the one marker whose absence has a known, specific, catastrophic cause.
for m in \
    "phase 2: console ready" \
    "phase 3: filesystems mounted" \
    "phase 4: signals ready" \
    "phase 6: argonaut ready" \
    "phase 8: services started" \
    "phase 9: harness done"; do
    if _has "$m" "$OUT1"; then
        echo "  OK: $m"
    else
        echo "  FAIL: missing marker — $m"
        [ "$m" = "phase 4: signals ready" ] && \
            echo "        ⚠ phase 4 is the CRITICAL-1 sentinel: signalfd is broken again."
        tail -12 "$OUT1" | sed 's/^/        /' || true
        fail=1
    fi
done

for m in "kybernet: filesystems mounted" "kybernet: loaded config" \
         "kybernet: argonaut initialized" "kybernet: shutdown"; do
    if _has "$m" "$OUT1"; then echo "  OK: $m"; else echo "  FAIL: missing — $m"; fail=1; fi
done

# Cgroup v2 controllers must actually be enabled, not merely attempted — the
# count proves cgroup.subtree_control was written (standing rule 15).
if grep -aqE 'cgroup controllers enabled: [1-9]' "$OUT1"; then
    echo "  OK: cgroup controllers enabled on aarch64"
else
    echo "  FAIL: no cgroup controllers were enabled"
    grep -aiE 'cgroup' "$OUT1" | head -3 || true
    fail=1
fi

if _has "reboot: Power down" "$OUT1"; then
    echo "  OK: the board powered down under its own control"
else
    echo "  FAIL: no clean power down — init did not reach sys_reboot"
    tail -8 "$OUT1" | sed 's/^/        /' || true
    fail=1
fi
_assert_no_panic "$OUT1" "boot"

# ⚠ WAS THIS BOOT REALLY STARVED? An entropy assertion that cannot tell a seeded
# boot from a starved one tests nothing: if a QEMU upgrade started passing a seed
# again, the budget below would pass without the wait ever happening. So require the
# kernel's `crng init done` to come AFTER kybernet's first line.
_crng="$(grep -aE '^\[ *[0-9]+\.[0-9]+\] random: crng init done' "$OUT1" | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
_ph1="$(grep -aE '^\[ *[0-9]+\.[0-9]+\] phase 1:' "$OUT1" | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
if [ -n "$_crng" ] && [ -n "$_ph1" ] && awk -v c="$_crng" -v p="$_ph1" 'BEGIN{exit !(c > p)}'; then
    echo "  OK: PID 1 ran with an unseeded CRNG (seeded at ${_crng}s, after phase 1 at ${_ph1}s)"
else
    echo "  FAIL: the boot was not entropy-starved (crng init at '${_crng:-?}', phase 1 at '${_ph1:-?}')"
    echo "        so nothing below measured the getrandom wait it claims to"
    fail=1
fi

# --- pass 1 services: the x86 fixtures' properties, on aarch64 (1.7.2) --------
# Each assertion mirrors the x86 harness's assertion of the same name. The reasoning
# behind each one lives there; what is new here is that it RUNS on aarch64, where
# the syscall numbers, the seccomp allowlist and the struct layouts differ.
_prop "config: services parsed: 38" \
    'kybernet: config: services parsed: 38([^0-9]|$)' "$OUT1"
# 1.7.8: the config above is padded past the old 16 KiB limit. Check the size kybernet
# itself reports, so a fixture that shrank back under 16 KiB fails here rather than
# proving nothing.
_cfg_bytes="$(grep -aoE 'loaded config: /etc/kybernet/config.json, bytes: [0-9]+' "$OUT1" | head -1 | grep -oE '[0-9]+$' || true)"
if [ -n "$_cfg_bytes" ] && [ "$_cfg_bytes" -gt 16384 ]; then
    echo "  OK: loaded a ${_cfg_bytes}-byte config.json, over the old 16,384-byte limit"
else
    echo "  FAIL: config.json loaded at '${_cfg_bytes:-?}' bytes; this pass needs one over 16,384"
    grep -aE 'config' "$OUT1" | head -4 | sed 's/^/        /' || true
    fail=1
fi
_prop "completed (oneshot): kyb-dep" 'completed \(oneshot\): kyb-dep' "$OUT1"
_prop "completed (oneshot): kyb-svc, after its dependency" 'completed \(oneshot\): kyb-svc' "$OUT1"
_prop "started: kyb-live" 'started: kyb-live' "$OUT1"
# 23, not 24: kyb-prereq-dep is skipped, so no cgroup is ever made for it.
_prop "removed service cgroups: 37 (every started service, torn down, a delegated one's child first)" \
    'kybernet: removed service cgroups: 37([^0-9]|$)' "$OUT1" 'removed service cgroups'

# ⚠ THE LABEL IS THE PLACEMENT CHECK. svc-fixture labels its report with the leaf
# of its OWN cgroup path, so a service whose child-side join failed (standing rule
# 16) reports under the wrong name and every ST[kyb-*] assertion below fails.
_prop "kyb-confined reported from inside its own cgroup" \
    'ST\[kyb-confined\]-CGROUP=/kybernet\.slice/kyb-confined' "$OUT1" 'ST\[|CGROUP'
_prop "kyb-confined dropped every capability (CapEff=0)" \
    'ST\[kyb-confined\]-CapEff=0{16}([^0-9a-f]|$)' "$OUT1" 'ST\[kyb-confined\]-Cap'
_prop "kyb-confined emptied its bounding set (CapBnd=0)" \
    'ST\[kyb-confined\]-CapBnd=0{16}([^0-9a-f]|$)' "$OUT1" 'ST\[kyb-confined\]-Cap'
_prop "kyb-confined has no_new_privs set" 'ST\[kyb-confined\]-NoNewPrivs=1([^0-9]|$)' "$OUT1"
# The control for the limits below: no limits block, so memory.max must read "max".
_prop "kyb-confined, with no limits block, is unlimited (the control)" \
    'ST\[kyb-confined\]-memory\.max=max([^a-z0-9]|$)' "$OUT1" 'ST\[kyb-confined\]-memory'

_prop "kyb-limited memory.max applied (64 MiB)" 'ST\[kyb-limited\]-memory\.max=67108864([^0-9]|$)' "$OUT1" \
    'ST\[kyb-limited\]'
_prop "kyb-limited memory.high applied (48 MiB)" 'ST\[kyb-limited\]-memory\.high=50331648([^0-9]|$)' "$OUT1"
_prop "kyb-limited pids.max applied (32)" 'ST\[kyb-limited\]-pids\.max=32([^0-9]|$)' "$OUT1"
_prop "kyb-limited cpu.weight applied (250)" 'ST\[kyb-limited\]-cpu\.weight=250([^0-9]|$)' "$OUT1"
_prop "kyb-limited cpu.max applied (50000 100000)" 'ST\[kyb-limited\]-cpu\.max=50000 100000([^0-9]|$)' "$OUT1"

# Relayed through /dev/shm: a uid-65534 process cannot open /dev/console.
_prop "kyb-nonroot runs as uid 65534 (real, effective, saved, fs)" \
    'ST\[kyb-nonroot\]-Uid=65534 65534 65534 65534' "$OUT1" 'ST\[kyb-nonroot\]|kyb-nonroot'
_prop "kyb-nonroot runs as gid 65534" 'ST\[kyb-nonroot\]-Gid=65534 65534 65534 65534' "$OUT1"
_prop "kyb-capuid runs as uid 65534" 'ST\[kyb-capuid\]-Uid=65534 65534 65534 65534' "$OUT1" \
    'ST\[kyb-capuid\]|kyb-capuid'
_prop "kyb-capuid kept CAP_NET_BIND_SERVICE across the uid drop (ambient)" \
    'ST\[kyb-capuid\]-CapAmb=0*400([^0-9a-f]|$)' "$OUT1" 'ST\[kyb-capuid\]-Cap'
_prop "kyb-capuid's bounding set is exactly CAP_NET_BIND_SERVICE" \
    'ST\[kyb-capuid\]-CapBnd=0*400([^0-9a-f]|$)' "$OUT1" 'ST\[kyb-capuid\]-Cap'

_n_done=$(grep -acE 'ST\[kyb-(confined|limited|nonroot|capuid)\]-DONE=1' "$OUT1" || true)
if [ "$_n_done" -eq 4 ]; then
    echo "  OK: all four status reports ran to completion"
else
    echo "  FAIL: $_n_done of 4 status reports completed (a report stopped half way, or never ran)"
    fail=1
fi

# environment, env_files and ready_check (1.7.5): the same services and assertions
# as the x86 harness. kyb-env's report comes from inside the child; KYB_OVERRIDDEN
# is in both its `environment` block and its env file, and the file must win.
_prop "environment reached the child (KYB_FROM_CONFIG)" \
    'ST\[kyb-env\]-ENV-KYB_FROM_CONFIG=config value' "$OUT1" 'ST\[kyb-env\]'
_prop "env_files reached the child, quotes stripped (KYB_FROM_FILE)" \
    'ST\[kyb-env\]-ENV-KYB_FROM_FILE=file value' "$OUT1" 'ST\[kyb-env\]'
_prop "an env file overrides environment (KYB_OVERRIDDEN)" \
    'ST\[kyb-env\]-ENV-KYB_OVERRIDDEN=from file' "$OUT1" 'ST\[kyb-env\]'
# env_files are argonaut's to read, at each start (1.10.0). kyb-envgen writes
# kyb-env-late's file at boot, so it did not exist when config.json was read. The other
# two are what moved with the read: each fails the start, and the load accepts it.
_prop "an env file written after config load reached the service that needed it" \
    'ST\[kyb-env-late\]-ENV-KYB_LATE=written at boot' "$OUT1" 'kyb-env-late|kyb-envgen'
_prop "an env file nothing writes fails the start" 'FAILED to start: kyb-env-gone' "$OUT1" 'kyb-env-gone'
_prop_absent "a service with no env file never ran" 'ST\[kyb-env-gone\]' "$OUT1"
_prop "a bad variable name in an env file fails the start" 'FAILED to start: kyb-env-bad' "$OUT1" 'kyb-env-bad'
_prop_absent "a service with a bad env file never ran" 'ST\[kyb-env-bad\]' "$OUT1"
# required_for_modes (1.10.0): this board is `recovery`.
_prop "a service naming this boot's mode ran" 'ST\[kyb-mode-in\]-DONE=1' "$OUT1" 'kyb-mode'
_prop "a service naming another mode was left out, and said so" \
    'not required for this boot mode, not registered: kyb-mode-out' "$OUT1" 'kyb-mode'
_prop_absent "a service naming another mode never started" 'starting: kyb-mode-out|ST\[kyb-mode-out\]' "$OUT1"
_prop "a service whose ready_check passes is started" 'started: kyb-ready-ok' "$OUT1" 'kyb-ready'
_prop "a service whose ready_check cannot pass is failed" 'FAILED to start: kyb-ready-fail' "$OUT1" 'kyb-ready'
# agnos-init (1.7.6): the real binary as a oneshot, and an observer that depends on it
# lstat()ing the result from inside the guest. Owners come from the staged passwd.
_prop "agnos-init ran as a oneshot and exited 0" 'completed \(oneshot\): agnos-init' "$OUT1" 'agnos-init'
# Since 1.12.0 the socket directories are aethersafha's (uid 900), agent-memory is
# daimon's, the two device nodes are granted to video (44) and input (104), and the
# slice is 0711 so a delegated service can walk to its own cgroup.
_prop "agnos-init: /run/agnos/agents, 0755, aethersafha's (900)" \
    'ST\[kyb-agnos-dirs\]-STAT-/run/agnos/agents=dir 0755 900:900' "$OUT1" 'ST\[kyb-agnos-dirs\]'
_prop "agnos-init: /run/agnos/plugins, 0755, aethersafha's (900)" \
    'ST\[kyb-agnos-dirs\]-STAT-/run/agnos/plugins=dir 0755 900:900' "$OUT1"
_prop "agnos-init: /var/lib/agnos/agent-memory, daimon's (900)" \
    'ST\[kyb-agnos-dirs\]-STAT-/var/lib/agnos/agent-memory=dir 0755 900:900' "$OUT1"
_prop "agnos-init: /dev/input/event90 granted to input (104), 0660" \
    'ST\[kyb-agnos-dirs\]-STAT-/dev/input/event90=other 0660 0:104' "$OUT1" 'MKNOD|kyb-agnos-dirs\].*/dev/'
_prop "agnos-init: /dev/fb0 granted to video (44), 0660" \
    'ST\[kyb-agnos-dirs\]-STAT-/dev/fb0=other 0660 0:44' "$OUT1" 'MKNOD|kyb-agnos-dirs\].*/dev/'
_prop "the slice is 0711: a delegated service can walk to its own cgroup" \
    'ST\[kyb-agnos-dirs\]-STAT-/sys/fs/cgroup/kybernet.slice=dir 0711 0:0' "$OUT1"
_prop "agnos-init: /run/user/1000, 0700, uid 1000 with passwd's gid 1001" \
    'ST\[kyb-agnos-dirs\]-STAT-/run/user/1000=dir 0700 1000:1001' "$OUT1"
_prop "agnos-init: /var/lib/agnos/agents owned by agnos (900)" \
    'ST\[kyb-agnos-dirs\]-STAT-/var/lib/agnos/agents=dir 0755 900:900' "$OUT1"
_prop "agnos-init: /var/lib/agnos/models owned by agnos-llm (901)" \
    'ST\[kyb-agnos-dirs\]-STAT-/var/lib/agnos/models=dir 0755 901:901' "$OUT1"
_prop "agnos-init: /var/log/agnos, 0750 root" 'ST\[kyb-agnos-dirs\]-STAT-/var/log/agnos=dir 0750 0:0' "$OUT1"
# Identity (1.12.0), read from inside non-root services and relayed by a root one.
# kyb-grant has aethersafha's identity; kyb-nogrant is the same uid with no groups,
# the control arm. event90 has no driver, so a permitted open is ENXIO (6) after the
# permission check, and a refused one EACCES (13).
_prop "kyb-grant runs as 900 with groups video and input, exactly" 'ST\[kyb-grant\]-Groups=44 104([^0-9]|$)' "$OUT1" \
    'ST\[kyb-(grant|nogrant)\]'
_prop "kyb-grant: uid 900" 'ST\[kyb-grant\]-Uid=900 900 900 900' "$OUT1"
_prop "kyb-grant: no_new_privs" 'ST\[kyb-grant\]-NoNewPrivs=1' "$OUT1"
_prop "kyb-grant passes the permission check on the granted input node" \
    'ST\[kyb-grant\]-OPEN-/dev/input/event90=ERRNO=6([^0-9]|$)' "$OUT1"
_prop "kyb-grant opens past the permission check on /dev/fb0" \
    'ST\[kyb-grant\]-OPEN-/dev/fb0=(OK|ERRNO=([0-9]|1[0-24-9]|[2-9][0-9]))([^0-9]|$)' "$OUT1"
_prop "kyb-nogrant (no groups) is refused the input node" \
    'ST\[kyb-nogrant\]-OPEN-/dev/input/event90=ERRNO=13([^0-9]|$)' "$OUT1"
_prop "kyb-nogrant (no groups) is refused /dev/fb0" 'ST\[kyb-nogrant\]-OPEN-/dev/fb0=ERRNO=13([^0-9]|$)' "$OUT1"
_prop "kyb-deleg's cgroup was delegated" 'cgroup delegated: kyb-deleg' "$OUT1" 'delegat'
_prop "kyb-deleg made a cgroup below its own" 'ST\[kyb-deleg\]-CGD-MKDIR=OK' "$OUT1" 'ST\[kyb-(deleg|nodeleg)\]'
_prop "kyb-deleg moved itself into it" 'ST\[kyb-deleg\]-CGD-MOVE=OK' "$OUT1"
_prop "kyb-deleg now runs below its own cgroup" \
    'ST\[kyb-deleg\]-CGD-NOW=/kybernet.slice/kyb-deleg/kyb-sub' "$OUT1"
_prop "kyb-nodeleg (undelegated) cannot make one" 'ST\[kyb-nodeleg\]-CGD-MKDIR=ERRNO=13([^0-9]|$)' "$OUT1"
_prop "kyb-nodeleg cannot move itself" 'ST\[kyb-nodeleg\]-CGD-MOVE=ERRNO=13([^0-9]|$)' "$OUT1"
_prop "a oneshot whose binary is missing fails to start" 'FAILED to start: kyb-prereq-fail' "$OUT1"
_prop "its dependent is SKIPPED, with the blocker named" \
    'SKIPPED \(prerequisite failed\): kyb-prereq-dep' "$OUT1" 'prereq'
_prop_absent "the skipped dependent never ran" 'ST\[kyb-prereq-dep\]' "$OUT1"

_prop "landlock denied a path outside the rule set" 'LL-OUTSIDE=DENIED' "$OUT1" 'LL-|landlock'
_prop "landlock still permitted a path inside the rule set" 'LL-INSIDE=ALLOWED' "$OUT1" 'LL-'
# ⚠ On aarch64 this probe issued recvfrom, not truncate, from cyrius 6.6.5 until the
# fixture moved to sys_truncate at 1.7.0. This is the first gate to RUN it here.
_prop "landlock denied truncate() outside the rule set" 'LL-TRUNCATE=DENIED' "$OUT1" 'LL-'

# ⚠ THE aarch64 ALLOWLIST IS ITS OWN LIST (standing rule 47), and this is the
# first time it has been exercised by a real service on aarch64.
_prop "the seccomp probe ran under a loaded filter (mode 2)" 'SC\[2\]-MODE=2([^0-9]|$)' "$OUT1" 'SC\['
_prop "seccomp basic DENIED an off-list syscall (mkdirat)" 'SC\[2\]-MKDIRAT=DENIED' "$OUT1" 'SC\[2\]'
_prop "the denial is EPERM (standing rule 28), not a kill and not ENOENT" \
    'SC\[2\]-MKDIRAT_ERRNO=1([^0-9]|$)' "$OUT1" 'MKDIRAT_ERRNO'
_prop "seccomp basic still PERMITS an on-list syscall (getpid)" 'SC\[2\]-GETPID=ALLOWED' "$OUT1" 'SC\[2\]'
_prop "a confined daemon can still sleep 50 ms (ppoll reaches the kernel)" 'SC\[2\]-SLEEP=OK' "$OUT1" 'SLEEP'
_prop "control arm: the same mkdirat succeeds with no filter" 'SC\[0\]-MKDIRAT=ALLOWED' "$OUT1" 'SC\[0\]'
_prop "control arm: 50 ms of sleep is achievable here at all" 'SC\[0\]-SLEEP=OK' "$OUT1" 'SLEEP'

# ⚠ THE BUDGET IS KYBERNET'S OWN SPAN, NOT WALL TIME. Standing rule 37: under
# TCG the emulator and the guest kernel dominate wall clock, and gating on that
# measures the machine rather than the code. The kernel stamps each console line
# with [ seconds.micro ]; the span between kybernet's first and last is the part
# this repo is responsible for.
# ⚠ FIRST IS KYBERNET'S FIRST TIMESTAMPED LINE, NOT THE LOG'S. 1.7.2. This used to
# take the first timestamp in the whole log, which is the kernel's `Booting Linux`
# at 0.000000, so the "kybernet span" was kernel boot plus kybernet all along. It
# looked right while the initramfs was a lone ~500 KB PID 1; staging the service
# fixtures made it ~9 MB, the kernel spent 3 s unpacking it under TCG, and the gate
# blamed kybernet for 4.5 s. kybernet's first kernel-stamped line is its
# `phase 1:` kmsg (klog lines carry no stamp), so the span runs from there.
FIRST="$(grep -aE '^\[ *[0-9]+\.[0-9]+\] phase 1:' "$OUT1" | head -1 | grep -oE '^\[ *[0-9]+\.[0-9]+\]' | tr -d '[] ' || true)"
LAST="$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' "$OUT1" | tail -1 | tr -d '[] ' || true)"
if [ -n "$FIRST" ] && [ -n "$LAST" ]; then
    KYB_MS="$(awk -v a="$FIRST" -v b="$LAST" 'BEGIN{printf "%d", (b-a)*1000}')"
    if [ "$KYB_MS" -le "$KYB_BUDGET_MS" ]; then
        echo "  OK: kybernet span ${KYB_MS}ms (budget ${KYB_BUDGET_MS}ms, TCG-emulated)"
    else
        echo "  FAIL: kybernet span ${KYB_MS}ms exceeds ${KYB_BUDGET_MS}ms"
        echo "        ⚠ suspect the metric before the code (rule 37) — but this"
        echo "        one is already kybernet's own span, not wall time."
        fail=1
    fi
else
    echo "  FAIL: could not read kernel timestamps — cannot compute the budget"
    fail=1
fi

# ⚠ Standing rule 38: independent gates are independent. This pass runs
# unconditionally, NOT inside `if [ $fail -eq 0 ]` — the reactor is the only
# thing that executes an event-loop iteration (rule 23), and guarding it on
# pass 1 would let any single marker failure silently skip it.
echo
echo "=== pass 2: aarch64 reactor (kybernet.harness=loop) ==="
OUT2="${CACHE}/a64-loop.log"
_boot loop "$OUT2"

if _has "phase 9: ready - entering event loop" "$OUT2"; then
    echo "  OK: the reactor started on aarch64"
else
    echo "  FAIL: the reactor never started"
    tail -12 "$OUT2" | sed 's/^/        /' || true
    fail=1
fi

# The wakeup count is the load-bearing assertion: 1.4.1's undrained timerfds
# spun PID 1 at 100% CPU (standing rule 13), which shows up here as a count in
# the thousands rather than tens. Bounded, not exact — it is a real reactor.
WAKES="$(grep -aoE 'reactor wakeups=[0-9]+' "$OUT2" | tail -1 | grep -oE '[0-9]+' || true)"
if [ -z "$WAKES" ]; then
    echo "  FAIL: no reactor wakeup count reported"
    fail=1
elif [ "$WAKES" -ge 1 ] && [ "$WAKES" -le 500 ]; then
    echo "  OK: reactor woke $WAKES times in 5s (bounded 1..500 — it is not spinning)"
else
    echo "  FAIL: reactor wakeups=$WAKES outside 1..500 — a spin or a dead loop"
    fail=1
fi

if _has "phase 9: harness reactor done" "$OUT2"; then
    echo "  OK: the reactor exited cleanly and shut down"
else
    echo "  FAIL: the reactor did not reach an orderly shutdown"
    tail -8 "$OUT2" | sed 's/^/        /' || true
    fail=1
fi
_assert_no_panic "$OUT2" "reactor"

# --- pass 2 services: reactor-driven properties, on aarch64 (1.7.2) -----------
# These live here and not in pass 1 because they only happen inside the event loop
# (standing rules 23 and 41): kybernet.harness=1 stops before the reactor starts.
_prop "crash restart scheduled (not run inline)" 'restart scheduled: kyb-crash' "$OUT2" 'kyb-crash'
_prop "the restart tick performed the relaunch" 'restarted: kyb-crash' "$OUT2" 'kyb-crash'
_prop "PID 1 reaped a child it did not start (orphan)" 'reaped orphans: [1-9]' "$OUT2" 'orphan|reaped'
# The reload path, which no gate ran until 1.9.0: kyb-hup sends SIGHUP twelve times,
# swapping between two configs that differ only in their credential, and a reload's tree
# now lives in a generation that gets reset. Same assertions as x86.
_RELOADS="$(grep -acF 'config reload successful' "$OUT2" || true)"
if [ "${_RELOADS:-0}" -ge 5 ]; then
    echo "  OK: PID 1 reloaded its config ${_RELOADS} times"
else
    echo "  FAIL: expected at least 5 reloads, saw ${_RELOADS:-0}"
    grep -aE 'SIGHUP|reload' "$OUT2" | head -6 | sed 's/^/        /' || true
    fail=1
fi
_COMMITS="$(sed -n 's/.*config reload: generations committed: \([0-9][0-9]*\).*/\1/p' "$OUT2" | tail -1)"
if [ "${_COMMITS:-0}" = "$_RELOADS" ]; then
    echo "  OK: every reload moved to its new generation (${_COMMITS})"
else
    echo "  FAIL: ${_RELOADS} reloads but ${_COMMITS:-0} generation commits; the next one resets a tree in use"
    fail=1
fi
_ROTATED="$(grep -acF 'config reload: emergency credential CHANGED' "$OUT2" || true)"
if [ "${_ROTATED:-0}" -ge 4 ]; then
    echo "  OK: reloads saw the credential change ${_ROTATED} times, the old one read from the previous tree"
else
    echo "  FAIL: the credential changed on ${_ROTATED:-0} reloads; a tree reset too early reads the new record as the old one"
    fail=1
fi
_ARENA="$(sed -n 's/.*config reload: arena bytes in use: \([0-9][0-9]*\).*/\1/p' "$OUT2")"
_A2="$(echo "$_ARENA" | sed -n 2p)"
_AN="$(echo "$_ARENA" | tail -1)"
_AC="$(echo "$_ARENA" | grep -c . || true)"
if [ -n "$_A2" ] && [ "${_AC:-0}" -ge 3 ]; then
    _PER=$(( (_AN - _A2) / (_AC - 2) ))
    if [ "$_PER" -le 8192 ]; then
        echo "  OK: a reload adds ${_PER} bytes to PID 1's arena (ceiling 8192)"
    else
        echo "  FAIL: a reload adds ${_PER} bytes to PID 1's arena, the parse is leaking again"
        fail=1
    fi
else
    echo "  FAIL: no arena figures from the reloads (${_AC:-0} lines)"
    fail=1
fi
# ⚠ ZERO, NOT A CEILING (1.10.0). The figure above spans whatever else the reactor did
# between two reloads. This one is reload_config's own, and past the two reloads that
# build the generations nothing it does may touch an arena that is never reset.
_SPENT="$(sed -n 's/.*config reload: arena bytes spent: \([0-9][0-9]*\).*/\1/p' "$OUT2")"
_SN="$(echo "$_SPENT" | grep -c . || true)"
_SMAX="$(echo "$_SPENT" | tail -n +3 | sort -n | tail -1)"
if [ "${_SN:-0}" -ge 4 ] && [ "${_SMAX:-1}" = "0" ]; then
    echo "  OK: past the first two, $(( _SN - 2 )) reloads spent no arena at all"
else
    echo "  FAIL: a reload spent arena after the generations were built (${_SN:-0} figures, most ${_SMAX:-none}):"
    echo "$_SPENT" | tr '\n' ' ' || true
    echo ""
    fail=1
fi
# A reload reaches argonaut's start timeout, and b's 90 is rejected without disturbing
# what a set: once 120000 is in force no other value may appear (standing rule 25).
_TMOS="$(sed -n 's/.*config: oneshot and forking start timeout (ms): \([0-9][0-9]*\).*/\1/p' "$OUT2")"
_TAFTER="$(echo "$_TMOS" | sed -n '/^120000$/,$p' | sort -u)"
if [ "$_TAFTER" = "120000" ]; then
    echo "  OK: a reload set the start timeout, and a rejected value left it standing"
else
    echo "  FAIL: start timeouts across the reloads: $(echo "$_TMOS" | tr '\n' ' ')"
    fail=1
fi
_prop "the out-of-range start timeout was rejected with its reason" \
    'start_timeout_ms must be an integer in 1000\.\.3600000 - REJECTED' "$OUT2" 'start_timeout|start timeout'
# ⚠ THE LAST EVENT OF EACH KIND SPENDS NOTHING (1.10.1). This arena is never reset and
# these handlers run for the life of the system. A leak spends on every event, so it
# spends on the last one, and lazy setup spends early, so it cannot. Which early event
# pays for it depends on timing: under TCG the first health tick saw no failure, and the
# second paid for the first failure's strings. So nothing here asks when (standing rule
# 36). Each event zeroes its kind's figure, and only the spend reported after the last
# event survives. 16 bytes of it may be an audit action box, new for that event type.
_LASTS="$(awk '
/service exited: / { last["sigchld"] = 0; n["sigchld"] = n["sigchld"] + 1 }
/health check failed: / { last["health tick"] = 0; n["health tick"] = n["health tick"] + 1 }
/restarted: / { last["restart tick"] = 0; n["restart tick"] = n["restart tick"] + 1 }
/reactor: [a-z ]* spent: / { h = $0; sub(/.*reactor: /, "", h); sub(/ spent: .*/, "", h)
    v = $0; sub(/.* spent: /, "", v); last[h] = v + 0 }
END { printf "%d %d %d %d %d %d\n", n["sigchld"], last["sigchld"], n["health tick"], last["health tick"], n["restart tick"], last["restart tick"] }
' "$OUT2")"
read -r _NEX _LEX _NHF _LHF _NRS _LRS <<< "$_LASTS"
if [ "${_NEX:-0}" -ge 3 ] && [ "${_NHF:-0}" -ge 2 ] && [ "${_NRS:-0}" -ge 2 ]; then
    echo "  OK: those handlers had work: ${_NEX} exits, ${_NHF} failed probes, ${_NRS} restarts"
else
    echo "  FAIL: too few events to judge the handlers: ${_NEX} exits, ${_NHF} failed probes, ${_NRS} restarts"
    fail=1
fi
for _p in "exit:$_LEX" "failed probe:$_LHF" "restart:$_LRS"; do
    if [ "${_p##*:}" -le 16 ]; then
        echo "  OK: the last ${_p%%:*} spent ${_p##*:} bytes of PID 1's arena"
    else
        echo "  FAIL: the last ${_p%%:*} spent ${_p##*:} bytes of PID 1's arena, so every one does"
        grep -aE 'reactor: .* spent' "$OUT2" | head -10 | sed 's/^/        /' || true
        fail=1
    fi
done
# A command check runs under its service's confinement (argonaut 1.18.0), through
# kyb_pre_exec. The service only sleeps, so these can come only from its check, and the
# ST label is the check's own cgroup. Same assertions as the x86 reactor gate.
_prop "the command check ran confined, in its service's cgroup: Seccomp" \
    'ST\[kyb-hc-conf\]-Seccomp=2' "$OUT2" 'kyb-hc-conf|pre-exec'
_prop "the command check ran confined: NoNewPrivs" \
    'ST\[kyb-hc-conf\]-NoNewPrivs=1' "$OUT2" 'kyb-hc-conf|pre-exec'
_prop "the command check ran confined: CapEff" \
    'ST\[kyb-hc-conf\]-CapEff=0000000000000000' "$OUT2" 'kyb-hc-conf|pre-exec'
_prop "the command check's report finished" 'ST\[kyb-hc-conf\]-DONE=1' "$OUT2" 'kyb-hc-conf|pre-exec'
if grep -aq 'health check failed: kyb-hc-conf' "$OUT2"; then
    echo "  FAIL: the confined command check failed, so the policy broke the check"
    fail=1
else
    echo "  OK: the confined command check passed"
fi
_prop "the health tick ran and reported a failing check" 'health check failed: kyb-health' "$OUT2" 'health'
# Two services, not one: with one, the probe and the kill both land near the 2 s
# mark and whichever timer epoll reports first wins, which TCG does not order the
# same way twice (standing rule 36). kyb-health's retries 10 keeps its deadline
# outside the window; kyb-wdog's retries 1 gives a 1.2 s deadline.
_prop "the watchdog actually KILLED the unhealthy service (kyb-wdog)" 'watchdog killed: kyb-wdog' "$OUT2" \
    'watchdog|kyb-wdog'

# sd_notify: SO_PASSCRED, the cmsg parse and pid attribution, on aarch64.
_prop "READY promoted a type=notify service from STARTING to RUNNING" \
    'notify: READY - service is now running: kyb-notify' "$OUT2" 'notify'
_ready_n=$(grep -acE 'notify: (READY - service is now running|ready): kyb-notify' "$OUT2" || true)
if [ "$_ready_n" -ge 2 ]; then
    echo "  OK: READY found after a STATUS line (multiline scan)"
else
    echo "  FAIL: only $_ready_n READY seen — the STATUS-then-READY datagram lost its READY"
    fail=1
fi
_prop "WATCHDOG ping accepted and attributed" 'notify: watchdog ping: kyb-notify' "$OUT2" 'notify'
_prop "status text reached the log sanitised (ESC replaced)" 'esc\.\[31mred' "$OUT2" 'notify: status'
_prop "a forged MAINPID (pid 1) was refused on cgroup membership" \
    "notify: MAINPID not in this service's cgroup - REFUSED" "$OUT2" 'MAINPID'
_prop "a malformed MAINPID (-1) was rejected by the bounded parse" \
    'notify: MAINPID malformed - ignored' "$OUT2" 'MAINPID'
_prop "the refused-MAINPID counter recorded the attempts" 'notify: refused-mainpid: [1-9]' "$OUT2"
_prop "no legitimate datagram was rejected" 'notify: rejected: 0([^0-9]|$)' "$OUT2" 'notify: (accepted|rejected)'

# ============================================================================
# pass 3: the edge board, dm-verity verification on aarch64 (1.7.3)
# ============================================================================
# The x86 edge pass's four boots and properties (qemu/boot-test.sh). What is new
# here is the stand-in's own report, so the gate can check what the verifier was
# handed and why it decided, not only what kybernet concluded from its exit code.
echo
echo "=== pass 3: aarch64 edge boot (dm-verity verification, kybernet.harness=1) ==="
OUT3_GOOD="${CACHE}/a64-edge-intact.log"
OUT3_BAD="${CACHE}/a64-edge-corrupt.log"
OUT3_PERM="${CACHE}/a64-edge-permissive.log"
OUT3_OFF="${CACHE}/a64-edge-off.log"
if [ "$A64_EDGE" != "1" ]; then
    echo "  SKIP: veritysetup is not installed (ALLOW_A64_EDGE_SKIP=1)."
    echo "        ⚠ The edge pass executed NOTHING. A skip is not a pass."
elif [ "$XCHECK_OK" != "1" ]; then
    echo "  FAIL: not run. The verifier it depends on disagrees with veritysetup (above),"
    echo "        so its verdicts would grade kybernet against a broken tool."
    fail=1
else
    EDGE_APPEND="console=ttyAMA0 rdinit=/kyb-preinit kybernet.harness=1 panic=1"
    _boot_img "$EDGE_WORK/edge-good.cpio.gz" "$EDGE_APPEND" "$OUT3_GOOD"
    _boot_img "$EDGE_WORK/edge-corrupt.cpio.gz" "$EDGE_APPEND" "$OUT3_BAD"
    _boot_img "$EDGE_WORK/edge-corrupt.cpio.gz" "$EDGE_APPEND kybernet.edge=permissive" "$OUT3_PERM"
    _boot_img "$EDGE_WORK/edge-corrupt.cpio.gz" "$EDGE_APPEND kybernet.edge=off" "$OUT3_OFF"

    # ⚠ THE BOARD MUST HAVE BEEN PREPARED. An empty RAM disk fails verification, so
    # without this every refusal below could pass for the wrong reason.
    _prop "[intact] the pre-init loaded /dev/ram0 and /dev/ram1, then exec'd kybernet" \
        'PREINIT-OK' "$OUT3_GOOD" 'PREINIT'
    _prop "[corrupt] the pre-init loaded the board" 'PREINIT-OK' "$OUT3_BAD" 'PREINIT'
    _prop "[permissive] the pre-init loaded the board" 'PREINIT-OK' "$OUT3_PERM" 'PREINIT'
    _prop "[off] the pre-init loaded the board" 'PREINIT-OK' "$OUT3_OFF" 'PREINIT'
    _assert_no_panic "$OUT3_GOOD" "edge intact"
    _assert_no_panic "$OUT3_BAD" "edge corrupt"
    _assert_no_panic "$OUT3_PERM" "edge permissive"
    _assert_no_panic "$OUT3_OFF" "edge off"

    # 127 or a spawn failure. On aarch64 that is the exec path itself (argonaut's
    # run_safe_cmd_timeout) or the staged fixture, never a verification verdict.
    _prop_absent "[intact] kybernet could exec the verifier" 'veritysetup could not run' "$OUT3_GOOD"

    # 1. The intact image verifies, and the verifier was asked the right question.
    _prop "[intact] the verifier was handed the configured devices and root hash" \
        "VFX-ARGV=verify /dev/ram0 /dev/ram1 ${ROOT_HASH}" "$OUT3_GOOD" 'VFX-'
    _prop "[intact] the verifier walked the whole tree and exited 0" 'VFX-RESULT=0 VERIFIED' "$OUT3_GOOD" 'VFX-'
    _prop "[intact] kybernet: intact image verifies against its root hash" \
        'dm-verity integrity VERIFIED' "$OUT3_GOOD" 'edge boot|verit'
    _prop_absent "[intact] a verified board is not refused" 'refusing to continue boot' "$OUT3_GOOD"
    _prop "[intact] the verified board booted on and powered down under its own control" \
        'reboot: Power down' "$OUT3_GOOD"
    # 1.7.4: a failed boot stage on an edge board must not open an unauthenticated
    # shell. No credential is configured, and the edge sequence's required daimon
    # stage fails here, so phase 7 takes the emergency path on every intact boot.
    # Entering it is asserted first, so a boot that never got there cannot pass.
    _prop "[intact] the failed daimon stage reached the emergency path" \
        '=== ENTERING EMERGENCY MODE ===' "$OUT3_GOOD" 'daimon|boot stage|EMERGENCY'
    _prop "[intact] the edge board required authentication with emergency_require_auth unset" \
        'edge board - authentication required regardless of config' "$OUT3_GOOD" 'emergency shell'
    _prop "[intact] with no credential, the shell was suppressed" \
        'NO credential configured - shell suppressed' "$OUT3_GOOD" 'emergency shell'
    _prop_absent "[intact] no unauthenticated shell was started" 'emergency shell started' "$OUT3_GOOD"

    # 2. The corrupted image is refused. The verifier's own line is the positive
    #    evidence that it failed on the corruption, at the byte the gate wrote, and
    #    not on an empty disk or an unreadable superblock.
    _prop "[corrupt] the verifier failed on the first data block, where the corruption is" \
        'Verification failed at position 0\.' "$OUT3_BAD" 'VFX-|Verification'
    _prop "[corrupt] and exited 2, a block mismatch" 'VFX-RESULT=2 DATA-BLOCK-MISMATCH' "$OUT3_BAD" 'VFX-'
    _prop "[corrupt] kybernet: corrupted image fails verification" \
        'dm-verity verification FAILED' "$OUT3_BAD" 'edge boot|verit'
    _prop "[corrupt] the failed verification refuses the boot" \
        'refusing to continue boot without edge prerequisites' "$OUT3_BAD" 'edge|refus'
    _prop "[corrupt] with no credential configured, no root shell is opened" \
        'NOT opening a root shell' "$OUT3_BAD" 'shell'
    _prop_absent "[corrupt] the refused board did not go on to start services" \
        'phase 8: services started' "$OUT3_BAD"
    _prop "[corrupt] the refused board powered itself off" 'reboot: Power down' "$OUT3_BAD"

    # 3. The escape hatches. An operator locked out by a changed image cannot edit
    #    config on the rootfs that failed to verify, so these are the way back in.
    _prop "[permissive] kybernet.edge=permissive continues past a failed verification" \
        'continuing despite the above' "$OUT3_PERM" 'edge|PERMISSIVE'
    _prop "[permissive] the verification still ran, and still failed" \
        'VFX-RESULT=2 DATA-BLOCK-MISMATCH' "$OUT3_PERM" 'VFX-'
    _prop_absent "[permissive] the refusal was suppressed" 'refusing to continue boot' "$OUT3_PERM"
    _prop "[off] kybernet.edge=off downgrades to permissive on a root_hash-pinned board" \
        'DOWNGRADED to permissive' "$OUT3_OFF" 'edge'
    _prop "[off] the downgraded boot still runs and reports the verification" \
        'dm-verity verification FAILED' "$OUT3_OFF" 'edge|verit'
fi

# ============================================================================
# pass 4: emergency authentication on aarch64 (1.7.3)
# ============================================================================
# The x86 auth passes 4a, 4b and 4c, typed on the aarch64 serial console. Each image
# carries the corrupted data, so phase 6c refuses the boot and drops to the prompt.
# The emergency shell in these images is svc-fixture started as /usr/bin/agnoshi,
# which reports what kybernet handed it and exits.
echo
echo "=== pass 4: aarch64 emergency auth (console prompt, echo suppression, the shell) ==="
if [ "$A64_EDGE" != "1" ]; then
    echo "  SKIP: veritysetup is not installed (ALLOW_A64_EDGE_SKIP=1)."
    echo "        ⚠ The auth passes executed NOTHING, so neither credential format is gated"
    echo "        on aarch64 (standing rule 26). A skip is not a pass."
elif [ "$XCHECK_OK" != "1" ]; then
    echo "  FAIL: not run. The edge refusal that reaches the prompt depends on the verifier"
    echo "        that disagrees with veritysetup (above)."
    fail=1
else
    # A correct-password boot and a wrong-password boot of one image.
    # $1 = image, $2 = label. Leaves the correct-password log in AUTH_LAST_OK.
    _auth_pass() {
        local ok="${CACHE}/a64-$1-correct.log"
        local bad="${CACHE}/a64-$1-wrong.log"

        _auth_boot "$EDGE_WORK/$1.cpio.gz" "hunter2" "$ok"
        _assert_no_panic "$ok" "$2 correct password"
        _prop "[$2] the pre-init loaded the board" 'PREINIT-OK' "$ok" 'PREINIT'
        if grep -aqF 'emergency shell: authenticated' "$ok"; then
            echo "  OK: [$2] the correct password authenticates"
        else
            # A prompt with no verdict is the 1.5.4-1.5.7 brick (rule 20). No prompt at
            # all is a boot that died before phase 6c, which is a different defect.
            if [ "$AUTH_PROMPT_SEEN" = "1" ]; then
                echo "  FAIL: [$2] the prompt appeared, but the correct password did not authenticate"
                echo "        (the 1.5.4-1.5.7 brick shape, see CLAUDE.md rule 20)"
            else
                echo "  FAIL: [$2] the password prompt never appeared within ${PROMPT_WAIT_S}s"
                echo "        (NOT the brick: the boot did not reach phase 6c's prompt)"
            fi
            grep -aiE 'password|authent|credential|edge' "$ok" | head -4 | sed 's/^/        /' || true
            fail=1
        fi
        _prop_absent "[$2] the password did not echo (termios ECHO suppressed)" 'hunter2' "$ok"

        # The shell. Each of these was once wrong, and no gate had ever looked.
        _prop "[$2] the shell's stdin is the console, not /dev/null (1.5.8)" \
            'ST\[emergency-shell\]-FD0=/dev/console' "$ok" 'ST\[emergency-shell\]|emergency shell'
        _prop "[$2] the shell's stdout is the console" 'ST\[emergency-shell\]-FD1=/dev/console' "$ok"
        _prop "[$2] the shell's stderr is the console" 'ST\[emergency-shell\]-FD2=/dev/console' "$ok"
        _prop "[$2] the shell runs with no signal blocked (1.4.2 MEDIUM-4)" \
            'ST\[emergency-shell\]-SigBlk=0{16}([^0-9a-f]|$)' "$ok" 'ST\[emergency-shell\]-Sig'
        _prop "[$2] the shell runs as root" 'ST\[emergency-shell\]-Uid=0 0 0 0' "$ok"
        _prop "[$2] the shell got argonaut's PATH (1.5.8)" \
            'ST\[emergency-shell\]-ENV-PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$ok" 'ST\[emergency-shell\]-ENV'
        _prop "[$2] the shell got TERM" 'ST\[emergency-shell\]-ENV-TERM=linux' "$ok"
        _prop "[$2] the shell got the emergency PS1" 'ST\[emergency-shell\]-ENV-PS1=kybernet-emergency#' "$ok"
        _prop "[$2] the shell's report ran to completion" 'ST\[emergency-shell\]-DONE=1' "$ok"
        # 1.4.2 HIGH-2: the operator gets the shell, and when it exits the refused
        # board powers off. It must never go on to boot the unverified system.
        _prop "[$2] when the shell exits, the refusal stands" \
            'refusing to continue boot without edge prerequisites' "$ok" 'refus|emergency shell'
        _prop_absent "[$2] the refused board did not go on to start services" \
            'phase 8: services started' "$ok"
        _prop "[$2] the refused board powered itself off" 'reboot: Power down' "$ok"

        _auth_boot "$EDGE_WORK/$1.cpio.gz" "wrongpass" "$bad"
        _assert_no_panic "$bad" "$2 wrong password"
        _prop "[$2] a wrong password is rejected" 'AUTHENTICATION FAILED' "$bad" 'password|authent'
        _prop_absent "[$2] the wrong password did not echo" 'wrongpass' "$bad"
        _prop_absent "[$2] no shell after a rejection" 'ST\[emergency-shell\]' "$bad"
        # ⚠ HALTED, ASSERTED POSITIVELY. The x86 pass can only check that no
        # "rebooting" line appeared. Here the VM must still be running
        # HALT_OBSERVE_S seconds after the verdict: with -no-reboot, a reboot or a
        # power-off ends the VM, so a live VM is a halted board.
        if [ "$AUTH_HALTED" = "1" ]; then
            echo "  OK: [$2] the rejection halts: the VM was still up ${HALT_OBSERVE_S}s after the verdict"
        else
            echo "  FAIL: [$2] the VM did not stay up after the rejection. It rebooted, powered"
            echo "        off or died, and a rejection must halt (the loop 1.5.8 fixed)."
            tail -5 "$bad" | sed 's/^/        /' || true
            fail=1
        fi
        _prop_absent "[$2] the rejection does not reboot" 'rebooting|reboot: ' "$bad"
        AUTH_LAST_OK="$ok"
    }

    echo "--- pass 4a: the legacy unsalted SHA-256 credential ---"
    _auth_pass auth-legacy "legacy sha256"
    _prop "[legacy sha256] the boot log names the format as deprecated" \
        'legacy unsalted SHA-256' "$AUTH_LAST_OK" 'credential'

    echo "--- pass 4b: the argon2id v1 credential in emergency.cred (0600) ---"
    _auth_pass auth-kdf "argon2id v1"
    # config.json holds a decoy no password can match, so authenticating at all
    # proves the file won. This line says so directly.
    _prop "[argon2id v1] emergency.cred took precedence over the config key" \
        'emergency.cred present - the emergency_password_hash key is IGNORED' "$AUTH_LAST_OK" \
        'emergency.cred|password_hash'
    _prop "[argon2id v1] the boot log reports the KDF parameters" \
        'argon2id t=[0-9]+ m=[0-9]+KiB p=[0-9]+' "$AUTH_LAST_OK" 'credential|argon'
    if [ -z "$KDF_SALT" ] || [ -z "$KDF_TAG" ]; then
        echo "  FAIL: [argon2id v1] the staged record has no salt or tag, so the leak check cannot run"
        fail=1
    else
        _prop_absent "[argon2id v1] the salt never reaches the console" "$KDF_SALT" "$AUTH_LAST_OK"
        _prop_absent "[argon2id v1] the stored tag never reaches the console" "$KDF_TAG" "$AUTH_LAST_OK"
    fi

    # 4c: the SAME real record in a 0644 emergency.cred and in config.json. The file
    # is refused, and the key must not answer in its place (1.7.1). "Did not
    # authenticate" alone would also pass on a boot that died early, so the
    # suppression line is required as positive evidence that phase 6c decided.
    echo "--- pass 4c: a refused emergency.cred does not fall back to the config key ---"
    OUT4C="${CACHE}/a64-auth-refused.log"
    _auth_boot "$EDGE_WORK/auth-refused.cpio.gz" "hunter2" "$OUT4C"
    _assert_no_panic "$OUT4C" "refused cred"
    _prop "[refused cred] the pre-init loaded the board" 'PREINIT-OK' "$OUT4C" 'PREINIT'
    _prop "[refused cred] the 0644 credential file is refused" \
        'emergency.cred is group/world readable - REFUSED' "$OUT4C" 'emergency.cred|credential'
    _prop "[refused cred] the boot log says the config key is not a fallback" \
        'the emergency_password_hash key is NOT used as a fallback' "$OUT4C" 'emergency.cred|password_hash'
    _prop_absent "[refused cred] the config key did not become the credential" \
        'emergency credential read from config.json' "$OUT4C"
    _prop "[refused cred] phase 6c ran and suppressed the shell" \
        'NOT opening a root shell' "$OUT4C" 'edge refusal|emergency|phase 6c'
    _prop_absent "[refused cred] the correct password did not authenticate via the config key" \
        'emergency shell: authenticated' "$OUT4C"
fi

# ============================================================================
# pass 5: the quiet boot, log_to_console=false (1.7.3)
# ============================================================================
# pass 1's image with one key changed. ⚠ "kybernet printed nothing" is also what a
# board that died before phase 1 looks like, so the pass needs positive evidence
# too: a line a SERVICE wrote to the console, which only a boot that got through
# phase 8 can produce. klog lines start with "kybernet: "; kmsg lines carry a
# kernel timestamp and are not kybernet's console output.
echo
echo "=== pass 5: aarch64 quiet boot (log_to_console=false) ==="
OUT5="${CACHE}/a64-quiet.log"
_boot_img "$QCPIO" "console=ttyAMA0 kybernet.harness=1 panic=1" "$OUT5"
_assert_no_panic "$OUT5" "quiet"
QN="$(grep -acE '^kybernet: ' "$OUT5" || true)"
LOUD_N="$(grep -acE '^kybernet: ' "$OUT1" || true)"
# Everything up to and including the announcement that console logging goes off
# may survive. The ceiling is the x86 pass's; pass 1 is the control.
if [ "$LOUD_N" -le 20 ]; then
    echo "  FAIL: pass 1, the same image with logging on, printed only $LOUD_N kybernet lines,"
    echo "        so a low count here would prove nothing"
    fail=1
elif [ "$QN" -le 10 ]; then
    echo "  OK: log_to_console=false suppressed kybernet's console output ($QN lines, $LOUD_N with it on)"
else
    echo "  FAIL: log_to_console=false did not suppress ($QN kybernet lines, $LOUD_N with it on)"
    grep -aE '^kybernet: ' "$OUT5" | head -5 | sed 's/^/        /' || true
    fail=1
fi
_prop "services still reached the console (the boot was quiet, not dead)" \
    'ST\[kyb-limited\]-memory\.max=67108864([^0-9]|$)' "$OUT5" 'ST\['
_prop "the switch to quiet is announced on the console" 'console logging OFF' "$OUT5"
_prop "the quiet boot powered down under its own control" 'reboot: Power down' "$OUT5"

# ============================================================================
# pass 6: start_timeout_ms reaches argonaut's wait (1.10.0)
# ============================================================================
# Rule 27: the key reaches a kill. A oneshot that sleeps for ten minutes either fails at
# two seconds, or the key did nothing and this boot never reaches `FAILED to start`.
# kyb-start-fast is the control, and a dependent of a failed service is not started.
echo
echo "=== pass 6: aarch64 start timeout (start_timeout_ms) ==="
OUT6="${CACHE}/a64-slow.log"
_boot_img "$SCPIO" "console=ttyAMA0 kybernet.harness=1 panic=1" "$OUT6"
_assert_no_panic "$OUT6" "start timeout"
_prop "the key reached argonaut" 'config: oneshot and forking start timeout \(ms\): 2000' "$OUT6" 'start timeout|kyb-start'
_prop "the control finished under the timeout" 'completed \(oneshot\): kyb-start-fast' "$OUT6" 'kyb-start'
_prop "a oneshot past the timeout was killed and failed" 'FAILED to start: kyb-start-slow' "$OUT6" 'kyb-start'
_prop "its dependent was not started" 'SKIPPED \(prerequisite failed\): kyb-start-after' "$OUT6" 'kyb-start'
_prop "the board powered down under its own control" 'reboot: Power down' "$OUT6"

# ============================================================================
# pass 7: the TPM board (1.11.1)
# ============================================================================
# The x86 harness's TPM board gate, on aarch64: attestation, the verified root
# opened and mounted read-only, PCR 15 measured, the LUKS2 token unsealed and the
# PCR capped, a swapped root and an unverified one refused, and a corrupted block
# read as EIO. The same five boots and the same properties.
#
# ⚠ IT BOOTS A DIFFERENT KERNEL FROM PASSES 1-6, AND FIRMWARE. Neither Alpine aarch64
# kernel builds a TPM TIS driver, so no QEMU TPM can appear on that board. This pass
# boots Debian's cloud kernel through Debian's AAVMF, both pinned with every other
# input in qemu/tpm-board-aarch64.pins. Firmware is not optional: PCR 7 is what
# firmware measures, and a kernel QEMU starts directly leaves it all-zero, which
# kybernet reads as an unread PCR, never as a match.
#
# The board's tools are Debian's arm64 builds, and the shared-library closure staged
# with them is computed on every run from the binaries themselves, because an x86 host
# cannot run aarch64 ldd. Its disks are virtio-blk, loaded by the pre-init with the
# device-mapper modules, so it needs no RAM disks.
#
# Host side, as on x86: swtpm, systemd-cryptenroll for the token with the tpm2-tss
# libraries it dlopen()s (tpm2-tools brings them), cryptsetup and veritysetup to format
# the disks, e2fsprogs, plus depmod, dpkg-deb and python3 to unpack the pinned packages. A missing one fails this pass with its name, and
# ALLOW_A64_TPM_SKIP=1 acknowledges that it did not run. The other passes run either
# way (standing rule 38).
echo
echo "=== pass 7: aarch64 TPM board (swtpm, UEFI, PCR 15, a sealed LUKS2 token, dm-verity open) ==="
TPM_PINS="${SCRIPT_DIR}/tpm-board-aarch64.pins"
TPM_A64="${CACHE}/tpm-a64"
TPM_TIMEOUT_S="${A64_TPM_TIMEOUT_S:-240}"
TPM_WHY=""
# A reason this pass cannot run that is the environment's, not kybernet's.
_tpm_env() {
    if [ "${ALLOW_A64_TPM_SKIP:-0}" = "1" ]; then
        echo "  SKIP: $1 (ALLOW_A64_TPM_SKIP=1)."
        echo "        ⚠ The TPM board executed NOTHING. A skip is not a pass."
    else
        echo "  FAIL: [env] $1. An environment failure, not a kybernet defect."
        echo "        Install it, or set ALLOW_A64_TPM_SKIP=1 to acknowledge this pass did not run."
        fail=1
    fi
}

# Fetch, check and unpack every pinned input. Sets TPM_KERNEL, TPM_CODE, TPM_VARS,
# TPM_KMOD and TPM_SYSROOT, or TPM_WHY and returns 1 (2 for an environment failure).
_tpm_a64_inputs() {
    local base sum path f got krel
    local -a pinned=()
    base="$(awk '$1 == "base" {print $2}' "$TPM_PINS")"
    case "$base" in
        https://snapshot.debian.org/archive/debian/[0-9]*T[0-9]*Z) ;;
        *)
            TPM_WHY="the pins' base is not a snapshot.debian.org timestamp (${base:-none}): any other URL can move"
            return 1
            ;;
    esac
    mkdir -p "${TPM_A64}/debs"
    while read -r sum path; do
        case "$sum" in '' | '#'* | base) continue ;; esac
        f="${TPM_A64}/debs/${path##*/}"
        pinned+=("$f")
        if [ -f "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$sum" ]; then continue; fi
        rm -f "$f"
        # ⚠ snapshot.debian.org THROTTLES A BURST (1.12.0). Fetching all 60 files back to
        # back, a replay of CI got HTTP 503 on seven straight tries of one file, and once lost
        # its resolver for longer than three retries' backoff. So a fetch waits a second
        # after the one before it, and retries 8 times: curl backs off 1, 2, 4 s..., about
        # four minutes, and only while it is failing. CI caches these files on the pins'
        # hash, so it fetches only when a pin changes.
        if [ "${_tpm_fetched:-0}" = 1 ]; then sleep 1; fi
        _tpm_fetched=1
        if ! curl -sSf -L --retry 8 -o "$f.tmp" "${base}/${path}"; then
            rm -f "$f.tmp"
            TPM_WHY="could not fetch ${base}/${path}"
            return 2
        fi
        got="$(sha256sum "$f.tmp" | cut -d' ' -f1)"
        if [ "$got" != "$sum" ]; then
            rm -f "$f.tmp"
            TPM_WHY="checksum mismatch on ${path##*/}: pinned ${sum}, got ${got}"
            return 1
        fi
        mv "$f.tmp" "$f"
    done < "$TPM_PINS"

    rm -rf "${TPM_A64}/kernel" "${TPM_A64}/fw" "${TPM_A64}/sysroot"
    mkdir -p "${TPM_A64}/kernel" "${TPM_A64}/fw" "${TPM_A64}/sysroot"
    # Only what the pins name: the cache keeps an older snapshot's files after a move.
    for f in "${pinned[@]}"; do
        case "${f##*/}" in
            linux-image-*) dpkg-deb -x "$f" "${TPM_A64}/kernel" ;;
            qemu-efi-aarch64_*) dpkg-deb -x "$f" "${TPM_A64}/fw" ;;
            *) dpkg-deb -x "$f" "${TPM_A64}/sysroot" ;;
        esac || { TPM_WHY="dpkg-deb could not unpack ${f##*/}"; return 1; }
    done
    TPM_KERNEL="$(ls "${TPM_A64}"/kernel/boot/vmlinuz-* 2> /dev/null | head -1 || true)"
    krel="${TPM_KERNEL##*/vmlinuz-}"
    TPM_KMOD="${TPM_A64}/kernel/usr/lib/modules/${krel}"
    TPM_CODE="${TPM_A64}/fw/usr/share/AAVMF/AAVMF_CODE.secboot.fd"
    TPM_VARS="${TPM_A64}/fw/usr/share/AAVMF/AAVMF_VARS.fd"
    TPM_SYSROOT="${TPM_A64}/sysroot"
    [ -n "$TPM_KERNEL" ] && [ -d "$TPM_KMOD" ] || { TPM_WHY="the kernel package holds no vmlinuz and modules"; return 1; }
    [ -f "$TPM_CODE" ] && [ -f "$TPM_VARS" ] || { TPM_WHY="the firmware package holds no AAVMF secboot image"; return 1; }
    # Debian generates modules.dep at install time, so it is not in the package. depmod
    # reads either arch's modules; which base it wants depends on how kmod was built.
    depmod -b "${TPM_A64}/kernel/usr" "$krel" 2> /dev/null || depmod -b "${TPM_A64}/kernel" "$krel" 2> /dev/null || true
    [ -s "${TPM_KMOD}/modules.dep" ] || { TPM_WHY="depmod wrote no modules.dep for ${krel}"; return 1; }
    return 0
}

# The shared-library closure of $2..., relative paths under the sysroot $1: each root
# as given, each DT_NEEDED at the path the loader would take it from, and PT_INTERP.
# "MISSING <soname>" for anything the sysroot cannot supply.
_tpm_a64_closure() {
    python3 -I - "$@" << 'CLOSUREPY'
import os, struct, sys
root, todo = sys.argv[1], list(sys.argv[2:])
dirs = ['usr/lib/aarch64-linux-gnu', 'usr/lib', 'usr/lib/aarch64-linux-gnu/systemd']
def elf(rel):
    d = open(os.path.join(root, rel), 'rb').read()
    if d[:4] != b'\x7fELF' or d[4] != 2 or d[5] != 1 or struct.unpack_from('<H', d, 18)[0] != 183:
        sys.exit('not an aarch64 ELF: ' + rel)
    phoff, = struct.unpack_from('<Q', d, 32)
    phentsize, phnum = struct.unpack_from('<HH', d, 54)
    loads, dyn, out = [], None, []
    for i in range(phnum):
        t, _, off, va, _, sz = struct.unpack_from('<IIQQQQ', d, phoff + i * phentsize)
        if t == 1: loads.append((va, off, sz))
        if t == 2: dyn = (off, sz)
        if t == 3: out.append(('interp', d[off:off + sz].rstrip(b'\0').decode()))
    if dyn is None: return out
    def at(va):
        for v, o, s in loads:
            if v <= va < v + s: return va - v + o
    ents, strtab = [], 0
    for i in range(dyn[1] // 16):
        tag, val = struct.unpack_from('<qQ', d, dyn[0] + i * 16)
        if tag == 0: break
        if tag == 5: strtab = at(val)
        ents.append((tag, val))
    for tag, val in ents:
        if tag in (1, 15, 29):
            s = d[strtab + val:d.index(b'\0', strtab + val)].decode()
            out.append(('needed' if tag == 1 else 'path', s))
    return out
seen, missing = [], set()
while todo:
    rel = todo.pop(0)
    if rel in seen: continue
    seen.append(rel)
    ents = elf(rel)
    extra = [p.lstrip('/') for k, v in ents if k == 'path' for p in v.split(':') if '$' not in p]
    for k, v in ents:
        if k == 'interp':
            todo.append('usr/' + v.lstrip('/') if v.startswith('/lib/') else v.lstrip('/'))
        elif k == 'needed':
            hit = [os.path.join(dd, v) for dd in extra + dirs if os.path.exists(os.path.join(root, dd, v))]
            if hit: todo.append(hit[0])
            else: missing.add(v)
for s in seen: print(s)
for m in sorted(missing): print('MISSING ' + m)
CLOSUREPY
}

# A module and, first, every module modules.dep says it needs, into the stage's list.
_tpm_a64_module() {
    local name="$1" line rel dep
    line="$(grep -E "(^|/)${name}\.ko(\.[a-z]+)?:" "${TPM_KMOD}/modules.dep" | head -1 || true)"
    if [ -z "$line" ]; then
        grep -qE "(^|/)${name}\.ko" "${TPM_KMOD}/modules.builtin" 2> /dev/null && return 0
        TPM_WHY="the kernel has no ${name} module"
        return 1
    fi
    rel="${line%%:*}"
    for dep in ${line#*:}; do
        _tpm_a64_module "$(basename "$dep" | sed 's/\.ko.*//')" || return 1
    done
    grep -qx "/kyb-board/m/${rel##*/}" "${TPM_STAGE}/kyb-board/modules" && return 0
    cp "${TPM_KMOD}/${rel}" "${TPM_STAGE}/kyb-board/m/" || return 1
    echo "/kyb-board/m/${rel##*/}" >> "${TPM_STAGE}/kyb-board/modules"
}

# One ext4 root for dm-verity: two files in two blocks, so a corruption in one leaves
# the other readable (the x86 board's roots, qemu/build-initramfs.sh).
_tpm_a64_root() {
    rm -rf "$1"
    mkdir -p "$1"
    echo "$3" > "$1/hello.txt"
    echo "KYB-SECOND-BLOCK" > "$1/other.txt"
    mkfs.ext4 -q -F -b 4096 -O ^has_journal -E root_owner=0:0 -d "$1" "$2" 4M
}

# The stage and the disks. Sets TPM_STAGE and TPM_DISKS, or TPM_WHY and returns 1.
_tpm_a64_board() {
    local p lst blk i
    TPM_STAGE="${TPM_A64}/stage"
    TPM_DISKS="${TPM_A64}/disks"
    rm -rf "$TPM_STAGE" "$TPM_DISKS"
    mkdir -p "$TPM_STAGE"/{sbin,dev,proc,sys,run,tmp,etc/kybernet,usr/bin,usr/sbin,usr/lib,var/log,kyb-board/m} "$TPM_DISKS"
    # Debian's binaries name /lib/ld-linux-aarch64.so.1, and trixie ships only /usr/lib.
    ln -s usr/lib "$TPM_STAGE/lib"
    cp "$BIN" "$TPM_STAGE/sbin/init"
    cp "${FIX_DIR}/kyb-preinit-fixture" "$TPM_STAGE/kyb-preinit"
    cp "${FIX_DIR}/kyb-svc-fixture" "$TPM_STAGE/usr/bin/kyb-svc-fixture"
    chmod 755 "$TPM_STAGE/sbin/init" "$TPM_STAGE/kyb-preinit" "$TPM_STAGE/usr/bin/kyb-svc-fixture"
    lst="${TPM_A64}/closure.txt"
    # The token plugin dlopen()s tpm2-tss, and glibc dlopen()s libgcc_s, so no
    # DT_NEEDED walk finds them: they are roots.
    if ! _tpm_a64_closure "$TPM_SYSROOT" usr/sbin/cryptsetup usr/sbin/veritysetup usr/bin/tpm2 \
        usr/lib/aarch64-linux-gnu/cryptsetup/libcryptsetup-token-systemd-tpm2.so \
        usr/lib/aarch64-linux-gnu/libtss2-esys.so.0 usr/lib/aarch64-linux-gnu/libtss2-rc.so.0 \
        usr/lib/aarch64-linux-gnu/libtss2-mu.so.0 usr/lib/aarch64-linux-gnu/libtss2-tctildr.so.0 \
        usr/lib/aarch64-linux-gnu/libtss2-tcti-device.so.0 usr/lib/aarch64-linux-gnu/libgcc_s.so.1 \
        > "$lst" 2>&1; then
        TPM_WHY="the library closure could not be computed: $(tail -1 "$lst" 2> /dev/null || true)"
        return 1
    fi
    if grep -q '^MISSING ' "$lst"; then
        TPM_WHY="the pinned packages lack $(grep '^MISSING ' "$lst" | cut -d' ' -f2 | tr '\n' ' ')"
        return 1
    fi
    while read -r p; do
        mkdir -p "$TPM_STAGE/$(dirname "$p")"
        cp -L "$TPM_SYSROOT/$p" "$TPM_STAGE/$p" || { TPM_WHY="cannot stage $p"; return 1; }
    done < "$lst"
    # sigil reads PCRs through this exact path. tpm2 is a multi-call binary that
    # dispatches on its argv[0], as the x86 board's copies of the host's tools do.
    cp -L "$TPM_SYSROOT/usr/bin/tpm2" "$TPM_STAGE/usr/bin/tpm2_pcrread"
    cp -L "$TPM_SYSROOT/usr/bin/tpm2" "$TPM_STAGE/usr/bin/tpm2_pcrextend"
    : > "$TPM_STAGE/kyb-board/modules"
    # xts is loaded by name: dm-crypt asks the crypto API for xts(aes), which would
    # need a modprobe, and modules.dep does not list it.
    for p in tpm_tis virtio_blk xts dm-crypt dm-verity; do
        _tpm_a64_module "$p" || return 1
    done

    # Two roots with valid hash trees: the board's own, and an attacker's.
    _tpm_a64_root "${TPM_DISKS}/tree" "${TPM_DISKS}/data.img" "KYB-VERIFIED-ROOT" || { TPM_WHY="mkfs.ext4 failed"; return 1; }
    _tpm_a64_root "${TPM_DISKS}/tree2" "${TPM_DISKS}/data2.img" "KYB-SWAPPED-ROOT" || { TPM_WHY="mkfs.ext4 failed"; return 1; }
    for i in "" 2; do
        truncate -s 1M "${TPM_DISKS}/hash${i}.img"
        veritysetup format "${TPM_DISKS}/data${i}.img" "${TPM_DISKS}/hash${i}.img" 2> /dev/null \
            | awk '/Root hash/{print $3}' > "${TPM_DISKS}/root_hash${i}.txt" || true
        [ "$(wc -c < "${TPM_DISKS}/root_hash${i}.txt")" -eq 65 ] || { TPM_WHY="veritysetup format failed"; return 1; }
    done
    # The board's root with hello.txt's block overwritten.
    blk="$(debugfs -R "blocks /hello.txt" "${TPM_DISKS}/data.img" 2> /dev/null | awk '{print $1}' || true)"
    [ -n "$blk" ] || { TPM_WHY="debugfs found no block for hello.txt"; return 1; }
    cp "${TPM_DISKS}/data.img" "${TPM_DISKS}/data-corrupt.img"
    printf 'KYB-CORRUPTED-BLOCK' | dd of="${TPM_DISKS}/data-corrupt.img" bs=1 seek=$((blk * 4096)) conv=notrunc status=none
    rm -rf "${TPM_DISKS}/tree" "${TPM_DISKS}/tree2"
    echo "  staged: $(wc -l < "$lst") files of the closure, $(wc -l < "$TPM_STAGE/kyb-board/modules") modules, kernel ${TPM_KERNEL##*/vmlinuz-}"
    return 0
}

TPM_A64_RUN=0
_tpm_missing=""
for t in swtpm swtpm_setup systemd-cryptenroll cryptsetup veritysetup mkfs.ext4 debugfs depmod dpkg-deb python3 curl; do
    command -v "$t" > /dev/null 2>&1 || _tpm_missing="${_tpm_missing} ${t}"
done
if [ -n "$_tpm_missing" ]; then
    _tpm_env "the host lacks${_tpm_missing}"
else
    _tpm_rc=0
    _tpm_a64_inputs || _tpm_rc=$?
    if [ "$_tpm_rc" = 2 ]; then
        _tpm_env "$TPM_WHY"
    elif [ "$_tpm_rc" != 0 ]; then
        echo "  FAIL: the pinned inputs are unusable: ${TPM_WHY}"
        fail=1
    elif ! _tpm_a64_board; then
        echo "  FAIL: the TPM board could not be staged: ${TPM_WHY}"
        fail=1
    else
        TPM_A64_RUN=1
    fi
fi

if [ "$TPM_A64_RUN" = 1 ]; then
    TW="$(mktemp -d /tmp/kybernet-tpm.XXXXXX)"
    _hexbin() { printf "$(printf '%s' "$1" | sed 's/../\\x&/g')"; }
    # SHA-256 of the bytes a hex string encodes, and a PCR extend: SHA-256(old || digest).
    _sha_hex() { _hexbin "$1" | sha256sum | cut -c1-64; }
    _extend() { { _hexbin "$1"; _hexbin "$2"; } | sha256sum | cut -c1-64; }
    _lower() { tr 'A-F' 'a-f'; }
    # $1 label, $2 a fixed string that must be in log $3.
    _tpm_has() {
        if grep -aqF "$2" "$3"; then
            echo "  OK: [$1] $2"
        else
            echo "  FAIL: [$1] missing: $2"
            grep -aE 'edge boot|PREINIT|READ-|FAILED|REFUSED|ST\[' "$3" | head -12 | sed 's/^/        /' || true
            fail=1
        fi
    }
    _tpm_lacks() {
        if grep -aqF "$2" "$3"; then
            echo "  FAIL: [$1] present: $2"
            fail=1
        else
            echo "  OK: [$1] absent: $2"
        fi
    }
    _tpm_unpacked() {
        if grep -aqF "Initramfs unpacking failed" "$2"; then
            echo "  FAIL: [$1] the kernel could not unpack the board's initrd, so its config never landed"
            fail=1
        fi
    }
    # A boot's initrd: the stage with this boot's config, as one archive (the x86
    # pass says why it is never an appended overlay).
    _tpm_initrd() {
        cp "$1" "$TPM_STAGE/etc/kybernet/config.json"
        ( cd "$TPM_STAGE" && find . | cpio -o -H newc 2> /dev/null | gzip -1 ) > "${TW}/boot.cpio.gz"
    }
    # One boot on the swtpm, through the firmware. $1 data image, $2 hash image, $3 log.
    # 1 GiB, as on x86: the board unpacks to ~40 MB of glibc tools.
    _tpm_boot() {
        rm -f "${TW}/q.ctrl" "${TW}/swtpm.pid"
        swtpm socket --tpm2 --tpmstate "dir=${TW}/state" --ctrl "type=unixio,path=${TW}/q.ctrl" \
            --terminate --daemon --pid "file=${TW}/swtpm.pid" > "${TW}/swtpm.log" 2>&1 || true
        local i=0
        while [ ! -S "${TW}/q.ctrl" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
        if [ ! -S "${TW}/q.ctrl" ]; then
            echo "  FAIL: [env] swtpm did not start, so this boot has no TPM:"
            tail -3 "${TW}/swtpm.log" 2> /dev/null | sed 's/^/        /' || true
            fail=1
        fi
        # A fresh variable store per boot, so the firmware measures the same PCR 7 every time.
        cp "$TPM_VARS" "${TW}/vars.fd"
        timeout "$TPM_TIMEOUT_S" qemu-system-aarch64 \
            -M virt -cpu cortex-a57 -m 1024M -smp 1 -nic none \
            -drive "if=pflash,format=raw,readonly=on,file=${TPM_CODE}" \
            -drive "if=pflash,format=raw,file=${TW}/vars.fd" \
            -chardev "socket,id=chrtpm,path=${TW}/q.ctrl" -tpmdev emulator,id=tpm0,chardev=chrtpm \
            -device tpm-tis-device,tpmdev=tpm0 \
            -drive "if=none,id=d0,file=$1,format=raw" -device virtio-blk-pci,drive=d0 \
            -drive "if=none,id=d1,file=$2,format=raw" -device virtio-blk-pci,drive=d1 \
            -drive "if=none,id=d2,file=${TW}/luks.img,format=raw" -device virtio-blk-pci,drive=d2 \
            -kernel "$TPM_KERNEL" -initrd "${TW}/boot.cpio.gz" \
            -append "console=ttyAMA0 rdinit=/kyb-preinit kybernet.harness=1 panic=1" \
            -nographic -no-reboot -serial mon:stdio < /dev/null > "$3" 2>&1 || true
        if [ -f "${TW}/swtpm.pid" ]; then kill "$(cat "${TW}/swtpm.pid")" 2> /dev/null || true; fi
        _check_qemu_env "$3"
    }
    # $1 file, $2 root hash, $3 readonly, $4 luks, $5 extra edge keys, $6 services
    _tpm_cfg() {
        cat > "$1" << TPMCFG
{
  "boot_mode": "edge",
  "verify_boot": true,
  "shutdown_timeout_ms": 400,
  "edge": {
    "readonly_rootfs": $3,
    "luks_enabled": $4,
    "max_boot_ms": 60000,
    "root_device": "/dev/vda",
    "hash_device": "/dev/vdb",
    "luks_device": "/dev/vdc",
    "root_hash": "$2"$5
  },
  "services": [$6
  ]
}
TPMCFG
    }
    _svc() { printf '\n    { "name": "%s", "binary": "%s", "args": [%s], "type": "oneshot", "restart": "never" }%s' "$1" "$2" "$3" "$4"; }
    FX=/usr/bin/kyb-svc-fixture
    CS=/usr/sbin/cryptsetup
    RH="$(cat "${TPM_DISKS}/root_hash.txt")"
    RH2="$(cat "${TPM_DISKS}/root_hash2.txt")"
    _tpm_ok=1
    mkdir -p "${TW}/state"
    swtpm_setup --tpm2 --tpmstate "${TW}/state" > "${TW}/setup.log" 2>&1 || _tpm_ok=0
    truncate -s 32M "${TW}/luks.img"
    printf 'kyb-bootstrap' > "${TW}/pw"
    chmod 600 "${TW}/pw"
    cryptsetup luksFormat --type luks2 --batch-mode --key-file "${TW}/pw" --pbkdf pbkdf2 \
        --pbkdf-force-iterations 1000 "${TW}/luks.img" > "${TW}/luks.log" 2>&1 || _tpm_ok=0
    if [ "$_tpm_ok" != 1 ]; then
        echo "  FAIL: the TPM board could not be prepared: swtpm_setup or luksFormat failed"
        cat "${TW}/setup.log" "${TW}/luks.log" 2> /dev/null | tail -4 | sed 's/^/        /' || true
        fail=1
    else
        # 1. Read the firmware's PCR 7, which the token is sealed to.
        T1="${CACHE}/a64-tpm-measure.log"
        _tpm_cfg "${TW}/c.json" "$RH" true false "" "$(_svc kyb-pcr7 "$FX" '"read", "/sys/class/tpm/tpm0/pcr-sha256/7"' '')"
        _tpm_initrd "${TW}/c.json"
        _tpm_boot "${TPM_DISKS}/data.img" "${TPM_DISKS}/hash.img" "$T1"
        _assert_no_panic "$T1" "tpm measure"
        _tpm_unpacked "tpm measure" "$T1"
        _tpm_has "tpm measure" "PREINIT-OK" "$T1"
        _tpm_has "tpm measure" "edge boot: TPM detected" "$T1"
        P7="$(sed -n 's/.*READ-\/sys\/class\/tpm\/tpm0\/pcr-sha256\/7=\([0-9A-Fa-f]\{64\}\).*/\1/p' "$T1" | head -1 | _lower)"
        Z="$(printf '0%.0s' $(seq 1 64))"
        if [ -z "$P7" ] || [ "$P7" = "$Z" ]; then
            echo "  FAIL: [tpm measure] no PCR 7 from the firmware (read '${P7}'), so nothing can be enrolled"
            fail=1
        else
            echo "  OK: [tpm measure] the firmware's PCR 7: ${P7}"
            MEAS="$(_sha_hex "$RH")"
            P15="$(_extend "$Z" "$MEAS")"
            CAP="$(printf '%s' "kybernet: data volume unlocked" | sha256sum | cut -c1-64)"
            P15CAP="$(_extend "$P15" "$CAP")"
            # 2. Enrol the token on the host, to PCR 7 + the PCR 15 this root measures.
            rm -f "${TW}/e.sock" "${TW}/e.sock.ctrl" "${TW}/e.pid"
            swtpm socket --tpm2 --tpmstate "dir=${TW}/state" --server "type=unixio,path=${TW}/e.sock" \
                --ctrl "type=unixio,path=${TW}/e.sock.ctrl" --flags startup-clear --daemon \
                --pid "file=${TW}/e.pid" > "${TW}/swtpm-e.log" 2>&1 || true
            i=0
            while [ ! -S "${TW}/e.sock" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
            ENR="$(systemd-cryptenroll "--tpm2-device=swtpm:path=${TW}/e.sock" "--unlock-key-file=${TW}/pw" \
                "--tpm2-pcrs=7:sha256=${P7}+15:sha256=${P15}" "${TW}/luks.img" 2>&1 || true)"
            if [ -f "${TW}/e.pid" ]; then kill "$(cat "${TW}/e.pid")" 2> /dev/null || true; fi
            sleep 0.3
            if grep -aqF "New TPM2 token enrolled" <<< "$ENR"; then
                echo "  OK: [tpm enrol] New TPM2 token enrolled"
            else
                echo "  FAIL: [tpm enrol] systemd-cryptenroll enrolled no token (the host side, not kybernet):"
                { echo "$ENR"; cat "${TW}/swtpm-e.log" 2> /dev/null; } | tail -4 | sed 's/^/        /' || true
                fail=1
            fi

            # 3. The board's own root.
            T2="${CACHE}/a64-tpm-board.log"
            SV="$(_svc kyb-read-root "$FX" '"read", "/verified/hello.txt"' ',')"
            SV="${SV}$(_svc kyb-ro-write "$FX" '"write", "/verified/kyb-write", "x"' ',')"
            SV="${SV}$(_svc kyb-pcr15 "$FX" '"read", "/sys/class/tpm/tpm0/pcr-sha256/15"' ',')"
            SV="${SV}$(_svc kyb-mapper "$FX" '"stat", "/dev/mapper/agnos-data", "/dev/mapper/verified-root"' ',')"
            SV="${SV}$(_svc kyb-cap-check "$CS" '"open", "--test-passphrase", "--type", "luks2", "--token-only", "--token-id", "0", "--tries", "1", "--", "/dev/vdc"' '')"
            _tpm_cfg "${TW}/c.json" "$RH" true true ", \"tpm_attestation\": true, \"pcr_bindings\": \"7\", \"expected_pcrs\": [\"${P7}\"], \"root_mount\": \"/verified\"" "$SV"
            _tpm_initrd "${TW}/c.json"
            _tpm_boot "${TPM_DISKS}/data.img" "${TPM_DISKS}/hash.img" "$T2"
            _assert_no_panic "$T2" "tpm board"
            _tpm_unpacked "tpm board" "$T2"
            _tpm_has "tpm board" "PREINIT-OK" "$T2"
            _tpm_has "tpm board" "all configured PCR baselines MATCH" "$T2"
            _tpm_has "tpm board" "dm-verity integrity VERIFIED" "$T2"
            _tpm_has "tpm board" "verified root mounted read-only at /verified" "$T2"
            _tpm_has "tpm board" "verified root measured into PCR 15" "$T2"
            _tpm_has "tpm board" "edge boot: data volume unlocked: /dev/mapper/agnos-data" "$T2"
            _tpm_has "tpm board" "edge boot: PCR 15 capped" "$T2"
            _tpm_has "tpm board" "READ-/verified/hello.txt=KYB-VERIFIED-ROOT" "$T2"
            _tpm_has "tpm board" "FAILED to start: kyb-ro-write" "$T2"
            _tpm_has "tpm board" "ST[kyb-mapper]-STAT-/dev/mapper/agnos-data=other" "$T2"
            GOT15="$(sed -n 's/.*READ-\/sys\/class\/tpm\/tpm0\/pcr-sha256\/15=\([0-9A-Fa-f]\{64\}\).*/\1/p' "$T2" | head -1 | _lower)"
            if [ "$GOT15" = "$P15CAP" ]; then
                echo "  OK: [tpm board] PCR 15 is the enrolled value extended by the cap: ${GOT15}"
            else
                echo "  FAIL: [tpm board] PCR 15 is '${GOT15}', expected the cap over the enrolled ${P15}: ${P15CAP}"
                fail=1
            fi
            _tpm_has "tpm board" "FAILED to start: kyb-cap-check" "$T2"
            _tpm_lacks "tpm board" "completed (oneshot): kyb-cap-check" "$T2"

            # 4. A swapped root, valid against its own hash: no key.
            T3="${CACHE}/a64-tpm-swap.log"
            _tpm_cfg "${TW}/c.json" "$RH2" true true "" ""
            _tpm_initrd "${TW}/c.json"
            _tpm_boot "${TPM_DISKS}/data2.img" "${TPM_DISKS}/hash2.img" "$T3"
            _assert_no_panic "$T3" "tpm swap"
            _tpm_unpacked "tpm swap" "$T3"
            _tpm_has "tpm swap" "dm-verity integrity VERIFIED" "$T3"
            _tpm_has "tpm swap" "verified root measured into PCR 15" "$T3"
            _tpm_has "tpm swap" "LUKS unlock FAILED" "$T3"
            _tpm_has "tpm swap" "FATAL: LUKS unlock FAILED - the TPM released no key for this root" "$T3"
            _tpm_has "tpm swap" "refusing to continue boot without edge prerequisites" "$T3"
            _tpm_lacks "tpm swap" "data volume unlocked" "$T3"

            # 5. The board's own hash over a corrupted root: only the refusal of an
            # unverified root keeps the key from it (the x86 pass says why).
            T5="${CACHE}/a64-tpm-unverified.log"
            _tpm_cfg "${TW}/c.json" "$RH" false true "" ""
            _tpm_initrd "${TW}/c.json"
            _tpm_boot "${TPM_DISKS}/data-corrupt.img" "${TPM_DISKS}/hash.img" "$T5"
            _assert_no_panic "$T5" "tpm unverified"
            _tpm_unpacked "tpm unverified" "$T5"
            _tpm_has "tpm unverified" "dm-verity verification FAILED" "$T5"
            _tpm_has "tpm unverified" "FATAL: LUKS unlock needs a verified root" "$T5"
            _tpm_lacks "tpm unverified" "verified root measured into PCR 15" "$T5"
            _tpm_lacks "tpm unverified" "data volume unlocked" "$T5"
        fi

        # 6. A corrupted root, allowed on: EIO from the bad block only.
        T4="${CACHE}/a64-tpm-corrupt.log"
        SV="$(_svc kyb-read-root "$FX" '"read", "/verified/hello.txt"' ',')"
        SV="${SV}$(_svc kyb-read-other "$FX" '"read", "/verified/other.txt"' '')"
        _tpm_cfg "${TW}/c.json" "$RH" false false ", \"root_mount\": \"/verified\"" "$SV"
        _tpm_initrd "${TW}/c.json"
        _tpm_boot "${TPM_DISKS}/data-corrupt.img" "${TPM_DISKS}/hash.img" "$T4"
        _assert_no_panic "$T4" "tpm corrupt"
        _tpm_unpacked "tpm corrupt" "$T4"
        _tpm_has "tpm corrupt" "dm-verity verification FAILED" "$T4"
        _tpm_has "tpm corrupt" "verified root mounted read-only at /verified" "$T4"
        _tpm_has "tpm corrupt" "READ-/verified/hello.txt-ERRNO=5" "$T4"
        _tpm_has "tpm corrupt" "READ-/verified/other.txt=KYB-SECOND-BLOCK" "$T4"
    fi
    rm -rf "$TW"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "=== AARCH64 BOOT GATE: OK (kybernet-aarch64 runs as PID 1) ==="
    exit 0
fi
echo "=== AARCH64 BOOT GATE: FAIL ==="
echo "  logs: $OUT1"
echo "        $OUT2"
echo "        ${CACHE}/a64-edge-*.log, ${CACHE}/a64-auth-*.log, $OUT5"
exit 1
