# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.7.2**: aarch64 fixture parity. The aarch64 boot gate ran with **no services** from
1.6.19 to 1.7.1, because the x86 harness's fixtures are busybox applets. It now stages 19
services built only from this repo's Cyrius fixtures and asserts on aarch64 what the x86
harness asserts about services. It went from **18 → 66** properties, and every one held
on the first run, so no kybernet defect turned up on aarch64. Suite counts are unchanged
(787 / 782).

`qemu/svc-fixture.cyr` is the new fixture, with six modes chosen by argv (`true`,
`false`, `sleep N`, `orphan`, `status`, `relay FILE`). `status` labels its report with
its **own cgroup's** leaf name, so the label doubles as the cgroup-placement check.

What the parity work found instead:

- **The aarch64 gate's span was measuring kernel boot.** It took the first timestamp in the
  whole log (`Booting Linux`, 0.000000). That only looked right while the initramfs was a
  lone ~500 KB PID 1. It now starts at kybernet's `phase 1:` kmsg (standing rule 37).
- **The health-check and watchdog assertions were a race** between two timers on one
  service. KVM always resolved it the same way and TCG did not. Each property now has its
  own service, `kyb-health` (retries 10) and `kyb-wdog` (retries 1), on both harnesses
  (standing rule 36). The x86 harness now has 20 services.
- **PID 1 waits for entropy at phase 6**, in the stdlib's hashmap seed
  (`getrandom(…, 0)`), not at the first audit record as the roadmap had assumed. That was
  870 ms under TCG with no seed. The aarch64 gate now boots with `dtb-randomness=off` and
  asserts that the boot really was starved (standing rule 51). The non-blocking fix
  (`GRND_INSECURE`) is upstream, in cyrius.

Checked by putting each defect back: an aarch64-only allowlist regression (`ppoll` removed)
turns the aarch64 gate red, and the x86 harness structurally cannot see it. A seeded boot
turns the entropy assertion red.

**1.7.1** fixed a refused `emergency.cred` falling back to the config key. 1.6.18 had
promised it would not.

1.7.0, the release before this one, moved cyrius 6.6.2 → 6.6.6 and every dep to its
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
But it waits for the CRNG, and no gate has exercised that on a machine with no hardware
RNG (roadmap).

`refusing to overwrite stdlib leaf 'patra'` is structural and expected. 1.6.20 explained
it as a stale libro pin, which was wrong: at 6.6.6 the pin and the fold are both 1.14.3
and byte-identical, and the warning still fires.

## Binary

| Arch | Bytes | `e_machine` |
|---|---|---|
| x86_64 (`CYRIUS_DCE=1`) | 704,776 | `0x3e` |
| aarch64 | 2,166,736 | `0xb7` |

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
| `cyrius test src/test.cyr` | **787** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **782** assertions + 5 syscall probes | executes aarch64 under `qemu-user`; its own declared floor |
| `bash qemu/boot-test-aarch64.sh` | **66** properties, 19 services | boots `kybernet-aarch64` as PID 1 (TCG), entropy-starved |
| `bash qemu/boot-test.sh` | **84** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
| `bash scripts/verify-lock.sh` | 2 halves, 5 commit pins | the committed lock (HEAD's, not the working tree's) vs a fresh resolve |
| `bash scripts/bench-history.sh` | **56** benchmarks (2 reported-not-gated) | ≥15% regression gate; `LAYOUT_SENSITIVE` names the two exempt ones |
| `cyrius lint` | 0 warnings, **0 untracked deferrals** | HARD GATE, both halves |
| `cyrius fmt --check` | clean | non-mutating; never `diff <(cyrius fmt …)` |

⚠ **787 and 782 are both correct, and neither floor gates the other.** Six assertions are
x86-only (`BS_OPEN`/`BS_STAT`/`BS_LSTAT`/`BS_PIPE`/`BS_POLL`/`BS_NANOSLEEP`) and one is
aarch64-only (`BS_PPOLL`). Both floors are declared in CLAUDE.md and must be bumped
together. **Do not pad the short arch to equalise them.**

20 modules in `src/lib/`. 20 `kyb-*` services in the x86 harness and 19 in the aarch64 gate. 6 `.cyr` files under `qemu/`.

## Verification posture

The technique that has repeatedly worked here, and whose absence is what let defects ship:
**inject the defect and watch the gate go red.** At 1.7.1: restoring the 1.7.0 fallback in
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

**v1.7.2 is ready and untagged.** It changes no dependency, lock or toolchain pin, and
no `src/` file: it is harness work, plus docs. The 1.7.2 CHANGELOG entry has the numbers.

## Next

In the order I would take them. The full list is [roadmap.md](roadmap.md), with 14 open
items.

1. **aarch64: the edge, emergency-auth and quiet passes.** None of them needs busybox. The
   dm-verity images are host-built data, and `-M virt` takes virtio drives. The auth passes
   would be the first time aarch64 runs Argon2id as PID 1.
2. **`ready_check` / `environment` / `env_files` config keys.** These have been unblocked
   since 1.6.20 consumed argonaut 1.15.0. Check that something downstream reads each field
   before adding its key.
3. **Port `agnos-init.sh`'s `setup_directories()` to a oneshot.** ⚠ Ship the binary before
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
