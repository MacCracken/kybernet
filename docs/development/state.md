# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.7.4**: an edge board no longer opens an unauthenticated emergency shell when a
required boot stage fails. 1.5.7 required authentication only at the phase-6c refusal;
`drop_to_emergency()` now requires it on every path when `boot_mode` is `edge`, through
`emerg_shell_needs_auth()`, and with no credential it suppresses the shell. Suite
793 / 788. Harness 108, aarch64 boot gate 162: both intact-image edge boots assert the
path was entered, the rule applied, and no shell started.

**1.7.3**: the aarch64 edge, emergency-auth and quiet passes. They were the last three
x86-only passes; the aarch64 boot gate now runs all five, **66 → 158** properties, and
every new one held on the first run. Suite counts are unchanged (787 / 782), and so are
the binaries: no `src/` file changed.

Two stand-ins, both built from this repo, replace what the x86 images take from the
build host:

- **`qemu/verity-fixture.cyr` is `/usr/sbin/veritysetup`.** Neither build host has an
  aarch64 veritysetup. The image is formatted by the host's real veritysetup, and on every
  run the stand-in's host build must match the real `veritysetup verify` exit code for
  exit code on five cases, with the real tool's own answers checked too (standing rule 52).
- **`qemu/preinit-fixture.cyr` gives the board its disks.** The pinned kernel builds
  virtio-blk and every other `virt` disk driver as a module, which the roadmap had not
  checked. It builds RAM disks in, so the pre-init copies the image into `/dev/ram0` and
  the tree into `/dev/ram1`, then execs kybernet. Every boot must print `PREINIT-OK`.

What the passes found:

- **No auth pass had ever run a shell**, on either arch. `/usr/bin/agnoshi` was busybox,
  which refuses that name. `svc-fixture`, started as `agnoshi`, now reports the shell's
  descriptors, `SigBlk`, uid and environment, on both arches (x86 84 → 104).
- **⚠ An edge board opens the emergency shell WITHOUT authentication when a required boot
  stage fails** (phase 7), because 1.5.7 forced authentication only for the phase-6c
  refusal. Every edge boot that passes phase 6c shows it: argonaut's edge sequence has a
  required daimon stage, and the fixtures have no daimon. **Not fixed in 1.7.3**, which
  changes no `src/` file. It is the first item on the roadmap.
- Argon2id verification as aarch64 PID 1 under TCG costs ~2.7 s at phase 6c, far inside
  the prompt's 120 s deadline.

Checked by putting nine defects back on aarch64, and one on x86. Every one turned its
gate red, at the properties it should have.

**1.7.2** brought the service fixtures to aarch64 (18 → 66). It also found the gate's
span measuring kernel boot, a health/watchdog race, and PID 1's entropy wait at phase 6
(standing rules 37, 36 and 51).

**1.7.1** fixed a refused `emergency.cred` falling back to the config key. 1.6.18 had
promised it would not.

1.7.0 moved cyrius 6.6.2 → 6.6.6 and every dep to its
latest tag. Its three fixes (only ENOENT is an absent config, the Landlock fixture's
truncate probe, and `read_signal` as a `Result`) are in the 1.7.0 CHANGELOG entry.
Its first CI run failed on a kernel pinned by checksum to a mutable Alpine URL. That
was fixed in place under 1.7.0.

## Toolchain

**cyrius 6.6.6**, via `~/.cyrius/bin/cyrius` (`cyriusly use 6.6.6`). The user asked for
it. The pack-wide lockstep is retired, so a dep's own pin governs only that dep's CI.
**Do not move any pin without being told to.**

**Provenance was checked, not assumed.** The install carries `tree-matches-tag: yes`, and
all **56** stdlib hashes in `cyrius.lock` match the files at the `6.6.6` tag on GitHub
byte for byte. That matters more than it did: since 6.6.4 a stdlib file whose hash
differs from the lock **aborts `cyrius build`**, so a locally patched `~/.cyrius/lib` now
breaks the build itself, not just `verify-lock.sh` and the exec gate.

What else 6.6.x changed that kybernet can see:

- The lock is **sorted** and ends with a `cyrius	6.6.6` record. `verify-lock.sh` keys on
  `commit` lines and compares sorted, so it needed nothing.
- **cyrlint** folds case and reads a deferral phrase across a whole comment paragraph,
  but a tracking pointer still has to sit on a line the phrase touches. Two lines went red
  and were fixed. One of them, in `cgroup.cyr`, was simply false: it said
  `cglim_cpu_max` is never read, and it has been read since 1.6.17.
- The aarch64 ladder grew (6.6.4, 6.6.5, 6.6.6). Every native literal in `src/` and
  `qemu/` was re-verified **by execution**: capget 90, capset 91 and clock_gettime 113
  pass through untranslated, `main()`'s `syscall(26, 0x30)` still lands on
  `inotify_init1`, and the fixtures' `syscall(60)` is routed to `exit`.
- ⚠ **qemu-user drops unknown flag bits.** `inotify_init1(0x30)` returned fd 3 under
  `qemu-aarch64`. The kernel refuses it: -22 natively, same generic check, same flag
  values. When qemu-user says yes to an argument the kernel should refuse, check it on a
  real kernel before believing it.
- The `CAP_*` conflicting-value warning is **blind** past about 1,024 globals. A probe
  with 1,500 globals ahead of a conflicting redefinition printed nothing.
  `test_capability_numbers_are_kernel` is the guard that counts.
- `lib/process.cyr`'s new fork guard (PDEATHSIG and a ppid check) is **dead** in PID 1.
  Services fork through argonaut's `fork_exec_service`.

`owl` reads `.cyr` files. **`cyim` is NOT installed here** despite sibling-repo references.
Use ordinary file edits.

## Dependencies

Resolved by `cyrius deps` from `cyrius.cyml`, sha256-pinned in `cyrius.lock`. `lib/` is
gitignored: **the contract is the lock file, not the bytes on disk.**

| Dep | Tag | Commit | Shape |
|---|---|---|---|
| sigil | 3.12.18 | `eb6b922` | THIN surface: mldsa + sha_ni + sha256 + hex + tpm + argon2. **Never the monolith.** |
| agnostik | 1.6.3 | `3729b55` | `dist/agnostik.cyr` full bundle |
| libro | 2.10.3 | `c95f296` | `dist/libro.cyr` full bundle |
| argonaut | 1.15.2 | `41c8948` | **12 selective modules**, no dist bundle |
| patra | 1.14.3 | `b9d3cf8` | stdlib fold, and libro's pin (byte-identical); kybernet calls no `patra_*` |

`cyrius deps --verify`: **76 verified, 0 failed**, 5 commit pins. Every tag was confirmed
on the remote, and each remote commit matches the local tag. The folded sakshi is 2.5.2.

⚠ **Every dep change was checked against the DCE list** (`CYRIUS_DCE_VERBOSE=1`), not
against a reading of the call graph. agnostik 1.6.3's `_fill_random` exits 70 when
`getrandom` fails, and it is **dead** in PID 1. libro 2.10.3's `uuid_v4` now calls
`getrandom(…, 0)` and is **live**, since every audit record calls it. That is better than
2.10.0's `/dev/urandom` open, which exited 74 without the device node, a panic in init.
It waits for the CRNG, but by the first audit record the CRNG is already seeded: the
stdlib's hashmap seed waited first, at phase 6. The aarch64 gate boots with no entropy
seed and shows it (standing rule 51).

`refusing to overwrite stdlib leaf 'patra'` is structural and expected. 1.6.20 explained
it as a stale libro pin, which was wrong: at 6.6.6 the pin and the fold are both 1.14.3
and byte-identical, and the warning still fires.

## Binary

| Arch | Bytes | `e_machine` |
|---|---|---|
| x86_64 (`CYRIUS_DCE=1`) | 710,008 | `0x3e` |
| aarch64 (`CYRIUS_DCE=1`) | 2,167,872 | `0xb7` |

1.7.4's edge-auth rule added 80 B on x86_64 and 72 B on aarch64. The note below is
1.7.0's, when the toolchain moved.

The toolchain accounts for almost all of the change: the unchanged 1.6.20 source built
under 6.6.6 is +512 B on x86_64 and **+66,048 B on aarch64**, where the ladder is emitted
at every syscall site and DCE still NOP-fills. Static data is 144,320 bytes. The
sibling-free reproduction produced byte-identical binaries on both arches and a
byte-identical lock.

⚠ Binary layout is a benchmark input. `strlen(52 chars)` moved +38% at this bump, and it
is one of the two benchmarks declared layout-sensitive (reported, not gated).

## Gate counts

**A next agent must not let any of these shrink.** Each is enforced by CI and each fails
the build; that is standing rule 32.

| Gate | Count | Enforcement |
|---|---|---|
| `cyrius test src/test.cyr` | **793** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **788** assertions + 5 syscall probes | executes aarch64 under `qemu-user`; its own declared floor |
| `bash qemu/boot-test-aarch64.sh` | **162** properties, all 5 passes, 19 services | boots `kybernet-aarch64` as PID 1 (TCG), entropy-starved; needs host `veritysetup` |
| `bash qemu/boot-test.sh` | **108** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
| `bash scripts/verify-lock.sh` | 2 halves, 5 commit pins | the committed lock (HEAD's, not the working tree's) vs a fresh resolve |
| `bash scripts/bench-history.sh` | **56** benchmarks (2 reported-not-gated) | ≥15% regression gate; `LAYOUT_SENSITIVE` names the two exempt ones |
| `cyrius lint` | 0 warnings, **0 untracked deferrals** | HARD GATE, both halves |
| `cyrius fmt --check` | clean | non-mutating; never `diff <(cyrius fmt …)` |

⚠ **793 and 788 are both correct, and neither floor gates the other.** Six assertions are
x86-only (`BS_OPEN`/`BS_STAT`/`BS_LSTAT`/`BS_PIPE`/`BS_POLL`/`BS_NANOSLEEP`) and one is
aarch64-only (`BS_PPOLL`). Both floors are declared in CLAUDE.md and must be bumped
together. **Do not pad the short arch to equalise them.**

20 modules in `src/lib/`. 20 `kyb-*` services in the x86 harness and 19 in the aarch64 gate. 8 `.cyr` files under `qemu/`.

## Verification posture

The technique that has repeatedly worked here, and whose absence is what let defects ship:
**inject the defect and watch the gate go red.** At 1.7.3, nine defects put back on
aarch64, each in its own copy of the tree, turned the gate red: a fail-open verify, the
1.7.0 credential fallback, the shell keeping PID 1's signal mask (`SigBlk=0000000020014003`),
the shell's fd 0 off the console, echo left on, a rejection that reboots, quiet mode
ignored, a stand-in hashing its salt last, and a pre-init that cannot read its image. At 1.7.1: restoring the 1.7.0 fallback in
`emerg_resolve_cred_at` failed 7 unit assertions and failed pass 4c on a real boot (80 OK, 4 FAIL); restoring the borrowed
buffer failed 2. At 1.7.0: restoring `load_config`'s old `n <= 0` classification failed 5
(753 passed, 5 failed, exit 5).
The Landlock fix was checked under `qemu-aarch64 -strace` before and after. The raw
literal ran `recvfrom` and got EBADF; `sys_truncate` runs `truncate`.

⚠ **"Does PID 1 reach this?" is answerable, and it should be answered by lookup.**
`CYRIUS_DCE=1 CYRIUS_DCE_VERBOSE=1 cyrius build` lists every eliminated function. At
1.7.0 that list settled four dep-change questions in minutes, and it caught one stale
claim: CLAUDE.md said edge boot calls `tpm_read_pcr`, which has been dead since 1.6.16
moved the read onto `tpm_read_pcr_timeout`.

⚠ **The 2026-08-26 audit's verification bar was weaker than 1.4.2's**, and that is
recorded so its findings are not over-trusted. A candidate survived unless both of its two
skeptics refuted it. 1.4.2 refuted 13 of 39, and this audit refuted 0 of 37. **Set a
stricter bar on the next sweep.**

## In flight

**v1.7.4 is ready and untagged.** It changes no dependency, lock or toolchain pin. The
1.7.4 CHANGELOG entry has the numbers.

## Next

In the order I would take them. The full list is [roadmap.md](roadmap.md), with 13 open
items.

1. **`ready_check` / `environment` / `env_files` config keys.** These have been unblocked
   since 1.6.20 consumed argonaut 1.15.0. Check that something downstream reads each field
   before adding its key.
2. **Port `agnos-init.sh`'s `setup_directories()` to a oneshot.** ⚠ Ship the binary before
   adding the dependency, or a working desktop boot becomes a non-booting one.

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
