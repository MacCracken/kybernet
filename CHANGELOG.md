# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html) (pre-1.0).

---

## [Unreleased]

### Added

#### v0.1.0 scope — Scaffold
- Project scaffold per AGNOS first-party standards
- `console.rs` — /dev/console + /dev/null stdio setup
- `mount.rs` — essential filesystem mounting (/proc, /sys, /dev, /run, cgroup2)
- `signals.rs` — signalfd setup for SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGPWR
- `reaper.rs` — zombie reaping via waitpid(-1, WNOHANG) loop
- `cgroup.rs` — cgroup v2 per-service isolation (create, move, kill, remove)
- `privdrop.rs` — privilege drop via pre_exec setuid/setgid/setgroups
- `eventloop.rs` — epoll event loop with timerfd for health/watchdog
- `main.rs` — PID 1 entrypoint: boot flow, service startup, event loop, shutdown
