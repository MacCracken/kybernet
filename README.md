# Kybernet

**PID 1 helmsman for AGNOS** — the init process that steers the Argo. Written in Cyrius.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                  kybernet (PID 1)                    │
│                                                      │
│  log.cyr        — klog / klog2 / kmsg / slog         │
│  cmdline.cyr    — /proc/cmdline token scanning       │
│  console.cyr    — stdio redirect + interactive open  │
│  termios.cyr    — console echo suppression           │
│  signals.cyr    — signalfd (SIGCHLD, SIGTERM, …)     │
│  reaper.cyr     — waitpid zombie reaping             │
│  mount.cyr      — /proc, /sys, /dev, /run, cgroup2   │
│  cgroup.cyr     — cgroup v2 controllers + limits     │
│  privdrop.cyr   — capability + privilege dropping    │
│  eventloop.cyr  — epoll + timerfd dispatch           │
│  notify.cyr     — sd_notify socket (READY, etc.)     │
│  seccomp.cyr    — seccomp BPF filter builder         │
│  sandbox.cyr    — Landlock filesystem sandbox        │
│  service_sandbox — per-service pre-exec confinement  │
│  svc_config.cyr — JSON → ServiceDefinition           │
│  boot_stages.cyr— per-stage OK / SKIP / FAIL         │
│  restart_queue  — deferred restarts with backoff     │
│  edge_boot.cyr  — TPM, PCR, dm-verity verification   │
│                                                      │
│  main.cyr — boot sequence + event loop + shutdown    │
│                                                      │
│  argonaut  — service lifecycle, boot stages,         │
│              health checks, audit logging            │
│  agnostik  — shared AGNOS types                      │
│  libro     — cryptographic audit chain               │
│  sigil     — TPM / crypto trust surface (thin)       │
└──────────────────────────────────────────────────────┘
```


## Build

Requires Cyrius 6.5.35 (`cyriusly install 6.5.35 && cyriusly use 6.5.35`).

```sh
cyrius deps                                # Resolve deps from cyrius.cyml into lib/
CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet   # Build (DCE recommended)
cyrius test src/test.cyr                   # Run 608 tests
cyrius bench src/bench.cyr                 # Run benchmarks
```

## Modules

| Module | Lines | What |
|--------|-------|------|
| main | 1478 | Boot sequence, argonaut init, event loop, emergency shell, shutdown |
| edge_boot | 580 | Verified-boot pre-flight: TPM PCR, dm-verity verification |
| cgroup | 564 | Cgroup v2 controllers, paths, limits, move, kill, teardown |
| svc_config | 538 | JSON → ServiceDefinition; security, limits and edge blocks |
| emergency_auth | 520 | Argon2id credential: record format, parameter bounds, legacy migration |
| sandbox | 325 | Landlock filesystem sandboxing (builder pattern) |
| seccomp | 393 | Seccomp BPF filter builder + loader |
| eventloop | 268 | epoll, timerfds, arch-gated `struct epoll_event` ABI |
| privdrop | 247 | Capability dropping + no_new_privs + agnostik bridge |
| log | 182 | klog / klog2 / kmsg / slog |
| boot_stages | 186 | Per-stage work with OK / SKIP / FAIL status |
| mount | 163 | Data-driven essential mount table |
| service_sandbox | 153 | Per-service pre-exec: cgroup join → no_new_privs → caps → Landlock → seccomp |
| notify | 134 | sd_notify socket (READY, STOPPING, WATCHDOG, STATUS, RELOADING) |
| termios | 120 | Console echo suppression (hand-rolled ioctl/termios) |
| restart_queue | 100 | Deferred restarts, static storage |
| signals | 83 | Block 5 signals, create signalfd, classify |
| console | 113 | stdio redirect; interactive `/dev/console` open |
| reaper | 75 | Non-blocking waitpid loop, structured results |
| cmdline | 56 | `/proc/cmdline` token scanning |

**6,278 lines of Cyrius** across `main.cyr` + 19 modules.

## Features

- **Full argonaut integration** — boot stages, wave-based service startup, health checks, watchdog, crash recovery, coordinated shutdown
- **cgroup v2 isolation and limits** — per-service slice with `memory.max`,
  `memory.high`, `cpu.weight` and `pids.max` from a per-service `limits` config
  block, written to the cgroup *before* the service is forked. The child joins
  its own cgroup in the pre-exec window, so even a oneshot is contained before
  it runs. Controllers are enabled in `cgroup.subtree_control` at boot —
  without that the limit files do not exist at all. Teardown at give-up and
  shutdown.
- **Per-service sandbox** — seccomp BPF filters, Landlock filesystem sandbox,
  capability dropping and no_new_privs, applied in the child between fork and
  exec via argonaut's pre-exec hook (added 1.9.0). Order is cgroup join →
  no_new_privs → capabilities → Landlock → seccomp, and it **fails closed**: a policy that cannot be applied
  aborts the child rather than launching the service unconfined. Policy is
  **opt-in per service**, written as config data — a `security` block naming a
  capabilities keep-list, Landlock rules and a seccomp profile. A service
  without one behaves exactly as before. The QEMU harness boots a confined
  service that reports its own `/proc/self/status` and asserts `CapEff=0`.
- **Verified boot (edge mode)** — TPM detection and PCR read, plus dm-verity
  **integrity verification** against an operator-pinned root hash via
  `veritysetup verify`, which walks the hash tree in pure userspace and so needs
  no device-mapper. PCR baselines are compared and reported, deliberately not
  enforced. `kybernet.edge=permissive` / `=off` are the cmdline escape hatches.
  An absent `edge` config block means detection-only.
- **Deferred restarts** — a crash-looping service is re-launched on argonaut's
  exponential backoff from a reactor tick, not synchronously from the SIGCHLD
  handler.
- **Authenticated emergency shell** — optional, opt-in via config. Reads from a
  real `/dev/console` with terminal echo suppressed, on a bounded wait; a
  rejection halts rather than rebooting into the condition that caused it. The
  credential is **Argon2id** in a self-describing record that carries its own
  cost parameters (1.5.9):

  ```
  "emergency_require_auth": true,
  "emergency_password_hash": "v1$2$19456$1$<salt-hex>$<tag-hex>"
  ```

  Generate one with `./scripts/mkcred.sh` (needs OpenSSL 3.2+, whose Argon2id
  is byte-identical to sigil's). Parameters are validated at config-load time
  and out-of-range values are **rejected, never clamped** — clamping a
  verification parameter derives a different tag and would lock the board out
  permanently. The pre-1.5.9 unsalted 64-hex SHA-256 digest still verifies for
  one release; the two formats are provably disjoint, so a new record can never
  be downgraded onto the old path.
- **Audit logging** — a SHA-256 hash-linked chain via libro, maintained by
  argonaut. Note it is **in-memory only**: kybernet makes no direct `audit_*`
  call and never enables `audit_persist`, so the chain does not survive a
  reboot. Durable audit is an argonaut-side configuration this consumer does
  not turn on.
- **Result/Option everywhere** — proper error handling via tagged unions
- **Data-driven mount table** — not hardcoded per-mount calls
- **sd_notify compatible** — READY, STOPPING, WATCHDOG, STATUS, RELOADING messages via epoll
- **String builder** for path construction and logging
- **608 tests**, 55 benchmarks

## Dependencies

Resolved via `cyrius.cyml` (locked in `cyrius.lock`):

| Dep | Version | What |
|-----|---------|------|
| sigil | 3.12.10 | TPM / crypto trust surface + Argon2id (thin sub-bundles only; toolchain brought to 6.5.35 at this tag) |
| agnostik | 1.5.1 | Shared AGNOS types (security, agent, error) |
| libro | 2.8.12 | Cryptographic audit chain |
| argonaut | 1.13.2 | Service lifecycle, boot stages, health, audit, pre-exec + extra-env hooks |

`patra` and `sakshi` are **not** declared as git deps — cyrius 6.5.20+ ships
them in the stdlib snapshot, and a git pin would silently downgrade the
folded copy. They are listed in `[deps].stdlib` alongside 30 other stdlib
modules from `~/.cyrius/lib/`.

sigil is pulled as a **thin** set of capability sub-bundles rather than the
monolithic `dist/sigil.cyr`, whose x509/RSA bignum banks add static `.bss`
that dead-code elimination cannot strip. The same reasoning drove sigil
3.12.10: its Argon2 profile carried a 352 KB banked static that DCE also could
not strip, so linking it cost +377 KB for a function called at most once per
boot. With the working lane moved onto the caller's arena it costs +25 KB.

## Documentation

| Doc | What |
|-----|------|
| [CHANGELOG.md](CHANGELOG.md) | What each release actually did, and why |
| [docs/architecture/overview.md](docs/architecture/overview.md) | Two-layer model, boot phases, modules, event-loop tokens |
| [docs/development/roadmap.md](docs/development/roadmap.md) | Active work first; shipped releases one line each |
| [docs/audit/](docs/audit/) | P(-1) audit reports (2026-05-11, 2026-08-24) |
| [docs/benchmarks-rust-v-cyrius.md](docs/benchmarks-rust-v-cyrius.md) | Historical v1.0.0 port comparison — not maintained |
| [CLAUDE.md](CLAUDE.md) | Build/release gates and the standing audit rules |

## Testing

```sh
cyrius test src/test.cyr            # 608 assertions
bash scripts/bench-history.sh       # 55 benchmarks, load-tolerant regression gate
bash qemu/boot-test.sh              # PID-1 boot harness (needs KVM)
```

The QEMU harness is the gate that matters: it boots kybernet as real PID 1 and
asserts 44 properties across four passes — the boot sequence, the reactor
(that it sleeps rather than spins), dm-verity verification against a real
image pair on virtio disks, and the emergency-auth prompt with a password fed
over the serial line. Pass 4 runs against **both** credential formats: the
deprecated unsalted SHA-256 digest, and an Argon2id `v1` record generated by
`scripts/mkcred.sh` itself — so the tool operators are given and the code that
verifies its output are checked against each other under a real PID 1.

## Requirements

- Linux, x86_64 or aarch64 (both are release-gated; `cyrius build --aarch64`)
- Cyrius 6.5.35 (`~/.cyrius/bin/cyrius`)
- No C, no Rust, no libc
- OpenSSL 3.2+ — **provisioning only**, for `scripts/mkcred.sh`. Nothing kybernet
  runs at boot depends on it; the verifier is sigil's own Argon2id.

## Legacy

The Rust implementation this was ported from was removed at 1.5.4, once the
last behavioural gap it still held over the Cyrius port was closed. It
remains in git history.

## License

GPL-3.0-only
