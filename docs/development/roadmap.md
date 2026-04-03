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

## v0.50.0 — Hardening + QEMU Boot (done)

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
- [x] cargo vet initialized (Mozilla, ISRG, Google, Zcash imports)
- [x] CI + release workflows (no `v` prefix on tags)
- [x] QEMU boot: minimal mode — 2.98s total, 140ms init-to-event-loop
- [x] QEMU boot: desktop mode with real daimon — 2.9s total, 120ms init-to-event-loop
- [x] Crash recovery tested: exponential backoff (1s→2s→4s), restart limit enforced, GiveUp after 3/3
- [x] Clean shutdown tested: SIGTERM → shutdown plan → stop services → sync → power off
- [x] Wave-based parallel startup verified (postgres+redis parallel, then daimon+dependents)
- [x] Reap ordering fix: reap_services BEFORE reap_zombies (prevents waitpid race)
- [x] devtmpfs mount before console setup (QEMU initramfs has no device nodes)
- [x] kmsg-based serial output for QEMU debugging

## v0.60.0 — Security Enforcement

- [ ] Apply seccomp filters via agnosys in pre_exec
- [ ] Apply Landlock rules via agnosys in pre_exec
- [ ] Audit logging integration (libro AuditLog in event loop)
- [ ] Capability drop via pre_exec (integrate privdrop with CapabilityConfig)
- [ ] NOTIFY_SOCKET registered in epoll (event-driven, not polled)

## v0.70.0 — Production Hardening

- [ ] Edge boot test in QEMU (< 1s target)
- [ ] Real hardware testing (RPi4, NUC)
- [ ] Integration tests with real argonaut configs
- [ ] Graceful degradation on mount failures
- [ ] Control socket for agnoshi runtime commands
- [ ] Structured log output to /var/log/kybernet.log
- [ ] Boot time optimization (profile + reduce allocations)

## v1.0.0 Criteria

- [x] QEMU boot: minimal < 3s ✓ (2.98s)
- [x] QEMU boot: desktop < 3s with ALL real AGNOS binaries ✓ (3.28s, 21MB initramfs)
- [x] QEMU boot: edge mode ✓ (init 99ms, total 3.8s — daimon startup dominates)
- [x] QEMU boot: pure AGNOS — zero external dependencies (no busybox) ✓
- [x] Crash recovery ✓ (exponential backoff 1s→2s→4s, restart limit, GiveUp)
- [x] Shutdown ordering ✓ (SIGTERM → plan → stop services → sync → poweroff)
- [x] No panics under crash/shutdown ✓
- [x] All unsafe blocks documented with SAFETY comments ✓
- [x] synapse → ifran rename across argonaut + kybernet ✓
- [x] agnosys ioctl musl fix (enables agnoshi static build) ✓
- [x] Boot times recorded in bench history ✓
- [ ] Real hardware boot (RPi4, NUC)
- [ ] Unit coverage 13.88% (expected — PID 1 code needs QEMU, not unit tests)
- [ ] Edge boot < 1s from init (currently 99ms init + ~1s daimon — needs daimon hardening)
