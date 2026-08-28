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
#   "removed service cgroups: 16"    — the shutdown sweep killed and rmdir'd them
#
#     ⚠ NINE of NINE. This said EIGHT from 1.5.3 to 1.6.1, with a comment
#     arguing the shortfall was correct: kyb-orphan backgrounds a child, this
#     pass never enters the reactor, so nothing reaps it and "its cgroup is
#     still populated when the teardown sweep rmdirs".
#
#     That reasoning is wrong, and the gate was encoding a bug as an
#     expectation. An unreaped zombie does NOT hold a cgroup populated —
#     the kernel drops a task from the populated count in cgroup_exit(),
#     which runs during do_exit(), long before anyone calls wait(). What
#     actually produced an occasional 8 was a race: `cgroup.kill` is
#     asynchronous, and the rmdir on the next line could beat SIGKILL
#     delivery to a still-RUNNING `sleep`. Measured across kernels the
#     literal 8 was not even stable — a faster kernel, a slower kernel, or a
#     loaded host each yield 9, which meant this gate failed on correct
#     behaviour depending on the weather.
#
#     1.6.1 made it deterministic instead of blessing the flake: the sweep
#     now retries EBUSY under a whole-sweep budget (see
#     _remove_cgroup_settled in src/main.cyr), so every cgroup is torn down
#     and the answer is 9 every time. Keeping it exact rather than ">= 8" is
#     now meaningful — the count is a property, not a coin flip, so a real
#     teardown regression still moves it.
# Before 1.5.3 create_service_cgroup and move_to_cgroup were the only cgroup
# calls with production call sites, so directories accumulated for the life of
# the system and CRASH_GIVE_UP left a populated one behind.
#
# 1.5.0 service markers — these are the gate for "services actually come
# from config". build-initramfs.sh stages /etc/kybernet/config.json with a
# set of oneshots in which kyb-svc depends_on kyb-dep. The count has grown
# with each fixture (2 at 1.5.0, 7 at 1.6.0 with kyb-seccomp); the assertion
# below carries the live number, so adding a fixture means updating it:
#   "config: services parsed: N"          — the JSON services array is read
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

# ⚠ EVERY DIAGNOSTIC `... | grep ... | head -N` BELOW ENDS IN `|| true`, AND IT
# IS NOT DECORATION. With `pipefail` set, a grep that matches NOTHING makes the
# whole pipeline exit 1, and with `set -e` that ABORTS THE SCRIPT. Those
# pipelines run only inside failure branches — so the first failing assertion
# whose diagnostic found nothing to print would kill the run then and there,
# skipping every remaining assertion, the reactor pass, the edge pass and the
# auth passes, and reporting a single failure as though it were the only one.
# That fired for real in 1.6.3 while adding the sd_notify assertions: five
# failures printed, then the run stopped before the reactor gate.
#
# This is standing rule 38 wearing a different hat — a gate must not be able to
# suppress a different gate. A diagnostic must never be able to end the run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KERNEL="${1:-}"
TIMEOUT="${2:-15}"
BUDGET_MS="${BUDGET_MS:-1200}"
WALL_CEILING_MS="${WALL_CEILING_MS:-20000}"
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

# ⚠ THE BINARY MUST BE NEWER THAN THE SOURCE, AND UNTIL 1.6.12 NOTHING CHECKED.
# This script has never built build/kybernet — it stages whatever is already
# there. So the sequence "edit src/, run bash qemu/boot-test.sh" tested the
# PREVIOUS binary and reported a confident green for code that was never
# compiled. It bit this repo for real while adding the orphan assertion below:
# a deliberately injected defect produced 62 OK / 0 FAIL, which is precisely the
# failure the inject-the-defect discipline exists to rule out, arriving through
# the one channel that discipline does not cover.
#
# CI cannot see it — the workflow builds immediately before running this — so it
# is a dev-box-only false green, which is worse rather than better: the dev box
# is where iteration happens and where a wrong green costs the most.
#
# It FAILS rather than rebuilding, per standing rule 32. Rebuilding here would
# fork a second build path that could silently drift from the documented
# CYRIUS_DCE=1 one, and a gate whose job is to notice staleness should not be
# the thing papering over it.
_newest_src=$(find "${PROJECT_DIR}/src" -name '*.cyr' -newer "${PROJECT_DIR}/build/kybernet" -print -quit 2>/dev/null || true)
if [ ! -f "${PROJECT_DIR}/build/kybernet" ]; then
    echo "ERROR: build/kybernet does not exist. This script does not build it."
    echo "       run: CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet"
    exit 1
fi
if [ -n "$_newest_src" ] || [ "${PROJECT_DIR}/cyrius.cyml" -nt "${PROJECT_DIR}/build/kybernet" ]; then
    echo "ERROR: build/kybernet is STALE — source has changed since it was built."
    echo "       newer: ${_newest_src:-cyrius.cyml}"
    echo "       this script does not build; it would have tested the OLD binary"
    echo "       and reported a green for code that was never compiled."
    echo "       run: CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet"
    exit 1
fi

# Build / rebuild the initramfs when anything it is BUILT FROM is newer.
#
# ⚠ THIS ONLY CHECKED build/kybernet AND cyrius.cyml UNTIL 1.6.13 (MEDIUM-13).
# Every fixture INPUT was exempt: edit a service definition, a security block,
# a credential or the generator script itself, re-run the harness, and it
# booted the PREVIOUS initramfs and reported a confident pass for a fixture
# that was never staged. That is rule 43's defect — the gate grading something
# other than what you just changed — surviving in the half of the pipeline
# rule 43 did not cover, and it bites hardest during exactly the fixture work
# rule 27 demands for every new config key.
#
# Rebuilding (rather than failing as rule 43 does for the binary) is correct
# here: the initramfs is a derived artifact this script owns and builds itself,
# whereas build/kybernet is built by a documented command this script must not
# duplicate.
_initramfs_stale() {
    [ ! -f "$INITRAMFS" ] && return 0
    local f
    for f in "${PROJECT_DIR}/build/kybernet" "${PROJECT_DIR}/cyrius.cyml" \
             "${SCRIPT_DIR}/build-initramfs.sh" "${SCRIPT_DIR}/mkcred-fixture.cyr" \
             "${SCRIPT_DIR}/notify-fixture.cyr" "${SCRIPT_DIR}/landlock-fixture.cyr"; do
        [ -e "$f" ] && [ "$f" -nt "$INITRAMFS" ] && return 0
    done
    return 1
}
if _initramfs_stale; then
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
echo "  budget:    ${BUDGET_MS}ms (kybernet span, kernel boot excluded)"
echo ""

LOG=$(mktemp /tmp/kybernet-harness.XXXXXX.log)
# Same capture, each line prefixed with a host-side nanosecond stamp, so the
# boot budget can measure kybernet's own span instead of the runner's kernel.
# $LOG stays byte-identical to the raw stream — every marker assertion below
# reads it, and none of them should have to know about the timestamps.
TLOG="${LOG}.ts"
trap "rm -f $LOG $TLOG" EXIT
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
    -serial mon:stdio 2>&1 \
    | awk '{ "date +%s%N" | getline t; close("date +%s%N"); print t, $0; fflush() }' \
    | tee "$TLOG" \
    | sed 's/^[0-9][0-9]* //' \
    | tee "$LOG" \
    | grep -E "kybernet:|phase [0-9]|kernel panic|Attempted to kill init" || true

END_NS=$(date +%s%N)
WALL_MS=$(( (END_NS - START_NS) / 1000000 ))

# KYB_MS — the span kybernet is actually responsible for.
#
# ⚠ WALL_MS IS MOSTLY NOT ABOUT KYBERNET. Measured on a runner-faithful
# rebuild (Ubuntu's azure kernel, the one ubuntu-24.04 images pin): qemu spin-up
# plus kernel boot to the `kybernet: starting` line is 2333 ms of a 2827 ms
# wall, i.e. 82%. On the Arch dev kernel the same split is 630 of 749 ms. So
# the same tree "takes" 750 ms here and 2830 ms in CI while executing an
# identical amount of kybernet, and the budget comment used to tell whoever hit
# it to go hunting for a slowdown in kybernet. There isn't one — it is the
# distro kernel's mitigations and module set, and it gets worse under the
# nested virtualisation GitHub actually runs.
#
# This is the same defect the benchmark gate had at 1.6.1 (is_mounted measured
# the host's mount table, +641% on a runner) and it gets the same treatment:
# measure the code, not the machine it happens to be on. Timestamp the serial
# stream host-side and take the span between kybernet's own first and last
# lines. WALL_MS stays as a loose liveness ceiling; KYB_MS is the real gate.
# ⚠ `|| true` IS LOAD-BEARING — standing rule 40, in the one place where
# breaking it costs the most. This runs under `set -euo pipefail`, so a grep
# that matches NOTHING exits 1, pipefail propagates it, and `set -e` ABORTS THE
# SCRIPT. "Matches nothing" is exactly the case where kybernet FAILED TO BOOT —
# so the harness died here, silently, before printing a single assertion,
# skipping all five passes and deleting its logs, in precisely the scenario it
# exists to diagnose. The `KYB_MS=-1` branch below was unreachable dead code.
# Verified: `X=$(_ts_of nomatch)` under `set -euo pipefail` exits 1 without
# reaching the next line. 1.6.13 MEDIUM-11.
_ts_of() { grep -aF "$1" "$TLOG" 2>/dev/null | head -1 | awk '{print $1}' || true; }
T_START=$(_ts_of "kybernet: starting")
T_END=$(_ts_of "kybernet: shutdown")
if [ -n "$T_START" ] && [ -n "$T_END" ]; then
    KYB_MS=$(( (T_END - T_START) / 1000000 ))
else
    KYB_MS=-1
fi

echo ""
echo "=== marker check ==="

fail=0

# ⚠ DEFINED HERE, ABOVE EVERY PASS THAT USES THEM. These lived below the boot
# and reactor passes until 1.6.4, which meant the veritysetup skip could not
# reach _skip_or_fail and silently ignored HARNESS_STRICT — and adding the
# quiet pass put a third caller above the definitions. A shell function used
# before its definition is not a syntax error; it is an unbound command at
# runtime, inside a failure branch, under `set -e`. Keep these first.
# ⚠ THIS LINE READ `ARNESS_STRICT=` UNTIL 1.6.13 (MEDIUM-12) — a dropped H, in
# the assignment whose entire purpose is to give HARNESS_STRICT a default
# before the first caller. `_skip_or_fail` reads `$HARNESS_STRICT`, so on any
# box that did not already export it the first SKIP hit an UNBOUND VARIABLE
# under `set -u` and killed the harness inside a failure branch. It stayed
# invisible because a machine with every tool installed never skips, and CI
# exports HARNESS_STRICT=1 — so the only configuration that could hit it was a
# developer box missing cryptsetup or busybox, which is also the configuration
# least likely to be believed over "works in CI".
HARNESS_STRICT="${HARNESS_STRICT:-0}"

# Assert a captured boot did not panic PID 1.
#
# ⚠ THE EDGE AND AUTH PASSES NEVER CHECKED THIS. Pass 1 and the reactor gate
# both grep for "Attempted to kill init|Kernel panic"; the other EIGHT boots
# grepped only for the verity/password string they cared about. A PID-1 panic
# in any of them was therefore invisible unless it also happened to suppress
# that one string. This is not hypothetical — 1.6.1 found a SIGSEGV in
# argonaut's watchdog that panicked PID 1, and it was found by a fixture, not
# by the passes that were already booting through the same code.
_assert_no_panic() {
    # $1 = captured output, $2 = label
    if echo "$1" | grep -aqE "Attempted to kill init|Kernel panic"; then
        echo "  FAIL: [$2] PID 1 panicked"
        echo "$1" | grep -aE "Attempted to kill init|Kernel panic" | head -2 || true
        fail=1
    fi
}

_skip_or_fail() {
    if [ "$HARNESS_STRICT" = "1" ]; then
        echo "  FAIL: $1 (HARNESS_STRICT=1 — a skip is a failure here)"
        fail=1
    else
        echo "  SKIP: $1"
    fi
}

# ⚠ QEMU DOES NOT FAIL ON A CPU FEATURE IT CANNOT PROVIDE — IT WARNS AND BOOTS.
# `-cpu host,+invtsc` with invtsc unavailable prints
#   qemu-system-x86_64: warning: host doesn't support requested feature: ...
# on stderr and continues. sakshi's _sk_clock_init then reads CPUID 0x80000007
# EDX bit 8, finds it clear, and _sk_clock_panic's with exit 75 — so PID 1 dies
# before phase 1 and the operator gets a wall of "missing marker" lines with
# nothing anywhere pointing at the CPU flag. The warning IS in $LOG, but the
# display pipeline greps only kybernet/phase/panic lines and drops it, and no
# assertion looked for it. Nested virtualisation is where this bites, and CI
# runs nested. Checked here, before the markers, so it is the FIRST thing said.
if grep -aq "doesn't support requested feature" "$LOG" 2>/dev/null; then
    echo "  FAIL: qemu could not provide a requested CPU feature:"
    grep -a "doesn't support requested feature" "$LOG" | head -3 || true
    echo "        If that is invtsc, sakshi's clock init panics (exit 75) before"
    echo "        phase 1 — every 'missing marker' below follows from this alone."
    fail=1
fi

# Qemu serial uses CRLF — strip \r so grep doesn't trip on terminators.
RUNTIME_OUT=$(cat -v "$LOG" | tr '\r' '\n')

for marker in \
    "kybernet: starting" \
    "kybernet: filesystems mounted" \
    "kybernet: argonaut initialized" \
    "kybernet: services started" \
    "kybernet: harness done" \
    "kybernet: shutdown" \
    "kybernet: config: services parsed: 17" \
    "kybernet:   completed (oneshot): kyb-dep" \
    "kybernet:   completed (oneshot): kyb-svc" \
    "kybernet: boot: skipped (not applicable): Start udev device manager" \
    "kybernet:   started: kyb-live" \
    "kybernet: removed service cgroups: 16"; do
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
    echo "$RUNTIME_OUT" | grep -aE '^CapEff:' | head -2 || true
    fail=1
fi
if echo "$RUNTIME_OUT" | grep -qE '^NoNewPrivs:[[:space:]]*1'; then
    echo "  OK: kyb-confined has no_new_privs set"
else
    echo "  FAIL: kyb-confined missing no_new_privs"
    fail=1
fi

# 1.6.0: `"seccomp": "basic"` is applied AND is survivable.
#
# This is a regression test for a fatal defect, not a feature test. From 1.4.3
# to 1.6.0 the basic profile had no `execve` on its 37-syscall allowlist and
# denied with SECCOMP_RET_KILL_PROCESS, so the documented config key killed
# every service it was applied to — with SIGSYS, before the binary ran an
# instruction. Nothing caught it because no fixture had ever set the key, so
# `seccomp_apply` had never run in a gate on either arch.
#
# kyb-seccomp reports its own /proc/self/status, so both halves are asserted
# from inside the confined child: that it LIVED (there is output at all), and
# that the filter was really loaded (Seccomp: 2 = SECCOMP_MODE_FILTER).
if echo "$RUNTIME_OUT" | grep -qE '^Seccomp:[[:space:]]*2'; then
    echo "  OK: kyb-seccomp runs under a loaded filter (Seccomp=2, mode filter)"
else
    echo "  FAIL: kyb-seccomp produced no Seccomp line — the profile killed it, or was never applied"
    echo "$RUNTIME_OUT" | grep -aiE 'seccomp' | head -3 || true
    fail=1
fi
# --- health poll interval (1.6.7) --------------------------------------------
#
# `health_check.interval_ms` was parsed onto the HealthCheck struct and then
# ignored: the reactor polled on a hardcoded 30 s timer. That is not merely a
# slow poll — argonaut sizes the runtime watchdog as `interval * retries +
# timeout` from the service's OWN configured interval, so a service asking for
# 5 s and polled at 30 s carried a watchdog sized for a cadence it never got.
#
# kyb-health asks for interval_ms: 1000, so a correct kybernet re-arms the
# timer to 1 s and says so. The assertion is the LOG LINE rather than observed
# tick spacing: timing an interval inside a 5 s VM window would be asserting
# the outcome of a race (rule 36), whereas the line proves the config value
# reached timerfd_settime, which is the property that was missing.
if echo "$RUNTIME_OUT" | grep -aqF "health poll interval (s): 1"; then
    echo "  OK: health_check.interval_ms drove the poll timer (1s, from kyb-health)"
else
    echo "  FAIL: the health timer was not re-armed from config — interval_ms is ignored again"
    echo "$RUNTIME_OUT" | grep -aiE 'health poll interval' | head -2 || true
    fail=1
fi

# --- non-root services (1.6.9) -----------------------------------------------
#
# The whole uid/gid half of privdrop.cyr was unreachable: `drop_privileges` had
# no caller anywhere, there was no config key, and every service therefore ran
# as root. That is why the 1.6.3 sd_notify forgery analysis concluded the real
# exposure was one compromised service forging notifications ABOUT ANOTHER —
# with no uid separation, SO_PASSCRED's uid check excludes nobody.
#
# ⚠ THE ASSERTION IS THE UID, NOT THE SURVIVAL. A service that merely starts
# proves nothing; a root service starts too. kyb-nonroot reads its OWN
# /proc/self/status and records the Uid/Gid lines, so the value is observed
# from inside the dropped child.
#
# It cannot report directly: /dev/console is 0600 root, which is exactly the
# point — a non-root service has genuinely lost that access. It writes to
# /dev/shm (tmpfs mode=1777) and a root reader with an explicit depends_on
# surfaces it. The dependency is load-bearing, not decoration: without it the
# wave order is whatever the resolver produces and the reader can run first
# (standing rule 36 — the same trap that made kyb-limited pass on luck).
if echo "$RUNTIME_OUT" | grep -aqE '^NONROOT-Uid:[[:space:]]*65534'; then
    echo "  OK: service ran as uid 65534 — privilege drop reached the child"
elif echo "$RUNTIME_OUT" | grep -aqE '^NONROOT-Uid:[[:space:]]*0'; then
    echo "  FAIL: service ran as ROOT despite security.uid — the drop did not happen"
    fail=1
else
    echo "  FAIL: no NONROOT-Uid line — the service died, or the reader ran first"
    echo "$RUNTIME_OUT" | grep -aiE 'nonroot' | head -3 || true
    fail=1
fi

if echo "$RUNTIME_OUT" | grep -aqE '^NONROOT-Gid:[[:space:]]*65534'; then
    echo "  OK: gid dropped to 65534 as well"
else
    echo "  FAIL: gid was not dropped — setgid must precede setuid or it cannot happen"
    fail=1
fi

# --- capabilities AND a uid, together (1.6.14 HIGH-3) ------------------------
#
# ⚠ THE INTERSECTION OF THE TWO MOST IMPORTANT SECURITY KEYS, WHICH NO FIXTURE
# HAD EVER COMBINED. kyb-confined sets `capabilities` and no uid; kyb-nonroot
# sets a uid and no `capabilities`. Both passed, and the combination could not
# work at all: the capability step surrendered CAP_SETGID/CAP_SETUID before the
# privilege drop needed them, so `{"capabilities": [...], "uid": N}` — the
# canonical "bind a low port as an unprivileged user" policy — was accepted by
# the parser and made the service exit 126 every time. Two green fixtures, one
# on each axis, and the axis nobody crossed was broken.
#
# ⚠ THE TRAILING ANCHOR IS A NON-HEX BOUNDARY, NOT `[[:space:]]*$`. The serial
# capture carries a trailing carriage-return artefact that `$` will not see
# past, so an anchored match silently never fires — a green-looking assertion
# that can only ever FAIL, which is the mirror of the usual defect and just as
# useless. `([^0-9a-fA-F]|$)` still rejects a longer mask: 0x4004 does not
# match, 0x400 followed by anything non-hex does.
#
# CapAmb is the assertion that matters. Permitted alone would not survive
# execve of a plain binary, so a service can hold a capability in Prm and still
# reach main() with nothing: the AMBIENT set is what actually delivers it.
if echo "$RUNTIME_OUT" | grep -aqE '^CAPUID-Uid:[[:space:]]*65534'; then
    echo "  OK: capabilities+uid service ran as uid 65534"
elif echo "$RUNTIME_OUT" | grep -aqE '^CAPUID-Uid:[[:space:]]*0'; then
    echo "  FAIL: capabilities+uid service ran as ROOT — the drop did not happen"
    fail=1
else
    echo "  FAIL: no CAPUID-Uid line — the service never started (exit 126 = the 1.6.13 shape)"
    echo "$RUNTIME_OUT" | grep -aiE 'capuid' | head -3 || true
    fail=1
fi

# 0x400 = 1 << 10 = CAP_NET_BIND_SERVICE, and nothing else.
if echo "$RUNTIME_OUT" | grep -aqE '^CAPUID-CapAmb:[[:space:]]*0*400([^0-9a-fA-F]|$)'; then
    echo "  OK: CAP_NET_BIND_SERVICE is AMBIENT — it survives execve to the service"
else
    echo "  FAIL: the kept capability is not in the ambient set — a non-root service gets nothing"
    echo "$RUNTIME_OUT" | grep -aE '^CAPUID-Cap' | head -3 || true
    fail=1
fi

if echo "$RUNTIME_OUT" | grep -aqE '^CAPUID-CapBnd:[[:space:]]*0*400([^0-9a-fA-F]|$)'; then
    echo "  OK: the bounding set is exactly the keep-list — nothing can be regained"
else
    echo "  FAIL: the bounding set is not the keep-list"
    echo "$RUNTIME_OUT" | grep -aE '^CAPUID-CapBnd' | head -2 || true
    fail=1
fi

# --- Landlock (1.6.6) --------------------------------------------------------
#
# ⚠ THE THIRD CONFINEMENT MECHANISM, AND THE LAST ONE WITHOUT A FIXTURE.
# kyb-confined covers capabilities and no_new_privs; kyb-seccomp covers the
# filter; `"landlock"` reached landlock_restrict_self through kyb_pre_exec with
# NOTHING asserting it did anything. That is precisely the shape in which
# `"seccomp": "basic"` shipped for three releases killing every service it was
# applied to (standing rule 27).
#
# ⚠ THE ASSERTION IS THE DENIAL, NOT THE SURVIVAL. kyb-landlock is granted
# read-exec on /bin ONLY. It then reads a path inside the rule set and a path
# outside it, reporting both from INSIDE the confined child. "The service ran"
# proves nothing — an unconfined service also runs. Requiring BOTH outcomes is
# what makes this falsifiable: if Landlock silently did nothing, the outside
# read would succeed and this fails; if the ruleset were wrong in the other
# direction, the inside read would fail and this also fails.
#
# Note rule 29: sandbox_apply returns Ok(1) when the kernel has no Landlock
# (pre-5.13). The fixture sets "landlock_optional": false, so on such a kernel
# kyb_pre_exec fails the service closed rather than starting it unconfined —
# which surfaces here as the INSIDE read being absent, not as a false pass.
if echo "$RUNTIME_OUT" | grep -aqF "LL-OUTSIDE=DENIED"; then
    echo "  OK: landlock denied a path outside the rule set"
elif echo "$RUNTIME_OUT" | grep -aqF "LL-OUTSIDE=ALLOWED"; then
    echo "  FAIL: landlock did NOT deny a path outside its rule set — the sandbox is inert"
    fail=1
else
    echo "  FAIL: kyb-landlock produced no LL-OUTSIDE line — it never ran, or died"
    echo "$RUNTIME_OUT" | grep -aiE 'landlock|LL-' | head -3 || true
    fail=1
fi

if echo "$RUNTIME_OUT" | grep -aqF "LL-INSIDE=ALLOWED"; then
    echo "  OK: landlock still permitted a path inside the rule set"
else
    echo "  FAIL: landlock denied a path it was told to allow (or the child never ran)"
    echo "$RUNTIME_OUT" | grep -aiE 'LL-' | head -3 || true
    fail=1
fi

# ⚠ A DENIED `open` SAYS NOTHING ABOUT `truncate`. 1.6.14 HIGH-2.
#
# A Landlock ruleset governs only the operations named in `handled_access_fs`,
# and kybernet's mask was frozen at ABI v1 — which has no
# LANDLOCK_ACCESS_FS_TRUNCATE (1 << 14, ABI v3 / Linux 6.2). So every confined
# service could `truncate("/boot/vmlinuz", 0)` while `sandbox_from_config`
# returned Ok(0) "applied", and this pass could not see it because the fixture
# only ever called `sys_open(O_RDONLY)`. Measured on the dev box: open denied,
# truncate allowed, a 16-byte file reduced to 0.
#
# Since the uid drop is opt-in, the common shape is a ROOT service under
# Landlock, for which DAC imposes nothing either — so this reached every file
# on the filesystem.
if echo "$RUNTIME_OUT" | grep -aqF "LL-TRUNCATE=DENIED"; then
    echo "  OK: landlock denied truncate() on a path outside the rule set"
elif echo "$RUNTIME_OUT" | grep -aqF "LL-TRUNCATE=ALLOWED"; then
    echo "  FAIL: landlock allowed truncate() outside its rule set — file destruction is unconfined"
    fail=1
else
    echo "  FAIL: kyb-landlock produced no LL-TRUNCATE line — the fixture is stale or died"
    echo "$RUNTIME_OUT" | grep -aiE 'LL-' | head -3 || true
    fail=1
fi

if echo "$RUNTIME_OUT" | grep -qE '^Seccomp_filters:[[:space:]]*[1-9]'; then
    echo "  OK: kyb-seccomp has at least one filter installed"
else
    echo "  FAIL: kyb-seccomp reports no installed seccomp filter"
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
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-cgroup' | head -1 || true
    fail=1
fi
if echo "$RUNTIME_OUT" | grep -aqF "LIMIT-memmax=67108864"; then
    echo "  OK: memory.max applied (64 MiB, read back from kernel)"
else
    echo "  FAIL: memory.max not applied"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-memmax' | head -1 || true
    fail=1
fi
# ⚠ THE HARD CPU CAP. 1.6.17.
#
# kybernet could express `cpu.weight` — a RELATIVE share, meaning "this service
# matters less than its neighbours when they compete" — and could not express a
# ceiling, so no service could be told it may never exceed half a core. The
# blocker was mechanical: every other limit file takes one integer and `cpu.max`
# takes "<quota> <period>".
#
# 50000 against the kernel's default 100000 us period is 0.5 CPU, so the file
# must read back exactly "50000 100000" — the period proves kybernet wrote both
# halves rather than the kernel defaulting one.
# ⚠ A FAILED PREREQUISITE MUST BLOCK ITS DEPENDENTS. 1.6.17.
#
# `resolve_service_waves` only ORDERS the waves — a wave-N failure incremented
# `failed` and wave N+1 started regardless. So a service whose prerequisite did
# not come up was launched into a world without the thing it requires, and
# either exited nonzero immediately (an exit the operator has to trace back by
# hand) or ran degraded against missing state.
#
# kyb-prereq-fail cannot start: its binary does not exist. kyb-prereq-dep
# depends on it and prints PREREQ-DEP-RAN if it runs. The assertion that matters
# is the ABSENCE of that line — a service that merely started proves nothing,
# since it would have started before this change too.
#
# Note the cgroup count is 16, not 17, for 17 services: the FAILED service is
# prepared before argonaut is asked to start it and so owns a cgroup, while the
# SKIPPED one is caught before `_prepare_service_cgroup` and owns none. That
# asymmetry is deliberate and is what the count is pinning.
if echo "$RUNTIME_OUT" | grep -aqF "FAILED to start: kyb-prereq-fail"; then
    echo "  OK: a service with a missing binary fails to start"
else
    echo "  FAIL: kyb-prereq-fail did not fail — the fixture no longer proves anything"
    fail=1
fi

if echo "$RUNTIME_OUT" | grep -aqF "SKIPPED (prerequisite failed): kyb-prereq-dep"; then
    echo "  OK: a dependent of a failed service is SKIPPED, with the blocker named"
else
    echo "  FAIL: kyb-prereq-dep was not skipped — a failed prerequisite did not block it"
    echo "$RUNTIME_OUT" | grep -aiE 'prereq' | head -3 || true
    fail=1
fi

if echo "$RUNTIME_OUT" | grep -aqF "PREREQ-DEP-RAN"; then
    echo "  FAIL: kyb-prereq-dep RAN despite its prerequisite failing"
    fail=1
else
    echo "  OK: the dependent never executed — the skip is real, not just logged"
fi

if echo "$RUNTIME_OUT" | grep -aqE '^LIMIT-cpumax=50000 100000'; then
    echo "  OK: cpu.max applied (0.5 CPU, read back from kernel)"
else
    echo "  FAIL: cpu.max not applied — the hard CPU cap did not reach the kernel"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-cpumax' | head -1 || true
    fail=1
fi

if echo "$RUNTIME_OUT" | grep -aqF "LIMIT-pidsmax=32"; then
    echo "  OK: pids.max applied (32, read back from kernel)"
else
    echo "  FAIL: pids.max not applied"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-pidsmax' | head -1 || true
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
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-cpuweight' | head -1 || true
    fail=1
fi
if echo "$RUNTIME_OUT" | grep -aqF "LIMIT-memhigh=50331648"; then
    echo "  OK: memory.high applied (48 MiB, read back from kernel)"
else
    echo "  FAIL: memory.high not applied"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-memhigh' | head -1 || true
    fail=1
fi
if echo "$RUNTIME_OUT" | grep -aqE '^LIMIT-ctrl=.*memory.*pids'; then
    echo "  OK: cgroup subtree_control enables memory + pids"
else
    echo "  FAIL: cgroup controllers not enabled on the slice"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-ctrl' | head -1 || true
    fail=1
fi
if echo "$RUNTIME_OUT" | grep -aqF "LIMIT-unlimited=max"; then
    echo "  OK: unlimited service reads memory.max=max (control case)"
else
    echo "  FAIL: control case wrong — kyb-live should be unlimited"
    echo "$RUNTIME_OUT" | grep -aE '^LIMIT-unlimited' | head -1 || true
    fail=1
fi

# 1.5.1: no boot stage may fail in the harness. Before 1.5.1 this could not
# have fired — execute_boot_stage returned 1 for all eleven stages, so
# init_mark_step_failed was unreachable and a stage failure was structurally
# impossible to observe. Now that stages do real work, a FATAL here means a
# stage genuinely did not do its job.
if echo "$RUNTIME_OUT" | grep -aqF "FATAL: required boot stage failed"; then
    echo "  FAIL: a required boot stage failed"
    echo "$RUNTIME_OUT" | grep -aF "FATAL: required boot stage failed" | head -3 || true
    fail=1
else
    echo "  OK: no boot stage failed"
fi

# Boot-time budget. See the KYB_MS derivation above: the gate is kybernet's
# own span (`kybernet: starting` -> `kybernet: shutdown`), NOT wall time.
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
# The retry disappears with it and boots land at ~650 ms again. If this ever
# needs raising, find out what is actually slow first — do not just move the
# number. (1.6.1 did exactly that and found 82% of the old number was the
# runner's kernel, which is why the gate moved to KYB_MS.)
#
# 1200 ms against a measured 119 ms on Arch and 494 ms on the azure kernel is
# ~2.4x headroom over the slower of the two, on the metric that no longer
# includes kernel boot.
echo ""
if [ "$KYB_MS" -lt 0 ]; then
    echo "  FAIL: could not time kybernet's span (missing start/shutdown marker)"
    fail=1
else
    echo "  kybernet span: ${KYB_MS} ms (budget: ${BUDGET_MS} ms, excludes kernel boot)"
    if [ "$KYB_MS" -gt "$BUDGET_MS" ]; then
        echo "  FAIL: kybernet exceeded its boot budget"
        fail=1
    fi
fi

# Wall time is retained as a LOOSE liveness ceiling only — it catches a hang
# that never reaches the shutdown marker at all. It is deliberately far above
# anything a real runner produces (measured tail: 4269 ms under contention on
# direct KVM; nested is slower) because its job is "did this board die", not
# "is kybernet fast".
echo "  boot wall time: ${WALL_MS} ms (ceiling: ${WALL_CEILING_MS} ms, includes qemu + kernel)"
if [ "$WALL_MS" -gt "$WALL_CEILING_MS" ]; then
    echo "  FAIL: wall time exceeded the liveness ceiling — the VM is not just slow"
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
# ⚠ NOT GUARDED ON `$fail`. Until 1.6.1 this whole block sat inside
# `if [ $fail -eq 0 ]`, so ANY pass-1 marker failure silently skipped it —
# and pass 1 has ~25 assertions, several of which have been flaky. Standing
# rule 23 exists because this is the ONLY gate that executes a reactor
# iteration; making it conditional on everything else passing meant the
# rule was one unrelated failure away from not being enforced, with no
# line in the output saying so. It is a separate boot with its own log and
# its own assertions: it costs one qemu invocation and it always runs.
# `fail` keeps accumulating across both passes.
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

# 1.6.1 — the health-check and watchdog tick BODIES actually execute.
#
# Before this fixture, `grep -rn health_check qemu/` returned nothing, so
# init_poll_health recorded nothing for any service and both tick handlers
# drained empty vecs on every reactor tick. The reactor gate proved the
# DRAINS happen (audit rule 13) and nothing more — every
# restart-on-threshold and watchdog path from 1.5.4 was dead code in
# practice. Worth stating plainly: with no health_check configured there
# is NO WATCHDOG AT ALL, because init_check_watchdog's only non-startup
# arm is health-check-driven.
#
# kyb-health fails deterministically: a TCP connect to 127.0.0.1:9
# (discard), which nothing in the initramfs listens on, with retries=1 so
# the first failed poll crosses the threshold.
# 1.6.1 — PID 1 reaps a child it did not start.
#
# kyb-orphan backgrounds `sleep 1` and exits, so the sleep is reparented
# to init and must be collected by reap_and_log (src/lib/reaper.cyr) on
# SIGCHLD — a different path from argonaut's init_reap_services, which
# only knows about managed services. This is the property
# qemu/boot-crash-test.sh was written for; that script booted with
# -m 256M, which audit rule 8 says fails alloc_init outright, so it has
# been retired in favour of asserting it here where it actually runs.
# ⚠ ASSERTED AT LAST, IN THE REACTOR PASS, AFTER ELEVEN RELEASES OF
# "NOT ASSERTED". The fixture exercised the orphan path from 1.6.1 but
# nothing observable came out of it: argonaut's init_reap_services calls
# proc_table_reap_orphans_into(), which does waitpid(-1, WNOHANG) in a
# loop, and it DISCARDED the count — and it runs before kybernet's own
# reaper, so reap_and_log finds nothing left and stays silent too. The
# count was thrown away twice and the property was untestable from here.
# argonaut 1.13.8 added init_last_orphan_count(); kybernet 1.6.12 reads it
# in handle_sigchld and logs "reaped orphans: N".
#
# ⚠ IT IS ASSERTED IN THE REACTOR PASS AND NOT THE BOOT PASS, WHICH IS
# STANDING RULE 41. handle_sigchld is reachable from exactly one place:
# the event loop's TOKEN_SIGNAL arm. kybernet.harness=1 shuts down at
# phase 9 BEFORE the reactor starts, so under that mode the orphan's
# SIGCHLD sits queued in the signalfd and is never handled. Asserting it
# there would fail confidently for a feature that works.

if echo "$LOOP_OUT" | grep -aqE "reaped orphans: [1-9]"; then
    echo "  OK: PID 1 reaped a child it did not start (orphan count surfaced)"
else
    echo "  FAIL: no orphan reap observed — kyb-orphan's child was not collected,"
    echo "        or init_last_orphan_count() is not being read (argonaut >= 1.13.8)"
    echo "$LOOP_OUT" | grep -aiE 'orphan|reaped' | head -5 || true
    fail=1
fi

if echo "$LOOP_OUT" | grep -aqF "health check failed: kyb-health"; then
    echo "  OK: health tick body executed and reported a failing check"
else
    echo "  FAIL: no health-check failure observed — the tick body never ran"
    echo "$LOOP_OUT" | grep -aiE 'health' | head -3 || true
    fail=1
fi

# ⚠ THE WATCHDOG KILL RAN ON EVERY REACTOR PASS AND NOTHING ASSERTED IT.
# 1.6.16 LOW-5.
#
# `init_poll_health` and `init_check_watchdog` are INDEPENDENT paths: the
# assertion above covers the probe, and nothing covered the kill. So a
# regression that stopped the watchdog killing while leaving the probe intact
# left all 66 properties green with PID 1 having no runtime watchdog at all — a
# wedged service never killed, never restarted, which is the exact failure the
# watchdog exists to prevent.
#
# The concrete regression this guards is the one CLAUDE.md already warns about:
# writing `managed_svc_set_last_hc` on a FAILED probe would silence the watchdog,
# and that is a plausible edit while touching argonaut's `_hc_is_due` scheduling.
#
# Same shape as `"seccomp": "basic"` (rule 27) except HARDER to notice — there
# the fixture was missing, here the fixture exists and drives the path, and only
# the assertion was absent. Verified present in a real loop boot before being
# asserted, and verified to go red by stubbing argonaut's `init_enforce_watchdog`.
#
# Deliberately NOT asserting "watchdog restart scheduled": measured absent under
# this fixture and correctly so — the restart half is already covered by the
# `restarting:` / `restarted:` assertions above.
if echo "$LOOP_OUT" | grep -aqF "watchdog killed: kyb-health"; then
    echo "  OK: the watchdog actually KILLED the unhealthy service"
else
    echo "  FAIL: the watchdog never killed kyb-health — the probe ran but the kill path did not"
    echo "$LOOP_OUT" | grep -aiE 'watchdog|kyb-health' | head -5 || true
    fail=1
fi

# ⚠ THESE LIVE IN THE REACTOR PASS, NOT THE BOOT PASS, AND THAT IS THE WHOLE
# POINT OF STANDING RULE 23. `handle_notify_msg` is only ever called from the
# event loop (main.cyr's TOKEN_NOTIFY arm). `kybernet.harness=1` shuts down at
# phase 9 BEFORE the reactor starts, so under that mode the fixture's datagrams
# sit unread in the socket queue and are discarded at shutdown. I put them in
# the boot pass first and got five failures for a feature that works: the gate
# was asserting the outcome of code it had arranged never to run.
# --- sd_notify (1.6.3) — REACTOR PASS -----------------------------------------------------
#
# ⚠ THIS IS THE PASS THAT DID NOT EXIST. Before 1.6.3 `grep -rn notify qemu/`
# returned nothing: kybernet bound the socket, registered it with epoll and
# wrote a handler, and no release gate had ever delivered a datagram to it.
# Same shape as `"seccomp": "basic"`, which shipped for three releases killing
# every service it was applied to (standing rule 27).
#
# kyb-notify sends four datagrams as a real supervised service, so the kernel
# stamps SCM_CREDENTIALS with a pid kybernet knows. Each assertion below proves
# a different half of the path.

# 1. The datagram was ACCEPTED and ATTRIBUTED to the sending service. This is
#    the whole authentication story: before 1.6.3 nothing set SO_PASSCRED and
#    the receive passed a NULL src_addr, so kybernet could not have named the
#    sender even in principle.
# ⚠ THE STRING CHANGED AT 1.6.8 AND THAT IS THE ASSERTION. Before argonaut
# 1.13.6 a READY could only be logged as an observation ("notify: ready: X")
# because no service was ever awaiting one — every type went STATE_RUNNING the
# instant fork+exec returned. kyb-notify is now `"type": "notify"`, so it is
# left STATE_STARTING and its own authenticated READY=1 is what promotes it.
# Matching the PROMOTION line rather than the observation line is what makes
# this prove a state transition instead of a log statement.
if echo "$LOOP_OUT" | grep -aqF "notify: READY - service is now running: kyb-notify"; then
    echo "  OK: READY promoted a type=notify service from STARTING to RUNNING"
elif echo "$LOOP_OUT" | grep -aqF "notify: ready: kyb-notify"; then
    echo "  FAIL: READY was logged but did NOT promote the service — is the type notify?"
    fail=1
else
    echo "  FAIL: no attributed READY — SO_PASSCRED, the drain, or attribution is broken"
    echo "$LOOP_OUT" | grep -aiE 'notify' | head -5 || true
    fail=1
fi

# 2. STATUS= first, READY= second. The pre-1.6.3 classifier compared at offset
#    0 and returned the FIRST match, so this ordering — the one systemd's own
#    docs show — silently LOST the readiness notification. The fixture sends
#    both a plain READY and a STATUS-then-READY datagram; two accepted READY
#    lines proves the multiline scan works.
# ⚠ COUNT BOTH FORMS. The fixture sends two READY datagrams: a plain one and a
# STATUS-then-READY one. The FIRST promotes the service and logs the promotion
# line; the second finds it already RUNNING and logs the observation line,
# because init_notify_ready is idempotent. Counting only the observation string
# therefore sees 1, not 2 — and would fail on correct behaviour.
_ready_n=$(echo "$LOOP_OUT" | grep -acE "notify: (READY - service is now running|ready): kyb-notify" || true)
if [ "$_ready_n" -ge 2 ]; then
    echo "  OK: READY found after a STATUS line (multiline scan)"
else
    echo "  FAIL: only one READY seen — the STATUS-then-READY datagram lost its READY"
    fail=1
fi

# 3. WATCHDOG is accepted and attributed but explicitly NOT honoured. The only
#    refreshable deadline is managed_svc_last_hc, which already means "the last
#    health check PASSED" — refreshing it on a self-reported ping would let a
#    wedged service silence a probe kybernet actually ran and saw fail.
if echo "$LOOP_OUT" | grep -aqF "notify: watchdog ping: kyb-notify"; then
    echo "  OK: WATCHDOG ping accepted and refreshed the notify deadline"
else
    echo "  FAIL: watchdog ping was not accepted"
    fail=1
fi

# 4. The status text reached the log SANITISED. The fixture sends an ESC
#    sequence; a raw ESC byte on the console means attacker-controlled text is
#    reaching dmesg unfiltered.
if echo "$LOOP_OUT" | grep -aqF "notify: status: kyb-notify"; then
    if echo "$LOOP_OUT" | grep -aq 'esc\.\[31mred'; then
        echo "  OK: status text sanitised (ESC replaced)"
    else
        echo "  FAIL: status line present but the ESC byte was not sanitised"
        echo "$LOOP_OUT" | grep -aiE 'notify: status' | head -3 || true
        fail=1
    fi
else
    echo "  FAIL: no attributed status line"
    fail=1
fi

# 4b. ⚠ A FORGED MAINPID IS REFUSED. This is the assertion that distinguishes
#     authentication from authorisation. kyb-notify is authenticated, attributed
#     and entirely legitimate — and it claims MAINPID=1, which is kybernet
#     itself and is emphatically not in its cgroup. Honouring it would point
#     kybernet's supervision, and eventually its kill path, at PID 1.
#
#     It also sends MAINPID=-1, which `str_to_int` would have read as -1: from
#     PID 1 that value handed to kill(2) is every process on the machine.
#
#     Both must be refused, and the counter proves it rather than the absence
#     of a crash.
if echo "$LOOP_OUT" | grep -aqF "notify: MAINPID not in this service's cgroup - REFUSED"; then
    echo "  OK: a forged MAINPID (pid 1) was refused on cgroup membership"
else
    echo "  FAIL: forged MAINPID was not refused — authorisation check missing"
    echo "$LOOP_OUT" | grep -aiE 'mainpid' | head -3 || true
    fail=1
fi

if echo "$LOOP_OUT" | grep -aqF "notify: MAINPID malformed - ignored"; then
    echo "  OK: a malformed MAINPID (-1) was rejected by the bounded parse"
else
    echo "  FAIL: malformed MAINPID was not rejected — str_to_int would read it as -1"
    fail=1
fi

if echo "$LOOP_OUT" | grep -aqE "notify: refused-mainpid: [1-9]"; then
    echo "  OK: refused-MAINPID counter recorded the attempts"
else
    echo "  FAIL: refused-mainpid counter is zero — were the claims even seen?"
    fail=1
fi

# 5. Nothing was rejected. Every datagram came from a live service pid, so a
#    non-zero reject count means authentication is refusing legitimate traffic
#    — the failure mode where SO_PASSCRED is set but the cmsg parse is wrong.
if echo "$LOOP_OUT" | grep -aqF "notify: rejected: 0"; then
    echo "  OK: no legitimate datagram was rejected"
else
    echo "  FAIL: some datagrams were rejected — cmsg parsing or attribution is wrong"
    echo "$LOOP_OUT" | grep -aiE 'notify: (accepted|rejected)' | head -3 || true
    fail=1
fi

rm -f "$LOOP_LOG"

# ============================================================
# Quiet gate (1.6.4) — `log_to_console: false` actually suppresses.
#
# From 1.5.0 to 1.6.3 this key was parsed, stored and copied on reload, and
# `config_log_console` had exactly TWO readers in the tree: its own definition
# and that reload copy. `klog`/`klog2` wrote to STDERR_FD unconditionally, so
# setting it false did nothing whatsoever. Rule 27: the key reaches a syscall
# (sys_write), so it needs a fixture.
#
# ⚠ THE FALSIFIABILITY GUARD IS THE WHOLE DESIGN HERE. "kybernet printed
# nothing" is exactly what a board that died before phase 1 also looks like, so
# an assertion that only counts absent lines cannot fail correctly. This pass
# therefore requires BOTH: kybernet's own lines collapse, AND a line a SERVICE
# wrote to /dev/console is still present — proving the boot got all the way
# through phase 8 while kybernet itself stayed quiet.
# ============================================================
QUIET_INITRD="${SCRIPT_DIR}/initramfs-quiet.cpio.gz"
echo ""
echo "=== quiet gate (log_to_console=false) ==="
if [ ! -f "$QUIET_INITRD" ]; then
    _skip_or_fail "no quiet fixture (log_to_console is ungated)"
else
    QUIET_OUT=$(timeout "$TIMEOUT" qemu-system-x86_64 \
        -kernel "$KERNEL" -initrd "$QUIET_INITRD" \
        -append "console=ttyS0 panic=5 rdinit=/sbin/init kybernet.harness=1 loglevel=3" \
        $ACCEL_FLAGS -m 512M -nographic -no-reboot \
        -serial mon:stdio 2>&1 | cat -v | tr '\r' '\n')
    _assert_no_panic "$QUIET_OUT" "quiet"

    QN=$(echo "$QUIET_OUT" | grep -acF "kybernet: " || true)
    # Only the pre-config-load lines may survive: everything up to and including
    # the announcement that console logging is going off. Measured at 6; the
    # ceiling of 10 leaves room for a phase marker without letting a regression
    # that disables the gate entirely slip through.
    if [ "$QN" -le 10 ]; then
        echo "  OK: log_to_console=false suppressed kybernet's console output ($QN lines)"
    else
        echo "  FAIL: log_to_console=false did not suppress ($QN kybernet lines)"
        echo "$QUIET_OUT" | grep -aF "kybernet: " | head -5 || true
        fail=1
    fi

    # The guard: a SERVICE-written console line proves the boot progressed.
    if echo "$QUIET_OUT" | grep -aqE '^LIMIT-memmax=67108864'; then
        echo "  OK: services still reached the console (the boot was quiet, not dead)"
    else
        echo "  FAIL: no service output — the quiet boot did not progress, so the"
        echo "        line count above proves nothing"
        fail=1
    fi

    # And the last thing said before the silence must explain it.
    if echo "$QUIET_OUT" | grep -aqF "console logging OFF"; then
        echo "  OK: the transition to quiet is announced on the console"
    else
        echo "  FAIL: console went quiet with no line explaining why"
        fail=1
    fi
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
# ⚠ STRICT MODE — the answer to "a skip and a pass look the same".
#
# Three of this harness's four passes are guarded on a fixture existing, and
# a missing fixture printed SKIP and moved on. That is right on a developer
# box without veritysetup, and useless as a gate: a change that BREAKS
# fixture generation produces exactly the same SKIP as a machine that never
# had the tool, so the regression class the pass exists to catch is the one
# it cannot see. CI sets HARNESS_STRICT=1 (it installs the tools, so a
# missing fixture there means something broke). The strict flag and the two
# helpers it drives are defined near the top of this script, above every pass
# that calls them.

EDGE_INITRD="${SCRIPT_DIR}/initramfs-edge.cpio.gz"
EDGE_DIR="${SCRIPT_DIR}/edge"
if [ ! -f "$EDGE_INITRD" ]; then
    echo ""
    echo "=== edge gate ==="
    _skip_or_fail "no edge fixture — veritysetup absent on the build host"
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
    _assert_no_panic "$GOOD_OUT" "edge good"

    # Distinguish a BROKEN FIXTURE from a real failure. kybernet reports
    # "veritysetup missing or unrunnable" (rc 127 / spawn failure) as a
    # distinct outcome from a verification verdict, precisely so this gate
    # can tell them apart. An incomplete shared-library closure in the
    # staged initramfs is an environment problem, not a kybernet defect —
    # skip loudly rather than fail, and never silently pass.
    # Match the klog line, not the kmsg one: kmsg goes to /dev/kmsg and the
    # harness boots with loglevel=3, which keeps it off the serial console.
    if echo "$GOOD_OUT" | grep -aqF "veritysetup could not run"; then
        # ⚠ ROUTED THROUGH STRICT MODE, with its OWN message. This used to be a
        # bare `echo SKIPPED` that set SKIP_EDGE=1 and nothing else — the one
        # edge path that ignored HARNESS_STRICT. The run still went red, but
        # indirectly and much later, because SKIP_EDGE=1 makes the auth block
        # report "no auth fixture". So a broken shared-library closure inside
        # the VM — precisely the multiarch failure the staging loop in
        # build-initramfs.sh exists to prevent, i.e. the Ubuntu-specific one —
        # was reported to the operator as a missing credential fixture. That is
        # a full CI round trip spent diagnosing the wrong subsystem.
        _skip_or_fail "staged veritysetup could not run in the VM (incomplete library closure — fixture problem, not a kybernet defect)"
        SKIP_EDGE=1
    fi

    if [ "$SKIP_EDGE" != "1" ] && echo "$GOOD_OUT" | grep -aqF "dm-verity integrity VERIFIED"; then
        echo "  OK: intact image verifies against its root hash"
    elif [ "$SKIP_EDGE" != "1" ]; then
        echo "  FAIL: intact image did not verify"
        echo "$GOOD_OUT" | grep -aiE 'edge boot|verit' | head -5 || true
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
    _assert_no_panic "$BAD_OUT" "edge corrupt"
    if echo "$BAD_OUT" | grep -aqF "dm-verity verification FAILED"; then
        echo "  OK: corrupted image fails verification"
    else
        echo "  FAIL: corrupted image was not detected"
        echo "$BAD_OUT" | grep -aiE 'edge boot|verit' | head -5 || true
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
    _assert_no_panic "$PERM_OUT" "edge permissive"
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
    _assert_no_panic "$OFF_OUT" "edge off"
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

# ============================================================
# Emergency-auth gate (1.5.8)
#
# This is a REGRESSION TEST FOR A BRICK, not a feature test.
#
# From 1.5.4 until 1.5.8 the password prompt read fd 0 — which setup_console
# deliberately points at /dev/null, so services never block on a console. The
# read returned EOF instantly, authentication always failed, and the failure
# path rebooted. Once 1.5.7 began forcing require_auth on an edge refusal, a
# board with a hash configured refused, rebooted, refused, rebooted, forever.
# The pre-fix serial log shows the whole story on one line:
#
#     Password: kybernet: emergency shell: AUTHENTICATION FAILED — rebooting
#
# Feeding stdin is what makes this assertable: `-serial stdio` (not
# `mon:stdio`, which multiplexes the monitor onto the same stream) takes the
# password from a pipe after a delay long enough for the prompt to appear.
AUTH_INITRD="${SCRIPT_DIR}/initramfs-auth.cpio.gz"
if [ ! -f "$AUTH_INITRD" ] || [ "${SKIP_EDGE:-0}" = "1" ]; then
    echo ""
    echo "=== emergency-auth gate ==="
    _skip_or_fail "no auth fixture (both credential formats ungated — CLAUDE.md rule 26)"
else
    echo ""
    echo "=== emergency-auth gate (console prompt + echo suppression) ==="

    AUTH_BAD="${EDGE_DIR}/auth-corrupt.img"
    cp "${EDGE_DIR}/data.img" "$AUTH_BAD"
    printf 'CORRUPTED' | dd of="$AUTH_BAD" bs=1 seek=2000 conv=notrunc status=none

    # These boots must outlive the feeder's own sleeps, so they get their own
    # floor rather than the caller's default (15 s, which cuts the run off
    # mid-password and silently skips the later assertions).
    AUTH_TIMEOUT="$TIMEOUT"
    [ "$AUTH_TIMEOUT" -lt 45 ] && AUTH_TIMEOUT=45

    _auth_boot() {
        # $1 = password to type, $2 = the initrd to boot. The sleep is a fixed
        # wait for the prompt; under KVM it appears in ~1 s, under TCG a few
        # seconds, so 8 s is generous on both.
        #
        # ⚠ 1.5.9 — the KDF fixture spends ~230 ms more before the verdict
        # (Argon2id at m=19456/t=2 on top of everything else), which is well
        # inside the 5 s trailing sleep. If the parameters are ever raised,
        # raise that sleep with them or the boot is cut off mid-verify and the
        # assertion silently reports a failure that is really a timeout.
        ( sleep 8; printf '%s\n' "$1"; sleep 5 ) | timeout "$AUTH_TIMEOUT" qemu-system-x86_64 \
            -kernel "$KERNEL" -initrd "${2:-$AUTH_INITRD}" \
            -append "console=ttyS0 panic=5 rdinit=/sbin/init kybernet.harness=1 loglevel=3" \
            -drive "file=${AUTH_BAD},if=virtio,format=raw" \
            -drive "file=${EDGE_DIR}/hash.img,if=virtio,format=raw" \
            $ACCEL_FLAGS -m 512M -nographic -no-reboot -monitor none \
            -serial stdio 2>&1 | cat -v | tr '\r' '\n'
        # `timeout` kills qemu with 124 on the reject path, because a
        # rejection now HALTS (sys_pause) instead of rebooting — so the guest
        # never exits on its own. That is the correct behaviour under test,
        # not a failure, and `set -e` must not abort on it.
        return 0
    }

    # The four properties, run against whichever credential format is staged.
    # $1 = initrd, $2 = a label for the log lines.
    _auth_assert() {
        local initrd="$1" label="$2"
        local ok_out bad_out

        ok_out=$(_auth_boot "hunter2" "$initrd" || true)
        _assert_no_panic "$ok_out" "$label correct-password"
        if echo "$ok_out" | grep -aqF "emergency shell: authenticated"; then
            echo "  OK: [$label] correct password authenticates"
        else
            # Discriminate the real regression from a slow VM. Both produce the
            # same missing "authenticated" line, but they mean opposite things:
            # no prompt at all = the boot died earlier or the fixed 8 s wait in
            # _auth_boot fired before the prompt appeared (nested virt, cold
            # cache); a prompt with no verdict = the 1.5.4-1.5.7 brick, where
            # the read hit EOF on fd 0 and treated it as a failed auth. Saying
            # "brick" for the former sends the next person into emergency_auth
            # for what is a timing problem in this script.
            if echo "$ok_out" | grep -aqF "Password:"; then
                echo "  FAIL: [$label] prompt appeared but correct password did not authenticate"
                echo "        (this is the 1.5.4-1.5.7 brick shape — see CLAUDE.md rule 20)"
            else
                echo "  FAIL: [$label] the password prompt never appeared at all"
                echo "        NOT the brick: the boot died before phase 6c, or the VM was"
                echo "        too slow for _auth_boot's fixed 8 s pre-prompt wait."
            fi
            echo "$ok_out" | grep -aiE 'password|authent|credential' | head -3 || true
            fail=1
        fi

        # The password must not appear anywhere in the serial log.
        if echo "$ok_out" | grep -aqF "hunter2"; then
            echo "  FAIL: [$label] password echoed to the console"
            fail=1
        else
            echo "  OK: [$label] password did not echo (termios ECHO suppressed)"
        fi

        bad_out=$(_auth_boot "wrongpass" "$initrd" || true)
        _assert_no_panic "$bad_out" "$label wrong-password"
        if echo "$bad_out" | grep -aqF "AUTHENTICATION FAILED"; then
            echo "  OK: [$label] wrong password is rejected"
        else
            echo "  FAIL: [$label] wrong password was not rejected"
            fail=1
        fi

        # The brick itself: a rejection must HALT, never reboot into the same
        # refusal. "rebooting" in the log is the loop coming back.
        if echo "$bad_out" | grep -aqiF "rebooting"; then
            echo "  FAIL: [$label] rejection reboots — the reboot loop 1.5.8 fixed"
            fail=1
        else
            echo "  OK: [$label] rejection halts instead of reboot-looping"
        fi

        AUTH_LAST_OK_OUT="$ok_out"
    }

    # Pass 4a — the LEGACY unsalted SHA-256 credential. 1.5.9 promises it
    # keeps working for one release; this is what makes that a claim rather
    # than an intention.
    _auth_assert "$AUTH_INITRD" "legacy sha256"
    if echo "$AUTH_LAST_OK_OUT" | grep -aqF "legacy unsalted SHA-256"; then
        echo "  OK: [legacy sha256] boot log names the format as deprecated"
    else
        echo "  FAIL: [legacy sha256] deprecation not surfaced in the boot log"
        fail=1
    fi

    # Pass 4b — the argon2id v1 credential, generated by scripts/mkcred.sh.
    # This is the end-to-end proof that the tool this release ships produces
    # something PID 1 can actually verify.
    KDF_INITRD="${SCRIPT_DIR}/initramfs-auth-kdf.cpio.gz"
    if [ ! -f "$KDF_INITRD" ]; then
        _skip_or_fail "argon2id fixture absent (needs openssl 3.2+ with ARGON2ID)"
    else
        _auth_assert "$KDF_INITRD" "argon2id v1"

        # The parameters must reach the boot log. That is what turns a typo
        # into something an operator sees months before they need the shell,
        # and it is the only externally visible evidence that the KDF path —
        # not the legacy path — is the one that ran.
        if echo "$AUTH_LAST_OK_OUT" | grep -aqE "argon2id t=[0-9]+ m=[0-9]+KiB p=[0-9]+"; then
            echo "  OK: [argon2id v1] boot log reports the KDF parameters"
        else
            echo "  FAIL: [argon2id v1] KDF parameters not reported at load"
            echo "$AUTH_LAST_OK_OUT" | grep -aiE 'credential|argon' | head -3 || true
            fail=1
        fi

        # Neither the salt nor the tag may reach the log. Both are in the
        # record; describe() is supposed to print parameters only.
        KDF_REC=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['emergency_password_hash'])" \
            "${SCRIPT_DIR}/initramfs-auth-kdf/etc/kybernet/config.json" 2>/dev/null || echo "")
        KDF_SALT=$(echo "$KDF_REC" | cut -d'$' -f5)
        KDF_TAG=$(echo "$KDF_REC" | cut -d'$' -f6)
        # ⚠ A LEAK ASSERTION WITH NOTHING TO GREP FOR PASSES VACUOUSLY. If the
        # staging config is missing or python3 is not installed, both fields
        # come back empty, both guards below are false, and the else-arm prints
        # OK having compared nothing. Fail loudly instead — an untestable
        # secret-leak check is worse than an absent one, because it reads as
        # evidence.
        if [ -z "$KDF_SALT" ] || [ -z "$KDF_TAG" ]; then
            echo "  FAIL: [argon2id v1] could not read the staged credential — leak check did not run"
            fail=1
        elif echo "$AUTH_LAST_OK_OUT" | grep -aqF "$KDF_SALT"; then
            echo "  FAIL: [argon2id v1] the salt was printed to the console"
            fail=1
        elif echo "$AUTH_LAST_OK_OUT" | grep -aqF "$KDF_TAG"; then
            echo "  FAIL: [argon2id v1] the stored tag was printed to the console"
            fail=1
        else
            echo "  OK: [argon2id v1] neither salt nor tag reaches the log"
        fi
    fi

    rm -f "$AUTH_BAD"
fi

if [ $fail -eq 0 ]; then
    echo ""
    echo "=== HARNESS TEST: OK (markers, budget, reactor, edge verification) ==="
    exit 0
else
    echo ""
    echo "=== HARNESS TEST: FAIL ==="
    echo "  full log: $LOG (preserved for inspection)"
    echo "  timestamped: $TLOG (host ns prefix per line)"
    trap - EXIT
    exit 1
fi
