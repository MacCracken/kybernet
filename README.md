# Kybernet

**PID 1 helmsman for AGNOS** — the init process that steers the Argo.

Uses the [argonaut](https://github.com/MacCracken/argonaut) library for service management, boot sequencing, and health checks. Handles the unsafe kernel interactions that argonaut's `#![forbid(unsafe_code)]` cannot provide.

## Architecture

```
┌─────────────────────────────────────────────┐
│              kybernet (PID 1)               │
│                                             │
│  mount.rs    — /proc, /sys, /dev, /run      │
│  signals.rs  — signalfd (SIGCHLD, SIGTERM)  │
│  reaper.rs   — waitpid(-1, WNOHANG) loop   │
│  cgroup.rs   — cgroup v2 per-service        │
│  privdrop.rs — setuid/setgid in pre_exec    │
│  console.rs  — /dev/console setup           │
│  eventloop.rs — epoll event loop            │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │      argonaut (library crate)       │    │
│  │  boot stages │ service lifecycle    │    │
│  │  health      │ shutdown planning    │    │
│  │  waves       │ security configs     │    │
│  └─────────────────────────────────────┘    │
└─────────────────────────────────────────────┘
```

## Build

```sh
cargo build --release
```

The resulting binary is installed as the init process (PID 1) on AGNOS.

## License

GPL-3.0-only
