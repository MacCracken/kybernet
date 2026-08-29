# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.6.19** — `seccomp: basic` could not open a file on x86_64, and had not been
able to since 1.6.0. Suite 739 → **747** assertions (742 on aarch64: the seccomp
allowlist is arch-specific, so six assertions are x86-only and one is
aarch64-only, and each gate now reads its own declared floor). Harness 72 →
**79** properties. **No dep bumps**: sigil 3.12.13 / agnostik 1.5.1 / libro 2.9.0 /
argonaut 1.14.0. **cyrius 6.5.35 → 6.5.36.**

⚠ **The defect, and why it hid.** aarch64 is an `*at`-only architecture, so the
stdlib's `sys_open()` compiles to `openat` there — allowed since 1.6.0. On
x86_64 the *same wrapper* compiles to legacy `open` (nr 2), which was not on the
list. So a confined service could not open a single file on x86_64. Under
standing rule 28's deliberate `ERRNO(EPERM)` default it failed **silently**: the
service ran to completion, did nothing, and kybernet logged
`completed (oneshot)`. It survived six releases because the only fixture was a
busybox `/bin/sh` one-liner and **glibc uses `openat`** — the profile had never
been executed against the binary shape AGNOS actually ships, which is a static,
libc-free Cyrius binary. Standing rules **47** and **48** are the generalisation.

⚠ **An adversarial review of that fix then found a second hole in the same
profile: a confined daemon could not SLEEP, on either arch.** `chrono.sleep_ms`
is `syscall(7, 0, 0, ms)` and discards the result — `poll` on x86_64, and on
aarch64 the ESYSXLAT ladder rewrites source-7 to `ppoll` (nr 73). Neither was
allowed, so the call was a silent no-op and **every confined daemon's main loop
busy-spun at 100% of a core**. sakshi's TSC calibration was worse: its 10 ms
`nanosleep` window collapsed and `_sk_tsc_freq_hz` came back 2.5x–4.3x low and
different every run, making every log timestamp and span duration in a confined
service plausible-looking fiction. This one is a **widening**, so it carries its
own rule — *add a syscall when the capability is already reachable through an
allowed one* — and `epoll_wait` (allowed since 1.6.0) is a strictly more capable
wait than either, so nothing new is granted. The harness asserts it by **elapsed
time**, since a discarded return leaves no other observable.

The same review found three defects in this release's own gate: the initramfs
staleness guard did not list the new fixture (**standing rule 43, reintroduced
by the release that cites it** — now a glob), the EPERM assertion was an
unanchored match that EACCES and EEXIST both satisfied, and two comments said
`openat` where the binary issues `open`, in the file whose subject is that
distinction. ⚠ The obvious fix for the second — a `$` anchor — was also wrong:
`RUNTIME_OUT` is `cat -v | tr '\r' '\n'` and **`cat -v` runs first**, so every
line ends in a literal `^M` and an end-of-line anchor fails on correct output.

**The fix is four x86_64-only syscalls** — `open`, `stat`, `lstat`, `pipe` —
added under a rule narrow enough to apply mechanically: *add only where the
other arch's counterpart is already allowed*. Each is then a parity fix granting
no new capability, and `mkdir`/`unlink`/`chmod`/`rename`/`readlink` fall out as
excluded without a judgement call. Filesystem mutation stays denied, and the
harness asserts that.

**`qemu/seccomp-fixture.cyr`** is the new primary evidence: a Cyrius binary run
as **two services** — `kyb-seccomp-on` under `basic` and `kyb-seccomp-off` with
no security block. ⚠ The control arm is load-bearing: a denial-only assertion
cannot tell a working filter from a broken environment. The gate asserts the
denial, that the denial is specifically **EPERM**, that an on-list syscall still
works, and that the unconfined arm performs the same operation successfully. The
fixture labels its output with the seccomp mode it reads from its own
`/proc/self/status` rather than an argv it was handed, and **exits non-zero if
it cannot report** — silent success is precisely how this hid.

Verified by injection: commenting out the single `seccomp_allow(b, BS_OPEN)`
turns the harness red with four failures and exit 1.

**Also added: the `restart_config` config key** (`max_restarts`,
`base_delay_ms`, `max_delay_ms`), validated at load and **refused rather than
clamped** per rule 25. ⚠ `environment` and `env_files` were implemented and then
**withheld**: both would have parsed correctly and done nothing, because
`fork_exec_service` builds envp from `build_default_envp()` and never reads
`svc_def_env`. The seam is in argonaut 1.15.0 (unreleased); the keys land once
it is tagged.

**Unreleased dep work sitting ready to tag:** libro **2.10.0** (the canonical-JSON
object emitter no longer allocates for ordinary documents — an empty `{}` cost
608 bytes of vectors before a single key was parsed, paid per nesting level, per
audit record) and argonaut **1.15.0** (`_append_service_env`,
`svc_def_set_ready_check`, audit source/action caching).

## cyrius 6.5.36 — the aarch64 boot blocker is gone (1.6.19)

⚠ **1.6.13 CRITICAL-1 is closed upstream, with the fix this repo filed.** 6.5.36
moves `SYS_PPOLL` 73 → **1073** and `SYS_SIGNALFD4` 74 → **1074** into the ≥1000
private-alias band, ending the ESYSXLAT collision that made `sys_signalfd()`
issue `fsync(-1)` and stopped the aarch64 binary booting at all.
`AARCH64_KNOWN_BROKEN` is now **empty** — stricter than declaring the pair
broken, since the gate fails if either regresses.

⚠ **Verified against the RELEASED tarballs, not the local install**, because
this box has patched copies of both 6.5.35 and 6.5.36 and neither is a
reference.

**And the binary now BOOTS.** `qemu/boot-test-aarch64.sh` (18 properties) runs
`kybernet-aarch64` as PID 1 under TCG: phases 2/3/4/6/8/9, 6 cgroup controllers,
config loaded, argonaut initialised, clean `reboot: Power down`, no panic — and
the reactor wakes **21 times in 5 s, the identical count x86_64 reports**. It
worked on the first attempt. ⚠ `phase 4: signals ready` is the gate's CRITICAL-1
sentinel, verified by injecting `Err(EBADF)` into `setup_signals`.
⚠ It boots with **no services** — the x86 fixtures exec busybox applets and an
aarch64 busybox is a host capability rule 33 forbids assuming — so everything
the x86 harness proves about services is still x86-only. That is the roadmap's
next item, and the three Cyrius fixtures already cross-build.

⚠ **The pack-wide 6.5.35 lockstep is retired.** kybernet is on 6.5.36 alone;
argonaut 1.15.0 / libro 2.10.0 / agnostik 1.5.1 / sigil 3.12.13 remain 6.5.35,
which is fine — a dep's pin governs only the dep's own CI, since kybernet
compiles dep *source* with its own toolchain.

## Toolchain

**cyrius 6.5.36**, via `~/.cyrius/bin/cyrius` (`cyriusly use 6.5.36`). ⚠ kybernet
moved alone — the pack-wide lockstep is retired and every other repo is still on
6.5.35. A dep's pin governs only that dep's CI; kybernet compiles dep source
with its own toolchain. Do not move any pin without being told to.

`owl` reads `.cyr` files. **`cyim` is NOT installed here** despite sibling-repo references —
use ordinary file edits.

⚠ **This toolchain mis-emits two syscalls on aarch64** (above). **Filed upstream on
2026-08-27** as `docs/development/issues/2026-08-27-aarch64-esysxlat-eats-native-signalfd4-and-ppoll.md`
in the cyrius repo, with a runnable repro — cyrius is off-limits to this repo and
filing an issue is the only permitted action there. Root cause: `SYS_FSYNC = 74`
(x86 number, awaiting translation) and `SYS_SIGNALFD4 = 74` (native aarch64 number,
expecting passthrough) are both defined in `lib/syscalls_aarch64_linux.cyr`, and the
ELF-aarch64 rewrite cannot tell them apart. No consumer workaround exists. `scripts/aarch64-exec-gate.sh`
carries them as a DECLARED known-broken list and fails if the observed set drifts in
either direction — including a declared break that gets fixed, so the declaration cannot
go stale. When a fixed cyrius is pinned, drop the entries and the gate turns green on its
own; if you drop them early it turns red.

## Dependencies

Resolved by `cyrius deps` from `cyrius.cyml`, sha256-pinned in `cyrius.lock`. `lib/` is
gitignored: **the contract is the lock file, not the bytes on disk.**

| Dep | Tag | Commit | Shape |
|---|---|---|---|
| sigil | 3.12.13 | `6a422b1` | THIN surface — mldsa + sha_ni + sha256 + hex + tpm + argon2. **Never the monolith.** |
| agnostik | 1.5.1 | `a09383a` | `dist/agnostik.cyr` full bundle |
| libro | 2.9.0 | `ce5aa0c` | `dist/libro.cyr` full bundle |
| argonaut | 1.14.0 | `25f39ba` | **12 selective modules**, no dist bundle |
| patra | 1.13.10 | `490f8ff` | transitive via libro; kybernet calls no `patra_*` |

Unchanged at 1.6.13 — no dep bump. `cyrius deps --verify` → **70 verified, 0 failed**,
5 commit pins, and the committed lock is now gated by `scripts/verify-lock.sh` rather
than by a verify that runs after the resolve rewrites it.

## Binary

| Arch | Bytes |
|---|---|
| x86_64 (`CYRIUS_DCE=1`) | 1,542,904 |
| aarch64 | 1,968,632 |

Static data is 141,168 bytes, **+96 over 1.6.13** — deliberately. The config read
buffer is allocated once and cached rather than living in BSS: the BSS version worked
and grew static data by 16,392 bytes, which moved `is_mounted` 15-19% on the bench
gate. Verified `e_machine` 0x3e / 0xb7 respectively.

## Gate counts

**A next agent must not let any of these shrink.** Each is enforced by CI and each fails
the build; that is standing rule 32.

| Gate | Count | Enforcement |
|---|---|---|
| `cyrius test src/test.cyr` | **739** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **739** assertions + 5 syscall probes | **NEW at 1.6.13** — the only gate that executes aarch64 |
| `bash qemu/boot-test.sh` | **72** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
| `bash scripts/verify-lock.sh` | 2 halves, 5 commit pins | **NEW at 1.6.13** — the committed lock vs a fresh resolve |
| `bash scripts/bench-history.sh` | **56** benchmarks (2 reported-not-gated) | ≥15% regression gate; a dropped benchmark must be declared `BENCH_REMOVED=n`; `LAYOUT_SENSITIVE` names the two exempt ones |
| `cyrius lint` | 0 warnings, **0 untracked deferrals** | HARD GATE — both halves |
| `cyrius fmt --check` | clean | non-mutating; never `diff <(cyrius fmt …)` |

20 modules in `src/lib/`. 17 `kyb-*` harness fixtures. 4 `.cyr` files under `qemu/`.

## Verification posture

The technique that has repeatedly worked here, and whose absence is what let defects ship:
**inject the defect and watch the gate go red.** Used four times at 1.6.13 — the PCR test
(SIGSEGV on the unfixed source), the lock gate (four defect classes), the aarch64 gate
(drift in both directions), and `_ts_of` (aborts under `set -euo pipefail`).

⚠ **The audit's own verification bar was weaker than 1.4.2's, and this is recorded so the
findings are not over-trusted.** A candidate survived if fewer than two of its two
skeptics refuted it, so a single refutation did not kill it. 1.4.2 refuted 13 of 39;
this one refuted 0 of 37, which is a property of the threshold rather than evidence that
every candidate was airtight. **Ten findings were re-verified by hand** — including both
CRITICALs, each reproduced by execution — and are marked in the report. None of the 21
deferred items is among them: check their evidence, not their severity label.

## In flight

**v1.6.18 is NOT tagged.** All gates green locally. The user tags.

⚠ **argonaut 1.15.0 is written, tested and clean but NOT TAGGED.** It adopts libro
2.9.0's `chain_append_nokeep` in `audit_log_record` — MEDIUM-10's consumer half, worth
312 → 176 real bytes per audit record. It is a MINOR because the return type changes
from an entry to the head hash (nothing consumed the entry; every call site discarded
it). Tag it, then bump kybernet's argonaut pin to bank the 44%.

## Next

**12 open items**, one of which is the argonaut tag above. The ones with real
substance, in the order I would take them:

1. **MEDIUM-10's remaining 176 bytes** — a fixed-buffer hash in libro. ⚠ Read the
   roadmap entry first: two attempts have now under-delivered because both assumed the
   entry struct was the cost. It is not. The remainder is the timestamp Str, the
   superseded head-hash Str and the hasher's output, and removing them changes what a
   hash IS — blast radius is every consumer's linkage.
2. **`seccomp: basic` is measured against a dynamically linked binary only** — the dev
   box stages Arch's dynamic busybox, CI installs `busybox-static`, and the two greens
   attest to different syscall sets. Decide whether `basic` covers static linkage and
   measure whichever answer is chosen, rather than widening the list to quiet a
   harmless denial.
3. **Seven `ServiceDefinition` fields have no config key** — `ready_check` and
   `restart_config` are the notable two, so readiness and restart policy are argonaut
   defaults on every AGNOS board. Needs a decision about how much of argonaut's model
   kybernet intends to expose.
4. **Give the AGNOS default services a non-root uid** — the mechanism has worked since
   1.6.9 and nothing uses it. Mostly an agnosticos change.

## Release order (cross-repo)

Dep first, consumer second, and **never** with a `path` override in the shipped lock:

1. Finish the dep → **the user tags it** (never commit/tag/push from here) → confirm the
   tag is on the remote via the GitHub API (`curl`, never `gh`).
2. `rm -rf lib && cyrius deps && cyrius deps --verify` in kybernet.
3. `bash scripts/verify-lock.sh` — this is what now catches a stale committed lock;
   step 2 alone cannot, because the resolve rewrites the file the verify then reads.
4. Run all release gates, then the sibling-free reproduction.
5. Then tag kybernet.

## Audit cadence

P(-1) audits at 1.1.5, 1.4.2, and 1.6.13. All three found CRITICALs that the full gate
suite passed over — and all three found them in a place no gate was looking, rather than
in code that looked wrong on the page.
