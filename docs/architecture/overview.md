# Kybernet Architecture

## Two-Layer Model

Following the pattern used by s6, dinit, and systemd, AGNOS splits init into two layers:

```
PID 1: kybernet (small, direct syscalls, no libc)
  mount /proc, /sys, /dev, /run, cgroup2
  set up signalfd for SIGCHLD + SIGTERM + SIGINT + SIGHUP + SIGPWR
  create epoll event loop + notify socket
  load /etc/kybernet/config.json, hand argonaut the built config
  execute boot stages + start services (wave-based)
  reap zombies, manage cgroups
  enforce health checks, watchdog timeouts
  coordinated shutdown via argonaut

Service management library: argonaut (886 assertions across 30 suites)
  boot sequencing, service lifecycle
  health checks, watchdog enforcement, crash recovery
  audit logging via libro (SHA-256 hash-linked chain)
```

⚠ **This is a source-level split, not a process or isolation boundary.**
argonaut is 13 modules compiled directly into kybernet's single static binary —
there is no separate process, no shared object, no runtime loading. A bug in
argonaut's service management *can* panic PID 1, and several have come close:
the 1.5.6 aarch64 syscall repairs and the 1.5.7 fail-open exec fix were both
argonaut-side defects reachable from kybernet's boot path.

What the split actually buys is that the service-management logic is
independently tested (886 assertions in argonaut's own suite, against
kybernet's 491) and independently versioned, so a change there is reviewed and
gated on its own before kybernet pins the tag. That is real value — it is just
not fault isolation.

## Boot Flow

Sub-lettered phases were added after the original numbering and kept their
position rather than renumbering, so the sequence below is the real one.

```
Phase 0 : kmsg("phase 0: starting") — the first observable marker
Phase 1 : Mount devtmpfs (needed for /dev/console, /dev/kmsg)
Phase 2 : Console setup — stdin→/dev/null, stdout/stderr→/dev/console
Phase 3 : Mount essential filesystems. /proc, /sys, /run and cgroup2 are
          REQUIRED — a failure there is fatal. /dev/pts and /dev/shm are
          OPTIONAL: a failure is logged and boot continues.
Phase 3a: Enable cgroup v2 controllers in subtree_control        (1.5.5)
Phase 3b: Initialize structured logging (needs /var/log)
Phase 4 : Block signals, create signalfd
Phase 5 : Create epoll event loop + timerfds
Phase 5b: Bind the sd_notify socket, publish $NOTIFY_SOCKET      (1.5.4)
Phase 6 : Load /etc/kybernet/config.json, initialize argonaut
Phase 6b: Execute tmpfile directives
Phase 6c: Edge-boot pre-flight — capability detect, PCR read,
          dm-verity integrity verification                       (1.2.0/1.5.7)
Phase 7 : Run boot stages (OK / SKIP / FAIL per stage)           (1.5.1)
Phase 8 : Start services (wave-based, cgroup + limits before fork)
Phase 9 : Enter the epoll event loop
Shutdown: SIGTERM/SIGINT → stop services → kill+remove cgroups → sync
          → reboot / poweroff / halt
```

## Modules

All under `src/lib/`, included by `src/main.cyr`.

| Module | Purpose |
|--------|---------|
| `main.cyr` (src/) | PID 1 entrypoint, boot orchestration, event loop, shutdown |
| `log.cyr` | `klog` / `klog2` / `kmsg` / `slog` (factored out at 1.2.0) |
| `cmdline.cyr` | `/proc/cmdline` token scanning (factored out at 1.5.7) |
| `console.cyr` | stdio redirect; `console_open_rw()` for interactive reads |
| `termios.cyr` | Console echo suppression — hand-rolled ioctl/termios (1.5.8) |
| `signals.cyr` | signalfd for SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGPWR |
| `reaper.cyr` | Zombie reaping via `sys_waitpid(-1, WNOHANG)` |
| `mount.cyr` | Essential filesystems, data-driven mount table |
| `cgroup.cyr` | Cgroup v2: controllers, create, limits, move, kill, cleanup |
| `privdrop.cyr` | Privilege drop: capabilities, no_new_privs, agnostik bridge |
| `eventloop.cyr` | epoll multiplexer; arch-gated `struct epoll_event` ABI |
| `notify.cyr` | sd_notify socket (READY, STOPPING, WATCHDOG, STATUS, RELOADING) |
| `seccomp.cyr` | Seccomp BPF filter builder + loader |
| `sandbox.cyr` | Landlock filesystem sandbox |
| `service_sandbox.cyr` | Per-service pre-exec hook: cgroup join → **no_new_privs** → caps → Landlock → seccomp |
| `svc_config.cyr` | JSON → `ServiceDefinition`, security / limits / edge blocks |
| `boot_stages.cyr` | Per-stage work with OK / SKIP / FAIL status |
| `restart_queue.cyr` | Deferred service restarts, static storage |
| `edge_boot.cyr` | Verified-boot pre-flight: TPM, PCR, dm-verity verification |
| `emergency_auth.cyr` | Emergency-shell credential: `v1$t$m$p$salt$tag` Argon2id record, parameter bounds, legacy-digest migration (1.5.9) |

## Dependencies

Resolved by `cyrius deps` from `cyrius.cyml` and sha256-pinned in `cyrius.lock`;
`lib/` is gitignored, so the contract is the lock file rather than the bytes on disk.

- **argonaut 1.13.2** — service lifecycle, boot sequencing, health checks, crash
  recovery, audit. Imported as **13 selective modules**, not a dist bundle.
- **agnostik 1.5.1** — shared AGNOS types (`security_context`, `capability_set`,
  `cgroup_limits`, `agent_config`)
- **libro 2.8.12** — cryptographic audit logging (SHA-256 hash-linked chain)
- **sigil 3.12.10** — a deliberately **thin** surface: ML-DSA, SHA-256, hex, the TPM
  profile, and (1.5.9) Argon2id. Never the monolith, whose x509/RSA banks add `.bss`
  that DCE cannot strip. The Argon2 profile had the same problem until 3.12.10 moved
  its 352 KB working lane onto the caller's arena — see CHANGELOG [1.5.9].
- **patra**, **sakshi** — from the cyrius stdlib fold, not explicit deps

`agnosys` was **dropped at 1.3.5**; its trust and storage stack moved into sigil.
Syscalls come from the cyrius stdlib directly.

## Event Loop Tokens

| Token | Source | Handler |
|-------|--------|---------|
| 1 | signalfd | Signal dispatch (SIGCHLD→reap, SIGTERM→shutdown, etc.) |
| 2 | timerfd (health) | Health check polling via argonaut |
| 3 | timerfd (watchdog) | Watchdog enforcement via argonaut |
| 4 | timerfd (restart) | Deferred restarts whose backoff has elapsed (1.5.4) |
| 5 | notify socket | sd_notify message parsing (READY, STOPPING, etc.) |

Every level-triggered fd is retained and drained in its handler before any early
return — an undrained timerfd stays readable and spins PID 1 at 100% CPU
(1.4.2 CRITICAL-1).
