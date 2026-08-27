# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.6.14** — **all five HIGH findings** from the 2026-08-26 P(-1) audit. Four land in
kybernet; the fifth is argonaut's and is fixed in **argonaut 1.13.9, which is written,
tested and clean but NOT YET TAGGED** — so kybernet still pins 1.13.8 and that finding
stays open until the tag exists. Suite 681 → 702 assertions. Harness 62 → 66 properties.

What was wrong, in one line each:

- **HIGH-2** — Landlock was frozen at ABI v1, so `truncate(2)` was governed by nothing:
  a confined service could zero any file on the box while `sandbox_from_config` returned
  "applied". Measured: `open(O_WRONLY)` denied, `truncate()` allowed, 16 bytes → 0.
  Now negotiated (`landlock_create_ruleset(NULL,0,VERSION)`), TRUNCATE at ABI ≥ 3,
  IOCTL_DEV at ≥ 5, grants intersected with the handled mask so older kernels still work.
- **HIGH-3** — `capabilities` and `uid` could not be used together **at all**. The
  capability drop surrendered CAP_SETUID/CAP_SETGID before the privilege drop needed
  them, so the service exited 126 every time. New `drop_caps_and_privileges()` does
  KEEPCAPS → inheritable → bounding → setuid → effective → **AMBIENT**, the only set
  that survives execve of a plain binary.
- **HIGH-5** — every `kill -HUP 1` leaked ~38 KB, and leaked even with no config file.
- **HIGH-8** — dm-verity verification borrowed an undocumented hardcoded 10 s, so a
  board with an intact rootfs powered off blaming a veritysetup that was present and
  running. Now `edge.verify_timeout_ms`, validated at load, default 300 s, with a
  distinct TIMEOUT verdict.

⚠ **The `strlen(52 chars)` / `is_mounted` benchmark question is settled, and the answer
is that they are not gateable.** Proven, not assumed: inserting a purely INERT BSS pad
into `src/bench.cyr` — read by nothing, called by nothing — moves `strlen(52 chars)`
from 46 to 63 ns/op and back. That swing is larger than any regression the gate ever
flagged on it. Both are now reported as `layout … NOT gated`, still recorded and still
counted. Verified the gate still turns red on a real one: doubling `memeq`'s work was
flagged +118%.

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
| x86_64 (`CYRIUS_DCE=1`) | 1,524,632 |
| aarch64 | 1,962,656 |

Static data is 141,168 bytes, **+96 over 1.6.13** — deliberately. The config read
buffer is allocated once and cached rather than living in BSS: the BSS version worked
and grew static data by 16,392 bytes, which moved `is_mounted` 15-19% on the bench
gate. Verified `e_machine` 0x3e / 0xb7 respectively.

## Gate counts

**A next agent must not let any of these shrink.** Each is enforced by CI and each fails
the build; that is standing rule 32.

| Gate | Count | Enforcement |
|---|---|---|
| `cyrius test src/test.cyr` | **702** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **702** assertions + 5 syscall probes | **NEW at 1.6.13** — the only gate that executes aarch64 |
| `bash qemu/boot-test.sh` | **66** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
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

**v1.6.14 is NOT tagged.** All gates green locally. The user tags.

⚠ **v1.6.13 was tagged and never published** — its release run went red and the tag is
being withdrawn. **1.6.14 carries its content**; the 1.6.13 CHANGELOG section stays as
the record of what those changes were. CI red means it never shipped: do not invent a
follow-up patch release for work that never reached a user.

⚠ **What made it red was a gate in this repo, not the code.** `release.yml`'s aarch64
boot probe ran with an empty declared-broken list and failed the whole workflow, so an
upstream cyrius defect in one architecture blocked a fully-gated x86_64 binary from
shipping, with the only escape a hand-set repo variable. It now has three outcomes —
clean publishes both, the DECLARED breakage drops the aarch64 artifact and says why in
the release body, anything else hard-fails. All three were simulated against the real
gate before committing. **The lesson is the one this repo keeps relearning: a gate has
to be exercised in the state it will actually meet.** The probe was verified to detect
the defect and never verified against the release path it gates.

⚠ **argonaut 1.13.9 is written, tested and clean in `../argonaut`, and NOT TAGGED.**
33 suites pass; `health_exec.tcyr` went 23 → 33. kybernet cannot consume it until the
tag is on the remote — a `cyrius.cyml` naming an untagged version fails CI resolution
(and `path` overrides are forbidden, see the release order below). **Tag argonaut
first, then bump kybernet's manifest and re-resolve.**

## Next

**v1.6.15 — all thirteen MEDIUM findings**, then **v1.6.16 — all seven LOWs**, per the
plan set at 1.6.14. Both lists, with evidence, are in [roadmap.md](roadmap.md).

Before either: **bump argonaut to 1.13.9** once tagged, which closes HIGH-6 and lets
MEDIUM-4 (`health_check.type = "http"` blocking `connect(2)`) be fixed in the same
dep cycle.

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
