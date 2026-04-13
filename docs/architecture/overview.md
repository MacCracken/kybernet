# Kybernet Architecture

## Two-Layer Model

Following the pattern used by s6, dinit, and systemd, AGNOS splits init into two layers:

```
PID 1: kybernet (small, direct syscalls, no libc)
  mount /proc, /sys, /dev, /run, cgroup2
  set up signalfd for SIGCHLD + SIGTERM + SIGINT + SIGHUP + SIGPWR
  create epoll event loop + notify socket
  initialize argonaut (config, boot stages, services)
  execute boot stages + start services (wave-based)
  reap zombies, forward signals, manage cgroups
  enforce health checks, watchdog timeouts
  coordinated shutdown via argonaut

Service management library: argonaut (extensively tested, 424 tests)
  config loading, boot sequencing, service lifecycle
  health checks, watchdog enforcement, crash recovery
  audit logging via libro (SHA-256 hash-linked chain)
```

A bug in service management doesn't kernel-panic the system because the service manager logic lives in the argonaut library.

## Boot Flow

```
Phase 0: klog("starting")
Phase 1: Mount devtmpfs (needed for /dev/console, /dev/kmsg)
Phase 2: Console setup (/dev/console, /dev/null)
Phase 3: Mount essential filesystems (/proc, /sys, /run, cgroup2)
Phase 4: Block signals, create signalfd
Phase 5: Create epoll event loop + notify socket
Phase 6: Initialize argonaut (config, health tracker)
Phase 7: Run boot stages (via argonaut)
Phase 8: Start services (wave-based parallel startup)
Phase 9: Enter epoll event loop
Shutdown: SIGTERM/SIGINT → stop services → sync → reboot/poweroff
```

## Modules

| Module | Purpose |
|--------|---------|
| `main.cyr` | PID 1 entrypoint, boot orchestration, event loop, shutdown |
| `console.cyr` | Console I/O: stdin→/dev/null, stdout/stderr→/dev/console |
| `signals.cyr` | signalfd setup for SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGPWR |
| `reaper.cyr` | Zombie reaping via `sys_waitpid(-1, WNOHANG)` loop |
| `mount.cyr` | Essential filesystem mounting with data-driven mount table |
| `cgroup.cyr` | Cgroup v2 per-service: create, move, kill, cleanup, limits |
| `privdrop.cyr` | Privilege drop: capabilities, no_new_privs, agnostik bridge |
| `eventloop.cyr` | epoll multiplexer: signalfd, timerfd, notify socket |
| `notify.cyr` | sd_notify socket (READY, STOPPING, WATCHDOG, STATUS) |
| `seccomp.cyr` | Seccomp BPF filter builder + loader (37 safe syscalls preset) |
| `sandbox.cyr` | Landlock filesystem sandbox (builder pattern, graceful fallback) |

## Dependencies

- **argonaut 1.0.1** — service management, boot sequencing, health checks, crash recovery, audit
- **agnosys 0.97.2** — Linux syscall bindings (50+ syscalls, epoll, timerfd, signalfd)
- **agnostik 0.97.1** — shared AGNOS types (security_context, capability_set, agent_config)
- **libro** (via argonaut) — cryptographic audit logging (SHA-256 hash-linked chain)
- **sigil** (via libro) — Ed25519, SHA-256/512, HMAC
- **sakshi** (via argonaut) — structured tracing/logging

## Event Loop Tokens

| Token | Source | Handler |
|-------|--------|---------|
| 1 | signalfd | Signal dispatch (SIGCHLD→reap, SIGTERM→shutdown, etc.) |
| 2 | timerfd (health) | Health check polling via argonaut |
| 3 | timerfd (watchdog) | Watchdog enforcement via argonaut |
| 5 | notify socket | sd_notify message parsing (READY, STOPPING, etc.) |
