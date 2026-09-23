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
# ⚠ What is still x86-only, and why: the edge (dm-verity) and emergency-auth passes
# need veritysetup and a real block device, and the quiet pass and the busybox
# `kyb-seccomp` shape have no Cyrius equivalent yet. Those are on the roadmap.
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
    echo "       run: cyrius build --aarch64 src/main.cyr build/kybernet-aarch64"
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
    echo "       run: cyrius build --aarch64 src/main.cyr build/kybernet-aarch64"
    exit 1
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
for fx in svc landlock seccomp notify; do
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
    cp "${FIX_DIR}/kyb-${fx}-fixture" "$ROOT/usr/bin/"
    chmod 755 "$ROOT/usr/bin/kyb-${fx}-fixture"
done
# The Landlock truncate probe's victim: outside the rule set, 16 known bytes.
printf '0123456789abcdef' > "$ROOT/etc/kyb-landlock-victim"

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
      "type": "oneshot", "restart": "never" }
  ]
}
CFGEOF
# ⚠ DO NOT DISCARD cpio's STDERR, AND DO NOT ASSUME cpio EXISTS. The first
# version was `cpio ... 2> /dev/null`, which turns a missing or failing archiver
# into an empty initramfs — QEMU then boots a kernel with no `/init`, every
# marker is absent, and the gate reports a wall of kybernet failures for a
# missing package. Same shape as the romfile problem above: one environmental
# cause wearing another subsystem's name. `cpio` is also installed by a LATER
# CI step than this gate, so its presence here is not something to take on
# faith (standing rule 39).
if ! command -v cpio > /dev/null 2>&1; then
    echo "ERROR: cpio is not installed, so the initramfs cannot be built."
    echo "       This gate needs it BEFORE the x86 harness step that installs it."
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
_boot() {
    # $1 = harness mode, $2 = output file
    timeout "$TIMEOUT_S" qemu-system-aarch64 \
        -M virt,dtb-randomness=off -cpu cortex-a57 -m 512M -smp 1 \
        -nic none \
        -kernel "$KERNEL" -initrd "$CPIO" \
        -append "console=ttyAMA0 kybernet.harness=$1 panic=1" \
        -nographic -no-reboot -serial mon:stdio > "$2" 2>&1 || true

    # ⚠ NAME AN ENVIRONMENT FAILURE AS ONE. When QEMU cannot start, every
    # marker is absent and the gate reports a wall of missing-marker failures
    # that read like kybernet regressions — one environmental cause presented
    # as eight code defects. That happened, and it is standing rule 38's
    # principle: a gate must not report one subsystem's cause under another's
    # name.
    if grep -aq 'failed to find romfile' "$2"; then
        echo "  FAIL: QEMU could not start — a missing option ROM, not a kybernet defect."
        grep -a 'failed to find romfile' "$2" | head -2 || true
        echo "        This gate passes -nic none precisely so no ROM is needed;"
        echo "        seeing this means a device is being created that should not be."
        fail=1
    fi
    if grep -aqE "dtb-randomness.*(not found|invalid)|Property .*dtb-randomness" "$2"; then
        echo "  FAIL: this QEMU has no virt 'dtb-randomness' property (needs >= 7.2) — an"
        echo "        environment failure, not a kybernet defect."
        grep -a 'dtb-randomness' "$2" | head -2 || true
        fail=1
    fi
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
_prop "config: services parsed: 19" \
    'kybernet: config: services parsed: 19([^0-9]|$)' "$OUT1"
_prop "completed (oneshot): kyb-dep" 'completed \(oneshot\): kyb-dep' "$OUT1"
_prop "completed (oneshot): kyb-svc, after its dependency" 'completed \(oneshot\): kyb-svc' "$OUT1"
_prop "started: kyb-live" 'started: kyb-live' "$OUT1"
# 18, not 19: kyb-prereq-dep is skipped, so no cgroup is ever made for it.
_prop "removed service cgroups: 18 (every started service, torn down)" \
    'kybernet: removed service cgroups: 18([^0-9]|$)' "$OUT1" 'removed service cgroups'

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

echo
if [ "$fail" -eq 0 ]; then
    echo "=== AARCH64 BOOT GATE: OK (kybernet-aarch64 runs as PID 1) ==="
    exit 0
fi
echo "=== AARCH64 BOOT GATE: FAIL ==="
echo "  logs: $OUT1"
echo "        $OUT2"
exit 1
