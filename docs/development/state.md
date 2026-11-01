# Kybernet — Current State

> Refreshed every release. CLAUDE.md is preferences/process/procedures (durable);
> this file is **state** (volatile). Bumped at release time alongside `VERSION` and the
> CHANGELOG header. [roadmap.md](roadmap.md) is what is **not** done; this is what **is**.

## Version

**1.8.1**: cyrius 6.7.9 → 6.7.18, with every dep at its latest tag: argonaut 1.18.0, libro
2.11.3, agnostik 2.0.0 and sigil 3.13.15. The toolchain needed no source change; agnostik 2.0.0's
`<Struct>_<field>` accessor renames touched seven files. Three things reach PID 1. argonaut now
runs `kyb_pre_exec` for command health and ready checks, so a check the policy forbids reads as
unhealthy; `kyb-hc-conf` is the first fixture to run that path. bayan refuses a duplicate JSON
key or a leading-zero number, so such a config.json takes the unusable path. And the toolchain
adds 308 KB of Unicode data DCE cannot remove, while agnos-init compacts again (565,032 B). Suite
895 / 890. Harness 126, aarch64 boot gate 180.

**1.8.0**: cyrius 6.6.20 → 6.7.9, with argonaut 1.16.2, libro 2.11.0 and agnostik 1.12.0 (the
latest tags that pin 6.7.9) and sigil 3.13.12 (libro's and argonaut's own pin; 3.13.13–15 pin
6.7.9 too and were not taken). The toolchain needed no source change. argonaut's 1.16.x
behaviour changes were read against every call site: the ordered `init_stop_all` arrives with
no code change, starts of a live service are refused, oneshot and forking starts time out at
90 s, and `emergency_shell_default()` is closed, which `drop_to_emergency` overrides. Only two
unit assertions and one comment changed. Suite 892 / 887. Harness 121, aarch64 boot gate 175.
kybernet is +35,792 B on x86_64 and +134,040 B on aarch64, nearly all of it the deps.

Its first CI run failed: `ubuntu-latest` moved to Ubuntu 26.04, which has no `qemu-user-static`
package. CI now installs `qemu-user`. Replaying `ci.yml` in `ubuntu:26.04` also showed the x86
boot budget measuring its own stamper (true span about 490 ms, reported up to 1,297 ms), so
`qemu/boot-test.sh` stamps with `$EPOCHREALTIME`. Both are part of 1.8.0 (standing rules 37, 39).

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

**cyrius 6.7.18**, via `~/.cyrius/bin/cyrius` (`cyriusly use 6.7.18`). The user asked for it,
and it is the latest tag and the installed default. The pack-wide lockstep is retired, so a dep's
own pin governs only that dep's CI. **Do not move any pin without being told to.**

**Provenance was checked, not assumed.** The install carries `tree-matches-tag: yes`, and
all 113 files in `~/.cyrius/versions/6.7.18/lib/` match `lib/` at the cyrius `6.7.18` tag
byte for byte. A stdlib file whose hash differs from the lock aborts `cyrius build`
(since 6.6.4), so a locally patched install breaks the build itself.

What 6.7.10–6.7.18 changed that kybernet can see:

- **⚠ bayan 1.11.1 refuses a duplicate JSON key and a leading-zero number.** Such a config.json
  takes rule 30's unusable path. `test_config_json_strictness` pins it.
- **⚠ bayan's JSON parser reads through bounds-checked slices.** An out-of-range index is
  `exit 134`, a panic in PID 1, and the call is compiler-emitted, so grepping the source misses
  it. 77,661 damaged documents on both arches reached no trap. Re-run that if the parser changes.
- **⚠ Seven `lib/unicode/` table files cost 308 KB in the data segment**, through sigil-mldsa's
  `# Requires`. DCE removes functions, not global initializers (roadmap).
- **x86 DCE's 4,096-run compaction cap is gone** (6.7.14). kybernet has 4,126 unreachable fns,
  agnos-init 5,124, and both compact.
- **Nothing else needed a source change.** Every other silent change needs a shape kybernet does
  not have. CHANGELOG [1.8.1] has the table, including the scan. Rule 1, rule 2 and the enum probe
  were re-run on 6.7.18 and hold.

What 6.7.0–6.7.9 changed that kybernet can see:

- **Nothing needed a source change.** kybernet compiled unchanged, with the warnings 6.6.20
  printed, under the new reserved words (`trait`, `const`, `true`, `false`, `do`, `dyn`), the
  `bool` write check, struct-argument checks and forward-call arity checks.
- **Some changes alter what already-compiling code computes, so they were audited, not
  tested.** With comments and strings stripped, `src/` and `qemu/` hold no lone `!` (a real
  operator since 6.7.3, silently dropped before), no typed pointer, no slice, no `f32`, no
  `println` of a name and no exec-family call. The two `~` sites are parenthesised, so the
  unary-fold bug 6.7.9 fixed (`-K + 10` was 15 from 6.6.10) has nothing to reach. **Repeat
  this scan at every toolchain bump.** CHANGELOG [1.8.0] has the table.
- **Rule 1, rule 2 and the enum probe were re-run on 6.7.9.** 113, 26 and 7 as a literal and
  as a variable, variable 90/91, 444–446, 1 and 60 land on the intended call under
  `qemu-aarch64 -strace`. qemu-user reports `inotify_init1(0x30)` as succeeding because it
  drops unknown flag bits; a real kernel refuses it, which is what `main.cyr` relies on.
- **The toolchain alone moves kybernet +3,568 B on x86_64 and −552 B on aarch64.**

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
- **x86 DCE compaction was capped at 4,096 dead-code runs** until 6.7.14
  (`2026-10-15-kybernet-dce-compaction-cap-agnos-init.md`).
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
| sigil | 3.13.15 | `3c47656` | THIN surface: mldsa + sha_ni + sha256 + hex + tpm + argon2. **Never the monolith.** libro's, argonaut's and the fold's pin |
| agnostik | 2.0.0 | `e6d33aa` | `dist/agnostik.cyr` full bundle |
| libro | 2.11.3 | `f4a31a4` | `dist/libro.cyr` full bundle |
| argonaut | 1.18.0 | `88e45a2` | **12 selective modules**, no dist bundle |
| patra | 1.16.6 | `efa2e34` | stdlib fold, and libro's pin (byte-identical); kybernet calls no `patra_*` |

`cyrius deps --verify`: **84 verified, 0 failed**, 5 commit pins, each compared with the
remote through the GitHub API. The folded sakshi is 2.5.10 and bayan 1.11.1. Every dep is at its
latest tag, and the deps' pins of each other agree.

⚠ **Every dep change was checked against the DCE list** (`CYRIUS_DCE_VERBOSE=1`), not
against a reading of the call graph. agnostik's `_stik_fill_random` (renamed at 1.7.0)
exits 70 when `getrandom` fails, and it is **dead** in PID 1. At 1.8.1 the DCE list was
diffed against 1.8.0's. ⚠ That list cannot see a compiler-emitted call, which is how
`_slice_bounds_trap` looked unreachable from a parser that calls it, and "not in the dead list"
also matches a fn `#ifdef`'d out on this target. Newly live exits: `_stik_alloc_fail` (71, arena
exhaustion from config load), `_crypto_lane_refuse` (70, no kybernet path reaches it, PID 1 is one
thread) and the JSON slice trap (134, fuzzed, CHANGELOG [1.8.1]). `mldsa65_sign`/`_verify` and `ed25519_verify` are dead. libro's `uuid_v4` calls
`getrandom(…, 0)` and is **live**, since every audit record calls it. That is better than
2.10.0's `/dev/urandom` open, which exited 74 without the device node, a panic in init.
It waits for the CRNG, and since cyrius 6.6.7 it is the FIRST thing in PID 1 that does: the
stdlib hash seed no longer blocks. The aarch64 gate boots with no entropy seed and shows the
wait at the first service start (standing rule 51).

`refusing to overwrite stdlib leaf 'patra'` is structural and expected. 1.6.20 explained
it as a stale libro pin, which was wrong: at 6.7.18 the pin and the fold are both 1.16.6
and byte-identical, and the warning still fires.

## Binary

| Arch | Bytes | `e_machine` |
|---|---|---|
| x86_64 (`CYRIUS_DCE=1`) | 1,114,096 | `0x3e` |
| aarch64 (`CYRIUS_DCE=1`) | 2,662,008 | `0xb7` |
| agnos-init x86_64 (`CYRIUS_DCE=1`) | 565,032 | `0x3e` |
| agnos-init aarch64 (`CYRIUS_DCE=1`) | 2,526,736 | `0xb7` |

⚠ 1.8.1 is mostly the toolchain. 1.8.0's source and deps under 6.7.18 give 1,095,824 B on x86_64
(+308,488), of which 283,912 B is the data segment's Unicode tables; the deps and this release's
source add +18,272. agnos-init compacts again, and its 565,032 B is mostly those same tables: its
data segment is 495 KB against 69 KB of code. The sibling-free reproduction cloned every tag from
an empty dep cache and produced byte-identical binaries on both arches, agnos-init included, and a
byte-identical lock.

⚠ Binary layout is a benchmark input. `strlen(52 chars)` moved +42% at the 1.8.0 bump and −37% at
1.8.1, and it is one of the two benchmarks declared layout-sensitive (reported, not gated).

## Gate counts

**A next agent must not let any of these shrink.** Each is enforced by CI and each fails
the build; that is standing rule 32.

| Gate | Count | Enforcement |
|---|---|---|
| `cyrius test src/test.cyr` | **895** assertions | floor read from CLAUDE.md; a shrinking suite fails |
| `bash scripts/aarch64-exec-gate.sh` | **890** assertions + 5 syscall probes | executes aarch64 under `qemu-user`; its own declared floor |
| `bash qemu/boot-test-aarch64.sh` | **180** properties, all 5 passes, 25 services | boots `kybernet-aarch64` as PID 1 (TCG), entropy-starved; needs host `veritysetup` |
| `bash qemu/boot-test.sh` | **126** properties, 5 passes | `HARNESS_STRICT=1` in CI makes a skip a failure |
| `bash scripts/verify-lock.sh` | 2 halves, 5 commit pins | the committed lock (HEAD's, not the working tree's) vs a fresh resolve |
| `bash scripts/bench-history.sh` | **56** benchmarks (2 reported-not-gated) | ≥15% regression gate; `LAYOUT_SENSITIVE` names the two exempt ones |
| `cyrius lint` | 0 warnings, **0 untracked deferrals** | HARD GATE, both halves |
| `cyrius fmt --check` | clean | non-mutating; never `diff <(cyrius fmt …)` |

⚠ **895 and 890 are both correct, and neither floor gates the other.** Six assertions are
x86-only (`BS_OPEN`/`BS_STAT`/`BS_LSTAT`/`BS_PIPE`/`BS_POLL`/`BS_NANOSLEEP`) and one is
aarch64-only (`BS_PPOLL`). Both floors are declared in CLAUDE.md and must be bumped
together. **Do not pad the short arch to equalise them.**

21 modules in `src/lib/`. 26 services in the x86 harness and 25 in the aarch64 gate. 8 `.cyr` files under `qemu/`.

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

1.8.1 is cut in the working tree, not yet committed or tagged. `scripts/verify-lock.sh` reads
HEAD's lock, so it fails until this release is committed; it passed on a scratch commit of the
tree. 1.8.0 is tagged and on the remote.

## Next

The "Next" section of [roadmap.md](roadmap.md), in order; 23 open items in all.

1. **Every config load, SIGHUP included, costs ~4 bytes of arena per config byte.** It is
   PID 1 memory that never comes back, so it goes first.
2. **bayan's Unicode tables**: about 284 KB in PID 1's data segment that nothing reads.
3. **`hashmap` / `agent_config` measure string-literal layout**: make them
   layout-insensitive, or exempt them with the experiment. 1.7.8 moved both back down
   without touching their code.
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
