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

## v0.50.0 — Hardening (done)

- [x] P(-1) audit: 11 findings fixed (fd leaks, no panics, /proc mount order, etc.)
- [x] 27 unit tests (reaper, eventloop, cgroup, config, signals, mount, privdrop)
- [x] Delayed restart via timerfd (PendingRestart queue with backoff)
- [x] Config reload on SIGHUP (registers new services)
- [x] Edge boot wired (rootfs lockdown, dm-verity, LUKS)
- [x] NOTIFY_SOCKET bound before service startup
- [x] Cgroup cleanup on service exit (kill + remove)
- [x] Health-driven restart (threshold exceeded → schedule restart)
- [x] Watchdog-killed services scheduled for restart
- [x] Emergency shell authentication (verify_emergency_auth)
- [x] cargo vet initialized (Mozilla, ISRG, Google, Zcash imports)
- [x] CI + release workflows (no `v` prefix on tags)

## v0.60.0 — Security Enforcement

- [ ] Apply seccomp filters via agnosys in pre_exec
- [ ] Apply Landlock rules via agnosys in pre_exec
- [ ] Audit logging integration (libro AuditLog in event loop)
- [ ] Capability drop via pre_exec (integrate privdrop with CapabilityConfig)
- [ ] NOTIFY_SOCKET registered in epoll (event-driven, not polled)

## v0.70.0 — Production Hardening

- [ ] QEMU boot testing (minimal + desktop + edge modes)
- [ ] Boot time measurement and optimization
- [ ] Integration tests with real argonaut configs
- [ ] Graceful degradation on mount failures
- [ ] Control socket for agnoshi runtime commands
- [ ] Structured log output to /var/log/kybernet.log

## v1.0.0 Criteria

- [ ] All boot modes tested on real hardware (QEMU, RPi4, NUC)
- [ ] Boot time < 3s (Desktop), < 1s (Edge)
- [ ] Crash recovery: kill every service, verify auto-restart
- [ ] Shutdown ordering: no orphan processes after halt
- [ ] No panics under any input
- [ ] All unsafe blocks documented with SAFETY comments
- [ ] 80%+ code coverage on testable code
