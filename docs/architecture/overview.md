# Kybernet Architecture

## Two-Process Model

Following the pattern used by s6, dinit, and systemd, AGNOS splits init into two processes:

```
PID 1: kybernet (tiny, contains unsafe)
  mount /proc, /sys, /dev, /run
  set up signalfd for SIGCHLD + SIGTERM + SIGPWR
  create epoll event loop
  load argonaut config
  start services via argonaut library
  reap zombies, forward signals, manage cgroups
```

A bug in service management doesn't kernel-panic the system because the service manager logic lives in the argonaut library (which is `forbid(unsafe_code)` and extensively tested).

## Boot Flow

```
1. Console setup (/dev/console, /dev/null)
2. Mount essential filesystems
3. Block signals, create signalfd
4. Load /etc/argonaut/config.json
5. ArgonautInit::new(config)
6. Execute tmpfiles (directories, symlinks, devices)
7. Run boot stages (security, rootfs verification)
8. Start services (wave-based parallel startup)
9. Enter epoll event loop
10. Shutdown on SIGTERM/SIGPWR
```

## Modules

| Module | Purpose |
|--------|---------|
| `main.rs` | PID 1 entrypoint, boot orchestration, event loop |
| `mount.rs` | Essential filesystem mounting with mount-point detection |
| `signals.rs` | signalfd setup for SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGPWR |
| `reaper.rs` | Zombie reaping via `waitpid(-1, WNOHANG)` loop |
| `cgroup.rs` | Cgroup v2 per-service: create, move, kill, cleanup |
| `privdrop.rs` | Privilege drop via `pre_exec` setuid/setgid/setgroups |
| `console.rs` | Console I/O: stdin→/dev/null, stdout/stderr→/dev/console |
| `eventloop.rs` | epoll multiplexer: signalfd, timerfd, notify socket |

## Dependencies

- **argonaut** — service management, boot sequencing, health checks, security configs
- **agnosys** — seccomp, Landlock application (via argonaut's `security` feature)
- **libro** — audit logging (via argonaut's `audit` feature)
- **nix** — safe Unix API wrappers (signals, mount, process)
- **libc** — raw syscalls for epoll, timerfd, reboot, dup2
