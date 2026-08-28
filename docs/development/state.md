# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.6.18** — consumed the three dep releases, and moved the emergency credential out
of the world-readable config. Suite 733 → 739 assertions. Harness 71 → **72**
properties. sigil 3.12.11 → **3.12.13**, libro 2.8.12 → **2.9.0**, argonaut 1.13.10 →
**1.14.0**.

**Closed by the bumps:** `check_command`'s 232 bytes per health check (now 0), and
sigil's `exec_capture`/`exec_vec` — no module outside `sys_util.cyr` calls either any
more. The worst site there was `dmverity_verify`, which returned **Ok(true)** for a
`veritysetup verify` that never ran.

**Added: `/etc/kybernet/emergency.cred` at 0600.** config.json is world-readable *by
design* — it is a service manifest — so an Argon2id record in it let every local
unprivileged process read the salt and tag and grind the KDF offline. The file mode
does not defeat an image-holder, which is exactly why it **complements** the 1.5.9 KDF
rather than replacing it. The file wins over the config key (announced, not silent),
and a group- or world-readable file is **REFUSED** rather than fallen back from — a
credential file anyone can read buys nothing over the key it replaced.

The loader is in `src/lib/emergency_auth.cyr`, not `main.cyr`, so the unit suite can
reach it (rule 34). ⚠ `st_mode` is read with `load32` via the stdlib's arch-dispatched
`STAT_MODE` — a 32-bit `mode_t` at **+24 on x86_64 and +16 on aarch64**, so neither
width nor offset may be hardcoded.

⚠ **The harness fixture for it is falsifiable**, which is the point: it stages the real
record in the file and a deliberately WRONG one (valid shape, all-zero tag) in
config.json, so the correct password authenticating can only happen if the file won.

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
