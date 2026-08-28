# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.6.17** — working the 1.5.9 sweep survivors. Suite 725 → 733 assertions. Harness
67 → **71** properties. **No dep bump**: libro 2.9.0, argonaut 1.14.0 and sigil
3.12.13 are written, tested and clean but not yet tagged.

**Added: a hard CPU cap.** `limits.cpu_max_us`. kybernet could express `cpu.weight`
— a relative share, "matters less when they compete" — and never a ceiling, so no
service could be capped at half a core. The blocker was mechanical: `cpu.max` takes
`"<quota> <period>"` where every other limit file takes one integer. Verified by
reading `cpu.max` back **from the kernel** in a real PID-1 boot.

**Fixed: a failed prerequisite now blocks its dependents.** `resolve_service_waves`
only ORDERS waves; a wave-N failure incremented `failed` and wave N+1 started anyway,
launching a service into a world without the thing it requires. The dependent is
skipped with its blocker named, and is itself recorded as failed so ITS dependents
are skipped too. A skipped dependent is **not** counted in `failed` — it did not
fail, it was never attempted, and conflating them would make the emergency-shell
heuristic fire on one root cause times its fan-out.

**Closed: the Landlock ABI item**, which was already done at 1.6.14 (HIGH-2) — ticked
after checking `sandbox.cyr` rather than the roadmap's word.

⚠ **MEDIUM-10 stays open, and the earlier analysis was wrong about why.** libro 2.9.0
adds `chain_append_nokeep` and it works. Measured: a streaming append was **224 bytes
of arena plus an 88-byte `fl_alloc`**; with nokeep it is **208 and no `fl_alloc`** —
a third of the real cost, freelist half at zero, arena barely moved. **The entry
struct was never the dominant cost**, which is what 1.6.15 assumed. What dominates is
Strs inherent to producing a link: the RFC3339 timestamp (40 bytes), the superseded
head-hash Str, and the hasher's output. Closing it means changing what a hash IS in
libro — a fixed buffer rather than a fresh `Str` per record — which touches
`entry_compute_hash` and therefore byte-identical linkage for every consumer.

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
| x86_64 (`CYRIUS_DCE=1`) | 1,537,288 |
| aarch64 | 1,967,128 |

Static data is 141,168 bytes, **+96 over 1.6.13** — deliberately. The config read
buffer is allocated once and cached rather than living in BSS: the BSS version worked
and grew static data by 16,392 bytes, which moved `is_mounted` 15-19% on the bench
gate. Verified `e_machine` 0x3e / 0xb7 respectively.

## Gate counts

**A next agent must not let any of these shrink.** Each is enforced by CI and each fails
the build; that is standing rule 32.

| Gate | Count | Enforcement |
|---|---|---|
| `cyrius test src/test.cyr` | **733** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **733** assertions + 5 syscall probes | **NEW at 1.6.13** — the only gate that executes aarch64 |
| `bash qemu/boot-test.sh` | **71** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
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

**v1.6.17 is NOT tagged.** All gates green locally. The user tags.

⚠ **THREE dep releases are written, tested and clean but NOT TAGGED**, and they are
independent of each other — tag them in any order, then bump kybernet once:

- **libro 2.9.0** — `chain_append_nokeep` (MEDIUM-10's API half). 762 assertions.
- **argonaut 1.14.0** — `check_command` 232 → **0** bytes per health check, and an
  over-long command refused rather than silently truncated. 41 assertions in
  `health_exec.tcyr`; all suites pass.
- **sigil 3.12.13** — no module outside `sys_util.cyr` calls the stdlib's `exec_vec`
  or `exec_capture`. All 65 suites pass; every bundle regenerated and verified
  idempotent; `cyrius doc --check` 0 undocumented.

⚠ **argonaut 1.14.0 does NOT yet adopt libro's `chain_append_nokeep`** — argonaut
pins libro 2.8.12, so that adoption needs libro tagged first and is a further
argonaut release. The chain is libro → argonaut → kybernet.

## Next

Remaining after the tags land: **12 survivors of the 1.5.9 sweep** plus MEDIUM-10.
The ones with real substance:

1. **MEDIUM-10's remaining bytes** — a fixed-buffer hash in libro. Blast radius is
   every consumer's linkage, so it wants its own release and its own verification.
2. **Give the AGNOS default services a non-root uid** — the mechanism has worked
   since 1.6.9 and nothing uses it. Needs a uid allocation per service and matching
   ownership on the runtime paths each one writes; mostly an agnosticos change.
3. **Port `agnos-init.sh`'s `setup_directories()` to a oneshot** — one of its two
   kybernet blockers is now closed (a failed prerequisite blocks its dependents); the
   other is that `aethersafha`'s `depends_on` is hardcoded in argonaut's
   `default_services`.
4. **`seccomp: basic` is measured against a dynamically linked binary only** — the
   dev box stages Arch's dynamic busybox, CI installs `busybox-static`, and the two
   greens attest to different syscall sets.

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
