# Kybernet

**PID 1 helmsman for AGNOS** — the init process that steers the Argo. Written in Cyrius.

## Architecture

```
┌──────────────────────────────────────────────────┐
│                kybernet (PID 1)                  │
│                                                  │
│  console.cyr   — /dev/console stdio redirect     │
│  signals.cyr   — signalfd (SIGCHLD, SIGTERM)     │
│  reaper.cyr    — waitpid zombie reaping          │
│  cgroup.cyr    — cgroup v2 per-service           │
│  privdrop.cyr  — capability + privilege dropping │
│  mount.cyr     — /proc, /sys, /dev, /run         │
│  eventloop.cyr — epoll + timerfd dispatch        │
│  notify.cyr    — sd_notify socket (READY, etc.)  │
│  seccomp.cyr   — seccomp BPF filter builder      │
│  sandbox.cyr   — Landlock filesystem sandbox     │
│                                                  │
│  main.cyr — boot sequence + event loop           │
│                                                  │
│  argonaut  — service lifecycle, boot stages,     │
│              health checks, audit logging         │
│  agnosys   — Linux syscall bindings              │
│  agnostik  — shared AGNOS types                  │
│  libro     — cryptographic audit chain           │
└──────────────────────────────────────────────────┘
```

## Build

Requires Cyrius 5.7.12 (`cyriusly install 5.7.12 && cyriusly use 5.7.12`).

```sh
cyrius deps                                # Resolve deps from cyrius.cyml into lib/
cyrius build src/main.cyr build/kybernet   # Build
cyrius test src/test.cyr                   # Run 140 tests
cyrius bench src/bench.cyr                 # Run benchmarks
```

## Modules

| Module | Lines | What |
|--------|-------|------|
| main | 434 | Boot sequence, argonaut init, event loop, shutdown |
| sandbox | 299 | Landlock filesystem sandboxing (builder pattern) |
| seccomp | 206 | Seccomp BPF filter builder + loader |
| cgroup | 204 | Cgroup v2 paths, move PID, kill, limits |
| privdrop | 184 | Capability dropping + no_new_privs + agnostik bridge |
| eventloop | 123 | OwnedFd, epoll, timerfd, structured events |
| notify | 96 | sd_notify socket (READY, STOPPING, WATCHDOG, STATUS) |
| mount | 89 | Data-driven essential mount table |
| signals | 83 | Block 5 signals, create signalfd, classify |
| reaper | 63 | Non-blocking waitpid loop, structured results |
| console | 36 | Redirect stdin/stdout/stderr for PID 1 |

**1,817 lines of Cyrius** across 11 modules + main (was 1,649 lines of Rust).

## Features

- **Full argonaut integration** — boot stages, wave-based service startup, health checks, watchdog, crash recovery, coordinated shutdown
- **Security stack** — seccomp BPF filters, Landlock filesystem sandbox, capability dropping, no_new_privs
- **Audit logging** — cryptographic audit chain via libro (SHA-256 hash-linked)
- **Result/Option everywhere** — proper error handling via tagged unions
- **Data-driven mount table** — not hardcoded per-mount calls
- **sd_notify compatible** — READY, STOPPING, WATCHDOG, STATUS messages via epoll
- **String builder** for path construction and logging
- **140 tests**, 46 benchmarks

## Dependencies

Resolved via `cyrius.cyml` (locked in `cyrius.lock`):

| Dep | Version | What |
|-----|---------|------|
| agnosys | 1.0.2 | Linux syscall bindings |
| agnostik | 1.0.0 | Shared AGNOS types (security, agent, error) |
| libro | 2.0.5 | Cryptographic audit chain |
| argonaut | 1.5.0 | Service lifecycle, boot stages, health, audit |

Plus 21 stdlib modules from `~/.cyrius/lib/`. Selective `src/<module>.cyr`
imports (not `dist/` bundles) keep the combined unit under the 64-struct
compiler ceiling.

## Requirements

- Linux x86_64
- Cyrius 5.7.12 (`~/.cyrius/bin/cyrius`)
- No C, no Rust, no libc

## Legacy

Previous Rust implementation preserved in `rust-old/` for reference.

## License

GPL-3.0-only
