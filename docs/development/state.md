# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.7.0**: toolchain **6.6.2 → 6.6.6**, and every dependency at its latest tag (sigil
3.12.18, agnostik 1.6.3, libro 2.10.3, argonaut 1.15.2). Suite 747 → **758** assertions
(742 → **753** on aarch64). The x86_64 harness passed **79/79** under
`HARNESS_STRICT=1`, and the aarch64 boot gate **18/18**.

⚠ **The bump compiled clean, and that was not the finding.** Reading what 6.6.3–6.6.6
changed turned up three things in kybernet, and all three are fixed:

- **A reload could apply DEFAULT timeouts after a read error.** 6.6.6's `file_read_all`
  returns a negative errno when a read fails part way, where it used to return the bytes
  read so far. `load_config`'s `n <= 0` test moved that case from "present but unusable"
  (standing rule 30: reload keeps the running config) to "absent", and on SIGHUP that path
  applies the default `boot_timeout_ms` / `shutdown_timeout_ms` / `log_to_console` over
  the live ones. Only **ENOENT** is absent now. The classification is `cfg_read_class` in
  `svc_config.cyr`, unit-tested against the real `file_read_all`: a directory must read
  as UNREADABLE, which pins 6.6.6's contract. Injecting the old `n <= 0` logic turns the
  suite red with 5 failures.
- **The Landlock fixture's truncate probe ran `recvfrom` on aarch64.** 6.6.5 added a
  `45 → 207` row to the aarch64 x86-compat ladder, and the fixture's `#ifdef`-gated native
  `SYS_TRUNCATE_NR = 45` became x86 `recvfrom`, confirmed by `qemu-aarch64 -strace`. So its
  denial check was vacuous on aarch64. It uses `sys_truncate` now. Standing rule 1 gained
  a clause: an `#ifdef`-gated native aarch64 number is not safe by construction either.
- **`read_signal` warned on every build, 1.6.20's included.** That was the mixed-return
  diagnostic misfiring on a nullary `None()`, verified correct on both arches. It returns
  `Ok(signum)` / `Err(errno)` now, so a failed signalfd read carries its errno.

⛔ **Found and NOT fixed: a refused `emergency.cred` falls back to the config key**,
against 1.6.18's explicit promise that it would not. `emerg_load_cred_file_at` returns 0
for both "absent" and "refused", and `load_config` falls back on any 0. The unit test
asserts only the loader's 0, which is exactly the value that triggers the fallback. The
fix changes authentication behaviour and needs its own harness fixture, so it is the first
roadmap item rather than part of a toolchain bump.

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
| `cyrius test src/test.cyr` | **758** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **753** assertions + 5 syscall probes | executes aarch64 under `qemu-user`; its own declared floor |
| `bash qemu/boot-test-aarch64.sh` | **18** properties | boots `kybernet-aarch64` as PID 1 (TCG) |
| `bash qemu/boot-test.sh` | **79** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
| `bash scripts/verify-lock.sh` | 2 halves, 5 commit pins | the committed lock (HEAD's, not the working tree's) vs a fresh resolve |
| `bash scripts/bench-history.sh` | **56** benchmarks (2 reported-not-gated) | ≥15% regression gate; `LAYOUT_SENSITIVE` names the two exempt ones |
| `cyrius lint` | 0 warnings, **0 untracked deferrals** | HARD GATE, both halves |
| `cyrius fmt --check` | clean | non-mutating; never `diff <(cyrius fmt …)` |

⚠ **758 and 753 are both correct, and neither floor gates the other.** Six assertions are
x86-only (`BS_OPEN`/`BS_STAT`/`BS_LSTAT`/`BS_PIPE`/`BS_POLL`/`BS_NANOSLEEP`) and one is
aarch64-only (`BS_PPOLL`). Both floors are declared in CLAUDE.md and must be bumped
together. **Do not pad the short arch to equalise them.**

20 modules in `src/lib/`. 19 `kyb-*` harness fixtures. 5 `.cyr` files under `qemu/`.

## Verification posture

The technique that has repeatedly worked here, and whose absence is what let defects ship:
**inject the defect and watch the gate go red.** At 1.7.0: restoring `load_config`'s old
`n <= 0` classification failed 5 of the new assertions (753 passed, 5 failed, exit 5).
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

**v1.7.0 is ready and untagged.** ⚠ Its first CI run **failed the aarch64 boot gate**:
the kernel's sha256 was pinned on Alpine's unversioned `netboot/` URL, which 3.21.8
overwrote on 2026-09-17, and local runs stayed green only because `qemu/.cache/` held
the old bytes. It is fixed in place under 1.7.0 (a versioned `netboot-3.21.7/` URL with
the same checksum, and a guard against unversioned ones), and verified with the cached
kernel removed: 18/18. Every dep tag it pins already exists on the remote, so nothing
upstream has to be released first. `git show HEAD:cyrius.lock` is still 1.6.20's,
so `verify-lock.sh` will fail half 1 **until the new lock is committed**. That is correct:
it checks what CI checks out. It passes against a committed snapshot of this tree.

## Next

In the order I would take them. The full list is [roadmap.md](roadmap.md), with 15 open
items.

1. **Fix the `emergency.cred` fallback, with a rule-27 fixture.** It is security-relevant,
   a promise the code does not keep, and the one open item this release found.
2. **aarch64 fixture parity.** The boot gate still runs with **no services**. The Cyrius
   fixtures already cross-build. It is also now the only way to test the fixed Landlock
   probe on aarch64 and an entropy-starved first audit record.
3. **`ready_check` / `environment` / `env_files` config keys.** These have been unblocked
   since 1.6.20 consumed argonaut 1.15.0. Check that something downstream reads each field
   before adding its key.
4. **Port `agnos-init.sh`'s `setup_directories()` to a oneshot.** ⚠ Ship the binary before
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
