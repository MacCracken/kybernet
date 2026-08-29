#!/usr/bin/env bash
# aarch64-exec-gate.sh — EXECUTE aarch64 code, rather than only compiling it.
#
# ⚠ WHY THIS EXISTS (1.6.13 HIGH-9, and the CRITICAL it was hiding)
# ------------------------------------------------------------------
# kybernet cross-builds `kybernet-aarch64`, checks its `e_machine`, publishes
# it as a release artifact, and README + CLAUDE.md both state that BOTH
# architectures are release-gated. Until 1.6.13 no gate had ever executed a
# single aarch64 instruction: `qemu/boot-test.sh` is x86_64/KVM only, and
# `cyrius test` runs native. The whole arch half of the product shipped on the
# strength of the cross-compiler exiting 0.
#
# What that blindness hid is CRITICAL-1: `sys_signalfd()` issues `fsync(-1)` on
# aarch64, so `setup_signals()` returns Err(EBADF), main.cyr takes its phase-4
# FATAL arm, and every aarch64 board powers itself off before loading config.
# The published binary was 100% non-functional and every gate was green.
#
# It also hid three assertions in src/test.cyr that hardcoded x86_64 constants
# — including the `epoll_event` data offset that WAS 1.4.2's CRITICAL-2, so the
# one test guarding that CRITICAL could only ever pass on the architecture
# where the bug did not exist.
#
# TWO HALVES:
#   1. Run the unit suite under qemu-aarch64. Assert `0 failed` AND the COUNT,
#      because a suite that silently shrinks passes `0 failed` trivially
#      (same reasoning as ci.yml's native Test step).
#   2. Run qemu/aarch64-syscall-probe.cyr, which asserts the boot-critical
#      syscall PRIMITIVES from inside a real aarch64 process, by observable
#      result rather than by reading a table — reading tables is what produced
#      the bug, since the stdlib's aarch64 numbers are correct and the EMITTED
#      code is not.
#
# ⚠ HALF 2 IS EXPECTED TO FIND KNOWN BREAKAGE, AND THAT IS DECLARED, NOT
# ASSUMED. `AARCH64_KNOWN_BROKEN` lists the primitives currently broken by the
# toolchain. The gate fails if the observed set differs in EITHER direction:
#   - something NEW is broken            -> a regression
#   - a declared break is now FIXED      -> the declaration is stale, and a
#                                           stale exception is how a gate goes
#                                           quiet (standing rule 32)
# This is the same shape as bench-history.sh's BENCH_REMOVED.
#
# ⚠ THE LIST IS NOW EMPTY, AND THAT IS THE POINT OF HAVING HAD IT. From 1.6.13
# to 1.6.19 it declared `signalfd,pause`: cyrius emitted an x86-compat
# translation ladder in which `SYS_SIGNALFD4 = 74` collided with the `74 -> 82`
# fsync row and `SYS_PPOLL = 73` with the `73 -> 32` flock row, so `sys_signalfd()`
# issued `fsync(-1)` and kybernet's phase 4 took its FATAL arm — the aarch64
# binary could not boot at all (1.6.13 CRITICAL-1). cyrius 6.5.36 moved both to
# the >=1000 private-alias band (`SYS_PPOLL = 1073`, `SYS_SIGNALFD4 = 1074`),
# which is the fix this repo filed and proposed. Confirmed against the RELEASED
# tarballs, not a local install: 6.5.35 has 73/74, 6.5.36 has 1073/1074.
#
# Emptying it is not a relaxation — the gate now fails if EITHER primitive
# breaks again, which is strictly stronger than declaring it broken. Re-adding
# an entry means a real regression, not a workaround.
#
# Usage:
#   bash scripts/aarch64-exec-gate.sh
#   AARCH64_KNOWN_BROKEN="" bash scripts/aarch64-exec-gate.sh   # expect a clean toolchain

set -euo pipefail

cd "$(dirname "$0")/.."

# The primitives cyrius 6.5.35's aarch64 backend is known to mis-emit.
# Comma-separated, sorted. Empty means "expect a fully correct toolchain".
# Empty since 1.6.19 (cyrius 6.5.36) — see the block above.
KNOWN_BROKEN="${AARCH64_KNOWN_BROKEN-}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Prerequisite. A missing one FAILS with a reason — it never passes quietly.
# ---------------------------------------------------------------------------
QEMU=""
for cand in qemu-aarch64 qemu-aarch64-static; do
    if command -v "$cand" > /dev/null 2>&1; then QEMU="$cand"; break; fi
done
if [ -z "$QEMU" ]; then
    echo "::error::no qemu-aarch64 user-mode emulator found"
    echo "  This is the ONLY gate that executes aarch64 code, and kybernet"
    echo "  publishes an aarch64 release artifact. Refusing to pass without it."
    echo "  Debian/Ubuntu: apt-get install -y qemu-user-static"
    echo "  Arch:          pacman -S qemu-user"
    echo "  Set ALLOW_AARCH64_EXEC_SKIP=1 to override on a host that cannot run it."
    if [ "${ALLOW_AARCH64_EXEC_SKIP:-0}" = "1" ]; then
        echo "::warning::aarch64 exec gate SKIPPED (ALLOW_AARCH64_EXEC_SKIP=1)"
        exit 0
    fi
    exit 1
fi
echo "using $QEMU ($($QEMU --version 2>/dev/null | head -1))"

fail=0

# ---------------------------------------------------------------------------
# Half 1 — the unit suite, executed on aarch64.
# ---------------------------------------------------------------------------
echo
echo "=== half 1: unit suite under $QEMU ==="

CYRIUS_DCE=1 cyrius build --aarch64 src/test.cyr "$WORK/test-aarch64" > "$WORK/build.log" 2>&1 || {
    echo "  FAIL: aarch64 cross-build of src/test.cyr did not succeed"
    tail -20 "$WORK/build.log" || true
    exit 1
}

# The suite is pure logic plus a few live syscalls; 300 s is generous under
# emulation and still bounds a hang.
if ! timeout 300 "$QEMU" "$WORK/test-aarch64" > "$WORK/test.out" 2>&1; then
    rc=$?
    echo "  FAIL: the aarch64 unit suite exited $rc"
    if [ "$rc" = "139" ]; then
        echo "        139 = SIGSEGV. A crash under emulation is a crash on silicon."
    elif [ "$rc" = "124" ]; then
        echo "        124 = timed out. Something blocked that does not block natively."
    fi
    tail -25 "$WORK/test.out" || true
    fail=1
fi

SUMMARY="$(tail -1 "$WORK/test.out" 2>/dev/null || true)"
if ! printf '%s' "$SUMMARY" | grep -qE '^[0-9]+ passed,'; then
    echo "  FAIL: no test summary line — the suite did not report."
    tail -15 "$WORK/test.out" || true
    fail=1
else
    COUNT="$(printf '%s' "$SUMMARY" | sed -E 's/^([0-9]+) passed.*/\1/')"
    # ⚠ THE AARCH64 FLOOR IS ITS OWN NUMBER, NOT THE x86 ONE.
    #
    # This read `(N tests must pass)` — the x86_64 floor — and failed a
    # perfectly correct suite with "the aarch64 suite SHRANK — 741 < 745".
    # src/test.cyr necessarily carries `#ifdef CYRIUS_ARCH_*` assertions,
    # because a seccomp allowlist is arch-specific (standing rule 47):
    # BS_OPEN / BS_STAT / BS_LSTAT / BS_PIPE / BS_POLL / BS_NANOSLEEP exist
    # only on x86_64, BS_PPOLL only on aarch64. The counts differ for a real
    # reason, and padding the short arch with filler assertions to equalise
    # them would buy a tidy number at the cost of the suite meaning anything.
    #
    # So both floors are declared in CLAUDE.md and each gate reads its own.
    # They must be bumped together — see standing rule 49.
    # ⚠ `grep -oE '[0-9]+'` HERE RETURNS 64 — from the "64" in "aarch64".
    # It did, and because 742 >= 64 the check then PASSED vacuously while
    # reporting "floor 64". A gate that reads the wrong number and passes is
    # worse than one that fails (standing rule 32), so take the digits at the
    # END of the match and sanity-bound the result below.
    FLOOR="$(grep -oE 'aarch64 test floor: [0-9]+' CLAUDE.md | grep -oE '[0-9]+$' | head -1)"
    if [ -n "$FLOOR" ] && [ "$FLOOR" -lt 100 ]; then
        echo "  FAIL: parsed an implausible aarch64 test floor ($FLOOR)."
        echo "        The suite is in the hundreds; a small number means the"
        echo "        parse matched something else and the check would pass"
        echo "        vacuously. Fix the parse, not the floor."
        fail=1
        FLOOR=""
    fi
    if [ -z "$FLOOR" ]; then
        echo "  FAIL: could not read 'aarch64 test floor: N' from CLAUDE.md."
        echo "        This gate needs its OWN floor — the x86_64 one is higher"
        echo "        because src/test.cyr has arch-gated assertions (rule 49)."
        echo "        Deleting the line is not a way past this gate."
        fail=1
    elif ! printf '%s' "$SUMMARY" | grep -q '0 failed'; then
        echo "  FAIL: aarch64 suite has failures: $SUMMARY"
        grep -E '^\s*FAIL' "$WORK/test.out" | head -20 || true
        fail=1
    elif [ "$COUNT" -lt "$FLOOR" ]; then
        echo "  FAIL: the aarch64 suite SHRANK — $COUNT < $FLOOR (floor from CLAUDE.md)."
        fail=1
    else
        echo "  OK: $COUNT assertions, 0 failed (floor $FLOOR)"
    fi
fi

# ---------------------------------------------------------------------------
# Half 2 — the boot-critical syscall primitives.
# ---------------------------------------------------------------------------
echo
echo "=== half 2: boot-critical syscall primitives under $QEMU ==="

CYRIUS_DCE=1 cyrius build --aarch64 qemu/aarch64-syscall-probe.cyr "$WORK/probe" > "$WORK/pbuild.log" 2>&1 || {
    echo "  FAIL: aarch64 cross-build of qemu/aarch64-syscall-probe.cyr did not succeed"
    tail -20 "$WORK/pbuild.log" || true
    exit 1
}

# ⚠ A CORRECT `pause` BLOCKS FOREVER, so a timeout here is the SUCCESS signal
# for that one check and the probe puts it last. Everything before it has
# already been written and flushed.
timeout 10 "$QEMU" "$WORK/probe" > "$WORK/probe.out" 2>&1 || true

if ! grep -q '^PROBE:' "$WORK/probe.out"; then
    echo "  FAIL: the probe produced no PROBE: lines — it did not run."
    tail -10 "$WORK/probe.out" || true
    fail=1
else
    OBSERVED=""
    while IFS= read -r line; do
        name="${line#PROBE:}"; name="${name%%:*}"
        verdict="${line##*:}"
        [ "$name" = "pause" ] && [ "$verdict" = "entering" ] && continue
        if [ "$verdict" = "BROKEN" ]; then
            echo "  BROKEN: sys_$name does not reach its kernel entry point on aarch64"
            OBSERVED="$OBSERVED$name,"
        else
            echo "  ok:     sys_$name"
        fi
    done < <(grep '^PROBE:' "$WORK/probe.out")

    # `pause` never printed a trailing verdict => it blocked => it is correct.
    if grep -q '^PROBE:pause:entering' "$WORK/probe.out" && \
       ! grep -q '^PROBE:pause:BROKEN' "$WORK/probe.out"; then
        echo "  ok:     sys_pause (blocked, as pause(2) must)"
    fi

    OBS_SORTED="$(printf '%s' "$OBSERVED" | tr ',' '\n' | grep -v '^$' | sort | paste -sd, - || true)"
    DECL_SORTED="$(printf '%s' "$KNOWN_BROKEN" | tr ',' '\n' | grep -v '^$' | sort | paste -sd, - || true)"

    echo
    echo "  observed broken: [${OBS_SORTED}]"
    echo "  declared broken: [${DECL_SORTED}]"

    if [ "$OBS_SORTED" != "$DECL_SORTED" ]; then
        echo
        echo "  FAIL: the observed breakage does not match the declared set."
        for n in $(printf '%s' "$OBS_SORTED" | tr ',' ' '); do
            case ",$DECL_SORTED," in
                *",$n,"*) ;;
                *) echo "    NEW BREAKAGE: sys_$n — a regression, not a known issue." ;;
            esac
        done
        for n in $(printf '%s' "$DECL_SORTED" | tr ',' ' '); do
            case ",$OBS_SORTED," in
                *",$n,"*) ;;
                *) echo "    NOW FIXED: sys_$n — remove it from AARCH64_KNOWN_BROKEN."
                   echo "               A stale exception is how a gate goes quiet." ;;
            esac
        done
        fail=1
    elif [ -n "$OBS_SORTED" ]; then
        echo "  (declared breakage matches exactly — upstream cyrius; see roadmap.md)"
    fi
fi

echo
if [ "$fail" -ne 0 ]; then
    echo "=== AARCH64 EXEC GATE: FAIL ==="
    exit 1
fi
echo "=== AARCH64 EXEC GATE: OK ==="
