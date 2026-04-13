# Kybernet Roadmap

## v0.1.0 — Scaffold (done)

- [x] Project scaffold per AGNOS first-party standards
- [x] Console I/O setup
- [x] Essential filesystem mounting
- [x] Signal handling (signalfd)
- [x] Zombie reaping
- [x] Cgroup v2 per-service
- [x] Privilege drop (pre_exec)
- [x] epoll event loop
- [x] Boot flow: config → stages → waves → event loop → shutdown

## v0.50.0 — Hardening + QEMU Boot (done, Rust era)

- [x] P(-1) audit: 11 findings fixed (fd leaks, no panics, /proc mount order, etc.)
- [x] 27 unit tests (reaper, eventloop, cgroup, config, signals, mount, privdrop)
- [x] Delayed restart via timerfd (PendingRestart queue with exponential backoff)
- [x] Config reload on SIGHUP (registers new services)
- [x] Edge boot wired (rootfs lockdown, dm-verity, LUKS)
- [x] NOTIFY_SOCKET bound before service startup
- [x] Cgroup cleanup on service exit (kill + remove)
- [x] Health-driven restart (threshold exceeded → schedule restart)
- [x] Watchdog-killed services scheduled for restart
- [x] Emergency shell authentication (verify_emergency_auth)
- [x] QEMU boot: minimal mode — 2.98s total, 140ms init-to-event-loop
- [x] QEMU boot: desktop mode with real daimon — 2.9s total, 120ms init-to-event-loop
- [x] Crash recovery tested: exponential backoff, restart limit, GiveUp
- [x] Clean shutdown tested: SIGTERM → plan → stop → sync → poweroff

## v0.9.0 — Cyrius Rewrite (done)

- [x] Complete rewrite from Rust to Cyrius — 727 lines (was 1,649 Rust)
- [x] All 7 original modules + main in Cyrius
- [x] Result/Option error handling throughout (via tagged.cyr)
- [x] String builder for path construction
- [x] Data-driven mount table
- [x] Callback library for functional patterns
- [x] 33 integration tests

## v0.90.0 — Security + Argonaut Integration (done)

- [x] seccomp.cyr — BPF filter builder, 37 safe syscalls preset, agnostik bridge
- [x] sandbox.cyr — Landlock filesystem sandbox, builder pattern, graceful fallback
- [x] privdrop.cyr — capability dropping, no_new_privs, agnostik security_context bridge
- [x] notify.cyr — sd_notify socket integrated with epoll event loop
- [x] Full argonaut integration — boot stages, wave-based startup, health, watchdog, crash recovery, shutdown
- [x] Audit logging via libro (SHA-256 hash-linked chain)
- [x] agnosys 0.97.2, agnostik 0.97.1, argonaut 1.0.1 deps wired
- [x] cyrius.toml manifest with 22 stdlib + 3 external deps
- [x] 98 integration tests, 22 benchmarks
- [x] Builds on cc3 3.8.0 (474KB, ~900ms, 1 warning)

## v0.95.0 — Production Hardening (next)

- [ ] P(-1) scaffold hardening audit (current session)
- [ ] QEMU boot tests with Cyrius binary
- [ ] Graceful degradation on mount failures
- [ ] Close all fds before exec (CLOEXEC audit)
- [ ] Verify all error paths return, never fall through
- [ ] Audit kmsg/klog for all boot failure paths
- [ ] Integration tests with real argonaut configs
- [ ] Binary size optimization (currently 474KB — mostly from transitive deps)

## v1.0.0 — Release

- [ ] Service lifecycle fully exercised (wave startup, crash recovery, shutdown ordering)
- [ ] Health check enforcement and watchdog timeout handling tested end-to-end
- [ ] Config loading from JSON / SIGHUP reload
- [ ] Edge boot (dm-verity, LUKS, PCR binding)
- [ ] Emergency shell with authentication
- [ ] Real hardware boot (RPi4, NUC)
- [ ] QEMU boot: minimal < 3s, desktop < 3s
- [ ] Structured log output

## Not Yet Ported from Rust

These features existed in the Rust version and need reimplementation:

- Service restart with exponential backoff (timerfd-based PendingRestart queue)
- Tmpfile directive execution
- Emergency shell with authentication
- Edge boot (dm-verity, LUKS, PCR binding)
- Configuration loading from JSON / SIGHUP reload

Most depend on argonaut APIs that are now available via the 1.0.1 integration.
