# Kybernet — Claude Code Instructions

## Project Identity

**Kybernet** (Greek: kybernetes, "helmsman") — PID 1 init system for AGNOS. Written in Cyrius.

- **Type**: Cyrius binary (PID 1 init)
- **License**: GPL-3.0-only
- **Version**: 1.5.5
- **Language**: Cyrius 6.5.35 (the whole AGNOS pack front — kybernet/argonaut/libro/agnostik — pins 6.5.35; via `~/.cyrius/bin/cyrius`, `cyriusly use 6.5.35`)
- **Tools**: `owl` to read .cyr files, `cyim` to write/edit .cyr files

## Goal

The helmsman that steers the Argo. Manages system boot, essential mounts, signal handling, zombie reaping, cgroup isolation, orderly shutdown, and (1.2.0+) edge-boot pre-flight verification. Delegates service lifecycle to argonaut. All in Cyrius — no Rust, no C, no libc.

**Security enforcement is delivered, and profiles are config data as of 1.5.2.** `src/lib/service_sandbox.cyr`'s `kyb_pre_exec` is registered with argonaut 1.9.0's `argonaut_set_pre_exec_hook` and runs in the child between fork and exec, applying no_new_privs → capabilities → Landlock → seccomp, failing closed. It reads the per-service `seccomp` / `landlock` / `capabilities` fields on argonaut's `ServiceDefinition`; they are populated from the per-service `security` block in `/etc/kybernet/config.json` (see `src/lib/svc_config.cyr`). A service with no `security` block gets a strict no-op, so policy stays opt-in. ⚠ **Capability names map to KERNEL capability numbers** — `1 << cap` goes to `capset(2)`. agnostik and argonaut both define `enum LinuxCapability` with identical member names; both were wrong and both were corrected (agnostik 1.5.0, argonaut 1.11.0) to the kernel table, so the duplicate definition is now value-identical. If you ever see a `duplicate symbol 'CAP_*' redefined with conflicting value` warning again, they have diverged and the privilege drop is operating on the wrong capabilities.

## Build

```sh
cyrius deps                                  # Resolve deps from cyrius.cyml into lib/
CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet   # Build (DCE recommended)
cyrius test src/test.cyr                     # Run 440 tests
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
│   ├── test.cyr           # Integration tests (440 assertions)
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
│       ├── service_sandbox.cyr # Per-service pre_exec sandbox (1.4.3)
│       ├── svc_config.cyr  # JSON -> ServiceDefinition parsing (1.5.0)
│       └── boot_stages.cyr  # Per-stage work + OK/SKIP/FAIL status (1.5.1)
├── qemu/                  # PID-1 boot harness (1.1.4+); build-initramfs.sh + boot-test.sh
├── scripts/               # bench-history.sh + version-bump.sh
├── docs/
│   ├── architecture/overview.md
│   ├── audit/             # P(-1) audit reports (1.1.5+)
│   └── development/roadmap.md
├── lib/                   # gitignored; populated by `cyrius deps`
└── build/                 # Generated binaries (gitignored)
```

## Dependencies (resolved via cyrius.cyml)

Dependencies are resolved by `cyrius deps` from `cyrius.cyml` and locked in `cyrius.lock` (sha256-pinned). `lib/` is gitignored — the contract is the lock file, not the bytes on disk. Match AGNOS-wide convention (agnostik / libro / patra / argonaut all do this).

⚠ **`init_*` service APIs take a cstr; `resolve_service_waves` returns boxed `Str`.** argonaut keys its service map by `str_data(svc_def_name(sd))`, so anything walking waves into `init_start_service`/`init_restart_service` must `str_data()` first — passing the box makes `map_get` miss silently and every start return -1. kybernet carried that latent bug until 1.5.0. Also: `init_start_service` is **tri-state** — `>0` live pid, `==0` a oneshot that completed successfully, `<0` failure.

**Boot stages must return an honest status.** `src/lib/boot_stages.cyr` returns `STAGE_OK` / `STAGE_SKIP` / `STAGE_FAIL`; a stage kybernet does not perform is recorded `STEP_SKIPPED` (argonaut 1.10.1's `init_mark_step_skipped`), never a false COMPLETE. Do not add a stage arm that returns OK without checking something — that is exactly what 1.5.1 removed.

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

⚠ **A `path` override also DROPS that dep's `commit` line from `cyrius.lock`.** The lock is written from disk, so a resolve under `path` records the file hashes but no commit pin, and `cyrius deps --verify` still reports "N verified, 0 failed" — it cannot miss what is not there. **kybernet 1.5.4 shipped with no argonaut commit pin for exactly this reason.** If a dep change is needed for a release, the order is: finish the dep → **user tags it** → `rm -rf lib && cyrius deps && cyrius deps --verify` in kybernet → confirm `grep '^commit' cyrius.lock` lists every git dep → *then* tag kybernet. Using `path` temporarily to run local gates is fine; shipping the lock it produces is not.

- **sigil 3.12.9** — **THIN surface, NOT the monolithic `dist/sigil.cyr`** (the monolith's x509/RSA bignum banks add static `.bss` that DCE cannot strip). `[deps.sigil] modules` = `dist/sigil-mldsa.cyr` + `src/sha_ni.cyr` + `src/sha256.cyr` + `src/hex.cyr` (the crypto set libro's merkle/audit path needs transitively — **mirrors libro's own sigil block**; mandatory because cyrius dedups the two same-named `sigil` deps to kybernet's root list, so it must cover libro's `ed25519`/`hex`/`SIG_ALG_ED25519`) **+ `dist/sigil-tpm.cyr`** (the `tpm` distlib profile — `tpm_detect`/`tpm_read_pcr`/`TPM_SHA256`, all three called from `src/lib/edge_boot.cyr`). Note libro moved sigil-tpm to an *optional* `[deps.sigil_tpm]` behind a `tpm` feature; kybernet does not enable that feature and supplies sigil-tpm through its own block. dm-verity is **not** sourced from sigil (no dm-verity profile; raw `src/dmverity.cyr` has an unguarded cross-repo include) — `_eb_dmverity_supported` in `src/lib/edge_boot.cyr` is a local probe. sigil banks per-thread crypto scratch over TLS — the reason for the `thread_local` pin + explicit include.
- **agnostik 1.5.1** — `dist/agnostik.cyr` (full bundle). NOTE its error kinds are namespaced `STIK_ERR_*` — do **not** use bare `ERR_*` names (they collide with sigil's/sakshi's enums). 1.4.0 added a `*_parse()` inverse for all 31 enums that had `*_name()`; they return `Err(STIK_ERR_INVALID_ARGUMENT)` on an unrecognised string rather than defaulting to a sentinel. ⚠ **1.5.0 corrected `enum LinuxCapability`** — it omitted `CAP_MAC_OVERRIDE`/`CAP_MAC_ADMIN`, shifting everything above 31 by two — and added `capability_name`/`capability_parse`. 1.5.1 added `cglim_set_memory_high`/`cglim_set_cpu_max`/`cglim_set_cpu_weight`, the three `cgroup_limits` fields that had accessors but no setter.
- **libro 2.8.12** — `dist/libro.cyr` (full bundle). Pulls a thin sigil surface itself. ⚠ 2.8.11/2.8.12 changed the audit-chain **on-disk preimage**: chains written by libro ≤ 2.8.10 will not verify. Only affects `config.audit_persist` deployments (default off) — kybernet makes zero direct `audit_*` calls and imports argonaut's audit modules only to close the compile-time symbol graph.
- **patra** — no longer an explicit dep. Comes from the stdlib fold (1.13.10) via `[deps].stdlib`; libro pulls it transitively too. kybernet calls no `patra_*` symbol directly.
- **argonaut 1.13.0** — selective imports (no dist bundle shipped); **12-module** import list (`src/security.cyr` added at kybernet 1.5.4 for `verify_emergency_auth`/`password_hash`). 1.13.0 added the `cgroup_limits` field on `ServiceDefinition` (+168) with `svc_def_cgroup_limits`/`svc_def_set_cgroup_limits`. 1.12.0 added `argonaut_set_extra_env()` — argonaut builds the child envp inside `fork_exec_service`, so without that seam kybernet could not publish `$NOTIFY_SOCKET` and no service could discover the notify socket at all. 1.9.0 added `argonaut_set_pre_exec_hook()` (the seam kybernet's `kyb_pre_exec` uses) plus `svc_def_seccomp`/`svc_def_landlock`/`svc_def_capabilities` accessors. 1.10.0 added the enum `*_parse` inverses kybernet's config parser uses, `init_service_defs`/`init_service_names`, the `svc_def_set_*` field setters, and `svc_hc_*` HealthCheck accessors — note the `svc_hc_` prefix: bare `hc_retries`/`hc_timeout`/`hc_interval` are agnostik's, for a DIFFERENT struct layout, and kybernet links both. 1.10.1 added `init_mark_step_skipped` (the third boot-step state), `init_service_ready`, `init_boot_sequence` and `config_set_boot_mode`. ⚠ **1.11.0 corrected `enum LinuxCapability` to kernel numbers** (it was a 13-entry arbitrary order where `CAP_SYS_ADMIN` was 1) and added `capability_parse`. All additive and layout-neutral. ⚠ 1.8.6 changed `audit_log_verify_inclusion`/`audit_log_verify_consistency` to take the trusted root explicitly — kybernet calls neither, and cyrius 6.5.1 makes a wrong-arity call a hard compile error, so a stale call site cannot survive the build. kybernet imports argonaut source modules (not its vendored `lib/`):
  - `src/types.cyr` + `src/boot.cyr` + `src/services.cyr` + `src/process_mgmt.cyr`
  - `src/resolver.cyr` + `src/health.cyr` + `src/notify.cyr` + `src/tmpfiles.cyr`
  - `src/audit.cyr` + `src/audit_ext.cyr` + `src/init.cyr` + `src/security.cyr`
  - (NOT `pid1_harness.cyr` — that's argonaut's own qemu-graduation harness, not consumer-facing)

## Development Process

1. Make changes to `src/main.cyr` or `src/lib/*.cyr`
2. Build: `CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet`
3. Test: `cyrius test src/test.cyr` (440 tests must pass)
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
14. **⚠ `struct ResourceLimits` IS DEFINED TWICE, with incompatible layouts, and cyrius does NOT warn.** argonaut's is `{nofile, address_space, nproc, core}` (32 B); agnostik's is `{max_memory, max_cpu_time, max_fds, max_procs, max_disk, net_bw}` (48 B), and agnostik ships the only `rlim_*` accessors. kybernet links both. Duplicate *fns* and *symbols* warn; duplicate *structs* are silent. A probe on 6.5.35 gives `sizeof(ResourceLimits) == 48` — agnostik's wins. So `svc_def_rlimits(sd)` hands back a pointer argonaut filled to ITS layout, and reading it with `rlim_max_memory` returns `nofile`: a service configured for 1024 open files would get `memory.max = 1024 BYTES` and be OOM-killed on its first page. **Never pass `svc_def_rlimits` to anything `rlim_*`.** Per-service cgroup limits use argonaut's separate `cgroup_limits` field (+168) with agnostik's `cglim_*`, which has no twin. 1.5.5.

15. **cgroup v2 limit files do not exist unless the PARENT enables the controller.** `memory.max` / `pids.max` / `cpu.weight` appear in a cgroup only when its parent lists that controller in `cgroup.subtree_control`. kybernet never wrote it before 1.5.5, so every service cgroup held only the core `cgroup.*` files and any limit write would have returned ENOENT — which is why `cgroup_apply_limits` could sit unwired for four releases without anything failing. `cgroup_enable_controllers()` (phase 3a) enables **both** levels: root, so `kybernet.slice` gets the files, and the slice, so each service does. Enable **one controller per write** — the kernel parses the buffer atomically and rejects the whole write on an unrecognised name, so `+memory +pids` on a kernel without `pids` loses `memory` too. Note `cgroup.kill` is a *core* file present regardless, which is why the 1.5.3 teardown gate passed while no controller was ever enabled.

16. **The service is placed in its cgroup by the CHILD, in `kyb_pre_exec`, and placement is step 0.** argonaut owns fork+exec, so a parent-side move is unavoidably late: for a `simple` service with a ready_check it lands after the whole readiness poll, and for a `oneshot` it never lands at all (argonaut waits and returns 0, so there is no surviving pid). Worse than late — cgroup v2 charges memory on **first touch and does not migrate charges on move**, so pages faulted in before the move stay charged to the root cgroup. The child writes the literal `"0"` to `cgroup.procs` (the kernel's "move the writer" form; no getpid, no formatting). It must run **before** no_new_privs/capabilities/Landlock/seccomp — each of those can remove the ability to write cgroupfs. The parent creates the cgroup and writes its limits *before* `init_start_service`.

17. **A release gate that stops before the event loop does not test the event loop.** `kybernet.harness=1` shuts down at phase 9; `kybernet.harness=loop` runs the real reactor for 5 s and asserts a bounded wakeup count (ceiling 500, observed 21). Keep it green and keep it in CI — it is the only gate that executes a reactor iteration, and it is verified to FAIL on the unfixed 1.4.1 shape.


## Release gates

Every version bump runs all of these, in this order, and they must all be green before cutting:

```sh
rm -rf lib && cyrius deps && cyrius deps --verify   # expect: N verified, 0 failed
CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet
cyrius build --aarch64 src/main.cyr build/kybernet-aarch64
cyrius test src/test.cyr                            # 440 tests, 0 failed
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
- Test after every change (440 tests + harness when KVM available)
