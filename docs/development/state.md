# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.6.13** — the P(-1) audit, ten releases late. Nine independent lenses with adversarial
verification: 84 agents, 37 candidates, **31 findings** (2 CRITICAL, 9 HIGH, 13 MEDIUM,
7 LOW). Nine closed, one mitigated, **21 deferred with their evidence** into
[roadmap.md](roadmap.md). Full report:
[`docs/audit/2026-08-26-audit.md`](../audit/2026-08-26-audit.md).

⚠ **The aarch64 binary this project has published for ten releases cannot boot.**
`sys_signalfd()` issues **`fsync(-1)`** on aarch64 — aarch64's native `signalfd4` (74)
collides with x86_64's `fsync` (74) and the cyrius backend's inline translation ladder
eats it. `setup_signals()` returns `Err(EBADF)`, `main.cyr` takes its phase-4 FATAL arm,
and the board powers itself off before it loads config. Every gate was green, because no
gate had ever executed one aarch64 instruction: the cross-build exiting 0 was the entire
evidence base for half the product.

A sweep of all 34 `sys_*` wrappers kybernet reaches found **exactly two** wrong —
`sys_signalfd -> fsync` and `sys_pause -> flock`. The other 32 are correct. The
load-bearing fix is upstream in **cyrius**, which CLAUDE.md places off-limits here.

⚠ **`_eb_compare_pcrs` SIGSEGV'd PID 1 on the success path** of an attesting edge board,
reading sigil's raw cstr digest as a boxed `Str`. Measured exit 139. It survived because
no fixture sets `tpm_attestation: true`, so the function had never executed anywhere.
Fixed, with a test verified to kill the test binary on the unfixed source.

## Toolchain

**cyrius 6.5.35**, via `~/.cyrius/bin/cyrius` (`cyriusly use 6.5.35`). The whole AGNOS pack
front pins this — kybernet / argonaut / libro / agnostik / sigil / agnostic.

`owl` reads `.cyr` files. **`cyim` is NOT installed here** despite sibling-repo references —
use ordinary file edits.

⚠ **This toolchain mis-emits two syscalls on aarch64** (above). `scripts/aarch64-exec-gate.sh`
carries them as a DECLARED known-broken list and fails if the observed set drifts in
either direction — including a declared break that gets fixed, so the declaration cannot
go stale. When a fixed cyrius is pinned, drop the entries and the gate turns green on its
own; if you drop them early it turns red.

## Dependencies

Resolved by `cyrius deps` from `cyrius.cyml`, sha256-pinned in `cyrius.lock`. `lib/` is
gitignored: **the contract is the lock file, not the bytes on disk.**

| Dep | Tag | Commit | Shape |
|---|---|---|---|
| sigil | 3.12.10 | `08e3004` | THIN surface — mldsa + sha_ni + sha256 + hex + tpm + argon2. **Never the monolith.** |
| agnostik | 1.5.1 | `a09383a` | `dist/agnostik.cyr` full bundle |
| libro | 2.8.12 | `f101d29` | `dist/libro.cyr` full bundle |
| argonaut | 1.13.8 | `8e98429` | **12 selective modules**, no dist bundle |
| patra | 1.13.10 | `490f8ff` | transitive via libro; kybernet calls no `patra_*` |

Unchanged at 1.6.13 — no dep bump. `cyrius deps --verify` → **70 verified, 0 failed**,
5 commit pins, and the committed lock is now gated by `scripts/verify-lock.sh` rather
than by a verify that runs after the resolve rewrites it.

## Binary

| Arch | Bytes |
|---|---|
| x86_64 (`CYRIUS_DCE=1`) | 1,515,712 |
| aarch64 | 1,961,928 |

Both grew ~8.2 KB: `_CG_PROCS_BUF`, the static buffer that replaced `cgroup_has_pid`'s
per-datagram `alloc`. Verified `e_machine` 0x3e / 0xb7 respectively.

## Gate counts

**A next agent must not let any of these shrink.** Each is enforced by CI and each fails
the build; that is standing rule 32.

| Gate | Count | Enforcement |
|---|---|---|
| `cyrius test src/test.cyr` | **681** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **681** assertions + 5 syscall probes | **NEW at 1.6.13** — the only gate that executes aarch64 |
| `bash qemu/boot-test.sh` | **62** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
| `bash scripts/verify-lock.sh` | 2 halves, 5 commit pins | **NEW at 1.6.13** — the committed lock vs a fresh resolve |
| `bash scripts/bench-history.sh` | **56** benchmarks | ≥15% regression gate; a dropped benchmark must be declared `BENCH_REMOVED=n` |
| `cyrius lint` | 0 warnings, **0 untracked deferrals** | HARD GATE — both halves |
| `cyrius fmt --check` | clean | non-mutating; never `diff <(cyrius fmt …)` |

20 modules in `src/lib/`. 13 `kyb-*` harness fixtures. 4 `.cyr` files under `qemu/`.

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

**v1.6.13 is NOT yet tagged.** The working tree carries the audit, the fixes, two new
gates and the doc set. All release gates are green locally. The user tags.

## Next

**The 21 deferred audit findings**, in [roadmap.md](roadmap.md). The two that most want
a decision:

1. **CRITICAL-1's upstream half** — a cyrius fix for the aarch64 syscall ladder. Until
   then `release.yml` refuses to publish the aarch64 artifact, so a release either waits
   or ships x86_64 only via `ALLOW_BROKEN_AARCH64=1`. **That is a policy call the
   maintainer should make deliberately.**
2. **HIGH-3** — `capabilities` and `uid`/`gid` cannot be used together; the capability
   drop strips CAP_SETUID before the privilege drop needs it. The correct fix
   (PR_SET_KEEPCAPS, bounding-set drop, setuid, capset, ambient raise) is a redesign of
   the most dangerous path in the tree and must not ship without a fixture asserting
   CapEff/Uid from inside the child.

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
