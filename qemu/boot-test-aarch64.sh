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
# This boots with NO services. The x86 harness stages 19, but most of its
# fixtures exec busybox applets and an aarch64 busybox is a build-host
# capability standing rule 33 forbids assuming. What is covered here is the
# init-resident path: console, mounts, cgroup controllers, signals, argonaut
# init, boot stages, the REACTOR, and an orderly shutdown. Fixture parity is
# tracked in docs/development/roadmap.md and is the next increment, not a
# pretence made here.
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
KERNEL_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot/vmlinuz-lts"
KERNEL_SHA256="330dd0a88d18930dac4e425fad50f2947901a1c2bf782e72f58fef25ada4902a"

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
cat > "$ROOT/etc/kybernet/config.json" << 'CFGEOF'
{
  "boot_mode": "recovery",
  "log_to_console": true,
  "shutdown_timeout_ms": 3000,
  "services": []
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
_boot() {
    # $1 = harness mode, $2 = output file
    timeout "$TIMEOUT_S" qemu-system-aarch64 \
        -M virt -cpu cortex-a57 -m 512M -smp 1 \
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

# ⚠ THE BUDGET IS KYBERNET'S OWN SPAN, NOT WALL TIME. Standing rule 37: under
# TCG the emulator and the guest kernel dominate wall clock, and gating on that
# measures the machine rather than the code. The kernel stamps each console line
# with [ seconds.micro ]; the span between kybernet's first and last is the part
# this repo is responsible for.
FIRST="$(grep -aoE '^\[ *[0-9]+\.[0-9]+\]' "$OUT1" | head -1 | tr -d '[] ' || true)"
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

echo
if [ "$fail" -eq 0 ]; then
    echo "=== AARCH64 BOOT GATE: OK (kybernet-aarch64 runs as PID 1) ==="
    exit 0
fi
echo "=== AARCH64 BOOT GATE: FAIL ==="
echo "  logs: $OUT1"
echo "        $OUT2"
exit 1
