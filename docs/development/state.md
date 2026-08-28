# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.6.16** — **the P(-1) audit is closed.** Of the 2026-08-26 audit's 31 findings,
30 are done; MEDIUM-10 remains partial on purpose (see below). Suite 718 → 725
assertions. Harness 66 → **67** properties. argonaut 1.13.9 → **1.13.10**, sigil
3.12.10 → **3.12.11**.

**MEDIUM-4** and **MEDIUM-8** closed by consuming the dep releases: the HTTP health
check's `connect(2)` was blocking and unbounded (~127 s of frozen reactor per tick
against a blackholed target), and `tpm2_pcrread` was both unbounded and
status-discarding, so a wedged TPM hung PID 1 at phase 6c forever while a missing
tool came back as a zero-filled PCR bank. `edge_boot.cyr` now passes its own budget
into `tpm_read_pcr_timeout`, capped by whatever remains of `max_boot_ms`.

The six LOWs, one line each:

- **LOW-1** — a rejected `edge` block left its device paths COMMITTED, so kybernet
  announced edge verification was disabled and then verified anyway. Staged and
  committed at one point; `edge_reset_devices()` also clears state a removed block
  left behind (the SIGHUP path).
- **LOW-2** — a typo in `depends_on` became a phantom service: its own cgroup, a
  bogus `failed`, and a log line naming a service nobody configured. Skipped before
  the cgroup now, and named at load. ⚠ It WARNS rather than refusing — `depends_on`
  is ordering, and refusing would take a working service off a board over a typo.
- **LOW-3** — the `tpm2_pcrread` guard used `F_OK`, so `chmod 000` passed a
  fail-closed check. Now `X_OK`; and "PCR read complete" no longer prints for a read
  that returned all-zero (= unreadable) banks.
- **LOW-4** — `mkcred.sh --check` blessed a >19-digit cost field that the parser
  classifies INVALID. Now asserted on BOTH sides so they cannot drift.
- **LOW-5** — the watchdog KILL ran on every reactor gate run and nothing asserted
  it. One assertion; 66 → 67.
- **LOW-6** — already closed at 1.6.14 by HIGH-3's `kyb-capuid` fixture, which is
  the first to set a non-empty capability keep-list. Verified before ticking.

⚠ **MEDIUM-10 is still open and still partial**, unchanged from 1.6.15: 224 → 192
bytes per audit record, with the remaining 176 needing an opt-in libro API because
the obvious fix breaks a contract libro's own suite asserts. **libro stays at
2.8.12.** It is not being closed twice.

⚠ **`lib/` IS NOT A VALID INJECTION POINT.** Verifying the LOW-5 assertion by
stubbing `init_enforce_watchdog` in `lib/argonaut_init.cyr` changed nothing —
`cyrius build` re-resolves dependencies and restored the file underneath the build,
so the gate stayed green for the wrong reason and briefly looked like a gate that
could not fail. Injecting the same defect in `src/main.cyr` turned it red with the
intended message. Inject in `src/`.

## Toolchain

**cyrius 6.5.35**, via `~/.cyrius/bin/cyrius` (`cyriusly use 6.5.35`). The whole AGNOS pack
front pins this — kybernet / argonaut / libro / agnostik / sigil / agnostic.

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
| sigil | 3.12.11 | `4cf0f5b` | THIN surface — mldsa + sha_ni + sha256 + hex + tpm + argon2. **Never the monolith.** |
| agnostik | 1.5.1 | `a09383a` | `dist/agnostik.cyr` full bundle |
| libro | 2.8.12 | `f101d29` | `dist/libro.cyr` full bundle |
| argonaut | 1.13.10 | `27166b0` | **12 selective modules**, no dist bundle |
| patra | 1.13.10 | `490f8ff` | transitive via libro; kybernet calls no `patra_*` |

Unchanged at 1.6.13 — no dep bump. `cyrius deps --verify` → **70 verified, 0 failed**,
5 commit pins, and the committed lock is now gated by `scripts/verify-lock.sh` rather
than by a verify that runs after the resolve rewrites it.

## Binary

| Arch | Bytes |
|---|---|
| x86_64 (`CYRIUS_DCE=1`) | 1,532,976 |
| aarch64 | 1,966,920 |

Static data is 141,168 bytes, **+96 over 1.6.13** — deliberately. The config read
buffer is allocated once and cached rather than living in BSS: the BSS version worked
and grew static data by 16,392 bytes, which moved `is_mounted` 15-19% on the bench
gate. Verified `e_machine` 0x3e / 0xb7 respectively.

## Gate counts

**A next agent must not let any of these shrink.** Each is enforced by CI and each fails
the build; that is standing rule 32.

| Gate | Count | Enforcement |
|---|---|---|
| `cyrius test src/test.cyr` | **725** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **725** assertions + 5 syscall probes | **NEW at 1.6.13** — the only gate that executes aarch64 |
| `bash qemu/boot-test.sh` | **67** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
| `bash scripts/verify-lock.sh` | 2 halves, 5 commit pins | **NEW at 1.6.13** — the committed lock vs a fresh resolve |
| `bash scripts/bench-history.sh` | **56** benchmarks (2 reported-not-gated) | ≥15% regression gate; a dropped benchmark must be declared `BENCH_REMOVED=n`; `LAYOUT_SENSITIVE` names the two exempt ones |
| `cyrius lint` | 0 warnings, **0 untracked deferrals** | HARD GATE — both halves |
| `cyrius fmt --check` | clean | non-mutating; never `diff <(cyrius fmt …)` |

20 modules in `src/lib/`. 15 `kyb-*` harness fixtures. 4 `.cyr` files under `qemu/`.

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

**v1.6.16 is NOT tagged.** All gates green locally. The user tags. No dep is pending:
argonaut 1.13.10 and sigil 3.12.11 are both tagged and consumed.

## Next

**The P(-1) audit is closed.** What remains in [roadmap.md](roadmap.md) is 17 items:
the 14 survivors of the 1.5.9 sweep, MEDIUM-10 (partial by design), the argonaut
per-health-check allocation opened at 1.6.14, and the cyrius aarch64 filing.

The two worth picking up first, both because they are the largest remaining
correctness gaps rather than the easiest:

1. **The aarch64 ESYSXLAT defect** — filed upstream 2026-08-27 with a repro; there is
   no consumer workaround, and until a fixed cycc is pinned every release publishes
   x86_64 only. Closing it is: pin the fixed toolchain, drop the two entries from
   `AARCH64_KNOWN_BROKEN`, and the release resumes publishing both arches on its own.
2. **MEDIUM-10's real fix** — an opt-in libro append that returns the head hash
   rather than an entry. A libro MINOR release with consumer review.

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
