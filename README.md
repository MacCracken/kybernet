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
│  agnostik  — shared AGNOS types                  │
│  libro     — cryptographic audit chain           │
│  sigil     — TPM / crypto trust surface (thin)   │
└──────────────────────────────────────────────────┘
```

## Build

Requires Cyrius 6.5.35 (`cyriusly install 6.5.35 && cyriusly use 6.5.35`).

```sh
cyrius deps                                # Resolve deps from cyrius.cyml into lib/
CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet   # Build (DCE recommended)
cyrius test src/test.cyr                   # Run 235 tests
cyrius bench src/bench.cyr                 # Run benchmarks
```

## Modules

| Module | Lines | What |
|--------|-------|------|
| main | 738 | Boot sequence, argonaut init, event loop, shutdown |
| cgroup | 355 | Cgroup v2 paths, move PID, kill, limits, path cache |
| sandbox | 305 | Landlock filesystem sandboxing (builder pattern) |
| seccomp | 206 | Seccomp BPF filter builder + loader |
| privdrop | 175 | Capability dropping + no_new_privs + agnostik bridge |
| edge_boot | 174 | Verified-and-sealed boot pre-flight (TPM PCR, dm-verity) |
| mount | 154 | Data-driven essential mount table |
| eventloop | 124 | OwnedFd, epoll, timerfd, structured events |
| notify | 110 | sd_notify socket (READY, STOPPING, WATCHDOG, STATUS) |
| log | 107 | klog / klog2 / kmsg / slog |
| signals | 83 | Block 5 signals, create signalfd, classify |
| reaper | 75 | Non-blocking waitpid loop, structured results |
| console | 42 | Redirect stdin/stdout/stderr for PID 1 |

**2,648 lines of Cyrius** across main + 12 modules (was 1,649 lines of Rust).

## Features

- **Full argonaut integration** — boot stages, wave-based service startup, health checks, watchdog, crash recovery, coordinated shutdown
- **cgroup v2 isolation** — per-service slice, PID move, limits, kill
- **Per-service sandbox** — seccomp BPF filters, Landlock filesystem sandbox,
  capability dropping and no_new_privs, applied in the child between fork and
  exec via argonaut 1.9.0's pre-exec hook. Order is no_new_privs → capabilities
  → Landlock → seccomp, and it **fails closed**: a policy that cannot be applied
  aborts the child rather than launching the service unconfined. Policy is
  **opt-in per service** (`seccomp` / `landlock` / `capabilities` on the service
  definition, all 0 by default), so a service without a profile behaves exactly
  as before. Authoring profiles for the default AGNOS services is the v1.5.2
  roadmap item.
- **Audit logging** — cryptographic audit chain via libro (SHA-256 hash-linked)
- **Result/Option everywhere** — proper error handling via tagged unions
- **Data-driven mount table** — not hardcoded per-mount calls
- **sd_notify compatible** — READY, STOPPING, WATCHDOG, STATUS messages via epoll
- **String builder** for path construction and logging
- **235 tests**, 51 benchmarks

## Dependencies

Resolved via `cyrius.cyml` (locked in `cyrius.lock`):

| Dep | Version | What |
|-----|---------|------|
| sigil | 3.12.9 | TPM / crypto trust surface (thin sub-bundles only) |
| agnostik | 1.4.0 | Shared AGNOS types (security, agent, error) |
| libro | 2.8.12 | Cryptographic audit chain |
| argonaut | 1.10.0 | Service lifecycle, boot stages, health, audit, pre-exec hook |

`patra` and `sakshi` are **not** declared as git deps — cyrius 6.5.20+ ships
them in the stdlib snapshot, and a git pin would silently downgrade the
folded copy. They are listed in `[deps].stdlib` alongside 30 other stdlib
modules from `~/.cyrius/lib/`.

sigil is pulled as a **thin** set of capability sub-bundles rather than the
monolithic `dist/sigil.cyr`, whose x509/RSA bignum banks add static `.bss`
that dead-code elimination cannot strip.

## Requirements

- Linux x86_64
- Cyrius 6.5.35 (`~/.cyrius/bin/cyrius`)
- No C, no Rust, no libc

## Legacy

Previous Rust implementation preserved in `rust-old/` for reference.

## License

GPL-3.0-only
