# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.7.8**: config.json may be up to 256 KiB; over 16 KiB it was refused. The roadmap
named the stdlib's `file_read_whole` for this, and measuring it ruled it out for PID 1
(standing rule 53): it allocates 65,544 bytes per call in an arena that is never reset,
and on `/dev/zero` it doubles until `alloc()` fails and then writes through NULL. The new
`src/lib/read_whole.cyr` keeps one buffer per call site and grows it to a ceiling; a
larger file is still refused. The mount-table read moved onto it as well (8 KiB → 1 MiB),
since a longer table had been cut short without a word. Suite 876 / 871. Harness 121,
aarch64 boot gate 175: both harness configs are now over 16 KiB (22,200 and 18,290
bytes), and both gates go red with the old limit put back.

**1.7.7**: argonaut 1.15.2 → 1.15.3. On a desktop, aethersafha now depends on the
`agnos-init` oneshot (shipped in this package since 1.7.6), so its socket directories
exist before it starts. That completes the `setup_directories()` port.
`test_desktop_agnos_init_contract` checks both repos' halves: argonaut's built-in and
dependency, and the install path this package uses. Suite 855 / 850. Harnesses
unchanged (120 / 174): they boot `recovery`, which has no built-ins. The bench gate
flagged two benchmarks, which an inert-padding experiment showed to be string-literal
layout (roadmap).

**1.7.6**: `agnos-init`. The kybernet package now ships a second, separate program at
`/usr/lib/agnos/agnos-init`, run as a oneshot service, that makes the directories AGNOS
services expect at boot. That covers the `/run/agnos/{agents,plugins}` sockets
aethersafha binds in, `/run/user/1000`, and the `/var/lib/agnos` / `/var/log/agnos` /
`/etc/agnos` layout, with owners from `/etc/passwd`. It is symlink-safe (`lstat`),
never recursive, and fails closed on the layout. It is never linked into PID 1; kybernet's
binaries are byte-identical to 1.7.5's. Suite 849 / 844. Harness 120, aarch64 boot gate
174: both run it and `lstat` the result from a dependent service. **Next: argonaut
makes aethersafha depend on it** (roadmap).

**1.7.5**: three service keys. `environment` and `ready_check` set fields argonaut
1.15.0 reads. `env_files` sets a field argonaut still ignores, so kybernet reads the
files itself at config load and merges them over `environment` (systemd's order). A
ready check blocks PID 1 while it runs, so its bounds are refusals (timeout 100 to
60,000 ms). Suite 831 / 826. Harness 113, aarch64 boot gate 167: `kyb-env` reports its
environment from inside the child, and `kyb-ready-ok` / `kyb-ready-fail` show a passing
and a failing check.

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
| argonaut | 1.15.3 | `9bae8e2` | **12 selective modules**, no dist bundle |
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
| x86_64 (`CYRIUS_DCE=1`) | 719,752 | `0x3e` |
| aarch64 (`CYRIUS_DCE=1`) | 2,169,424 | `0xb7` |
| agnos-init x86_64 (`CYRIUS_DCE=1`) | 248,440 | `0x3e` |
| agnos-init aarch64 (`CYRIUS_DCE=1`) | 2,034,080 | `0xb7` |

1.7.8's bounded reader added 32 B to kybernet on each arch; agnos-init does not link it.
1.7.7's argonaut 1.15.3 (one more desktop default) added 4,160 B to kybernet on x86_64
and 56 on aarch64. 1.7.5's three service keys had added 5,552 and 1,464. The note below is
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
| `cyrius test src/test.cyr` | **876** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **871** assertions + 5 syscall probes | executes aarch64 under `qemu-user`; its own declared floor |
| `bash qemu/boot-test-aarch64.sh` | **175** properties, all 5 passes, 24 services | boots `kybernet-aarch64` as PID 1 (TCG), entropy-starved; needs host `veritysetup` |
| `bash qemu/boot-test.sh` | **121** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
| `bash scripts/verify-lock.sh` | 2 halves, 5 commit pins | the committed lock (HEAD's, not the working tree's) vs a fresh resolve |
| `bash scripts/bench-history.sh` | **56** benchmarks (2 reported-not-gated) | ≥15% regression gate; `LAYOUT_SENSITIVE` names the two exempt ones |
| `cyrius lint` | 0 warnings, **0 untracked deferrals** | HARD GATE, both halves |
| `cyrius fmt --check` | clean | non-mutating; never `diff <(cyrius fmt …)` |

⚠ **876 and 871 are both correct, and neither floor gates the other.** Six assertions are
x86-only (`BS_OPEN`/`BS_STAT`/`BS_LSTAT`/`BS_PIPE`/`BS_POLL`/`BS_NANOSLEEP`) and one is
aarch64-only (`BS_PPOLL`). Both floors are declared in CLAUDE.md and must be bumped
together. **Do not pad the short arch to equalise them.**

22 modules in `src/lib/`. 25 services in the x86 harness and 24 in the aarch64 gate. 8 `.cyr` files under `qemu/`.

## Verification posture

The technique that has repeatedly worked here, and whose absence is what let defects ship:
**inject the defect and watch the gate go red.** At 1.7.8, five defects put back in the
reader, the mount cache and the limit each turned the unit suite red, and the old 16 KiB
limit turned both harnesses red (x86 exit 1; aarch64 63 properties failed). At 1.7.3, nine defects put back on
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

**v1.7.8 is ready and untagged.** No dependency moved; the lock is unchanged from 1.7.7.
The 1.7.8 CHANGELOG entry has the numbers.

## Next

In the order I would take them. The full list is [roadmap.md](roadmap.md), with 13 open
items.

1. **Every config load, SIGHUP included, costs ~4 bytes of arena per config byte**
   (roadmap v1.6.x). It is PID 1 memory that never comes back, so it goes first.
2. **`hashmap` / `agent_config` measure string-literal layout** (roadmap v1.6.x): make
   them layout-insensitive, or exempt them with the experiment. 1.7.8 moved both back
   down without touching their code.
3. **agnostik's `_hex_nibble` rename** (roadmap v1.7.x), released in agnostik and then
   consumed.

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
