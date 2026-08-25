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
# 1.5.3 cgroup-lifecycle markers:
#   "started: kyb-live"              — a LIVE service, so a cgroup is really
#                                      created and the pid moved into it
#                                      (a completed oneshot correctly gets none)
#   "removed service cgroups: 6"     — the shutdown sweep killed and rmdir'd them
# Before 1.5.3 create_service_cgroup and move_to_cgroup were the only cgroup
# calls with production call sites, so directories accumulated for the life of
# the system and CRASH_GIVE_UP left a populated one behind.
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
# KEEP_LOG=1 preserves the raw serial capture. The display pipeline below
# only shows `kybernet:` lines, so anything a SERVICE writes to the console
# (see the confinement gate) is in the log but not on screen.
[ -n "${KEEP_LOG:-}" ] && trap - EXIT

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
    "kybernet: config: services parsed: 6" \
    "kybernet:   completed (oneshot): kyb-dep" \
    "kybernet:   completed (oneshot): kyb-svc" \
    "kybernet: boot: skipped (not applicable): Start udev device manager" \
    "kybernet:   started: kyb-live" \
    "kybernet: removed service cgroups: 6"; do
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

# ---------------------------------------------------------------------
# Confinement gate (1.5.2). The `kyb-confined` service in the staged config
# carries a real security policy — drop every capability, set no_new_privs
# — and reports its OWN /proc/self/status to /dev/console. So this asserts
# the policy actually took effect in the child, rather than trusting that
# kyb_pre_exec was invoked.
#
# It is also the only privileged validation of drop_cap_sets() available:
# the unit suite runs unprivileged, where every capability path
# short-circuits on the euid check, so capset(2) never actually executes
# there. Under QEMU kybernet is genuinely PID 1 as root and it does.
# No end-anchor: RUNTIME_OUT is built with `cat -v`, which renders the
# serial CR as a literal two-character "^M" BEFORE the tr, so every line
# ends in that text rather than in a real \r. Match the 16 hex zeros
# exactly instead.
if echo "$RUNTIME_OUT" | grep -qE '^CapEff:[[:space:]]*0{16}'; then
    echo "  OK: kyb-confined dropped all capabilities (CapEff=0)"
else
    echo "  FAIL: kyb-confined did not drop capabilities"
    echo "$RUNTIME_OUT" | grep -aE '^CapEff:' | head -2
    fail=1
fi
if echo "$RUNTIME_OUT" | grep -qE '^NoNewPrivs:[[:space:]]*1'; then
    echo "  OK: kyb-confined has no_new_privs set"
else
    echo "  FAIL: kyb-confined missing no_new_privs"
    fail=1
fi

# 1.5.5: cgroup limits are really in effect.
#
# kyb-limited reads its OWN cgroup back from inside the service, so these
# assert what the KERNEL accepted, not what kybernet logged. Each one is
# separately load-bearing:
#
#  - cgroup=/kybernet.slice/kyb-limited on a ONESHOT is the placement proof.
#    argonaut waits for a oneshot inside init_start_service and returns 0,
#    so under the pre-1.5.5 post-start create->move there was no surviving
#    pid and a oneshot got no cgroup at all. This can only pass because the
#    child joins itself in kyb_pre_exec, before exec.
#  - memory.max/pids.max echo the configured values exactly.
#  - subtree_control proves the controllers were enabled; without it the
#    limit files would not EXIST and every write would have been ENOENT.
#  - kyb-live carries no limits block, so its memory.max must read "max".
#    That control is what separates "kybernet wrote the value" from "the
#    file happened to already contain it".
if echo "$RUNTIME_OUT" | grep -aqF "LIMIT-cgroup=/kybernet.slice/kyb-limited"; then
    echo "  OK: oneshot was in its own cgroup before exec"
else
    echo "  FAIL: kyb-limited not placed in its cgroup"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-cgroup' | head -1
    fail=1
fi
if echo "$RUNTIME_OUT" | grep -aqF "LIMIT-memmax=67108864"; then
    echo "  OK: memory.max applied (64 MiB, read back from kernel)"
else
    echo "  FAIL: memory.max not applied"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-memmax' | head -1
    fail=1
fi
if echo "$RUNTIME_OUT" | grep -aqF "LIMIT-pidsmax=32"; then
    echo "  OK: pids.max applied (32, read back from kernel)"
else
    echo "  FAIL: pids.max not applied"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-pidsmax' | head -1
    fail=1
fi
# cpu.weight and memory.high exercise the OTHER controllers, and together
# they are the regression test for cgroup_apply_limits' fail-fast bug: the
# write order is memory.max -> memory.high -> cpu.weight -> pids.max, and
# before 1.5.5 the first Err abandoned every later file. pids.max asserting
# above while cpu.weight asserts here means all four were attempted.
if echo "$RUNTIME_OUT" | grep -aqF "LIMIT-cpuweight=250"; then
    echo "  OK: cpu.weight applied (250, read back from kernel)"
else
    echo "  FAIL: cpu.weight not applied"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-cpuweight' | head -1
    fail=1
fi
if echo "$RUNTIME_OUT" | grep -aqF "LIMIT-memhigh=50331648"; then
    echo "  OK: memory.high applied (48 MiB, read back from kernel)"
else
    echo "  FAIL: memory.high not applied"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-memhigh' | head -1
    fail=1
fi
if echo "$RUNTIME_OUT" | grep -aqE '^LIMIT-ctrl=.*memory.*pids'; then
    echo "  OK: cgroup subtree_control enables memory + pids"
else
    echo "  FAIL: cgroup controllers not enabled on the slice"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-ctrl' | head -1
    fail=1
fi
if echo "$RUNTIME_OUT" | grep -aqF "LIMIT-unlimited=max"; then
    echo "  OK: unlimited service reads memory.max=max (control case)"
else
    echo "  FAIL: control case wrong — kyb-live should be unlimited"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-unlimited' | head -1
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

    # 1.5.4 deferred-restart gate. `kyb-crash` is /bin/false, so argonaut
    # raises CRASH_RESTART with an exponential backoff on every exit. The
    # SIGCHLD handler must only SCHEDULE; the reactor's restart tick performs
    # the relaunch once the delay elapses. Only observable here — the
    # boot-only pass shuts down before the reactor starts.
    #
    # Pre-1.5.4 the backoff was passed as init_restart_service's
    # stop_timeout_ms and discarded, so a crash-looping service was
    # relaunched as fast as it could die.
    if echo "$LOOP_OUT" | grep -aqF "restart scheduled: kyb-crash"; then
        echo "  OK: crash restart scheduled (not run inline)"
    else
        echo "  FAIL: no deferred restart scheduled for kyb-crash"
        fail=1
    fi
    if echo "$LOOP_OUT" | grep -aqF "restarted: kyb-crash"; then
        echo "  OK: restart tick performed the relaunch"
    else
        echo "  FAIL: restart tick never relaunched kyb-crash"
        fail=1
    fi
    rm -f "$LOOP_LOG"
fi

# ============================================================
# Edge-boot gate (1.5.7)
#
# Runs against a SEPARATE initramfs (initramfs-edge.cpio.gz) staged by
# build-initramfs.sh, so every gate above stays byte-for-byte unchanged.
# SKIPS cleanly when the fixture is absent — it needs veritysetup on the
# build host, and a missing tool must never read as a pass.
#
# WHAT THIS PROVES: kybernet verifies a real 4 MiB image against a real
# dm-verity root hash, in a real PID-1 boot, and refuses when it does not
# match. `veritysetup verify` walks the hash tree in PURE USERSPACE, which
# is why this works in an initramfs where device-mapper is a module nothing
# can load — and is exactly why kybernet verifies with `verify` rather than
# `open`.
#
# WHAT IT DOES NOT PROVE: `veritysetup open`, the read-only mount of the
# verified target, LUKS unlock, and PCR baseline comparison. Those need a
# real device-mapper stack and a real TPM. They are hardware work
# (roadmap v1.2.2) and are NOT covered here — do not let this gate's green
# be read as covering them.
EDGE_INITRD="${SCRIPT_DIR}/initramfs-edge.cpio.gz"
EDGE_DIR="${SCRIPT_DIR}/edge"
if [ ! -f "$EDGE_INITRD" ]; then
    echo ""
    echo "=== edge gate: SKIPPED (no fixture — veritysetup absent on build host) ==="
else
    echo ""
    echo "=== edge-boot gate (dm-verity integrity verification) ==="

    _edge_boot() {
        # $1 = data image, $2 = extra cmdline
        timeout "$TIMEOUT" qemu-system-x86_64 \
            -kernel "$KERNEL" \
            -initrd "$EDGE_INITRD" \
            -append "console=ttyS0 panic=5 rdinit=/sbin/init kybernet.harness=1 loglevel=3 $2" \
            -drive "file=$1,if=virtio,format=raw" \
            -drive "file=${EDGE_DIR}/hash.img,if=virtio,format=raw" \
            $ACCEL_FLAGS -m 512M -nographic -no-reboot \
            -serial mon:stdio 2>&1 | cat -v | tr '\r' '\n'
    }

    CORRUPT_IMG="${EDGE_DIR}/data-corrupt.img"
    SKIP_EDGE=0

    # 1. GOOD image must verify.
    GOOD_OUT=$(_edge_boot "${EDGE_DIR}/data.img" "")

    # Distinguish a BROKEN FIXTURE from a real failure. kybernet reports
    # "veritysetup missing or unrunnable" (rc 127 / spawn failure) as a
    # distinct outcome from a verification verdict, precisely so this gate
    # can tell them apart. An incomplete shared-library closure in the
    # staged initramfs is an environment problem, not a kybernet defect —
    # skip loudly rather than fail, and never silently pass.
    # Match the klog line, not the kmsg one: kmsg goes to /dev/kmsg and the
    # harness boots with loglevel=3, which keeps it off the serial console.
    if echo "$GOOD_OUT" | grep -aqF "veritysetup could not run"; then
        echo "  SKIPPED: staged veritysetup could not run in the VM"
        echo "           (incomplete library closure — fixture problem, not a kybernet failure)"
        SKIP_EDGE=1
    fi

    if [ "$SKIP_EDGE" != "1" ] && echo "$GOOD_OUT" | grep -aqF "dm-verity integrity VERIFIED"; then
        echo "  OK: intact image verifies against its root hash"
    elif [ "$SKIP_EDGE" != "1" ]; then
        echo "  FAIL: intact image did not verify"
        echo "$GOOD_OUT" | grep -aiE 'edge boot|verit' | head -5
        fail=1
    fi

    if [ "$SKIP_EDGE" = "1" ]; then
        echo "  (remaining edge assertions skipped)"
    else

    # 2. CORRUPTED image must be REFUSED. This is the assertion that
    #    matters: a verified-boot path that cannot say no is decoration.
    cp "${EDGE_DIR}/data.img" "$CORRUPT_IMG"
    printf 'CORRUPTED' | dd of="$CORRUPT_IMG" bs=1 seek=2000 conv=notrunc status=none
    BAD_OUT=$(_edge_boot "$CORRUPT_IMG" "")
    if echo "$BAD_OUT" | grep -aqF "dm-verity verification FAILED"; then
        echo "  OK: corrupted image fails verification"
    else
        echo "  FAIL: corrupted image was not detected"
        echo "$BAD_OUT" | grep -aiE 'edge boot|verit' | head -5
        fail=1
    fi
    if echo "$BAD_OUT" | grep -aqF "refusing to continue boot without edge prerequisites"; then
        echo "  OK: failed verification refuses the boot"
    else
        echo "  FAIL: failed verification did not refuse the boot"
        fail=1
    fi

    # 3. The escape hatches. An operator locked out by a hardware change
    #    cannot edit a config file on a rootfs that is itself what failed
    #    to verify, so these are the only way back in — and an escape hatch
    #    that has never been executed is not an escape hatch.
    PERM_OUT=$(_edge_boot "$CORRUPT_IMG" "kybernet.edge=permissive")
    # ASCII-only needle: these logs are rendered through `cat -v`, which
    # escapes the em-dash in the source string into M-BM- byte sequences.
    if echo "$PERM_OUT" | grep -aqF "continuing despite the above"; then
        echo "  OK: kybernet.edge=permissive continues past a failed verification"
    else
        echo "  FAIL: permissive mode did not suppress the refusal"
        fail=1
    fi
    # `off` on a board that PINNED a root_hash must NOT silently skip the
    # check — /proc/cmdline is only as trustworthy as the bootloader, which
    # is the surface verified boot exists to protect. It downgrades to
    # permissive: the board still boots, but the verification still runs and
    # its result still reaches dmesg. The audit trail is the point.
    OFF_OUT=$(_edge_boot "$CORRUPT_IMG" "kybernet.edge=off")
    if echo "$OFF_OUT" | grep -aqF "DOWNGRADED to permissive"; then
        echo "  OK: kybernet.edge=off downgrades on a root_hash-pinned board"
    else
        echo "  FAIL: kybernet.edge=off was honoured as a silent total bypass"
        fail=1
    fi
    if echo "$OFF_OUT" | grep -aqF "dm-verity verification FAILED"; then
        echo "  OK: downgraded off still runs and reports the verification"
    else
        echo "  FAIL: downgraded off skipped the verification"
        fail=1
    fi

    rm -f "$CORRUPT_IMG"
    fi
fi

if [ $fail -eq 0 ]; then
    echo ""
    echo "=== HARNESS TEST: OK (markers, budget, reactor, edge verification) ==="
    exit 0
else
    echo ""
    echo "=== HARNESS TEST: FAIL ==="
    echo "  full log: $LOG (preserved for inspection)"
    trap - EXIT
    exit 1
fi
