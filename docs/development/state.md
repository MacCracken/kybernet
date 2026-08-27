# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.6.15** — **all ten deferred MEDIUM findings** from the 2026-08-26 P(-1) audit.
Six land here, two in deps that are written and tested but **not yet tagged**, one was
closed by filing upstream, and **one is deliberately partial and still open**. Suite
702 → 718 assertions. Harness 66 properties. argonaut 1.13.8 → **1.13.9**, which
closes HIGH-6 from the previous release.

Six in kybernet, one line each:

- **MEDIUM-1** — `"landlock": []` or an all-`"none"` block installed NO ruleset and
  returned `Ok(0)` "applied". Note the asymmetry that makes it easy:
  `"capabilities": []` means drop *everything*; `"landlock": []` was read as restrict
  *nothing*. Refused at load; `sandbox_from_config` fails closed if it ever reaches it.
- **MEDIUM-2** — a config service named after a built-in was parsed, counted, and
  silently discarded, taking the operator's whole `security` block with it.
- **MEDIUM-3** — health-check integers derive a SIGKILL deadline
  (`interval_ms * retries + timeout_ms`) and were unvalidated: `"retries": 0` flapped a
  HEALTHY service forever, `-1` gave a negative deadline that always fires, and a
  negative `timeout_ms` reaches `poll(2)` as INFINITE.
- **MEDIUM-5** — `"uid": "65534"` (a quoted number, the commonest JSON mistake) fell
  back to permissive defaults, so the service ran as root, unfiltered, with every
  signal saying the config loaded cleanly.
- **MEDIUM-6** — `"uid": N` without a gid left the service as **group root**, because
  `drop_privileges` gates setgid AND setgroups on `gid > 0`.
- **MEDIUM-7** — `require_auth` with no usable credential prompted for a password
  nothing could match, then halted PID 1 permanently, across reboots.

⚠ **MEDIUM-10 is PARTIAL and stays open, on purpose.** A streaming audit append cost
224 bytes; argonaut 1.13.10 caches the two constant Strs, bringing it to 192. The
remaining 176 is libro's `entry_new`. **The obvious fix was implemented and reverted:**
having a streaming chain reuse one scratch entry breaks `chain_append`'s contract that
the returned entry belongs to the caller, and libro's own suite asserts two returned
entries are independent — four tests go red. That is a real contract. Closing it needs
an opt-in libro API (append returning the head hash) and a minor release. **libro is
unchanged at 2.8.12.** The finding's original complaint was that it had been recorded
as closed in four documents while still being there; it is not being closed again.

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
| argonaut | 1.13.9 | `3c7ee76` | **12 selective modules**, no dist bundle |
| patra | 1.13.10 | `490f8ff` | transitive via libro; kybernet calls no `patra_*` |

Unchanged at 1.6.13 — no dep bump. `cyrius deps --verify` → **70 verified, 0 failed**,
5 commit pins, and the committed lock is now gated by `scripts/verify-lock.sh` rather
than by a verify that runs after the resolve rewrites it.

## Binary

| Arch | Bytes |
|---|---|
| x86_64 (`CYRIUS_DCE=1`) | 1,531,968 |
| aarch64 | 1,965,888 |

Static data is 141,168 bytes, **+96 over 1.6.13** — deliberately. The config read
buffer is allocated once and cached rather than living in BSS: the BSS version worked
and grew static data by 16,392 bytes, which moved `is_mounted` 15-19% on the bench
gate. Verified `e_machine` 0x3e / 0xb7 respectively.

## Gate counts

**A next agent must not let any of these shrink.** Each is enforced by CI and each fails
the build; that is standing rule 32.

| Gate | Count | Enforcement |
|---|---|---|
| `cyrius test src/test.cyr` | **718** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **718** assertions + 5 syscall probes | **NEW at 1.6.13** — the only gate that executes aarch64 |
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

**v1.6.15 is NOT tagged.** All gates green locally. The user tags.

⚠ **Two dep releases are written, tested and clean but NOT TAGGED:**

- **argonaut 1.13.10** — MEDIUM-4 (the HTTP health check's unbounded `connect`) plus
  the partial MEDIUM-10 Str caching. All 33 suites pass; `health_exec` 33 → 38.
- **sigil 3.12.11** — MEDIUM-8 (`tpm2_pcrread` unbounded and status-discarding). All
  65 suites pass; `dist/sigil-tpm.cyr` and `dist/sigil.cyr` regenerated, the other
  eleven bundles byte-identical.

kybernet cannot consume either until they are tagged — a manifest naming an untagged
version fails CI resolution, and `path` overrides are forbidden. **Tag argonaut and
sigil, then bump kybernet's manifest and re-resolve**, which closes MEDIUM-4 and
MEDIUM-8. Do the two in one bump; both are pure additions with the old arities kept.

## Next

**v1.6.16 — the seven LOW findings**, per the plan set at 1.6.14. Before it: bump
argonaut to 1.13.10 and sigil to 3.12.11 once tagged, and have `edge_boot.cyr` pass
the remaining `max_boot_ms` slice into `tpm_read_pcr_timeout` the way the verity
verify already does.

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
