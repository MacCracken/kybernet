# Kybernet

**PID 1 helmsman for AGNOS** — the init process that steers the Argo. Written in Cyrius.

## Architecture

```
┌─────────────────────────────────────────────┐
│              kybernet (PID 1)               │
│                                             │
│  console.cyr  — /dev/console stdio redirect │
│  signals.cyr  — signalfd (SIGCHLD, SIGTERM) │
│  reaper.cyr   — waitpid zombie reaping      │
│  cgroup.cyr   — cgroup v2 per-service       │
│  privdrop.cyr — setuid/setgid with verify   │
│  mount.cyr    — /proc, /sys, /dev, /run     │
│  eventloop.cyr — epoll + timerfd dispatch   │
│                                             │
│  main.cyr — boot sequence + event loop      │
└─────────────────────────────────────────────┘
```

## Build

```sh
sh scripts/build.sh        # requires ../cyrius/build/cc2
sh scripts/test.sh         # 33 tests
```

## Modules

| Module | Lines | What |
|--------|-------|------|
| console | 36 | Redirect stdin/stdout/stderr for PID 1 |
| signals | 81 | Block 5 signals, create signalfd, classify |
| reaper | 72 | Non-blocking waitpid loop, structured results |
| privdrop | 70 | setgroups → setgid → setuid with verification |
| mount | 96 | Data-driven essential mount table |
| cgroup | 110 | Cgroup v2 paths, move PID, kill with fallback |
| eventloop | 122 | OwnedFd, epoll, timerfd, structured events |
| main | 140 | Boot sequence, signal dispatch, shutdown |

**727 lines of Cyrius** (was 1649 lines of Rust — 2.3x smaller).

## Features

- **Result/Option everywhere** — proper error handling via tagged unions
- **Data-driven mount table** — not hardcoded per-mount calls
- **String builder** for path construction and logging
- **Callback library** — vec_map, vec_filter, vec_fold, fork_with_pre_exec
- **Structured events** — EpollEvent with token + flags
- **OwnedFd** pattern with explicit close
- **33 tests** covering all modules

## Requirements

- Linux x86_64
- Cyrius compiler (`../cyrius/build/cc2`)
- No other dependencies

## Legacy

Previous Rust implementation preserved in `rust-old/` for reference.

## License

GPL-3.0-only
