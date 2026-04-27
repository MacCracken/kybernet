# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.2] — 2026-04-27

### Changed
- **Cyrius language**: bumped requirement from 4.5.0 → **5.7.12** for consistency with the rest of the AGNOS base OS (daimon and agnostik already pin 5.7.12).
- **Manifest format**: renamed `cyrius.toml` → `cyrius.cyml` to match the current `cyrius deps` resolver. Package version now interpolates from `VERSION` via `${file:VERSION}`.
- **Stdlib**: dropped `sakshi_full` from `[deps]` — it is no longer shipped in the 5.7.x stdlib (functionality folded into `sakshi`).

### Dependencies
- agnosys 0.97.2 → **1.0.2** (still imports `lib/syscalls_linux.cyr` only — the dist bundle would push past the 64-struct compiler limit)
- agnostik 0.97.1 → **1.0.1** (selective: src/error, types, security, agent)
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
