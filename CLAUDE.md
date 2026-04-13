# Kybernet — Claude Code Instructions

## Project Identity

**Kybernet** (Greek: kybernetes, "helmsman") — PID 1 init system for AGNOS. Written in Cyrius.

- **Type**: Cyrius binary (PID 1 init)
- **License**: GPL-3.0-only
- **Version**: 0.90.0
- **Language**: Cyrius 3.8.0+ (via `~/.cyrius/bin/cc3`)

## Goal

The helmsman that steers the Argo. Manages system boot, essential mounts, signal handling, zombie reaping, cgroup isolation, security enforcement, and orderly shutdown. Delegates service lifecycle to argonaut. All in Cyrius — no Rust, no C, no libc.

## Build

```sh
cyrius build src/main.cyr build/kybernet   # Build (resolves deps from cyrius.toml)
cyrius test src/test.cyr                   # Run 98 tests
cyrius bench src/bench.cyr                 # Run benchmarks
```

## Project Structure

```
kybernet/
├── cyrius.toml            # Project manifest + dependency resolution
├── VERSION, CLAUDE.md, README.md, CHANGELOG.md, LICENSE
├── src/
│   ├── main.cyr           # Boot sequence + argonaut init + event loop
│   ├── test.cyr           # Integration tests (98 assertions)
│   ├── bench.cyr          # Microbenchmarks (22 benchmarks)
│   └── lib/
│       ├── console.cyr    # Stdio redirect
│       ├── signals.cyr    # Signal blocking + signalfd
│       ├── reaper.cyr     # Zombie reaping
│       ├── privdrop.cyr   # Privilege + capability dropping
│       ├── mount.cyr      # Essential filesystem mounts
│       ├── cgroup.cyr     # Cgroup v2 management + limits
│       ├── eventloop.cyr  # Epoll + timerfd
│       ├── notify.cyr     # sd_notify socket
│       ├── seccomp.cyr    # Seccomp BPF filter builder
│       └── sandbox.cyr    # Landlock filesystem sandbox
├── scripts/               # Build, test, bench scripts
├── docs/
│   ├── architecture/overview.md
│   └── development/roadmap.md
├── rust-old/              # Previous Rust implementation (reference)
└── build/                 # Generated binaries (gitignored)
```

## Dependencies (resolved via cyrius.toml)

Dependencies are resolved by `cyrius build` from `cyrius.toml`. No vendored copies.

**Stdlib** (from ~/.cyrius/lib/):
- string, fmt, alloc, io, vec, str, fnptr, tagged, callback, assert, bench, hashmap
- json, freelist, process, sakshi, sakshi_full, sigil, syscalls, mmap, bigint, chrono

**External** (local paths, pinned tags):
- agnosys 0.97.2 — Linux syscall bindings (modules: lib/syscalls_linux.cyr)
- agnostik 0.97.1 — Shared AGNOS types (modules: src/types.cyr, src/security.cyr, src/agent.cyr, src/error.cyr)
- argonaut 1.0.1 — Service lifecycle, boot stages, health, audit (modules: libro + src)

## Development Process

```
1. Make changes to src/lib/*.cyr or src/main.cyr
2. Build: cyrius build src/main.cyr build/kybernet
3. Test: cyrius test src/test.cyr (98 tests must pass)
4. All functions return Result or Option where failure is possible
5. Use str_builder for path construction
6. Use klog() for stderr logging, kmsg() for /dev/kmsg
7. Use agnostik types for security config (security_context, capability_set, etc.)
8. Use argonaut for service lifecycle (init_start_service, init_reap_services, etc.)
```

## DO NOT

- **Do not commit or push** — the user handles all git operations
- **NEVER use `gh` CLI** — use `curl` to GitHub API only
- Do not modify Cyrius stdlib — changes go via `~/.cyrius/`
- Do not modify dep repos (agnosys, agnostik, argonaut) from this repo
- Do not add C, Rust, or assembly files — everything is Cyrius
- Do not reference `../cyrius/` repo — use installed toolchain at `~/.cyrius/`
- Test after every change
