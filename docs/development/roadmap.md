# Kybernet Roadmap

## v1.0.0 — Release (done)

- [x] Config loading from /etc/kybernet/config.json with fallback to defaults
- [x] SIGHUP config reload (re-initializes argonaut with new config)
- [x] Service restart with exponential backoff via argonaut backoff_delay()
- [x] Restart limit enforcement with CRASH_GIVE_UP and reason logging
- [x] Emergency shell on boot failure (fork+exec agnoshi, fallback /bin/sh)
- [x] Tmpfile directive execution (mkdir, symlink, touch)
- [x] Structured JSON logging to /var/log/kybernet.log
- [x] Shutdown uses config_shutdown_timeout from loaded config
- [x] Service lifecycle: wave startup, crash recovery (RESTART/GIVE_UP/IGNORE), coordinated shutdown
- [x] Health check polling and watchdog enforcement via argonaut
- [x] P(-1) hardening: 5 CRITICAL + 3 HIGH fixes (buffer overflows, fd leaks, PID 1 exit paths)
- [x] Performance: klog batched (2.7x), mount cache (1583x)
- [x] 140 tests, 46 benchmarks
- [x] cc3 3.8.0, agnosys 0.97.2, agnostik 0.97.1, argonaut 1.1.0
- [x] 486KB binary, ~1s build

## v1.0.1 — Boot & Hardware

- [ ] Edge boot (dm-verity, LUKS, PCR binding)
- [ ] Real hardware boot (RPi4, NUC)
- [ ] QEMU boot: minimal < 3s, desktop < 3s
- [ ] QEMU boot time profiling and optimization

## v1.1.0 — Optimization

- [ ] Cgroup path precomputation — cgroup_file() at 911ns per call, precompute common paths per service
- [ ] Binary size optimization (currently 486KB — mostly from transitive deps; dead-code elimination pending cc3 4.0)
- [ ] Integration tests with real argonaut configs
- [ ] Control socket for agnoshi runtime commands
- [ ] Close all fds before exec (CLOEXEC audit)
- [ ] Graceful degradation on mount failures

## History

### v0.95.0 — Production Hardening

P(-1) audit: signals.cyr buffer overflow, console.cyr unchecked dup2, eventloop.cyr unchecked epoll_add, main.cyr PID 1 exit paths, mount.cyr array overflow + underflow guard. klog batching, mount cache. Tests 98→140, benchmarks 22→46.

### v0.90.0 — Security + Argonaut Integration

seccomp BPF, Landlock sandbox, capability dropping, sd_notify socket, full argonaut integration (boot stages, wave startup, health, watchdog, crash recovery, audit logging via libro). 98 tests, 22 benchmarks.

### v0.9.0 — Cyrius Rewrite

Complete rewrite from Rust to Cyrius. 727 lines (was 1,649 Rust). Result/Option error handling, data-driven mount table, callback library. 33 tests.

### v0.50.0 — Hardening + QEMU Boot (Rust era)

P(-1) audit, QEMU boot testing, crash recovery, clean shutdown, wave-based startup. 27 tests.

### v0.1.0 — Scaffold

Project scaffold, console, mount, signals, reaper, cgroup, privdrop, epoll, boot flow.
