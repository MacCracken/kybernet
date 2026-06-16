# Kybernet — Claude Code Instructions

## Project Identity

**Kybernet** (Greek: kybernetes, "helmsman") — PID 1 init system for AGNOS. Written in Cyrius.

- **Type**: Cyrius binary (PID 1 init)
- **License**: GPL-3.0-only
- **Version**: 1.3.4
- **Language**: Cyrius 6.2.11 (the whole AGNOS pack front — kybernet/argonaut/libro/agnosys/agnostik — pins 6.2.11; patra at 6.2.1; via `~/.cyrius/bin/cyrius`, `cyriusly use 6.2.11`)
- **Tools**: `owl` to read .cyr files, `cyim` to write/edit .cyr files

## Goal

The helmsman that steers the Argo. Manages system boot, essential mounts, signal handling, zombie reaping, cgroup isolation, security enforcement, orderly shutdown, and (1.2.0+) edge-boot pre-flight verification. Delegates service lifecycle to argonaut. All in Cyrius — no Rust, no C, no libc.

## Build

```sh
cyrius deps                                  # Resolve deps from cyrius.cyml into lib/
CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet   # Build (DCE recommended)
cyrius test src/test.cyr                     # Run 177 tests
cyrius bench src/bench.cyr                   # Run benchmarks
bash scripts/bench-history.sh                # Record bench history + ≥15% regression gate (MANDATORY on every release)
cyrius build --aarch64 src/main.cyr build/kybernet-aarch64   # Cross-build aarch64
bash qemu/boot-test.sh                       # QEMU PID-1 harness (1.1.4+; needs KVM)
```

## Project Structure

```
kybernet/
├── cyrius.cyml            # Project manifest + dependency resolution
├── cyrius.lock            # Locked dep tags (sha256-pinned by `cyrius deps`)
├── VERSION, CLAUDE.md, README.md, CHANGELOG.md, LICENSE
├── src/
│   ├── main.cyr           # Globals + boot sequence + event loop + harness gate
│   ├── test.cyr           # Integration tests (177 assertions)
│   ├── bench.cyr          # Microbenchmarks
│   └── lib/
│       ├── log.cyr        # klog / klog2 / kmsg / slog (factored out at 1.2.0)
│       ├── console.cyr    # Stdio redirect (fds 0/1/2)
│       ├── signals.cyr    # Signal blocking + signalfd
│       ├── reaper.cyr     # Zombie reaping
│       ├── privdrop.cyr   # Privilege + capability dropping
│       ├── mount.cyr      # Essential filesystem mounts (required + optional)
│       ├── cgroup.cyr     # Cgroup v2 management + path cache (1.1.3)
│       ├── eventloop.cyr  # Epoll + timerfd
│       ├── notify.cyr     # sd_notify socket (arch-dispatched syscalls — 1.1.5)
│       ├── seccomp.cyr    # Seccomp BPF filter builder
│       ├── sandbox.cyr    # Landlock filesystem sandbox
│       └── edge_boot.cyr  # Verified-and-sealed boot orchestration (1.2.0+)
├── qemu/                  # PID-1 boot harness (1.1.4+); build-initramfs.sh + boot-test.sh
├── scripts/               # bench-history.sh + version-bump.sh
├── docs/
│   ├── architecture/overview.md
│   ├── audit/             # P(-1) audit reports (1.1.5+)
│   └── development/roadmap.md
├── rust-old/              # Previous Rust implementation (reference)
├── lib/                   # gitignored; populated by `cyrius deps`
└── build/                 # Generated binaries (gitignored)
```

## Dependencies (resolved via cyrius.cyml)

Dependencies are resolved by `cyrius deps` from `cyrius.cyml` and locked in `cyrius.lock` (sha256-pinned). `lib/` is gitignored — the contract is the lock file, not the bytes on disk. Match AGNOS-wide convention (agnosys / agnostik / libro / argonaut all do this).

**Stdlib pins** (from `~/.cyrius/lib/`, ordering matters — keep `syscalls` early before `io`/`process` to avoid a cyrius transitive-dedup quirk that drops it; see 1.1.0 CHANGELOG):
- Core: string, fmt, alloc, vec, str, syscalls, io, fs, process, hashmap, tagged, **bayan**
  (`bayan` replaced `json` at 1.3.4 — cyrius 6.1.25 retired the standalone `json` module and folded it into the `bayan` serialization bundle (base64+csv+json); `bayan` ships back-compat `json_parse`/`json_get`/`json_get_int` aliases, so `main.cyr`'s cmdline parser is unchanged)
- Build helpers: fnptr, callback, freelist, mmap, chrono, ct, keccak, thread, thread_local, random
  (`bigint` dropped at 1.3.4 — gone as a standalone module under 6.2.11; sigil 3.7.x self-contains it and kybernet never used `bigint_*` directly. `thread_local` added at 1.3.2 for sigil's per-thread crypto scratch; **at 1.3.4 the manifest pin alone is no longer enough** — 6.2.x stopped auto-including stdlib-pinned modules into sigil's dep chain, so `src/main.cyr`/`test.cyr`/`bench.cyr` each carry an explicit `include "lib/thread_local.cyr"` ahead of the chain or the binary SIGILLs at runtime)
- Aux: slice, trait, net, result, assert, bench
- **NOT pinned** (transitive via libro/patra): sakshi, sigil

**External deps** (dist bundles where available; selective for argonaut which ships none):
- **agnosys 1.4.3** — three profile bundles pulled at 1.2.0+:
  - `agnosys-core` (syscall + error + logging + util) — unconditional
  - `agnosys-storage` (luks + dmverity + fuse) — for edge_boot
  - `agnosys-trust` (tpm + ima + secureboot + certpin) — for edge_boot; carries forward the F-13 IMA-truncation fix (log grows to EOF, 32 MB ceiling). 1.4.x rides the 6.2.11 toolchain; bundle module names unchanged, edge-boot API byte-compatible for kybernet
- **agnostik 1.3.1** — `dist/agnostik.cyr` (full bundle); type vocabulary byte-compatible, security-config use unaffected
- **libro 2.7.4** — `dist/libro.cyr` (full bundle); on cyrius 6.2.11. **Brings sigil 3.7.14** (was 3.6.0) + patra 1.11.2; libro's own tpm_seal/unseal surface unchanged. sigil 3.7.x still banks per-thread crypto scratch over TLS — the reason for the `thread_local` pin + the explicit include noted above
- **patra 1.11.2** — `dist/patra.cyr` (explicit pin; libro pulls transitively); latest tag
- **argonaut 1.8.3** — selective imports (no dist bundle shipped); on cyrius 6.2.11, same 11-module import list as 1.8.2 (`compat.cyr` stays retired since 1.8.1). kybernet imports argonaut source modules (not its vendored `lib/`):
  - `src/types.cyr` + `src/boot.cyr` + `src/services.cyr` + `src/process_mgmt.cyr`
  - `src/resolver.cyr` + `src/health.cyr` + `src/notify.cyr` + `src/tmpfiles.cyr`
  - `src/audit.cyr` + `src/audit_ext.cyr` + `src/init.cyr`
  - (NOT `pid1_harness.cyr` — that's argonaut's own qemu-graduation harness, not consumer-facing)

## Development Process

1. Make changes to `src/main.cyr` or `src/lib/*.cyr`
2. Build: `CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet`
3. Test: `cyrius test src/test.cyr` (177 tests must pass)
4. Cross-build: `cyrius build --aarch64 src/main.cyr build/kybernet-aarch64` (verify both arches)
5. Harness (when KVM available): `bash qemu/boot-test.sh` (asserts marker set + budget)
5b. **On a version bump: `bash scripts/bench-history.sh`** — records per-benchmark ns/op to `benches/history.csv` and exits non-zero on a ≥15% regression vs the previous run. Review and explain (or fix) any flagged delta before cutting.
6. All functions return `Result` or `Option` where failure is possible
7. Use `str_builder` for path construction
8. Use `klog` / `klog2` / `kmsg` from `src/lib/log.cyr` (1.2.0+; previously in main.cyr)
9. Use agnostik types for security config (security_context, capability_set, etc.)
10. Use argonaut for service lifecycle (init_start_service, init_reap_services, etc.)

## Audit checklist (from 1.1.5 P(-1) audit — standing rules)

Apply on every change touching src/:

1. **No literal `syscall(N, ...)` with integer `N`.** Use a stdlib wrapper (`sys_*`) or `#ifdef CYRIUS_ARCH_*`-gated enum. x86_64 numbers route to wildly different syscalls on aarch64; the cross-build won't catch it.
2. **`var X[N]` is N BYTES, not slots.** Sites holding N i64 ptrs need `[N * 8]`. Write the math inline at the declaration.
3. **`Str` vs `cstr`.** Argonaut surface is mostly `Str` (boxed); kybernet logging + cgroup path helpers are cstr-only. Any `vec_get`-derived service/health/watchdog name needs `str_data()` before being passed to `klog2 / slog / cgroup_*`.
4. **PID-1 exit paths must call `do_shutdown()` or log-and-continue.** Never `return 0` from `kybernet_run` directly — the kernel panics on init exit ("Attempted to kill init!").
5. **Mount-table size and stride must stay in sync.** Update the backing array AND the per-entry stride comment together. `test_mount_required_flag` is the canary.
6. **Benchmarks are a release gate.** Every version bump runs `bash scripts/bench-history.sh` (per-benchmark ns/op delta + ≥15% regression check; history in `benches/history.csv`). A flagged regression blocks the cut until explained or fixed. Mirrors agnosys 1.3.0's hard constraint.
7. **Stdlib-pinned modules used only transitively (e.g. `thread_local` for sigil) need an explicit `include "lib/<m>.cyr"` in `main.cyr`/`test.cyr`/`bench.cyr`** ahead of the consumer. Cyrius 6.2.x stopped auto-including a `[deps] stdlib` pin into a dep's chain — the pin only lands the file in `lib/`. Missing include → links fine, **SIGILLs at runtime** (1.3.4). Build warns `undefined function '<sym>'` — treat that warning as a hard error, not noise.
8. **Never `alloc_reset()` while a global caches an arena pointer.** Cyrius 6.1.19+ allocator hands out one 256 MB mmap chunk and `alloc_reset()` rewinds to its base; 6.0.64+ `str_builder` caches a default-allocator vtable AT that base. A reset under a live cache (`_default_allocator`, kybernet's cgroup path cache) leaves a dangling pointer → SIGSEGV on next use. PID 1 never resets the arena (lifetime = process), so this is a **bench/test-only** hazard — the bench's `arena_reset_clean()` is the safe wrapper (clears `_default_allocator` + `_cg_cache_reset_all()`). Also: the 256 MB chunk needs a VM with headroom — `qemu/boot-test.sh` uses `-m 512M` (a 256 MB VM fails `alloc_init`'s mmap → init exit(1) → panic).

## DO NOT

- **Do not commit or push** — the user handles all git operations
- **NEVER use `gh` CLI** — use `curl` to GitHub API only
- Do not modify Cyrius stdlib — changes go via `~/.cyrius/`
- Do not modify dep repos (agnosys, agnostik, libro, patra, argonaut) from this repo
- Do not add C, Rust, or assembly files — everything is Cyrius
- Do not reference `../cyrius/` repo — use installed toolchain at `~/.cyrius/`
- Do not bump a dep tag to a value > the highest existing git tag (CI clones from `git + tag`; an unreleased VERSION-file value fails resolution — see 1.1.0 CHANGELOG note)
- Test after every change (177 tests + harness when KVM available)
