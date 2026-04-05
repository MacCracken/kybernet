# Kybernet — Claude Code Instructions

## Project Identity

**Kybernet** (Greek: kybernetes, "helmsman") — PID 1 init system for AGNOS. Written in Cyrius.

- **Type**: Cyrius binary (PID 1 init)
- **License**: GPL-3.0-only
- **Version**: 0.9.0
- **Language**: Cyrius (self-hosting, zero external dependencies)

## Goal

The helmsman that steers the Argo. Manages system boot, essential mounts, signal handling, zombie reaping, cgroup isolation, and orderly shutdown. All in Cyrius — no Rust, no C, no libc.

## Build

```sh
sh scripts/build.sh        # Build (requires ../cyrius/build/cc2)
sh scripts/test.sh         # Run 33 tests
```

## Project Structure

```
kybernet/
├── VERSION, CLAUDE.md, README.md, CHANGELOG.md, LICENSE
├── src/
│   ├── main.cyr          # Boot sequence + event loop
│   ├── test.cyr           # Integration tests (33 assertions)
│   └── lib/
│       ├── console.cyr    # Stdio redirect
│       ├── signals.cyr    # Signal blocking + signalfd
│       ├── reaper.cyr     # Zombie reaping
│       ├── privdrop.cyr   # Privilege dropping
│       ├── mount.cyr      # Essential filesystem mounts
│       ├── cgroup.cyr     # Cgroup v2 management
│       └── eventloop.cyr  # Epoll + timerfd
├── scripts/
│   ├── build.sh           # Build script
│   └── test.sh            # Test runner
├── rust-old/              # Previous Rust implementation (reference)
└── build/                 # Generated binaries (gitignored)
```

## Dependencies (vendored in lib/)

Cyrius stdlib is vendored in `lib/` — no external path dependencies at compile time.
Only the compiler binary (`cc2`) is needed from the cyrius repo.

- string, fmt, alloc, io, vec, str, fnptr — core stdlib
- tagged — Option/Result types
- callback — vec_map, vec_filter, fork_with_pre_exec
- agnosys — Linux syscall bindings
- assert — test framework (test.cyr only)

## Development Process

```
1. Make changes to src/lib/*.cyr or src/main.cyr
2. Build: sh scripts/build.sh
3. Test: sh scripts/test.sh (33 tests must pass)
4. All functions return Result or Option where failure is possible
5. Use str_builder for path construction
6. Use klog() for stderr logging
```

## DO NOT

- **Do not commit or push** — the user handles all git operations
- **NEVER use `gh` CLI** — use `curl` to GitHub API only
- Do not modify Cyrius libraries from this repo — changes go in `../cyrius/`
- Do not add C, Rust, or assembly files — everything is Cyrius
- Test after every change
