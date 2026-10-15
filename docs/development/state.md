# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.7.11**: `src/lib/read_whole.cyr` is gone. config.json and the mount table are read
with the stdlib's `file_read_whole_into` (cyrius 6.6.7 fixed the filing the stopgap was
for), which keeps the same `{ptr, cap}` contract: one buffer per call site, nothing
allocated on a read that fits, a refusal past the ceiling. A file over the ceiling is now
`-EFBIG` (`KYB_EFBIG`, which `cfg_read_class` calls TOO_BIG). An oversized mount table
is still scanned to 1 MiB, now through `_mount_cache_load_path`, which the suite drives
with a 1 MiB+ table. Five defects put back each turn the suite red. Suite 890 / 885. The
binaries are the same size as 1.7.10 and agnos-init is byte-identical.

**1.7.10**: cyrius 6.6.6 → 6.6.20, with argonaut 1.15.6, libro 2.10.8 and agnostik 1.7.1
(the latest tags that pin 6.6.20) and sigil 3.13.10 (libro 2.10.8's own sigil pin; no sigil
tag pins 6.6.20). `privdrop.cyr` now calls the stdlib's new `sys_capget`/`sys_capset`, and
`verify-lock.sh` names the stale-commit-row shape 6.6.20's resolver leaves after a tag bump.
The stdlib hash seed no longer blocks, and the entropy wait it caused moved to the first
service start rather than going away (standing rule 51, roadmap). kybernet is +31,792 B on
x86_64 and −193,504 B on aarch64; agnos-init crossed x86 DCE's 4,096-run compaction cap and
is 1,574,640 B (filed with cyrius). Suite 882 / 877. Harness 121, aarch64 boot gate 175.

**1.7.9**: argonaut 1.15.3 → 1.15.4. argonaut's `RestartPolicy` and `SeccompAction` now
have agnostik's values (RESTART_NEVER / ALWAYS / ON_FAILURE = 0 / 1 / 2, SECCOMP_KILL /
TRAP / LOG = 1 / 3 / 4). Both enums meet in this unit, where one value per constant
silently wins, and they had disagreed. argonaut's config parser is now
`argonaut_restart_policy_parse`, and `svc_config.cyr` calls it by that name, because
agnostik is adding a PascalCase `restart_policy_parse` that would otherwise take over the
`restart` key. `test_restart_and_seccomp_values_agree` guards the values. Suite 882 / 877.
Harness 121, aarch64 boot gate 175. Binaries are the same size as 1.7.8 on both arches.

**1.7.8**: config.json may be up to 256 KiB; over 16 KiB it was refused. The roadmap
named the stdlib's `file_read_whole` for this, and measuring it found two defects that
matter in PID 1: it allocates 65,544 bytes per call in an arena that is never reset, and
on `/dev/zero` it doubles until `alloc()` fails and then writes through NULL. Both are
filed with cyrius (`2026-09-23-kybernet-file-read-whole-no-ceiling-unchecked-growth-alloc.md`).
Until they are fixed, `src/lib/read_whole.cyr` keeps one buffer per call site and grows
it to a ceiling; a larger file is still refused. The mount-table read moved onto it as well (8 KiB → 1 MiB),
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

**cyrius 6.6.20**, via `~/.cyrius/bin/cyrius` (`cyriusly use 6.6.20`). The user asked for
it. The pack-wide lockstep is retired, so a dep's own pin governs only that dep's CI.
**Do not move any pin without being told to.** (6.7.x is installed too and is the default
`current`; the manifest pin selects 6.6.20.)

**Provenance was checked, not assumed.** The install carries `tree-matches-tag: yes`, and
every file in `~/.cyrius/versions/6.6.20/lib/` matches `lib/` at the cyrius `6.6.20` tag
byte for byte. A stdlib file whose hash differs from the lock aborts `cyrius build`
(since 6.6.4), so a locally patched install breaks the build itself.

What 6.6.7–6.6.20 changed that kybernet can see:

- ⚠ **`cyrius deps` keeps an old tag's `commit` row after a tag bump** (6.6.20's CVE-83
  fix; filed as `2026-10-12-deps-keeps-a-stale-commit-row-after-a-tag-change.md`, placed
  at 6.7.12). The first resolve of this bump left 10 commit rows for 5 deps. Deleting
  `cyrius.lock` and resolving again gives the clean 5, and a sibling-free copy reproduces
  that lock byte for byte. `verify-lock.sh` half 1 now names the shape and the fix.
- **`SYS_CAPGET`/`SYS_CAPSET` and `sys_capget`/`sys_capset` are in the stdlib** (6.6.8),
  as x86 125/126 on aarch64 too, routed by new ladder rows to 90/91. kybernet's own
  aarch64 numbers became a conflicting redefinition. `privdrop.cyr` uses the wrappers;
  both forms were checked under `qemu-aarch64 -strace` first.
- **The aarch64 ladder is folded at compile time** (6.6.18): a literal number becomes one
  `movz`, a variable one calls a shared stub. kybernet-aarch64 is 194 KB smaller from the
  toolchain alone. Every remaining literal (113 as literal and variable, 26, 7, 1, 60,
  444–446, variable 90/91) and `sys_setsid`/`SYS_PRCTL` were re-run under
  `qemu-aarch64 -strace` and land on the intended call.
- **The hash seed draws with `GRND_INSECURE`** (6.6.7, kybernet's filing). Phase 4 → 6
  fell from about 870 ms to 35 ms on the entropy-starved aarch64 boot, and the first
  service start now takes 914 ms instead, in libro's `uuid_v4` (rule 51, roadmap).
- **Duplicate structs warn** (6.6.9): `struct 'ResourceLimits' redefined with a different
  layout — the FIRST definition is the one used`. That is standing rule 14's known hazard.
  A probe gives the first definition's size on both arches.
- **A reachable undefined call refuses to emit the binary** (6.6.9), on every target.
- **The conflicting-enum warning works past 1,024 globals again** (6.6.8): 1.7.0's
  1,500-global `CAPX` probe warns on 6.6.20.
- **x86 DCE compaction is capped at 4,096 dead-code runs.** kybernet has 3,351 and
  compacts. agnos-init has 4,180 and does not: 1,574,640 B, NOP-filled
  (`2026-10-15-kybernet-dce-compaction-cap-agnos-init.md`, untracked in the cyrius repo
  for the user to commit). 6.6.20 alone, with 1.7.9's deps, gives 4,170.
- **New warnings left in the build, roadmapped:** 21 calls of the deprecated
  `json_v_obj_get`, and four `streq(str_data(…))` sites in `main.cyr` (four more in
  `test.cyr`) that 6.6.20 flags because a `Str` is not NUL-terminated at its length.
- Rule 2's sizing (global `[4]`/`[16]` 32/128 B apart, local 8/16) re-measured on both
  arches: unchanged.
- The four kybernet filings from 2026-09-23 (`file_read_whole`, the hash seed, `fl_alloc`,
  the `None()` misfire) are all resolved by 6.6.9. 1.7.11 adopted `file_read_whole_into`
  and deleted `read_whole.cyr`. The stdlib opens without `O_CLOEXEC`, which the stopgap
  used; PID 1 opens, reads and closes in one synchronous call, single-threaded and with no
  signal handlers, so no fork can see the descriptor.

`owl` reads `.cyr` files. **`cyim` is NOT installed here** despite sibling-repo references.
Use ordinary file edits.

## Dependencies

Resolved by `cyrius deps` from `cyrius.cyml`, sha256-pinned in `cyrius.lock`. `lib/` is
gitignored: **the contract is the lock file, not the bytes on disk.**

| Dep | Tag | Commit | Shape |
|---|---|---|---|
| sigil | 3.13.10 | `6d065da` | THIN surface: mldsa + sha_ni + sha256 + hex + tpm + argon2. **Never the monolith.** libro 2.10.8's own pin |
| agnostik | 1.7.1 | `9c9c8b3` | `dist/agnostik.cyr` full bundle |
| libro | 2.10.8 | `53401e7` | `dist/libro.cyr` full bundle |
| argonaut | 1.15.6 | `63df6c6` | **12 selective modules**, no dist bundle |
| patra | 1.15.2 | `2bc1925` | stdlib fold, and libro's pin (byte-identical); kybernet calls no `patra_*` |

`cyrius deps --verify`: **76 verified, 0 failed**, 5 commit pins. Every tag was confirmed
on the remote, and each remote commit matches the local tag. The folded sakshi is 2.5.7.
argonaut, libro and agnostik are at the latest tags pinning cyrius 6.6.20. No sigil tag pins
6.6.20 (3.13.10 pins 6.6.18, 3.13.11 pins 6.7.5), so sigil follows libro 2.10.8's own pin,
which it must: 3.13.0 changed private `_mldsa_sv_*` arities, so two sigil 3.x minors cannot
share one unit.

⚠ **Every dep change was checked against the DCE list** (`CYRIUS_DCE_VERBOSE=1`), not
against a reading of the call graph. agnostik's `_stik_fill_random` (renamed at 1.7.0)
exits 70 when `getrandom` fails, and it is **dead** in PID 1. At 1.7.10 the DCE list was
diffed against 1.7.9's. Of 23 functions newly live, mostly argonaut's wave sort (`vec_sort_by`)
and small wrappers, the one exit is `sys_exit_group(86)` in the stdlib's poison core, armed
only under the `CYRIUS_POISON` compile flag. sigil's duplicated `crypto_scratch` names (`_sigil_random_fill`, `crypto_bank_set`, …)
drop off the dead list under 6.6.20 although every caller of `_sigil_random_fill` is dead
(`tpm_random`, `ed25519_generate_keypair`, `mldsa65_keypair`); 6.6.20 binds a duplicate to its
last definition, and the list does not report it the same way. `mldsa65_sign`/`_verify` and
`ed25519_verify` are dead. libro's `uuid_v4` calls
`getrandom(…, 0)` and is **live**, since every audit record calls it. That is better than
2.10.0's `/dev/urandom` open, which exited 74 without the device node, a panic in init.
It waits for the CRNG, and since cyrius 6.6.7 it is the FIRST thing in PID 1 that does: the
stdlib hash seed no longer blocks. The aarch64 gate boots with no entropy seed and shows the
wait at the first service start (standing rule 51).

`refusing to overwrite stdlib leaf 'patra'` is structural and expected. 1.6.20 explained
it as a stale libro pin, which was wrong: at 6.6.20 the pin and the fold are both 1.15.2
and byte-identical, and the warning still fires.

## Binary

| Arch | Bytes | `e_machine` |
|---|---|---|
| x86_64 (`CYRIUS_DCE=1`) | 751,544 | `0x3e` |
| aarch64 (`CYRIUS_DCE=1`) | 1,975,920 | `0xb7` |
| agnos-init x86_64 (`CYRIUS_DCE=1`) | 1,574,640 | `0x3e` |
| agnos-init aarch64 (`CYRIUS_DCE=1`) | 1,840,648 | `0xb7` |

1.7.11 (the reader swap) left both kybernet binaries the same size, with different bytes, and agnos-init byte-identical. 1.7.10 moved the toolchain, so most of the change is cyrius's. The unchanged 1.7.9 source and
deps built under 6.6.20 give 738,488 B on x86_64 (+18,736) and 1,975,152 on aarch64
(−194,272, the compile-time ladder fold); the dep moves and the `privdrop.cyr` change add
+13,056 and +768. agnos-init x86_64 went 248,440 → 1,574,640 because it crossed DCE's
4,096-run compaction cap (Toolchain above): its dead code is NOP-filled and kept. Static
data is 145,312 B on x86_64. The sibling-free reproduction produced byte-identical binaries
on both arches, agnos-init included, and a byte-identical lock.

⚠ Binary layout is a benchmark input. `strlen(52 chars)` moved +38% at the 1.7.0 bump, and it
is one of the two benchmarks declared layout-sensitive (reported, not gated).

## Gate counts

**A next agent must not let any of these shrink.** Each is enforced by CI and each fails
the build; that is standing rule 32.

| Gate | Count | Enforcement |
|---|---|---|
| `cyrius test src/test.cyr` | **890** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **885** assertions + 5 syscall probes | executes aarch64 under `qemu-user`; its own declared floor |
| `bash qemu/boot-test-aarch64.sh` | **175** properties, all 5 passes, 24 services | boots `kybernet-aarch64` as PID 1 (TCG), entropy-starved; needs host `veritysetup` |
| `bash qemu/boot-test.sh` | **121** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
| `bash scripts/verify-lock.sh` | 2 halves, 5 commit pins | the committed lock (HEAD's, not the working tree's) vs a fresh resolve |
| `bash scripts/bench-history.sh` | **56** benchmarks (2 reported-not-gated) | ≥15% regression gate; `LAYOUT_SENSITIVE` names the two exempt ones |
| `cyrius lint` | 0 warnings, **0 untracked deferrals** | HARD GATE, both halves |
| `cyrius fmt --check` | clean | non-mutating; never `diff <(cyrius fmt …)` |

⚠ **890 and 885 are both correct, and neither floor gates the other.** Six assertions are
x86-only (`BS_OPEN`/`BS_STAT`/`BS_LSTAT`/`BS_PIPE`/`BS_POLL`/`BS_NANOSLEEP`) and one is
aarch64-only (`BS_PPOLL`). Both floors are declared in CLAUDE.md and must be bumped
together. **Do not pad the short arch to equalise them.**

21 modules in `src/lib/`. 25 services in the x86 harness and 24 in the aarch64 gate. 8 `.cyr` files under `qemu/`.

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

1.7.10 and 1.7.11 are cut in the working tree, not yet committed or tagged. One cyrius
issue was filed on 2026-10-15 and is listed under "Waiting on cyrius" in
[roadmap.md](roadmap.md); the file is untracked in the cyrius repo for the user to commit. The four 2026-09-23 filings are
resolved. When kybernet next takes agnostik (1.9.0 or later, which adds
`restart_policy_name` / `_parse`; 1.7.1 does not), the agnostik sweep should show no
duplicate here, since argonaut's parser no longer shares the name.

## Next

The "Next" section of [roadmap.md](roadmap.md), in order; 18 open items in all.

1. **Every config load, SIGHUP included, costs ~4 bytes of arena per config byte.** It is
   PID 1 memory that never comes back, so it goes first.
2. **`hashmap` / `agent_config` measure string-literal layout**: make them
   layout-insensitive, or exempt them with the experiment. 1.7.8 moved both back down
   without touching their code.
3. **agnostik's `_hex_nibble` rename**, released in agnostik and then consumed.
4. **`sys_ioctl` in `termios.cyr`** (in the stdlib since cyrius 6.5.36).
5. **Source comments pointing at roadmap entries that no longer exist**, among them a
   stale sd_notify policy comment in `main.cyr`.

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
