# Kybernet: Rust vs Cyrius Comparison

Kybernet was rewritten from Rust to Cyrius in v0.9.0 (2026-04-05). This document compares the two implementations as of v1.0.0.

## Binary Size

| | Rust (v0.51.0) | Cyrius (v1.0.0) | Notes |
|---|---|---|---|
| **kybernet binary** | ~6.7 MB (release) | 486 KB | **14x smaller** |
| **stripped** | ~3.4 MB | 486 KB (no symbols to strip) | **7x smaller** |
| **Cargo deps** | 105 crates | 0 crates | No package manager deps |
| **Stdlib deps** | libc, nix, serde, serde_json, anyhow, tracing | 22 Cyrius stdlib modules | All resolved at build time |
| **External deps** | argonaut (Rust), agnosys (Rust) | argonaut 1.1.0, agnosys 0.97.2, agnostik 0.97.1 (all Cyrius) | Same functionality, native |
| **libc dependency** | Yes (libc + nix crates) | No | Direct syscalls |

Note: Cyrius v0.90.0 (before argonaut integration) was 93,800 bytes — 71x smaller than Rust. The 486KB v1.0.0 binary includes argonaut + libro + sigil + sakshi transitive deps. With cc3 4.0 dead-code elimination, binary size will drop significantly.

## Lines of Code

| Module | Rust | Cyrius | Delta |
|--------|------|--------|-------|
| main | 658 | 678 | +20 (+3%) |
| cgroup | 158 | 204 | +46 (+29%) — adds agnostik cgroup_limits bridge |
| console | 72 | 38 | -34 (-47%) |
| eventloop | 266 | 124 | -142 (-53%) |
| mount | 187 | 111 | -76 (-41%) |
| privdrop | 85 | 184 | +99 (+116%) — adds capabilities, agnostik bridge |
| reaper | 130 | 63 | -67 (-52%) |
| signals | 93 | 83 | -10 (-11%) |
| notify | — | 96 | new in Cyrius |
| seccomp | — | 206 | new in Cyrius |
| sandbox | — | 299 | new in Cyrius |
| **Subtotal (lib)** | **991** | **1,408** | +417 (+42%) |
| **Total (lib+main)** | **1,649** | **2,086** | +437 (+27%) |
| test | 27 unit tests | 140 tests | +113 tests |
| bench | 3 QEMU boot tests | 46 benchmarks | +43 benchmarks |

The Cyrius version is 27% more code but has **significantly more functionality**: seccomp BPF filter builder, Landlock filesystem sandboxing, capability dropping, sd_notify socket, agnostik type bridges, JSON config loading, SIGHUP reload, emergency shell, tmpfile directives, structured JSON logging, and exponential backoff restarts.

## Functionality Comparison

| Feature | Rust v0.51.0 | Cyrius v1.0.0 |
|---------|-------------|---------------|
| Console setup | Yes | Yes |
| Essential mounts | Yes | Yes (+ mount cache) |
| Signal handling | Yes (signalfd) | Yes (signalfd) |
| Zombie reaping | Yes | Yes |
| Cgroup v2 | Yes | Yes (+ agnostik limits bridge) |
| Privilege drop | setuid/setgid | setuid/setgid + capabilities + no_new_privs |
| Epoll event loop | Yes | Yes |
| Seccomp BPF | Via argonaut feature flag | Native builder + agnostik bridge |
| Landlock sandbox | Via argonaut feature flag | Native builder + agnostik bridge |
| sd_notify socket | Yes (via argonaut NotifyListener) | Yes (native, epoll-integrated) |
| Config loading | serde_json (full parse) | json.cyr (key-value parse) |
| SIGHUP reload | Yes (re-register services) | Yes (re-initialize argonaut) |
| Emergency shell | Yes (with auth) | Yes (fork+exec, auth deferred) |
| Service restart | PendingRestart queue + timerfd | argonaut backoff_delay() direct |
| Tmpfile directives | Via argonaut generate_tmpfile_commands | Native (mkdir, symlink, touch) |
| Structured logging | tracing + tracing-subscriber | JSON lines to /var/log/kybernet.log |
| Edge boot | dm-verity + LUKS (inline) | Deferred to v1.0.1 |
| Audit logging | Via argonaut audit feature | Via libro (SHA-256 chain) |
| Health checks | Via argonaut HealthTracker | Via argonaut (same API) |
| Watchdog | Via argonaut enforce_watchdog | Via argonaut (same API) |

## Benchmark Results (Cyrius v1.0.0)

### Hot Paths (every event loop cycle)

| Operation | ns/op | Notes |
|-----------|-------|-------|
| classify_signal | 2 | Switch dispatch |
| event_token+flags | 4 | Struct accessor |
| is_handled_signal | 6 | Sigset lookup |
| W* macros (4 calls) | 8 | Wait status parsing |
| Ok+is_ok | 18 | Tagged union check |
| Err+is_err_result | 18 | Tagged union check |
| Some+is_some+unwrap | 24 | Option chain |
| knotify_classify | 25 | memeq-based parse |
| notify_status_value | 30 | Pointer arithmetic |
| is_mounted (cached) | 90 | Mount cache hit |
| epoll_wait(timeout=0) | 452 | Syscall floor |

### Service Operations (per start/stop)

| Operation | ns/op | Notes |
|-----------|-------|-------|
| cgroup_path | 523 | str_builder |
| cgroup_file | 938 | str_builder (2 segments) |
| seccomp_build(5 syscalls) | 497 | BPF bytecode gen |
| seccomp_basic_service+build | 2,585 | 37 syscalls |
| sandbox_basic_service | 224 | 5 rules |
| sandbox_from_ruleset | 8,868 | Agnostik bridge |
| set_no_new_privs | 453 | prctl syscall |
| timer_new+close | 3,081 | timerfd_create |
| epoll(new+add+close) | 6,655 | Full lifecycle |

### Memory Operations

| Operation | ns/op | Notes |
|-----------|-------|-------|
| alloc(4 sizes burst) | 15 | Bump allocator |
| memeq (2 calls) | 31 | Byte-loop compare |
| strlen(52 chars) | 98 | Byte-loop scan |
| memset(128 bytes) | 276 | Byte-loop fill |
| memcpy(128 bytes) | 317 | Byte-loop copy |

### Agnostik Type Construction

| Operation | ns/op | Notes |
|-----------|-------|-------|
| resource_limits(new+3get) | 33 | 4 alloc + loads |
| cgroup_limits(new+2set+2get) | 73 | struct ops |
| agent_config(new+get+set) | 180 | Full config setup |
| security_context(new+4get) | 192 | Security struct |
| capability_set(new+3push) | 415 | Vec operations |

### Syscall Baselines

| Syscall | ns/op |
|---------|-------|
| getuid | 297 |
| is_root (getuid wrapper) | 305 |
| getpid | 322 |

### QEMU Boot Times (Rust v0.51.0)

| Mode | Total | Init-to-event-loop |
|------|-------|-------------------|
| Minimal | 2,980 ms | 140 ms |
| Desktop (real daimon) | 3,280 ms | 120 ms |
| Edge | 3,800 ms | ~100 ms |

Cyrius QEMU boot times pending (v1.0.1 milestone).

## Architecture Differences

**Rust**: Uses Cargo ecosystem (105 crates), `nix` for safe syscall wrappers, `serde_json` for config, `tracing` for structured logging. PendingRestart queue with dedicated timerfd for restart scheduling. Emergency shell with password authentication.

**Cyrius**: Zero external package manager. Direct Linux syscalls via agnosys. JSON parsing via stdlib json.cyr. Structured logging via single-write JSON lines. Restart scheduling delegated to argonaut's `backoff_delay()`. Emergency shell via fork+exec. Security features (seccomp, landlock, capabilities) implemented natively instead of through argonaut feature flags.

## Conclusions

The Cyrius rewrite trades Rust's type safety guarantees for:
- **14x smaller binary** (486KB vs ~6.7MB)
- **Zero external crate dependencies** (105 → 0)
- **No libc** — pure syscall interface
- **Native security stack** — seccomp, landlock, capabilities built into kybernet
- **More tests** (140 vs 27) and **more benchmarks** (46 vs 3)
- **Single-digit nanosecond** hot-path operations (classify_signal: 2ns, event_token: 4ns)

The P(-1) hardening audit addresses the safety gap: buffer overflows fixed, all error paths checked, PID 1 exit paths go through shutdown.
