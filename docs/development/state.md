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

⚠ **The aarch64 syscall mis-emission is FIXED and the declaration is now empty.**
Filed upstream 2026-08-27 in the **cyrius** repo (not this one) as
`<cyrius>/docs/development/issues/2026-08-27-aarch64-esysxlat-eats-native-signalfd4-and-ppoll.md`,
with a runnable repro; **cyrius took the proposed fix** in 6.5.36 —
the ≥1000 private-alias band (`SYS_PPOLL = 1073`, `SYS_SIGNALFD4 = 1074`), ending the
collision with the `73 → 32` flock and `74 → 82` fsync rows. `AARCH64_KNOWN_BROKEN` is
now **empty**, which is stricter than declaring the pair broken: the gate fails if
either regresses. ⚠ Verified against the **released tarballs**, not this box — see
"In flight" for why no local install is a reference.

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

Unchanged at 1.6.19 — no dep bump. `cyrius deps --verify` → **70 verified, 0 failed**,
5 commit pins, and the committed lock is gated by `scripts/verify-lock.sh` rather than
by a verify that runs after the resolve rewrites it.

⚠ **libro 2.10.0 and argonaut 1.15.0 are RELEASED and not yet consumed.** They carry
the whole of MEDIUM-10's fix plus the `svc_def_set_ready_check` and
`_append_service_env` seams. Bumping both pins is the single highest-value next change,
and it is a release in its own right — dep-then-consumer order, full gate run.

## Binary

| Arch | Bytes | `e_machine` |
|---|---|---|
| x86_64 (`CYRIUS_DCE=1`) | 1,543,280 | `0x3e` |
| aarch64 | 2,034,504 | `0xb7` |

Static data is 143,872 bytes. ⚠ The config read buffer is `alloc()`ed once and cached
rather than living in BSS: the BSS version worked and grew static data by 16,392 bytes,
which moved `is_mounted` 15–19% on the bench gate — **binary layout is a benchmark
input**, which is why two benchmarks are reported-not-gated.

⚠ **The aarch64 binary is no longer shipped on a cross-build exiting 0.** It BOOTS —
`qemu/boot-test-aarch64.sh` runs it as PID 1. See Gate counts.

## Gate counts

**A next agent must not let any of these shrink.** Each is enforced by CI and each fails
the build; that is standing rule 32.

| Gate | Count | Enforcement |
|---|---|---|
| `cyrius test src/test.cyr` | **747** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **742** assertions + 5 syscall probes | executes aarch64 under `qemu-user`; its own declared floor |
| `bash qemu/boot-test-aarch64.sh` | **18** properties | **NEW at 1.6.19** — boots `kybernet-aarch64` as PID 1 (TCG) |
| `bash qemu/boot-test.sh` | **79** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
| `bash scripts/verify-lock.sh` | 2 halves, 5 commit pins | the committed lock (HEAD's, not the working tree's) vs a fresh resolve |
| `bash scripts/bench-history.sh` | **56** benchmarks (2 reported-not-gated) | ≥15% regression gate; a dropped benchmark must be declared `BENCH_REMOVED=n`; `LAYOUT_SENSITIVE` names the two exempt ones |
| `cyrius lint` | 0 warnings, **0 untracked deferrals** | HARD GATE — both halves |
| `cyrius fmt --check` | clean | non-mutating; never `diff <(cyrius fmt …)` |

⚠ **747 and 742 are both correct and neither floor gates the other.** A seccomp
allowlist is arch-specific, so six assertions are x86-only (`BS_OPEN`/`BS_STAT`/
`BS_LSTAT`/`BS_PIPE`/`BS_POLL`/`BS_NANOSLEEP`) and one is aarch64-only (`BS_PPOLL`).
Both floors are declared in CLAUDE.md, each gate reads its own, and they must be bumped
together. **Do not pad the short arch to equalise them.**

20 modules in `src/lib/`. 19 `kyb-*` harness fixtures. 5 `.cyr` files under `qemu/`.

## Verification posture

The technique that has repeatedly worked here, and whose absence is what let defects ship:
**inject the defect and watch the gate go red.** Used seven times at 1.6.19 alone:
removing `BS_OPEN` (harness red, exit 1), denying `BS_POLL` (`SC[2]-SLEEP_MS=0` against
the control arm's 50), dropping `BS_STAT` from the allowlist (unit suite red), forcing
`setup_signals` to return `Err(EBADF)` (the aarch64 boot gate's CRITICAL-1 sentinel
fires by name), staging an initramfs with no PID 1 in it (the empty-image guard), a
stale `cyrius.cyml` (the rule-43 staleness guard), and flipping libro's inline sort
comparator from `<=` to `<` — which failed **only** the new inline-vs-spill digest
assertion while every pre-existing golden vector stayed green, which is the whole
argument for that test existing.

⚠ **The audit's own verification bar was weaker than 1.4.2's, and this is recorded so the
findings are not over-trusted.** A candidate survived if fewer than two of its two
skeptics refuted it, so a single refutation did not kill it. 1.4.2 refuted 13 of 39;
this one refuted 0 of 37, which is a property of the threshold rather than evidence that
every candidate was airtight. **Ten findings were re-verified by hand** — including both
CRITICALs, each reproduced by execution — and are marked in the report. ⚠ **Set a
stricter bar on the next sweep**: a 100% survival rate is a finding about the method,
not about the code.

## In flight

**v1.6.19 is tagged but NOT released** — the tag exists, the GitHub release does not,
because the workflow failed on the aarch64 suite-count gate. ⚠ Per this project's
practice a failed tag **keeps its version number**: fix in place under 1.6.19, never
invent a follow-up patch release. The fixes are in; the user re-tags.

⚠ **The cyrius pin moved to 6.5.36, kybernet alone.** The pack-wide lockstep is retired
(the user's call). argonaut / libro / agnostik / sigil stay on 6.5.35, which is fine — a
dep's pin governs only that dep's CI, since kybernet compiles dep *source* with its own
toolchain. **Do not move any pin without being told to.**

⚠ **`~/.cyrius/lib` and every `~/.cyrius/versions/*/lib` on the dev box carry in-place
patches**, so `cyrius --version` says nothing about the stdlib behind it and no local
install is a reference. Verify toolchain claims against the RELEASED tarballs
(`raw.githubusercontent.com/MacCracken/cyrius/<tag>/lib/...`).

## Next

**11 open items.** In the order I would take them:

1. **Bump libro 2.9.0 → 2.10.0 and argonaut 1.14.0 → 1.15.0.** Both are released. This
   closes MEDIUM-10 outright and unblocks `ready_check` / `environment` / `env_files`.
   Highest value per unit of risk, and it is a release in its own right.
2. **aarch64 fixture parity.** The boot gate runs with **no services**, so everything
   the x86 harness proves *about services* — cgroup placement and limits, `kyb_pre_exec`,
   seccomp, Landlock, capabilities, uid/gid drop, health checks, watchdog, restart
   backoff, sd_notify, prerequisite blocking — is still x86-only. The three Cyrius
   fixtures already cross-build; that is the path. Do not close it by adding services
   that assert nothing.
3. **Port `agnos-init.sh`'s `setup_directories()` to a oneshot.** ⚠ Verify the ordering
   hazard first: now that a failed prerequisite blocks its dependents, adding the dep
   before agnosticos ships the binary turns a working desktop boot into a non-booting
   one. Binary first, then the dep.
4. **Give the AGNOS default services a non-root uid.** Strictly downstream of (3) — a
   service with a uid needs its runtime directories to exist *and* be owned by it, and
   nothing currently creates `/run/agnos/{agents,plugins}` at all.

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
