# Kybernet — Claude Code Instructions

## Project Identity

**Kybernet** (Greek: kybernetes, "helmsman") — PID 1 init system for AGNOS. Written in Cyrius.

- **Type**: Cyrius binary (PID 1 init)
- **License**: GPL-3.0-only
- **Version**: 1.4.3
- **Language**: Cyrius 6.5.35 (the whole AGNOS pack front — kybernet/argonaut/libro/agnostik — pins 6.5.35; via `~/.cyrius/bin/cyrius`, `cyriusly use 6.5.35`)
- **Tools**: `owl` to read .cyr files, `cyim` to write/edit .cyr files

## Goal

The helmsman that steers the Argo. Manages system boot, essential mounts, signal handling, zombie reaping, cgroup isolation, orderly shutdown, and (1.2.0+) edge-boot pre-flight verification. Delegates service lifecycle to argonaut. All in Cyrius — no Rust, no C, no libc.

**Security enforcement is delivered as of 1.4.3, but policy is opt-in.** `src/lib/service_sandbox.cyr`'s `kyb_pre_exec` is registered with argonaut 1.9.0's `argonaut_set_pre_exec_hook` and runs in the child between fork and exec, applying no_new_privs → capabilities → Landlock → seccomp, failing closed. It reads the per-service `seccomp` / `landlock` / `capabilities` fields on argonaut's `ServiceDefinition`; **all three default to 0 and no default AGNOS service sets them yet**, so the hook is currently a no-op in practice. Say "the mechanism is wired, profiles are the v1.5.2 item" — not "kybernet sandboxes services".

## Build

```sh
cyrius deps                                  # Resolve deps from cyrius.cyml into lib/
CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet   # Build (DCE recommended)
cyrius test src/test.cyr                     # Run 203 tests
cyrius bench src/bench.cyr                   # Run benchmarks
bash scripts/bench-history.sh                # Record bench history + ≥15% regression gate (MANDATORY on every release)
cyrius build --aarch64 src/main.cyr build/kybernet-aarch64   # Cross-build aarch64
bash qemu/boot-test.sh                       # QEMU PID-1 harness + reactor gate (needs KVM)
```

## Project Structure

```
kybernet/
├── cyrius.cyml            # Project manifest + dependency resolution
├── cyrius.lock            # Locked dep tags (sha256-pinned by `cyrius deps`)
├── VERSION, CLAUDE.md, README.md, CHANGELOG.md, LICENSE
├── src/
│   ├── main.cyr           # Globals + boot sequence + event loop + harness gate
│   ├── test.cyr           # Integration tests (203 assertions)
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
│       ├── edge_boot.cyr  # Verified-and-sealed boot orchestration (1.2.0+)
│       └── service_sandbox.cyr # Per-service pre_exec sandbox (1.4.3)
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

Dependencies are resolved by `cyrius deps` from `cyrius.cyml` and locked in `cyrius.lock` (sha256-pinned). `lib/` is gitignored — the contract is the lock file, not the bytes on disk. Match AGNOS-wide convention (agnostik / libro / patra / argonaut all do this).

**Stdlib pins** (from `~/.cyrius/lib/`, ordering matters — keep `syscalls` early before `io`/`process` to avoid a cyrius transitive-dedup quirk that drops it; see 1.1.0 CHANGELOG):
- Core: string, fmt, alloc, vec, str, syscalls, io, fs, process, hashmap, tagged, **bayan**
  (`bayan` replaced `json` at 1.3.4 — cyrius 6.1.25 retired the standalone `json` module and folded it into the `bayan` serialization bundle (base64+csv+json); `bayan` ships back-compat `json_parse`/`json_get`/`json_get_int` aliases, so `main.cyr`'s cmdline parser is unchanged)
- Build helpers: fnptr, callback, freelist, mmap, chrono, ct, keccak, thread, thread_local, **atomic**, **sync**, random
  (`thread_local` is pinned for sigil's per-thread crypto scratch, but **the pin alone is not enough** — since 6.2.x a stdlib pin only lands the file in `lib/`, so `src/main.cyr`/`test.cyr`/`bench.cyr` each carry an explicit `include "lib/thread_local.cyr"` ahead of the chain or the binary SIGILLs at runtime. `atomic` must precede `sync`.)
- Aux: slice, trait, net, result, assert, bench
- **Folded** (cyrius 6.5.20+ ships these *in the stdlib snapshot*): `sakshi`, `patra`. Pin them in `[deps].stdlib` — **never** as a `[deps.<name>]` git block. `cyrius deps` overlays a git dep on top of the fold on every build, so a pin that lags the fold silently **downgrades** the file, and `deps --verify` can't catch it (the lock is written from disk). This bit kybernet at 1.4.0; see CHANGELOG [1.4.1].
- **NOT a stdlib pin**: `sigil` — stays an external git dep (`[deps.sigil]`) carrying the TPM surface. The fold *does* ship `sigil`, but it is the MONOLITH; naming it here would pull the whole x509/RSA/authenticode surface. Keep the thin block below.

**External deps** (dist bundles where available; selective for argonaut, which ships none). *agnosys was dropped at 1.3.5 — its trust/storage stack moved into sigil.*

Do **not** add a `path = "../<dep>"` alongside `git`/`tag`. When `path` resolves, cyrius makes `git`/`tag` fully inert *and* skips commit-pin verification — local builds then compile against the sibling working tree, and an unreleased tag passes every local gate before hard-failing CI. Removed at 1.4.1.

- **sigil 3.12.9** — **THIN surface, NOT the monolithic `dist/sigil.cyr`** (the monolith's x509/RSA bignum banks add static `.bss` that DCE cannot strip). `[deps.sigil] modules` = `dist/sigil-mldsa.cyr` + `src/sha_ni.cyr` + `src/sha256.cyr` + `src/hex.cyr` (the crypto set libro's merkle/audit path needs transitively — **mirrors libro's own sigil block**; mandatory because cyrius dedups the two same-named `sigil` deps to kybernet's root list, so it must cover libro's `ed25519`/`hex`/`SIG_ALG_ED25519`) **+ `dist/sigil-tpm.cyr`** (the `tpm` distlib profile — `tpm_detect`/`tpm_read_pcr`/`TPM_SHA256`, all three called from `src/lib/edge_boot.cyr`). Note libro moved sigil-tpm to an *optional* `[deps.sigil_tpm]` behind a `tpm` feature; kybernet does not enable that feature and supplies sigil-tpm through its own block. dm-verity is **not** sourced from sigil (no dm-verity profile; raw `src/dmverity.cyr` has an unguarded cross-repo include) — `_eb_dmverity_supported` in `src/lib/edge_boot.cyr` is a local probe. sigil banks per-thread crypto scratch over TLS — the reason for the `thread_local` pin + explicit include.
- **agnostik 1.4.0** — `dist/agnostik.cyr` (full bundle). NOTE its error kinds are namespaced `STIK_ERR_*` — do **not** use bare `ERR_*` names (they collide with sigil's/sakshi's enums). 1.4.0 added a `*_parse()` inverse for all 31 enums that had `*_name()`; they return `Err(STIK_ERR_INVALID_ARGUMENT)` on an unrecognised string rather than defaulting to a sentinel.
- **libro 2.8.12** — `dist/libro.cyr` (full bundle). Pulls a thin sigil surface itself. ⚠ 2.8.11/2.8.12 changed the audit-chain **on-disk preimage**: chains written by libro ≤ 2.8.10 will not verify. Only affects `config.audit_persist` deployments (default off) — kybernet makes zero direct `audit_*` calls and imports argonaut's audit modules only to close the compile-time symbol graph.
- **patra** — no longer an explicit dep. Comes from the stdlib fold (1.13.10) via `[deps].stdlib`; libro pulls it transitively too. kybernet calls no `patra_*` symbol directly.
- **argonaut 1.9.0** — selective imports (no dist bundle shipped); same 11-module import list. 1.9.0 added `argonaut_set_pre_exec_hook()` (the seam kybernet's `kyb_pre_exec` uses) plus `svc_def_seccomp`/`svc_def_landlock`/`svc_def_capabilities` accessors — additive and layout-neutral. ⚠ 1.8.6 changed `audit_log_verify_inclusion`/`audit_log_verify_consistency` to take the trusted root explicitly — kybernet calls neither, and cyrius 6.5.1 makes a wrong-arity call a hard compile error, so a stale call site cannot survive the build. kybernet imports argonaut source modules (not its vendored `lib/`):
  - `src/types.cyr` + `src/boot.cyr` + `src/services.cyr` + `src/process_mgmt.cyr`
  - `src/resolver.cyr` + `src/health.cyr` + `src/notify.cyr` + `src/tmpfiles.cyr`
  - `src/audit.cyr` + `src/audit_ext.cyr` + `src/init.cyr`
  - (NOT `pid1_harness.cyr` — that's argonaut's own qemu-graduation harness, not consumer-facing)

## Development Process

1. Make changes to `src/main.cyr` or `src/lib/*.cyr`
2. Build: `CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet`
3. Test: `cyrius test src/test.cyr` (203 tests must pass)
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
8. **Never `alloc_reset()` while a global caches an arena pointer.** The cyrius allocator hands out one 256 MB mmap chunk and `alloc_reset()` rewinds to its base, invalidating every pointer it has handed out. kybernet's cgroup path cache lives there, so a reset under a live cache leaves a dangling pointer → SIGSEGV on next use. PID 1 never resets the arena (lifetime = process), so this is a **bench/test-only** hazard — the bench's `arena_reset_clean()` is the safe wrapper (clears `_default_allocator` + `_cg_cache_reset_all()`). *The stdlib half of this was fixed at cyrius 6.5.7* — `default_alloc()` used to cache its vtable inside the arena it describes; it now lives in `_default_allocator_storage`, outside any resettable region. kybernet's own caches are still its own problem. Also: the 256 MB chunk needs a VM with headroom — `qemu/boot-test.sh` uses `-m 512M` (a 256 MB VM fails `alloc_init`'s mmap → init exit(1) → panic).
9. **The accumulate-in-loop `switch` miscompile is FIXED (cyrius 6.5.20) — but keep the if-ladders.** cyrius 6.4.62 miscompiled a `switch` whose cases accumulate (`x = x | CONST`) inside a loop closed by a `default: return`, SIGSEGVing at the call site; a `switch` of `case N: return K` bodies was unaffected. Root cause: the regalloc NOP-harvest compactor did not know the switch jump table existed and shifted each entry +4 per preceding case body, so only bodies containing a local store were hit. `_ll_access_to_kernel` (`src/lib/sandbox.cyr`) keeps its explicit `if`-ladder — correct on every toolchain, and it is the per-service Landlock path where a miscompile is a PID-1 crash. Do not convert it back.
10. **`cyrius.cyml` is a manifest, not a changelog.** Short statements of fact plus pointers; rationale and archaeology go in `CHANGELOG.md`. Three parser hazards make this load-bearing, not stylistic: (a) a `#` comment **inside** an array literal makes the parser stop collecting and silently truncate the list — no error; (b) never write a bracketed `deps.NAME` section header inside comment prose (backtick it) — `cyrius distlib` scans for that bracket sequence unanchored and drops NAME from the sidecar; (c) keep the file small — cyrius ≤ 6.5.27 read only the first 4,095 bytes of a manifest and resolved a `[deps]` section past that window to *zero* deps, silently (raised to 65,535 and fail-closed at 6.5.28). The 1.4.0 manifest tripped (a) and had every `[deps.*]` block past byte 5,400.
11. **`cyrius fmt` REWRITES IN PLACE as of 6.5.28** and prints nothing (`--dry` is the old stdout behaviour). Any CI gate of the form `diff -q <(cyrius fmt "$f") "$f"` now diffs an empty stream — it reports drift unconditionally *and* silently reformats the checkout underneath later steps. Use `cyrius fmt "$f" --check`, which sets the exit code and does not mutate.
12. **Kernel struct LAYOUT is as arch-specific as the syscall number.** `struct epoll_event` is packed on x86_64 (stride 12, `data` at +4) and natural everywhere else including aarch64 (stride 16, `data` at +8). Any hand-parsed kernel struct needs the same `#ifdef CYRIUS_ARCH_*` treatment rule 1 demands for syscall numbers, and must agree with whatever the stdlib does on the *write* side — `epoll_event_new` already dispatches per-arch. Cost of getting it wrong (1.4.2 CRITICAL-2): a kernel-written buffer overflow plus every epoll token decoded from the wrong offset, so SIGCHLD/SIGTERM are never handled on aarch64.
13. **Every level-triggered epoll registration needs a drain.** A timerfd / signalfd / eventfd stays readable until its counter is `read()`. Register the fd, *retain* the fd, and drain it in the handler **before any early return**. 1.4.2 CRITICAL-1 was two timer fds consumed inline as call arguments — nothing could drain them, so PID 1 span at 100 % CPU ~10 s after every boot and eventually panicked the kernel.
14. **A release gate that stops before the event loop does not test the event loop.** `kybernet.harness=1` shuts down at phase 9; `kybernet.harness=loop` runs the real reactor for 5 s and asserts a bounded wakeup count (ceiling 500, observed 21). Keep it green and keep it in CI — it is the only gate that executes a reactor iteration, and it is verified to FAIL on the unfixed 1.4.1 shape.


## Release gates

Every version bump runs all of these, in this order, and they must all be green before cutting:

```sh
rm -rf lib && cyrius deps && cyrius deps --verify   # expect: N verified, 0 failed
CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet
cyrius build --aarch64 src/main.cyr build/kybernet-aarch64
cyrius test src/test.cyr                            # 203 tests, 0 failed
bash scripts/bench-history.sh                       # ≥15% regression gate
bash qemu/boot-test.sh                              # needs KVM
```

Plus a **sibling-free reproduction** — the only gate that catches a tag which does not exist on the remote. Copy the tree somewhere with no `../<dep>` siblings, resolve, and confirm the lock and binary match. Without `path` fields this should be a no-op, which is exactly what makes it cheap to verify.

## DO NOT

- **Do not commit or push** — the user handles all git operations
- **NEVER use `gh` CLI** — use `curl` to GitHub API only
- Do not modify Cyrius stdlib — changes go via `~/.cyrius/`
- Dep repos (sigil, agnostik, libro, patra, argonaut, sakshi) ARE editable — they are all first-party. When a kybernet fix needs a capability the dep lacks, add it there rather than deferring (kybernet 1.4.3 added argonaut's pre-exec hook this way). Still: never commit/tag/push in any repo, and remember kybernet pins by git tag, so a dep change is not consumable by CI until the user tags it. The **cyrius language repo is off-limits**.
- Do not add C, Rust, or assembly files — everything is Cyrius
- Do not reference `../cyrius/` repo — use installed toolchain at `~/.cyrius/`
- Do not bump a dep tag to a value > the highest existing git tag (CI clones from `git + tag`; an unreleased VERSION-file value fails resolution — see 1.1.0 CHANGELOG note)
- Test after every change (203 tests + harness when KVM available)
