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

## v0.95.0 — Production Hardening (done)

- [x] P(-1) scaffold hardening audit — 5 CRITICAL, 3 HIGH fixes
- [x] signals.cyr buffer overflow (buf[16] → buf[128])
- [x] console.cyr unchecked sys_dup2 — now returns Err on failure
- [x] eventloop.cyr unchecked epoll_add_read for signal fd — now propagates error
- [x] main.cyr PID 1 exit paths — now call do_shutdown() instead of returning
- [x] main.cyr eventloop_add_notify return checked, cleans up on failure
- [x] mount.cyr array overflow (_mount_table[8] → [240])
- [x] mount.cyr integer underflow guard in is_mounted()
- [x] klog/klog2 batched to single sys_write (3 writes → 1, ~2.7x faster)
- [x] is_mounted() mount cache (145µs → 92ns, 1583x faster)
- [x] Tests: 98 → 140 (42 new across 10 test functions)
- [x] Benchmarks: 22 → 46 (24 new across all modules)
- [x] Updated all docs: README, CLAUDE.md, architecture, roadmap, CONTRIBUTING
- [x] argonaut 1.1.0, agnosys 0.97.2, agnostik 0.97.1 deps
- [x] Builds on cc3 3.8.0 (481KB, ~970ms, 1 warning)

## v1.0.0 — Release

- [ ] Service lifecycle fully exercised (wave startup, crash recovery, shutdown ordering)
- [ ] Health check enforcement and watchdog timeout handling tested end-to-end
- [ ] Config loading from JSON / SIGHUP reload
- [ ] Edge boot (dm-verity, LUKS, PCR binding)
- [ ] Emergency shell with authentication
- [ ] Real hardware boot (RPi4, NUC)
- [ ] QEMU boot: minimal < 3s, desktop < 3s
- [ ] Structured log output
- [ ] Service restart with exponential backoff (timerfd-based PendingRestart queue)
- [ ] Tmpfile directive execution

## v1.1.0 — Optimization

- [ ] Cgroup path precomputation — cgroup_file() at 911ns per call, precompute common paths per service
- [ ] Binary size optimization (currently 481KB — mostly from transitive deps; dead-code elimination pending cc3 4.0)
- [ ] QEMU boot time profiling and optimization
- [ ] Integration tests with real argonaut configs
- [ ] Control socket for agnoshi runtime commands
- [ ] Structured log output to /var/log/kybernet.log
- [ ] Close all fds before exec (CLOEXEC audit)
- [ ] Graceful degradation on mount failures
