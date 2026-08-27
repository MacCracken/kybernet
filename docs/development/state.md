# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.6.12** — argonaut 1.13.8 redep. Three things that were unobservable, unschedulable or
unbounded in the long-lived path, plus a gate that could report green for a binary it never
compiled. The orphan-reap count is logged, so the `kyb-orphan` fixture is finally
**asserted** after eleven releases carrying an explicit "NOT ASSERTED" comment. Health
probes are scheduled per service. The in-memory audit chain streams by default.

⚠ **`qemu/boot-test.sh` had never built `build/kybernet`** — it staged whatever was already
there. "Edit `src/`, run the harness" therefore graded the PREVIOUS binary and reported a
confident pass for code that was never compiled. CI could not see it (the workflow builds
immediately before invoking the harness), which made it a **dev-box-only false green** —
worse rather than better, because the dev box is where iteration happens. Found by an
inject-the-defect run that returned 62 OK / 0 FAIL when it had to fail. The script now
FAILS on a stale binary rather than rebuilding, so the gate whose job is to notice
staleness is not also the thing papering over it.

## Toolchain

**cyrius 6.5.35**, via `~/.cyrius/bin/cyrius` (`cyriusly use 6.5.35`). The whole AGNOS pack
front pins this — kybernet / argonaut / libro / agnostik / sigil / agnostic. A dep that
tests on a different compiler from the consumer linking it is a gate that proves nothing.

`owl` reads `.cyr` files. **`cyim` is NOT installed here** despite sibling-repo references —
use ordinary file edits.

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

`cyrius deps --verify` → **70 verified, 0 failed**, 5 commit pins.

## Binary

| Arch | Bytes |
|---|---|
| x86_64 (`CYRIUS_DCE=1`) | 1,507,288 |
| aarch64 | 1,953,528 |

Verified `e_machine` 0x3e / 0xb7 respectively — check the machine, not just ELF magic, so a
cross-built binary cannot pass as native.

## Gate counts

**A next agent must not let any of these shrink.** Each is enforced by CI and each fails the
build; that is standing rule 32, and every one of them was at some point a gate that could
not turn red.

| Gate | Count | Enforcement |
|---|---|---|
| `cyrius test src/test.cyr` | **676** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash qemu/boot-test.sh` | **62** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
| `bash scripts/bench-history.sh` | **56** benchmarks | ≥15% regression gate; a dropped benchmark must be declared `BENCH_REMOVED=n` |
| `cyrius lint` | 0 warnings, **0 untracked deferrals** | HARD GATE — both halves |
| `cyrius fmt --check` | clean | non-mutating; never `diff <(cyrius fmt …)` |

20 modules in `src/lib/`. 13 `kyb-*` harness fixtures.

## Verification posture

The technique that has repeatedly worked here, and whose absence is what let defects ship:
**inject the defect and watch the gate go red.** Used at 1.6.11 (`BENCH_REMOVED`), 1.6.12
(the stale-binary check, and the orphan accessor stubbed back to its pre-1.13.8 discard).
Its absence is why argonaut 1.13.6 shipped `SVC_NOTIFY` with no dispatcher arm — the test
*simulated* the start path, so it could not fail.

Five harness passes, each with **its own boot and its own log, run unconditionally**:
markers + budget, the reactor, dm-verity, emergency auth (both credential formats), and the
quiet gate. Never guard one gate on another's result (rule 38) — the reactor pass sat inside
`if [ $fail -eq 0 ]` for releases and skipped silently.

## In flight — nothing

**v1.6.12 is released**: tagged `5996eca`, on the remote, with `cyrius.lock` correctly
pinning argonaut `8e98429 / 1.13.8`. No code changes are pending; the working tree carries
only this doc set.

⚠ **The lock nearly shipped STALE, and CI could not have caught it.** 1.6.12 was first
committed with `cyrius.cyml` at argonaut `tag = "1.13.8"` and a `cyrius.lock` still pinning
1.13.7's commit (`7204b60`), because the tag did not exist at commit time. It took a second
commit (`5996eca`, "updated deps") to correct.

This was verified by running CI's own two steps against that exact tree, not by reasoning:
`cyrius deps` **silently rewrote** the stale pin in place, and `cyrius deps --verify` then
checked the resolve against the file it had just written — reporting "70 verified, 0 failed".
Verify-after-resolve is tautological. CLAUDE.md documents this shape for `path` overrides,
but it is a property of the **step order** and applies to every release.

A gate that does catch it is filed for v1.6.13, already validated: ⚠ a naive `diff` is a
**false positive**, because `cyrius deps` does not emit the lock's hash lines in a stable
order. `diff -q <(sort "$SAVED") <(sort cyrius.lock)` was verified to pass on the correct
lock twice, fail on the stale one, and not false-positive.

## Next

**v1.6.13 — a P(-1) audit.** The last was cut at 1.4.2, **ten releases ago**. Everything
that is now the attack surface landed after it: `edge_boot`'s exec path, `emergency_auth`'s
KDF, the security/limits parsers, `restart_queue`, `termios`, and the live
seccomp/Landlock/capset path. Both prior audits found CRITICALs that every gate was blind
to — spinning timerfds and an x86_64-only `epoll_event` layout at 1.4.2.

## Release order (cross-repo)

Dep first, consumer second, and **never** with a `path` override in the shipped lock:

1. Finish the dep → **the user tags it** (never commit/tag/push from here) → confirm the tag
   is on the remote via the GitHub API (`curl`, never `gh`).
2. `rm -rf lib && cyrius deps && cyrius deps --verify` in kybernet.
3. Confirm `grep '^commit' cyrius.lock` lists **every** git dep.
4. Run all six release gates, then the sibling-free reproduction.
5. Then tag kybernet.

⚠ A `path` override makes `git`/`tag` inert **and drops that dep's `commit` line from the
lock entirely** — `deps --verify` cannot miss what is not there. kybernet 1.5.4 shipped with
no argonaut commit pin for exactly this reason.

## Audit cadence

P(-1) audits at 1.1.5, 1.4.2, and due now at 1.6.13. Both prior ones found CRITICALs that
the full gate suite passed over.
