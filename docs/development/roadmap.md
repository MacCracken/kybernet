# Kybernet Roadmap

**Current: v1.5.8** — see [CHANGELOG.md](../../CHANGELOG.md) for what each release
actually did. This file carries only what is NOT done; everything shipped is a one-line
entry under [History](#history).

---

## Active

### v1.5.9 — salted KDF for the emergency password

Deferred from 1.5.8 deliberately, not skipped. The gate had to work at all
before the credential format was worth hardening, and the investigation
turned up three things that need resolving first:

- [ ] **`argon2id()` cannot be called from PID 1 as sigil ships it.** It
      allocates through `fl_alloc`, whose large path stores to the raw
      `mmap` return without checking it — so on memory exhaustion it faults
      instead of returning the error its own `if (mem == 0)` guard expects.
      Reproduced: exit 139. kybernet must use `argon2id_into(mem, ...)` with
      an `alloc()` arena, which fails cleanly
- [ ] **sigil's argon2 profile costs +377 KB, and 352 KB of it is `.bss`** —
      a single `var SCR[352256]` that DCE cannot strip. Fixable in sigil by
      taking the scratch lane off the tail of the caller-supplied arena
      (**not** by caching it in a global — that is audit rule 8, a bump-arena
      pointer in a static, and it was tried and rejected during this work)
- [ ] **There is no provisioning story at all.** Nothing in either repo tells
      an operator how to produce `emergency_password_hash`. Today it happens
      to be `printf 'pw' | sha256sum`; with a salted KDF that stops being
      possible with coreutils, so a generator has to ship with the format
- [ ] Migration: a stored 64-hex SHA-256 must keep working for one release,
      and the new format must be unambiguous enough that it cannot be
      downgraded to the legacy path
- [ ] Parameter CEILING as well as floor — `fl_alloc` has no upper bound, so
      an `m_cost` parsed from config could OOM or hang PID 1

PBKDF2 was evaluated and rejected: sigil's SHA-256 acceleration is
`#ifdef CYRIUS_ARCH_X86` only, so every ARM edge board runs the software
path — measured at ~164x slower than OpenSSL, which buys roughly 6-9k
iterations in a 1 s budget against an attacker doing millions. Argon2's
BLAKE2b has no such gap.

### v1.5.10 — edge boot on real hardware (was v1.2.2)

Everything below needs a real device-mapper stack or a real TPM, and is
**not** covered by the QEMU gate — measured, not assumed: the harness
kernel has `CONFIG_BLK_DEV_DM=m`, no `CONFIG_DM_INIT`, and the initramfs
busybox has no `insmod`. In-VM `veritysetup open` returns "Cannot
initialize device-mapper". Putting a module loader inside PID 1 to make a
test pass is scaffolding in the one process that must never crash.

- [ ] `veritysetup open` + read-only mount of the verified target — catches
      corruption at READ time, not just once at boot
- [ ] LUKS unlock against a TPM-sealed LUKS2 token
- [ ] PCR baseline **enforcement**, rooted in TPM sealing rather than in a
      userspace tool that lives on the filesystem being verified
- [ ] RPi4 / NUC boot validation

---

## Deferred (no movement until trigger surfaces)

- **Control socket for agnoshi runtime commands** — separate transport surface; pinned until an agnoshi consumer drives the protocol shape
- **Binary signing on release** — pinned until libro signing/timestamping is consumer-driven from outside kybernet's tree

**Closed since this list was written:** validating `drop_cap_sets()` on privileged
hardware. The unit suite runs unprivileged, where every capability path short-circuits on
the euid check — but the 1.5.2 harness `kyb-confined` service asserts `CapEff=0` and
`NoNewPrivs=1` from inside a real service under QEMU, where kybernet is genuinely PID 1
as root and `capset(2)` really executes. See `qemu/boot-test.sh`.

---

## History

### v1.5.8 — The emergency-auth gate actually works (2026-08-25)
Both roadmap items were aimed past a defect that made the gate non-functional. `setup_console` points fd 0 at /dev/null by design, and the password prompt added at 1.5.4 read fd 0 — so it got EOF instantly and every authentication failed, correct password or not. 1.5.7's forced `require_auth` on an edge refusal turned that into a reboot loop recoverable only from the bootloader. Reproduced in QEMU before any change. Interactive reads now open their own /dev/console (`O_RDWR|O_NOCTTY`); console echo suppression added in a new `src/lib/termios.cyr` (the stdlib has no ioctl, termios or poll — filed as a cyrius issue); the read is bounded; a rejection halts instead of rebooting; the shell got a real stdin and a real envp. Harness feeds a password over the serial line. Salted KDF deferred to 1.5.9. 491 tests.

### v1.5.7 — Edge boot actually verifies (2026-08-25)
The roadmap's stated blocker did not exist — argonaut's `execute_edge_boot` always took device paths as parameters. The gap it did not name did: kybernet parsed no edge config at all, so `"boot_mode": "edge"` was an un-overridable demand for a TPM and dm-verity whose refusal path powers the board off. An absent `edge` block now means detection-only. Real dm-verity integrity verification via `veritysetup verify` (pure userspace, so no device-mapper needed); PCR baseline comparison report-only and deliberately so; `kybernet.edge=permissive`, and `=off` narrowed so it cannot silently bypass a pinned board. argonaut 1.13.2 fixed two upstream defects found on the way: bare binary names against an `execve` that does not search `$PATH`, and an `exec_vec_str` that waits unbounded and fails OPEN. 477 tests.

### v1.5.6 — argonaut's hardcoded x86_64 syscall numbers (2026-08-25)
Consumed argonaut 1.13.1's arch repairs. `syscall(112)` for setsid is 157 on aarch64, so no service argonaut forked ever got its own session on ARM; `syscall(35)` for nanosleep is `unlinkat` there. Import list 12 → 13 modules — `src/syscall_compat.cyr` is mandatory, since types/health/notify all call into it. Also restored the argonaut and agnostik commit pins that 1.5.4/1.5.5 had dropped from the lock. 440 tests.

### v1.5.5 — Cgroup limits actually applied (2026-08-25)
Two things the roadmap item did not know about. Service cgroups had no controller files at all — nothing ever wrote `cgroup.subtree_control`, so every limit write would have been ENOENT (confirmed in a real PID-1 boot). And `ResourceLimits` is defined twice with incompatible layouts across argonaut and agnostik, silently, so the item's literal instruction would have set `memory.max` from a service's `nofile`. Limits now come from a `limits` config block into agnostik's `cgroup_limits`; placement moved into the child's pre-exec so even a oneshot lands in its cgroup before running. 437 tests.

### v1.5.4 — Rust port complete; rust-old/ removed (2026-08-25)
Eight behaviours the port had dropped, closed. Deferred restarts (the SIGCHLD handler restarted synchronously, discarding argonaut's exponential backoff); health-check failures and watchdog kills now act; `$NOTIFY_SOCKET` finally exported, which needed a new argonaut seam since it builds the child envp itself; emergency-shell `require_auth` — which the roadmap called blocked on a primitive that had existed all along. `rust-old/` deleted, 44 files. 409 tests.

### v1.5.3 — Lifecycle cleanup and observability (2026-08-25)
cgroup teardown wired in (previously no production call site); reload_config narrowed to what it can honestly apply; edge-boot refusals reach dmesg; edge-boot budget enforces before each exec-backed step. One audit finding corrected as misdiagnosed. 309 tests.

### v1.5.2 — Per-service security profiles (2026-08-25)
Profiles as config data; capability numbers corrected across agnostik/argonaut (both disagreed with the kernel, and kybernet's privilege drop fed them to capset(2)); harness proves confinement as root. 296 tests.

### v1.5.1 — Boot stages that do something (2026-08-25)
execute_boot_stage was `return 1` for all eleven arms, so init_mark_step_failed and the emergency path were dead code. Stages now return OK/SKIP/FAIL and check real state; argonaut 1.10.1 added the SKIPPED marker that made an honest third answer possible. Bench gate gained a noise floor. 255 tests.

### v1.5.0 — Config-driven services (2026-08-24)
services parsed from JSON; three defects fixed in the start path that had never executed; argonaut 1.10.0 for the enum parsers, service-set accessors and the oneshot-dependency fix. Harness now boots real services. 235 tests.

### v1.4.2 — P(-1) audit pass (2026-08-24)
Fifth P(-1) sweep; first since 1.1.5. 2 CRITICAL / 5 HIGH / 7 MEDIUM / 6 LOW, 19 of 20 closed. Both CRITICALs were gate-invisible: undrained level-triggered timerfds (PID 1 spinning at 100% CPU ~10s after every boot, then a kernel panic) and an x86_64-only `struct epoll_event` layout (kernel-written heap overflow + signals never handled on aarch64). Added the `kybernet.harness=loop` reactor gate — verified to fail on the unfixed tree — because no release gate had ever executed an event-loop iteration. 194 tests.

### v1.4.1 — Toolchain 6.5.35 + dependency refresh (2026-08-24)
cyrius 6.4.62 → 6.5.35; sigil 3.12.9 / agnostik 1.4.0 / libro 2.8.12 / argonaut 1.8.6. Retired the `[deps.patra]` git block (it was downgrading the newer stdlib fold) and the `path = "../…"` fields (they made the tag pins inert locally). Manifest trimmed 6,924 → 2,784 bytes. CI format gate repaired for `cyrius fmt`'s in-place rewrite. No functional source change; 177 tests, harness green (673–911 ms of a 3000 ms budget).

### v1.4.3 — Dead security code reached a production path (2026-08-24)
Audit HIGH-1: 686 lines of seccomp/Landlock/privilege-drop code that was reachable from nothing. argonaut 1.9.0 grew `argonaut_set_pre_exec_hook`, and `kyb_pre_exec` now confines services between fork and exec. 203 tests.

### v1.4.0 — THIN sigil surface; 14.35 MB → 0.96 MB (2026-07-13)
cyrius 6.2.11 → 6.4.62 and every sibling dep to its latest tag, but the headline is that kybernet stopped pulling the monolithic `dist/sigil.cyr` — a 93% smaller PID-1 binary. 177 tests.

### v1.3.x arc — Toolchain and dependency refreshes (2026-06)
v1.3.0 made benchmarks a mandatory regression-checked release gate; v1.3.1–v1.3.3 pin alignments (cyrius 6.0.26 → 6.0.56); v1.3.4 the 6.0.x → 6.2.11 leap that folded `json` into `bayan` and ended implicit stdlib auto-include; v1.3.5 dropped agnosys, re-sourcing TPM/dm-verity/LUKS from sigil. 177 tests throughout.

### v1.2.x arc — Edge boot scaffolding (2026-05-11 → 2026-05-28)
v1.2.0 landed capability detection (TPM via sigil, dm-verity via a local probe), PCR reads and the flag-driven prerequisite gate. v1.2.1 pinned argonaut 1.7.0 to light the boot-to-shell path; v1.2.2 took the toolchain to cyrius 6.0.14 and restored the aarch64 cross-build; v1.2.3 was a dependency refresh.

⚠ Note the roadmap ITEMS once numbered v1.2.1 ("real-device verify") and v1.2.2 ("real hardware validation") were never what shipped under those tags — the tags are the bumps above. That work is now v1.5.7 (which did the real verification) and v1.5.10 (hardware).

### v1.1.x arc — Modernization (2026-05-11)
v1.1.1 compiler-headroom cliff + size pass; v1.1.2 CLOEXEC audit + mount graceful degradation; v1.1.3 cgroup path precomputation; v1.1.4 the QEMU PID-1 boot harness; v1.1.5 the fourth P(-1) audit. 177 tests by the end of the arc.

### v1.1.0 — Foundation refresh (2026-05-11)
cyrius 5.7.12 → 5.10.44, dist-bundle adoption, argonaut imports extended, `kybernet_run()` renamed off a stdlib collision, cc2-era scripts removed. 140 tests.

### v1.0.2 — Toolchain rebase (2026-04-27)
cyrius 4.5.0 → 5.7.12, manifest renamed `cyrius.toml` → `cyrius.cyml`, agnosys 1.0.2 / agnostik 1.0.0 / libro 2.0.5 / argonaut 1.5.0. 140 tests.

### v1.0.1 — Release-pipeline patches (2026-04-12)
Versioning fixups, no source-level changes.

### v1.0.0 — Argonaut-integrated release (2026-04-12)
JSON config + SIGHUP reload, exponential-backoff restarts, emergency shell, tmpfile directives, structured JSON logging. P(-1) hardening (5 CRITICAL + 3 HIGH). klog batching (2.7x), mount cache (1583x). 140 tests, 46 benchmarks.

### v0.90.0 — Security + argonaut integration
seccomp BPF, Landlock sandbox, capability dropping, sd_notify socket, full argonaut integration.

### v0.9.0 — Cyrius rewrite
Complete port from Rust to Cyrius. 727 lines (was 1,649 Rust).

### v0.51.0 — Rust-era fd and signal fixes (2026-04-03)
`into_raw_fd()` for /dev/console (the `File` destructor was closing stdout's fd); a signal drain loop per epoll wake; `process_pending_restarts` switched to retain+collect.

### v0.50.0 — Rust-era hardening + QEMU boot
P(-1) audit, QEMU boot testing, crash recovery, clean shutdown.

### v0.1.0 — Scaffold
Project scaffold, console, mount, signals, reaper, cgroup, privdrop, epoll.
