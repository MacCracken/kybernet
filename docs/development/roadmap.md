# Kybernet Roadmap

## v0.1.0 — Scaffold

- [x] Project scaffold per AGNOS first-party standards
- [x] Console I/O setup
- [x] Essential filesystem mounting
- [x] Signal handling (signalfd)
- [x] Zombie reaping
- [x] Cgroup v2 per-service
- [x] Privilege drop (pre_exec)
- [x] epoll event loop
- [x] Boot flow: config → stages → waves → event loop → shutdown

## v0.2.0 — Hardening

- [ ] QEMU boot testing (minimal + desktop + edge modes)
- [ ] Boot time measurement and optimization
- [ ] Proper delayed restart via timerfd (not thread::sleep)
- [ ] Config reload on SIGHUP
- [ ] Graceful degradation on mount failures
- [ ] Integration tests with real argonaut configs

## v0.3.0 — Security

- [ ] Apply seccomp filters via agnosys in pre_exec
- [ ] Apply Landlock rules via agnosys in pre_exec
- [ ] Emergency shell authentication enforcement
- [ ] Audit logging integration (libro)

## v1.0.0 Criteria

- [ ] All boot modes tested on real hardware (QEMU, RPi4, NUC)
- [ ] Boot time < 3s (Desktop), < 1s (Edge)
- [ ] Crash recovery: kill every service, verify auto-restart
- [ ] Shutdown ordering: no orphan processes after halt
- [ ] No panics under any input
- [ ] All unsafe blocks documented with SAFETY comments
