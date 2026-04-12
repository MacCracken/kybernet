# Kybernet — Claude Code Instructions

## Project Identity

**Kybernet** (Greek: kybernetes, "helmsman") — PID 1 init system for AGNOS. Written in Cyrius.

- **Type**: Cyrius binary (PID 1 init)
- **License**: GPL-3.0-only
- **Version**: 0.90.0
- **Language**: Cyrius 1.9.1+ (self-hosting)

## Goal

The helmsman that steers the Argo. Manages system boot, essential mounts, signal handling, zombie reaping, cgroup isolation, and orderly shutdown. All in Cyrius — no Rust, no C, no libc.

## Build

```sh
cyrb build src/main.cyr build/kybernet   # Build via cyrb (resolves deps from cyrb.toml)
cyrb test src/test.cyr                   # Run 98 tests
cyrb bench src/bench.cyr                 # Run benchmarks
```

## Project Structure

```
kybernet/
├── cyrb.toml              # Project manifest + dependency resolution
├── VERSION, CLAUDE.md, README.md, CHANGELOG.md, LICENSE
├── src/
│   ├── main.cyr           # Boot sequence + event loop
│   ├── test.cyr            # Integration tests (98 assertions)
│   ├── bench.cyr           # Microbenchmarks (22 benchmarks)
│   └── lib/
│       ├── console.cyr     # Stdio redirect
│       ├── signals.cyr     # Signal blocking + signalfd
│       ├── reaper.cyr      # Zombie reaping
│       ├── privdrop.cyr    # Privilege + capability dropping
│       ├── mount.cyr       # Essential filesystem mounts
│       ├── cgroup.cyr      # Cgroup v2 management + limits
│       ├── eventloop.cyr   # Epoll + timerfd
│       ├── notify.cyr      # sd_notify socket
│       ├── seccomp.cyr     # Seccomp BPF filter builder
│       └── sandbox.cyr     # Landlock filesystem sandbox
├── scripts/
│   ├── build.sh            # Build script (legacy, use cyrb build)
│   └── test.sh             # Test runner (legacy, use cyrb test)
├── rust-old/               # Previous Rust implementation (reference)
└── build/                  # Generated binaries (gitignored)
```

## Dependencies (resolved via cyrb.toml)

Dependencies are resolved by `cyrb build` from `cyrb.toml`. No vendored copies.

**Stdlib** (from ~/.cyrius/lib/):
- string, fmt, alloc, io, vec, str, fnptr, tagged, callback, assert, bench

**External** (git tags, cached in ~/.cyrius/deps/):
- agnosys 0.90.0 — Linux syscall bindings (modules: lib/syscalls_linux.cyr)
- agnostik 0.95.0 — Shared AGNOS types (modules: src/security.cyr, src/agent.cyr, src/error.cyr)

## Development Process

```
1. Make changes to src/lib/*.cyr or src/main.cyr
2. Build: cyrb build src/main.cyr build/kybernet
3. Test: cyrb test src/test.cyr (98 tests must pass)
4. All functions return Result or Option where failure is possible
5. Use str_builder for path construction
6. Use klog() for stderr logging
7. Use agnostik types for security config (security_context, capability_set, etc.)
```

## DO NOT

- **Do not commit or push** — the user handles all git operations
- **NEVER use `gh` CLI** — use `curl` to GitHub API only
- Do not modify Cyrius libraries from this repo — changes go in `../cyrius/`
- Do not add C, Rust, or assembly files — everything is Cyrius
- Test after every change
