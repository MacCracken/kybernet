# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.1.2] — 2026-05-11

**CLOEXEC sweep + mount graceful degradation.** Two long-standing items on the v1.0.1/v1.1.0 slate that didn't have a forcing function but are necessary hygiene for a PID 1: fd-leak audit across `sys_open` call sites, and mount-table classification so optional filesystems don't wedge boot on minimal hardware.

### Security
- **CLOEXEC audit** across every `sys_open` call site in `src/main.cyr` and `src/lib/*.cyr`. PID 1 inherits no fds — but any fd it opens leaks into every spawned service via `fork+execve` unless `O_CLOEXEC` is set at open time (or `FD_CLOEXEC` is set via `fcntl(F_SETFD)` before exec). The kybernet/argonaut split puts the open-side discipline in kybernet's lap.
  - **`src/main.cyr:105`** — `g_log_fd` (`/var/log/kybernet.log`): **highest-risk** site. The fd is global, open for PID 1's entire lifetime, and absent CLOEXEC would have been inherited by every service argonaut spawned. Adding `O_CLOEXEC` here is the load-bearing fix.
  - **`src/main.cyr:60`** — `kmsg()` on `/dev/kmsg`: short-lived (open → write → close in-frame), but the frame is reentered from signal handlers and pre-fork code paths. Adding `O_CLOEXEC` is defensive against fork-between-open-and-close races.
  - **`src/main.cyr:223`** — tmpfile `TMP_TOUCH` create: same short-lived-but-defensive shape.
  - **`src/lib/cgroup.cyr:57, 71, 115`** — cgroup-control writes (`cgroup.procs`, `cgroup.kill`, generic u64 writes): all called from PID 1's parent side of `fork()`. Without CLOEXEC, an interleaving spawn would have inherited the cgroup-control fd into the child, allowing the child to move processes between cgroups or kill its own peers.
  - **`src/lib/console.cyr:21, 25, 27`** — fds 0/1/2: **intentionally NOT CLOEXEC.** Standard I/O must pass through exec to spawned services. A comment block at the call site documents the reason so a future audit doesn't "fix" it.
  - `src/lib/sandbox.cyr` already had `O_CLOEXEC_FLAG` on its two Landlock path opens (carried over from 0.90.0).
  - `signalfd`, `timerfd`, `socket` (notify), `epoll_create` all already CLOEXEC: the stdlib wrappers wrap `signalfd4`/`timerfd_create`/`socket`/`epoll_create1` with `SFD_CLOEXEC`/`TFD_CLOEXEC`/`SOCK_CLOEXEC`/`EPOLL_CLOEXEC` set, and the call sites pass the right flags. No fix needed; verified in the audit.

### Added
- **Mount graceful degradation** in `src/lib/mount.cyr`. The mount table grew a sixth `required` field per entry; `mount_essential()` now hard-fails only on required-mount errors and records optional-mount failures in a separate accessor-exposed list. `src/main.cyr` boot phase 3 iterates the skipped list after `mount_essential()` returns and emits a `klog2()` line per skipped target, so the operator sees `kybernet: skipped optional mount: /dev/pts` rather than a silent disappearance.
  - Classification: `/proc` `/sys` `/run` `/sys/fs/cgroup` = required (1); `/dev/pts` `/dev/shm` = optional (0).
  - The motivating use case is **minimal embedded boot** — RPi-class boards without a serial console can boot the rest of the AGNOS stack without `/dev/pts`, and POSIX-shm-free service sets don't need `/dev/shm`. Both were previously fatal at boot.
  - Entry stride moved 40 → 48 bytes (5 → 6 i64 slots); backing array `_mount_table[240]` → `[288]`.
  - New API surface (visible to test + future consumers): `mount_skipped_count()` and `mount_skipped_target(idx)`. Out-of-bounds indices return 0 rather than crashing.

### Tests
- **`test_cloexec_fcntl_probe`** (4 assertions): opens `/dev/null` once with `O_CLOEXEC` and once without, calls `syscall(SYS_FCNTL, fd, F_GETFD=1, 0)`, asserts the returned flags' `FD_CLOEXEC` bit (= 1) matches expectations. The without-CLOEXEC control proves the probe distinguishes set from unset — a bogus probe returning 1 for everything would still pass the first assertion. No `sys_fcntl` wrapper in stdlib at 5.10.44; `SYS_FCNTL` constant is defined on both x86_64 (72) and aarch64 (25), so the raw call is portable.
- **`test_mount_required_flag`** (9 assertions): verifies `required` field is stored at offset +40 for each entry, with the per-entry classification matching the design (`/proc` `/sys` `/run` `/sys/fs/cgroup` = 1; `/dev/pts` `/dev/shm` = 0). Catches stride mistakes or re-orderings on future edits. Also exercises `mount_skipped_count()` returning 0 + accessor returning 0 for OOB indices (positive and negative).
- Total: **140 → 153 tests** pass.

### Stats
- x86_64 DCE binary: 1.02 MB → **1.02 MB** (+1.4 KB; new mount-skipped tracking + classification overhead)
- aarch64 cross-build: clean
- fn_table / identifier buffer: still under warn thresholds (1.1.1 headroom holds)
- fmt / vet / bench: clean

### Notes
- Upstream issue filed at `cyrius/docs/development/issues/2026-05-11-kybernet-fn-table-identifier-buffer-caps.md` requesting `fn_table` and `identifier buffer` cap doubling. Rated P2: 1.1.1 trim shipped clean, but the next minor (1.2.0 edge boot) will press back into the warn band. This isn't a 1.1.2 fix, just adjacent diligence.

---

## [1.1.1] — 2026-05-11

**Compiler-headroom cliff + size pass.** 1.1.0 shipped at `fn_table 92% (3779/4096)` and `identifier buffer 85% (112094/131072)` — both ceilings are hard, and the next dep bump (agnosys 1.2.4 → 1.2.5 landed mid-cut) would have tipped past them. Roadmap had this as the 1.1.1 slot with 1.1.2 sequenced afterward for the DCE/size pass; one fix collapsed both.

Audit of `CYRIUS_DCE=1` dead-code reports showed **3116 dead functions** out of ~3779 registered — kybernet was paying compiler-table cost for the full agnosys dist bundle (350 fns) while calling **zero agnosys-prefixed functions from its own source**. The libro / agnostik / argonaut dist bundles also make no agnosys-domain calls (libro's TPM path is gated behind `-D LIBRO_TPM`, off by default). Switching `[deps.agnosys] modules` from `dist/agnosys.cyr` → `dist/agnosys-core.cyr` reclaimed ~290 fn_table slots without breaking any consumer.

### Changed
- **agnosys profile bundle**: `dist/agnosys.cyr` → **`dist/agnosys-core.cyr`** (56 fns vs. 350 — syscall + error + logging only). Mirrors the kavach pattern (`core` + per-domain profile); the storage/trust/security/system profiles aren't needed at the PID-1 layer.

### Dependencies
- agnosys 1.2.4 → **1.2.5** (matches the new agnosys tag landed alongside this cut; cyrius pin already at 5.10.44, no toolchain change)

### Stats
- **fn_table warning gone** (was 92% — now below the 90% warn threshold; cyrius stops emitting the line)
- **identifier buffer warning gone** (was 85%)
- **Dead-fn count**: 3116 → **2430** (down 686 — the difference is the 290 agnosys-non-core fns plus DCE-driven secondary trims)
- **Binary x86_64 (`CYRIUS_DCE=1`)**: 1.29 MB → **1.02 MB** (−21%). Parity with argonaut's 1.0 MB DCE binary.
- **Binary aarch64**: cross-build clean; ELF check passes
- **140 / 140 tests** pass; vet clean; bench runs; fmt OK

### Notes
- The 1.0.x roadmap had "Binary size optimization" as gated on "dead-code elimination pending cc3 4.0" — that gate became moot in 1.1.0 (cc5 has `CYRIUS_DCE`), and the actual win here was upstream of DCE: trimming surface that the compiler had to register at all. DCE just makes the choice cheaper to validate (smaller binary = same correctness signal).
- agnosys-core surface check (regression guard): kybernet calls **only** `sys_*` syscall wrappers from the agnosys/stdlib boundary. If a future change adds a `log_*` / `mac_*` / `audit_*` / `tpm_*` / `luks_*` etc. call, swap `agnosys-core.cyr` for `agnosys.cyr` (or add the specific profile via a second `[deps.agnosys-<profile>]` entry).
- Roadmap consequence: 1.1.2 (DCE + size pass) was folded into this cut. 1.1.3/1.1.4/1.1.5 renumber down by one slot (now 1.1.2/1.1.3/1.1.4).

---

## [1.1.0] — 2026-05-10

**Foundation refresh.** Cyrius toolchain bumped, all four AGNOS deps moved to current tags, manifest modernized to use dist bundles where the dep ships one. The forcing function was upstream renames (agnosys moved `lib/syscalls_linux.cyr` → `src/syscall.cyr`, retiring the path the 1.0.2 manifest pinned) — once the rebase started, several previously-deferred items unblocked, so they're collapsed into this cut and the 1.1.x arc is rewritten around what's now in reach.

### Changed
- **Cyrius language**: 5.7.12 → **5.10.44**. Pinned to match argonaut 1.6.2 — argonaut's `health.cyr`/`process_mgmt.cyr` call `exec_vec_str`/`exec_env_str`, which only exist in the 5.10.44+ stdlib `process.cyr`. The 5.10.x toolchain is also where `cc5` lives (cc3 retired); cc5 lifts the 64-struct compilation ceiling that previously forced selective module imports for the heavy deps.
- **Manifest** (`cyrius.cyml`): stdlib pin order reordered to `argonaut`-style (syscalls early, before `io`/`process`) — the pre-existing layout tripped a cyrius transitive-dedup bug that was silently dropping `syscalls.cyr` from the preprocessed output, segfaulting `cc5` on link.
- **Stdlib pins**: dropped `sakshi` and `sigil` (libro 2.5+ promoted both to external git-pinned deps; patra 1.9+ pulls sakshi as its own dep — they land in `lib/` via transitive resolve and would otherwise duplicate-define against the version-pinned stdlib copy). Added `slice`, `result`, `trait`, `net`, `fs`, `ct`, `keccak`, `thread`, `random` — required by the new dist bundles.
- **`src/main.cyr`**: renamed `fn run()` → `fn kybernet_run()`. The stdlib `process.cyr` now exports its own `run(cmd, arg1, arg2)` and the dist-bundle pull made the collision a duplicate-fn warning under `cc5`.
- **`src/bench.cyr`**: header comment "deps resolved via cyrb.toml" → "stdlib + deps auto-included via cyrius.cyml" (cyrb retired in 1.0.0).

### Added
- **patra 1.9.3** declared explicitly under `[deps.patra]` (rather than inheriting whatever libro's pin transitively pulls). Mirrors argonaut 1.6+'s pattern of surfacing transitively-resolved deps so the version is under direct local control.
- **argonaut imports extended** with `resolver.cyr` / `notify.cyr` / `audit_ext.cyr` / `tmpfiles.cyr` — back the symbols (`resolve_host_ipv4`, `notify_bind`, `audit_log_*persistent`, `pal_chain`) that 1.6.x `init.cyr`/`health.cyr`/`process_mgmt.cyr` reference. `pid1_harness.cyr` intentionally **not** imported — it's argonaut's own QEMU PID-1 graduation harness, not a consumer-facing module.

### Dependencies
- agnosys 1.0.2 → **1.2.4** (now via `dist/agnosys.cyr` bundle — was selective `lib/syscalls_linux.cyr` only)
- agnostik 1.0.0 → **1.2.1** (now via `dist/agnostik.cyr` — was selective error/types/security/agent)
- libro 2.0.5 → **2.6.2** (now via `dist/libro.cyr` — was selective error/hasher/entry/verify/query/retention/chain/export)
- argonaut 1.5.0 → **1.6.2** (selective; argonaut ships no dist bundle. 1.6.x adds PID-1 harness internals, sigmask hardening for spawned services, `PATH` envp default, and the `audit_ext` persistence layer. 1.6.2 is the latest tagged release; argonaut's working tree is at unreleased VERSION 1.6.3.)
- patra newly declared at **1.9.3** (transitive via libro)
- sigil **3.0.1** + sakshi (transitive via libro/patra; pinned in `cyrius.lock`)

### Removed
- `scripts/build.sh`, `scripts/test.sh`, `scripts/bench.sh`, `scripts/bench-compare.sh` — all referenced `${ROOT}/../cyrius/build/cc2` (cc2 retired with 1.0.0). The modern path is `cyrius build`/`test`/`bench` directly. Roadmap had flagged these for removal since 1.0.1; the removal landed here so the test/release surface only points at one toolchain.
- `scripts/version-bump.sh` no longer touches `Cargo.toml` (Rust era; the file hasn't existed since 0.9.0). It now only rewrites `VERSION`; `cyrius.cyml` already pulls `package.version` from `${file:VERSION}`.
- **`lib/` untracked from git** (`.gitignore` adds `/lib/`). `cyrius.lock` already pins every resolved dep file by sha256 — checked-in `lib/*.cyr` was duplicating that contract. Aligns with the AGNOS-wide convention: agnosys / agnostik / libro / argonaut all gitignore `lib/`. `cyrius deps --verify` against the locked hashes is the reproducibility guarantee.

### Notes
- Build green on cyrius 5.10.44; **140 / 140 tests pass**, vet clean, bench runs.
- Binary x86_64 with `CYRIUS_DCE=1`: **1.29 MB** (was 447 KB at 1.0.2). The growth is from full agnosys/agnostik/libro/patra dist bundles vs. the prior selective-import slim cuts; 1.1.2 plans a profile-bundle vs. full-bundle audit to reclaim the headroom.
- `cc5` reports `fn_table at 92% (3773/4096)` and `identifier buffer at 85%` — these are hard ceilings; v1.1.1 is sequenced first in the 1.1.x arc to trim before the next dep bump tips past them.
- Compile-time warning catalogue (all carried up from dep dist bundles, not kybernet-introduced): one `match arms span multiple enums` in `agnosys.cyr`, four `duplicate fn 'err_*'` in `agnostik.cyr` (last-definition-wins is intentional), one `duplicate fn 'health_check_new'` in `argonaut_types.cyr`, one `duplicate fn '_hex_nibble'` in `sigil.cyr`.
- CI/release workflows carried forward unchanged except for a comment update to the lock-verify step (pins now include patra and the transitive sigil/sakshi entries).

---

## [1.0.2] — 2026-04-27

### Changed
- **Cyrius language**: bumped requirement from 4.5.0 → **5.7.12** for consistency with the rest of the AGNOS base OS (daimon and agnostik already pin 5.7.12).
- **Manifest format**: renamed `cyrius.toml` → `cyrius.cyml` to match the current `cyrius deps` resolver. Package version now interpolates from `VERSION` via `${file:VERSION}`.
- **Stdlib**: dropped `sakshi_full` from `[deps]` — it is no longer shipped in the 5.7.x stdlib (functionality folded into `sakshi`).

### Dependencies
- agnosys 0.97.2 → **1.0.2** (still imports `lib/syscalls_linux.cyr` only — the dist bundle would push past the 64-struct compiler limit)
- agnostik 0.97.1 → **1.0.0** (selective: src/error, types, security, agent)
- libro is now declared directly (was previously transitive via argonaut): pinned to **2.0.5** with src/error, hasher, entry, verify, query, retention, chain, export
- argonaut 1.2.0 → **1.5.0** (src/types, audit, services, health, process_mgmt, boot, init)

### Notes
- Build green on cyrius 5.7.12; **140 tests pass**.
- Stayed on selective `src/<module>.cyr` imports for the heavy deps rather than switching to `dist/<dep>.cyr` bundles — full bundles overflow the compiler's 64-struct ceiling for kybernet's combined unit. daimon/argonaut can use dist bundles because their dep graphs are lighter.

---

## [1.0.1] — 2026-04-12

### Fixed
- Release pipeline / CI version handling (versioning fixups, no source-level changes from 1.0.0).

---

## [1.0.0] — 2026-04-12

### Added

#### Config Loading
- **JSON config** — loads /etc/kybernet/config.json at boot (boot_mode, timeouts, log_to_console)
- **SIGHUP reload** — `handle_sighup()` reloads config and updates argonaut instance
- Fallback to `argonaut_config_default()` when config file missing or parse fails

#### Service Lifecycle
- **Exponential backoff restart** — uses argonaut's `backoff_delay()` from `CrashAction` instead of fixed 5s delay
- **Restart limit enforcement** — `restart_limit_exceeded()` triggers `CRASH_GIVE_UP` with reason string
- **Crash action logging** — logs `CRASH_RESTART` (with delay), `CRASH_GIVE_UP` (with reason), `CRASH_IGNORE`
- Shutdown uses `config_shutdown_timeout()` from loaded config

#### Emergency Shell
- **`drop_to_emergency()`** — fork+exec emergency shell on boot failure
- Uses argonaut's `emergency_shell_default()` (agnoshi, with banner and env)
- Fallback to `/bin/sh` if primary shell exec fails
- Waits for shell exit, then continues boot

#### Tmpfile Directives
- **`execute_tmpfiles()`** — walks `config_tmpfiles()` vec before service startup
- Supports `TMP_DIR` (mkdir), `TMP_SYMLINK` (symlink), `TMP_TOUCH` (create empty file)

#### Structured Logging
- **JSON lines** to `/var/log/kybernet.log` via `slog()` function
- `slog_init()` opens log file after filesystems mounted
- All klog/klog2 messages also emitted as structured JSON (`{"level":"...","msg":"..."}`)
- Log fd closed during shutdown

#### P(-1) Hardening (v0.95.0 work)
- signals.cyr: buffer overflow fix (buf[16] → buf[128] for signalfd_siginfo)
- console.cyr: checked sys_dup2 returns
- eventloop.cyr: checked epoll_add_read for signal fd
- main.cyr: PID 1 exit paths now call do_shutdown() instead of returning
- main.cyr: eventloop_add_notify return checked with cleanup
- mount.cyr: array overflow fix (_mount_table[8] → [240])
- mount.cyr: integer underflow guard in is_mounted()
- klog/klog2 batched to single sys_write (~2.7x faster)
- is_mounted() mount cache (145µs → 92ns, 1583x faster)
- 140 tests (was 98), 46 benchmarks (was 22)

### Changed
- Build tool: `cyrius build` with auto-include from `cyrius.toml` (was `cyrb build`)
- Source files contain only project includes — stdlib + deps auto-prepended by build tool
- Compiler: cc3 3.9.6+ required (was 1.9.1)
- Binary size: 447KB (includes argonaut + libro + sigil + sakshi transitive deps)
- CI: `cyrius deps` + `cyrius build` with fallback rebuild if tool binary is stale

### Dependencies
- Declared in `cyrius.toml` `[deps]` section, resolved via `cyrius deps`
- Namespaced: `lib/{depname}_{basename}` (e.g. `agnostik_types.cyr`)
- agnosys 0.97.2 — `lib/syscalls_linux.cyr`
- agnostik 0.97.1 — types, security, agent, error
- argonaut 1.1.0 — libro (error, entry, hasher, chain, query, verify, retention, export), types, audit, services, health, process_mgmt, boot, init
- 22 stdlib modules (string, fmt, alloc, io, vec, str, fnptr, tagged, callback, hashmap, json, freelist, process, sakshi, sakshi_full, sigil, syscalls, mmap, bigint, chrono, bench, assert)

---

## [0.90.0] — 2026-04-07

### Added

#### Security Modules
- **seccomp.cyr** — seccomp BPF filter builder and loader
  - Builder pattern: `seccomp_builder_new()` → `seccomp_allow(nr)` → `seccomp_build()` → `seccomp_load()`
  - Generates raw BPF bytecode with JEQ instructions, default KILL_PROCESS
  - `seccomp_basic_service()` preset with 37 safe syscalls
  - Agnostik integration: `seccomp_from_profile()`, `seccomp_apply_profile()`
- **sandbox.cyr** — Landlock filesystem sandboxing (new, not in Rust version)
  - Builder pattern: `sandbox_builder_new()` → `sandbox_allow_read/write/exec(path)` → `sandbox_apply()`
  - Graceful fallback on kernels < 5.13 (ENOSYS/EOPNOTSUPP → Ok(1))
  - `sandbox_basic_service()` preset: /usr (exec), /lib (read), /etc (read), /tmp+/var+/run (read-write)
  - Agnostik integration: `sandbox_from_ruleset()`, `sandbox_from_config()`
- **privdrop.cyr** — capability dropping and no_new_privs
  - `drop_capabilities(keep_set)` via PR_CAPBSET_DROP prctl
  - `set_no_new_privs()` (required before seccomp/landlock)
  - `secure_pre_exec(uid, gid, keep_caps)` orchestrating full security setup
  - Agnostik integration: `privdrop_from_context()`, `drop_caps_from_set()`, `secure_from_context()`
- **notify.cyr** — sd_notify socket for service readiness
  - Unix datagram socket at /run/kybernet/notify
  - Parses READY=1, STOPPING=1, WATCHDOG=1, RELOADING=1, STATUS=
  - Integrated with epoll event loop via TOKEN_NOTIFY

#### Agnostik Integration
- Consume agnostik security types: `security_context`, `capability_set`, `seccomp_profile`, `landlock_ruleset`, `sandbox_config`, `cgroup_limits`, `resource_limits`, `agent_config`
- **privdrop.cyr** — `secure_from_context(ctx, caps)` accepts agnostik security context
- **seccomp.cyr** — `seccomp_apply_profile(profile)` accepts agnostik seccomp profile
- **sandbox.cyr** — `sandbox_from_ruleset(ruleset)` accepts agnostik landlock ruleset
- **cgroup.cyr** — `cgroup_apply_limits()`, `cgroup_apply_resource_limits()`, `cgroup_setup_agent()` accept agnostik limits and agent config
- 34 new tests covering all agnostik type construction, access, and integration bridges

#### Dependency Management
- **cyrb.toml** — TOML-based dependency resolution via Cyrius 1.9.1
  - `[deps] stdlib = [...]` for stdlib modules
  - `[deps.agnosys] git + tag + modules` for pinned git dependencies
  - `[deps.agnostik] git + tag + modules` for pinned git dependencies
  - `cyrb build` auto-prepends resolved includes before source
- Removed vendored `lib/agnosys/` — resolved from git tag at build time
- Removed manual `include` directives for stdlib and agnosys from all source files

#### Boot & Event Loop
- kmsg logging at each boot phase for QEMU serial console visibility
- Notify socket integrated with epoll event loop (TOKEN_NOTIFY)
- Event loop handles READY, STOPPING, WATCHDOG, STATUS notify messages

#### Benchmarks & Testing
- **src/bench.cyr** — 22 microbenchmarks across 8 categories
- **scripts/bench.sh** — build and run benchmarks with history tracking
- **scripts/bench-compare.sh** — side-by-side Cyrius vs Rust comparison table
- **benches/rust_compare.rs** — standalone Rust benchmark (raw syscalls, no libc)
- QEMU boot tests ported from rust-old: boot-test, boot-crash-test, boot-shutdown-test
- 98 integration tests (was 33)

### Changed
- **Cyrius 1.9.1** language features throughout:
  - `switch/case` with dense jump table optimization (classify_signal, handle_signal, priv_error_print, _access_to_flags)
  - `for` loops with step expressions replacing `while` + manual counter
  - `elif/else` chains replacing nested `if` blocks
  - `&&` and `||` operators replacing nested conditionals
  - `break/continue` in loops replacing flag variables
- Binary size: 93,800 bytes (was 47,888 at 0.9.0, increase from agnostik types)
- Rust comparison: 71x smaller binary, 2x faster boot, 1.06x syscall parity

### Dependencies
- agnosys 0.90.0 (git tag, modules: lib/syscalls_linux.cyr)
- agnostik 0.95.0 (git tag, modules: src/security.cyr, src/agent.cyr, src/error.cyr)
- Cyrius stdlib: string, fmt, alloc, io, vec, str, fnptr, tagged, callback, assert, bench

### Not Yet Ported from Rust
- Service lifecycle management (wave-based startup, restart with backoff)
- Health check enforcement and watchdog timeout handling
- Configuration loading from JSON / SIGHUP reload
- Edge boot (dm-verity, LUKS, PCR binding)
- Emergency shell with authentication
- Coordinated shutdown (service stop ordering)
- Tmpfile directive execution

These features depend on argonaut (service manager) which is being ported to Cyrius separately.

---

## [0.9.0] — 2026-04-05

### Changed
- **Complete rewrite from Rust to Cyrius** — 727 lines (was 1649 Rust)
- All 7 modules + main entry point in Cyrius
- Result/Option error handling throughout (via tagged.cyr)
- String builder for path construction
- Data-driven mount table (not hardcoded calls)
- Callback library for functional patterns (vec_map, vec_filter, fork_with_pre_exec)
- OwnedFd pattern, structured EpollEvent returns
- PrivError enum with specific error codes and verification
- 33 integration tests

### Added
- src/main.cyr — full boot sequence + event loop + signal dispatch + shutdown
- scripts/build.sh, scripts/test.sh — Cyrius build tooling
- rust-old/ — preserved Rust implementation for reference

## [0.51.0] — 2026-04-03

### Fixed
- **console.rs**: Use `into_raw_fd()` instead of `as_raw_fd()` when opening `/dev/console` — prevents the `File` destructor from closing the fd while it's still in use as stdout
- **main.rs**: Corrected boot phase comments (phase 6/7 → phase 8/9) to match actual ordering

### Changed
- **main.rs**: Signal handling now drains all queued signals per epoll wake (`while let` loop instead of single `if let`) — prevents signal loss under burst
- **main.rs**: `process_pending_restarts` uses `retain` + collect instead of front-popping — the queue is not sorted by `restart_at`, so the old approach could skip ready items behind a future one

### Added
- **eventloop.rs**: Test `drain_timerfd_returns_nonzero_after_expiration` — validates timerfd expiration count
- **eventloop.rs**: Test `into_raw_fd_keeps_fd_open` — documents the console.rs fd ownership fix

---

## [0.50.0] — 2026-04-03

### Added

#### Scaffold
- Project scaffold per AGNOS first-party standards
- `console.rs` — /dev/console + /dev/null stdio setup (after devtmpfs mount)
- `mount.rs` — essential filesystem mounting (/proc, /sys, /dev, /run, cgroup2)
- `mount_devtmpfs()` — standalone devtmpfs mount (must run before console setup)
- `signals.rs` — signalfd setup for SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGPWR
- `reaper.rs` — zombie reaping via waitpid(-1, WNOHANG) loop
- `cgroup.rs` — cgroup v2 per-service isolation (create, move, kill, remove)
- `privdrop.rs` — privilege drop via pre_exec setuid/setgid/setgroups
- `eventloop.rs` — epoll event loop with timerfd, OwnedFd RAII wrapper
- `main.rs` — PID 1 entrypoint: boot flow, service startup, event loop, shutdown

#### Hardening (P(-1) audit)
- Fixed 11 audit findings: fd leaks (OwnedFd), no assert/panic, /proc mount ordering, etc.
- 27 unit tests across all modules
- Delayed restart via timerfd with PendingRestart queue (exponential backoff)
- Config reload on SIGHUP (registers new services from reloaded config)
- Edge boot wired: rootfs lockdown + dm-verity + LUKS via argonaut::execute_edge_boot
- NOTIFY_SOCKET bound and set in environment before service startup
- Cgroup cleanup on service exit (kill_cgroup + remove_service_cgroup)
- Health-driven restart: poll_health results trigger restart when threshold exceeded
- Watchdog-killed services automatically scheduled for restart
- Emergency shell authentication via argonaut::verify_emergency_auth
- Reap ordering: reap_services BEFORE reap_zombies (prevents waitpid race)
- kmsg output for QEMU serial console debugging

#### QEMU Boot Testing
- Minimal mode: 2.98s kernel+init, 140ms init-to-event-loop
- Desktop mode with real daimon binary: 2.9s total, 120ms init-to-event-loop
- Wave-based parallel startup: postgres+redis (Wave 0) → daimon+dependents (Wave 1)
- Crash recovery: service crash → SIGCHLD → reap → delayed restart with backoff → GiveUp after limit
- Clean shutdown: SIGTERM → plan → stop services → sync → reboot(RB_POWER_OFF)
- QEMU test scripts: boot-test.sh, boot-crash-test.sh, boot-shutdown-test.sh, boot-desktop-test.sh
- build-initramfs.sh: creates QEMU-bootable initramfs with kybernet + busybox

#### Infrastructure
- cargo vet initialized (Mozilla, ISRG, Google, Zcash audit imports)
- CI workflow: fmt, clippy, test, audit, deny, msrv
- Release workflow: version verification, multi-arch build, GitHub release
- deny.toml with AGNOS git source allowlist
