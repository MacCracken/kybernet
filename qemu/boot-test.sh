#!/usr/bin/env bash
# boot-test.sh — boot kybernet in QEMU as real PID 1 with
# `kybernet.harness=1`, assert the full boot phase 0..8 markers
# fire, and gate on the kernel-to-services boot time.
#
# Shape adapted from argonaut/qemu/boot-test.sh (the patterns
# round-tripped between repos; kybernet's 1.0.x variant of this
# script was the original seed). 1.1.4 rewrite swaps the
# implicit "grep and hope" pass criterion for explicit marker
# assertions + a boot-time budget.
#
# Asserts (greps qemu serial output — klog markers, not the kmsg
# phase prefixes which only land in dmesg). klog goes to stderr →
# /dev/console → qemu's serial out at loglevel=3.
#
#   "kybernet: starting"                  — phase 0 entered
#   "kybernet: filesystems mounted"       — required mounts up
#   "kybernet: argonaut initialized"      — config loaded, init built
#   "kybernet: services started"          — service wave done
#   "kybernet: harness done"              — harness mode self-shutdown
#   "kybernet: shutdown"                  — final marker; clean exit
#
# 1.5.0 service markers — these are the gate for "services actually come
# from config". build-initramfs.sh stages /etc/kybernet/config.json with
# two oneshots where kyb-svc depends_on kyb-dep:
#   "config: services parsed: 2"          — the JSON services array is read
#   "completed (oneshot): kyb-dep"        — a config service really forked+exec'd
#   "completed (oneshot): kyb-svc"        — and its DEPENDENT ran after it,
#                                           proving wave ordering + that a
#                                           completed oneshot satisfies a
#                                           dependency (argonaut 1.10.0)
# Before 1.5.0 none of this executed: config_services() was always empty and
# start_services()'s wave-loop body had never run in a real boot.
#
# Exits 0 on full marker hit + boot under budget; non-zero otherwise.
#
# Usage:
#   qemu/boot-test.sh                            # default kernel, 15s
#   qemu/boot-test.sh /boot/vmlinuz-linux-lts    # explicit kernel
#   qemu/boot-test.sh "" 20                      # 20s timeout
#   BUDGET_MS=5000 qemu/boot-test.sh             # override boot budget

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KERNEL="${1:-}"
TIMEOUT="${2:-15}"
BUDGET_MS="${BUDGET_MS:-3000}"
# Reactor-gate ceiling: a sleeping reactor wakes ~20-30 times in the 5s
# window; the unfixed spin measured ~340,000/sec. 500 separates them by
# three orders of magnitude without being flaky on a loaded runner.
WAKEUP_CEILING="${WAKEUP_CEILING:-500}"
INITRAMFS="${SCRIPT_DIR}/initramfs.cpio.gz"

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "ERROR: qemu-system-x86_64 not on PATH."
    echo "  Arch:    sudo pacman -S qemu-system-x86"
    echo "  Debian:  sudo apt install qemu-system-x86"
    echo "  Fedora:  sudo dnf install qemu-system-x86"
    exit 1
fi

if [ -z "$KERNEL" ]; then
    for cand in /boot/vmlinuz-linux-lts /boot/vmlinuz-linux /boot/vmlinuz-$(uname -r) /boot/vmlinuz; do
        if [ -f "$cand" ]; then KERNEL="$cand"; break; fi
    done
fi
[ -f "$KERNEL" ] || { echo "ERROR: kernel not found. Pass an explicit path as \$1."; exit 1; }

# Build / rebuild the initramfs if the binary is newer than the cpio.
if [ ! -f "$INITRAMFS" ] || [ "${PROJECT_DIR}/build/kybernet" -nt "$INITRAMFS" ] || [ "${PROJECT_DIR}/cyrius.cyml" -nt "$INITRAMFS" ]; then
    bash "${SCRIPT_DIR}/build-initramfs.sh"
fi

# argonaut needs KVM (sakshi invariant-TSC); kybernet's transitive
# pull-in of agnostik+libro brings sakshi too, so we inherit that
# requirement. /dev/kvm readability gate matches argonaut's harness.
ACCEL_FLAGS="-cpu host,+invtsc -enable-kvm"
if [ ! -r /dev/kvm ]; then
    echo "WARNING: /dev/kvm not readable — running under TCG."
    echo "  sakshi clock_init will panic on missing invariant TSC; this run will fail."
    echo "  Add yourself to the 'kvm' group (Arch: usermod -aG kvm \$USER + relog)"
    echo "  or run as root."
    ACCEL_FLAGS="-cpu max,+invtsc"
fi

INIT_SIZE=$(wc -c < "${PROJECT_DIR}/build/kybernet")
echo "=== kybernet PID-1 HARNESS BOOT TEST ==="
echo "  kernel:    $KERNEL"
echo "  initramfs: ${INITRAMFS} ($(du -h "$INITRAMFS" | cut -f1))"
echo "  init:      ${INIT_SIZE}B (kybernet)"
echo "  cmdline:   kybernet.harness=1"
echo "  timeout:   ${TIMEOUT}s"
echo "  budget:    ${BUDGET_MS}ms (kernel-hand-off → phase 8)"
echo ""

LOG=$(mktemp /tmp/kybernet-harness.XXXXXX.log)
trap "rm -f $LOG" EXIT

START_NS=$(date +%s%N)

# `kybernet.harness=1` → kybernet_harness_requested() → shutdown after
# phase 8. `panic=5` is the safety net if kybernet ever returns from
# main while PID 1 — kernel triggers reboot 5s after the panic, qemu's
# `-no-reboot` then terminates the VM cleanly.
#
# `-m 512M`: the cyrius 6.1.19+ allocator reserves a single 256 MB mmap
# chunk at alloc_init() (the brk-era incremental growth this replaced is
# gone — see lib/alloc.cyr). The mapping is virtual/overcommitted (real
# AGNOS hardware has GBs and faults pages lazily), but a 256 MB VM left no
# headroom over kernel+initramfs+page-tables, so the overcommit heuristic
# rejected the mmap → alloc_init exit(1) → "Attempted to kill init". 512 M
# gives the 256 MB heap chunk room to map. Bumped at kybernet 1.3.4 with
# the 6.0.56 → 6.2.11 toolchain jump (brk-era → chunk-era allocator).
timeout "$TIMEOUT" qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRAMFS" \
    -append "console=ttyS0 panic=5 rdinit=/sbin/init kybernet.harness=1 loglevel=3" \
    $ACCEL_FLAGS \
    -m 512M \
    -nographic \
    -no-reboot \
    -serial mon:stdio 2>&1 | tee "$LOG" | grep -E "kybernet:|phase [0-9]|kernel panic|Attempted to kill init" || true

END_NS=$(date +%s%N)
WALL_MS=$(( (END_NS - START_NS) / 1000000 ))

echo ""
echo "=== marker check ==="

fail=0
# Qemu serial uses CRLF — strip \r so grep doesn't trip on terminators.
RUNTIME_OUT=$(cat -v "$LOG" | tr '\r' '\n')

for marker in \
    "kybernet: starting" \
    "kybernet: filesystems mounted" \
    "kybernet: argonaut initialized" \
    "kybernet: services started" \
    "kybernet: harness done" \
    "kybernet: shutdown" \
    "kybernet: config: services parsed: 2" \
    "kybernet:   completed (oneshot): kyb-dep" \
    "kybernet:   completed (oneshot): kyb-svc" \
    "kybernet: boot: skipped (not applicable): Start udev device manager"; do
    if echo "$RUNTIME_OUT" | grep -aqF "$marker"; then
        echo "  OK: $marker"
    else
        echo "  FAIL: missing marker — \"$marker\""
        fail=1
    fi
done

if grep -aqE "Attempted to kill init|Kernel panic" "$LOG"; then
    echo "  FAIL: kernel panicked — kybernet returned from main while PID 1"
    fail=1
fi

# 1.5.1: no boot stage may fail in the harness. Before 1.5.1 this could not
# have fired — execute_boot_stage returned 1 for all eleven stages, so
# init_mark_step_failed was unreachable and a stage failure was structurally
# impossible to observe. Now that stages do real work, a FATAL here means a
# stage genuinely did not do its job.
if echo "$RUNTIME_OUT" | grep -aqF "FATAL: required boot stage failed"; then
    echo "  FAIL: a required boot stage failed"
    echo "$RUNTIME_OUT" | grep -aF "FATAL: required boot stage failed" | head -3
    fail=1
else
    echo "  OK: no boot stage failed"
fi

# Boot-time budget. Wall time includes qemu spin-up overhead (~200-400 ms)
# so the budget is generous — the kernel-internal hand-off to phase 8 is
# what we actually want to measure, but it's hard to get without
# instrumenting the kernel. Wall time is the conservative proxy.
#
# History worth keeping: 1.5.0 raised this to 6000 because the harness
# booted BOOT_MINIMAL, whose default set includes `daimon` — and daimon's
# ready check is 10 x 200 ms of TCP connects against port 8090, which
# nothing in the initramfs listens on because its binary is not staged.
# That 2000 ms was argonaut correctly waiting on a service that could never
# come up, not kybernet being slow.
#
# 1.5.1 moved the harness to BOOT_RECOVERY, whose sequence is the four
# early stages plus boot-complete and whose default service set is empty.
# The retry disappears with it and boots land at ~650 ms again, so the
# budget goes back to 3000. If this ever needs raising, find out what is
# actually slow first — do not just move the number.
echo ""
echo "  boot wall time: ${WALL_MS} ms (budget: ${BUDGET_MS} ms, includes qemu start)"
if [ "$WALL_MS" -gt "$BUDGET_MS" ]; then
    echo "  FAIL: boot exceeded budget"
    fail=1
fi

# ---------------------------------------------------------------------
# Reactor gate (1.4.2) — the pass above NEVER enters the event loop.
#
# `kybernet.harness=1` shuts down at phase 9 before the reactor starts, so
# for four audits no release gate executed a single loop iteration. That is
# exactly how CRITICAL-1 shipped: health/watchdog timerfds were registered
# level-triggered and never drained, so ~10 s after every real boot PID 1
# span at 100% CPU forever — invisible to a gate that stops at phase 9.
#
# This second pass boots with `kybernet.harness=loop`, which runs the real
# loop for 5 s with short timer intervals and prints its wakeup count. A
# reactor that sleeps between ticks wakes a handful of times; a spinning
# one reported ~340,000/sec when measured against the unfixed tree.
if [ $fail -eq 0 ]; then
    echo ""
    echo "=== reactor gate (kybernet.harness=loop) ==="
    LOOP_LOG=$(mktemp /tmp/kybernet-reactor.XXXXXX.log)
    timeout "$TIMEOUT" qemu-system-x86_64 \
        -kernel "$KERNEL" \
        -initrd "$INITRAMFS" \
        -append "console=ttyS0 panic=5 rdinit=/sbin/init kybernet.harness=loop loglevel=3" \
        $ACCEL_FLAGS \
        -m 512M \
        -nographic \
        -no-reboot \
        -serial mon:stdio 2>&1 | tee "$LOOP_LOG" | grep -E "reactor|kybernet: shutdown|Attempted to kill init" || true

    LOOP_OUT=$(cat -v "$LOOP_LOG" | tr '\r' '\n')
    WAKEUPS=$(echo "$LOOP_OUT" | sed -n 's/.*reactor wakeups=\([0-9][0-9]*\).*/\1/p' | tail -1)

    if [ -z "$WAKEUPS" ]; then
        echo "  FAIL: reactor gate produced no wakeup count"
        fail=1
    else
        # 5s window, 250ms epoll timeout, 1s watchdog + 2s health ticks.
        # Correct behaviour is ~20-30 wakeups. Anything in the thousands
        # means the reactor is spinning instead of sleeping.
        echo "  reactor wakeups: ${WAKEUPS} (ceiling: ${WAKEUP_CEILING})"
        if [ "$WAKEUPS" -gt "$WAKEUP_CEILING" ]; then
            echo "  FAIL: reactor is spinning — a timerfd is not being drained"
            fail=1
        else
            echo "  OK: reactor sleeps between ticks"
        fi
    fi
    if grep -aqE "Attempted to kill init|Kernel panic" "$LOOP_LOG"; then
        echo "  FAIL: kernel panicked in reactor mode"
        fail=1
    fi
    rm -f "$LOOP_LOG"
fi

if [ $fail -eq 0 ]; then
    echo ""
    echo "=== HARNESS TEST: OK (all markers, within budget, reactor sleeps) ==="
    exit 0
else
    echo ""
    echo "=== HARNESS TEST: FAIL ==="
    echo "  full log: $LOG (preserved for inspection)"
    trap - EXIT
    exit 1
fi
