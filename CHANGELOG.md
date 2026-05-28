# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.2.2] — 2026-05-28

**Cyrius toolchain bump to 6.0.14 — both arches clean, aarch64
cross-build restored.** First kybernet cut to leapfrog the sibling AGNOS
pack on the toolchain pin: argonaut + patra still at 5.10.44, agnosys +
libro at 5.11.4, kybernet now at 6.0.14. The "matches argonaut's pin"
rationale carried since 1.1.0 no longer holds — kybernet leads on this
one. The aarch64 `cycc_aarch64` codegen hang that blocked the original
6.0.1 attempt (see below) is resolved upstream; 1.2.2 ships dual-arch.

### Changed

- **`[cyrius]` toolchain pin**: 5.10.44 → **6.0.14**. The cc5→cycc rename
  ceremony in the 6.0.x arc landed alongside new peer binaries (`cybs`,
  `cyaudit`, `ts_test_runner`); cc5 / cc5_aarch64 are retained as
  symlinks to `cycc` / `cycc_aarch64`. No kybernet source changes — the
  bump is toolchain-only.

### Stats

- x86_64 DCE binary: 1.148 MB → **1.146 MB** (−2 KB; codegen wash)
- aarch64 DCE binary: **1.258 MB** (restored; cross-build was broken
  under 6.0.1)
- 177 / 177 tests pass (unchanged from 1.2.1)
- fmt / vet clean
- Compile-time warning catalogue identical to 1.2.1 (all pre-existing
  dep-bundle duplicates documented since 1.1.0)
- New compile-time note from cyrius 6.0.x: `cwd ./lib/ shadows
  version-pinned /home/macro/.cyrius/versions/6.0.14/lib/` — informational
  only; the 6.0.x wrapper ships a bundled stdlib snapshot and notes when
  a project's `lib/` (populated by `cyrius deps`) takes precedence. Set
  `CYRIUS_NO_WARN_SHADOW_LIB=1` to silence. Kybernet's per-dep tag pins
  in `cyrius.cyml` are the source of truth; the note is expected.

### Fixed

- **aarch64 cross-build no longer hangs.** Under `cycc_aarch64` 6.0.1 the
  cross-build pinned at 99.9% CPU after parse/typecheck and never emitted
  output (killed at the 4-minute mark on four consecutive attempts);
  filed upstream as the
  `2026-05-20-kybernet-cycc_aarch64-6.0.1-codegen-hang` issue, adjacent
  to the 2026-05-19 `cycc 6.0.0 emits ud2 at every fncallN site`
  regression — both surfaced in the cc5→cycc rename cycle. As of 6.0.14
  the codegen hang is gone: `cyrius build --aarch64` completes in ~1.2 s
  and emits a 1.258 MB binary. This unblocks the aarch64 release artifact
  that 1.2.2 originally deferred.

### Verification

- `cyrius deps` clean resolution (10 deps).
- `CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet` clean; binary
  1.146 MB.
- `cyrius test src/test.cyr` — 177 passed, 0 failed.
- `CYRIUS_DCE=1 cyrius build --aarch64 src/main.cyr build/kybernet-aarch64`
  — clean; binary 1.258 MB; ~1.2 s.
- QEMU PID-1 harness (`bash qemu/boot-test.sh`, KVM available this cut):
  **OK** — all six boot markers present, boot wall time 807 ms within the
  3000 ms budget.

### Audit-checklist pass

Standing 1.1.5 P(-1) rules re-applied — no kybernet source changed, so
all five (no literal syscall(N, ...); var X[N] sizing; Str vs cstr;
PID-1 exit paths; mount-table size↔stride) hold by inheritance from
1.2.1. The x86_64 DCE delta (−2 KB) is consistent with a no-source-change
cut.

---

## [1.2.1] — 2026-05-11

**Pin argonaut 1.7.0 — boot-to-shell MVP path lit.** Consumer bump
that picks up argonaut's new `BOOT_MINIMAL` agnoshi registration.
Kybernet in BOOT_MINIMAL mode now launches agnoshi as a console
shell with no `aethersafha` dependency, enabling the AGNOS
closed-beta MVP (kernel + kybernet + shell prompt on real iron
without the desktop compositor stack).

### Changed

- **`[deps.argonaut]` tag**: 1.6.2 → 1.7.0. Picks up argonaut's
  `default_services(BOOT_MINIMAL)` agnoshi addition + the
  `STAGE_SHELL` step in `build_boot_sequence(BOOT_MINIMAL)`.
- Rebuilt against Cyrius 5.10.44 + argonaut 1.7.0. Binary size:
  ~1.15 MB (was ~1.1 MB at 1.2.0; +~50 KB from agnoshi service
  registration + STAGE_SHELL boot step in the argonaut bundle).

### Tests

- **177 passed, 0 failed** — full kybernet test suite clean against
  argonaut 1.7.0. No kybernet-side changes; this is purely a
  consumer pin bump.

### Motivation

The AGNOS closed-beta MVP is **boot-to-shell on real hardware**.
Previously kybernet's BOOT_MINIMAL mode registered only daimon —
no shell — and BOOT_DESKTOP required `aethersafha` (Wayland
compositor, not yet Cyrius-ported). argonaut 1.7.0 unblocks the
minimal-mode-with-shell path; this kybernet release picks it up.

### Verification

- `cyrius deps` clean resolution.
- `CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet` clean.
- Test suite 177/177.
- Static linkage preserved (no glibc dependency).

---

## [1.2.0] — 2026-05-11

**Edge boot — first 1.2.x minor.** Lifts the verified-and-sealed boot machinery into kybernet via agnosys 1.2.5's `agnosys-storage` and `agnosys-trust` profile bundles, alongside the existing `agnosys-core`. First kybernet release to pull more than one agnosys profile; first to declare a `[deps.agnosys-*]` block per profile. The 1.1.1 CHANGELOG flagged this as the moment fn_table headroom would press back into the warn band — measured this cut: still under, no warning emitted.

This cut is **scaffolding + capability detection + measurement**, not full verification. Real-device dm-verity / LUKS verify needs deployment-specific paths (data device, hash device, root hash, LUKS device) that argonaut's `EdgeBootConfig` doesn't carry yet. Those land in **1.2.1** alongside the argonaut-side struct extension. **1.2.2+** wires the real hardware boot validation (RPi4, NUC).

### Added
- **`[deps.agnosys-storage]` + `[deps.agnosys-trust]`** in `cyrius.cyml`. Both pin agnosys 1.2.5 (matches the existing `[deps.agnosys]` core entry). cyrius's dep resolver de-dupes the underlying git clone (one checkout, three profile-bundle reads). New `lib/agnosys-storage.cyr` + `lib/agnosys-trust.cyr` files in the resolved tree.
- **`src/lib/edge_boot.cyr`** — new module. Provides:
  - `edge_boot_run(config)` — orchestration entry point. Gates on `boot_mode == BOOT_EDGE && verify_on_boot != 0`. Returns 1 to continue boot, 0 to abort to emergency.
  - **Capability detection** via `tpm_detect()` (checks `/dev/tpmrm0` / `/dev/tpm0`) and `dmverity_supported()` (checks `/sys/module/dm_verity` + veritysetup binary). Logs both.
  - **PCR read** per `EdgeBootConfig.pcr_bindings` spec ("7+14" → indices 7, 14; tolerates any non-digit separator). Reads SHA-256 PCRs via agnosys-trust's `tpm_read_pcr`. Measurement-only — baseline comparison via `tpm_verify_measured_boot` lands in 1.2.1.
  - **Hard-prerequisite gating**: when `tpm_attestation == 1` and TPM is unavailable, returns 0 (FATAL → emergency shell). Same for `readonly_rootfs == 1` and dm-verity unavailable.
  - **`max_boot_ms` wall-clock budget** measured via `monotonic_ms()` deltas, warn-only.
  - **LUKS unlock + dm-verity verify stubs** that log "config land in 1.2.1; skipped" — placeholder for real-device wiring.
  - **Status accessors**: `edge_boot_tpm_present()`, `edge_boot_dmverity_supp()`, `edge_boot_pcr_count()`, `edge_boot_elapsed_ms()` for the boot-phase summary.
- **Phase 6c** in `kybernet_run` — wired between `execute_tmpfiles()` and `run_boot_stages()`. Skips when not in EDGE mode. Drops to emergency shell on hard-prerequisite failure (same path as boot-stage failures).
- **`src/lib/log.cyr`** — factored `klog` / `klog2` / `kmsg` / `slog` / `slog_init` / `_logbuf` / `_log_write` out of `src/main.cyr`. The forcing function was edge_boot.cyr's `klog` calls: src/lib/* modules can't take a circular dependency on main.cyr, and test/bench compiles emitted `error: undefined function 'klog' (will crash at runtime)` when edge_boot was included without main. Pure refactor — no behavior change at the boot path. `g_log_fd` stays in main's globals (shutdown still closes it directly).

### Tests
- **`test_edge_boot_pcr_parser`** (6 assertions) — exercises `_eb_parse_pcr_indices` against `"7+14"`, `"0,7,14,23"` (comma), `"  3  "` (space-padded), `""` (empty), and `"23"` (multi-digit boundary; must not split as 2+3).
- **`test_edge_boot_gating`** (6 assertions) — covers the three deterministic skip paths (`config=0`, non-EDGE boot_mode, `verify_on_boot=0`) plus the accessor initial-state invariants. The host-environment-dependent run path (`EDGE + verify_on_boot=1 + tpm_attestation=1`) is intentionally NOT asserted at the unit-test level — its outcome depends on `/dev/tpm0` + `/usr/bin/tpm2_pcrread` + veritysetup presence. End-to-end coverage is the qemu boot harness's job once a future variant carries `kybernet.harness=edge` on the cmdline (1.2.1 task).
- Total: **160 → 177 tests** pass (+17 — 6 parser + 6 gating + 5 from the 1.1.5 audit that I miscounted in the prior release notes).

### Stats
- x86_64 DCE binary: 1.028 MB → **1.148 MB** (+120 KB — `agnosys-storage` + `agnosys-trust` profile surfaces plus the new edge_boot module and the log-factor-out)
- aarch64 cross-build: clean
- fn_table: well under the 90% warn threshold — the 1.1.1 prediction that two new agnosys profiles would tip past was conservative. Upstream cap-raise (`cyrius/docs/development/issues/2026-05-11-kybernet-fn-table-identifier-buffer-caps.md`) tracking on the 5.11.x arc still relevant for the next round of growth.
- Harness end-to-end: 751 ms wall time (within 3000 ms budget); all six markers
- fmt / vet clean

### Deferred to 1.2.1
- argonaut-side: extend `EdgeBootConfig` with `data_device`, `hash_device`, `root_hash`, `luks_device`, `expected_pcrs` (vec of PCR baseline values). Out of kybernet's tree.
- kybernet-side once 1.2.1 lands the config extension:
  - `dmverity_verify(data_device, hash_device, root_hash)` against real devices
  - `luks_open(config, key_ptr, key_len)` + `luks_mount(device, mount_point, fs)` against a configured LUKS volume; key sourced from TPM unseal or initramfs passphrase
  - `tpm_verify_measured_boot(expected)` against the baseline vec from the extended config
  - Edge-mode qemu harness variant (`kybernet.harness=edge`) — boots with synthetic LUKS volume + dm-verity device produced by `qemu/build-initramfs.sh`

### Deferred to 1.2.2
- Real hardware boot validation: RPi4 + NUC. Needs hardware-in-the-loop testing infra that isn't on the CI runner. Will be a dedicated cut with a hardware-validation report attached to the audit-doc folder.

### Notes
- The 1.1.5 audit's "no literal `syscall(N, ...)`" standing rule paid off here. edge_boot.cyr was written from scratch in 1.2.0 and went through the audit checklist before commit — no raw syscalls; all dep calls go through agnosys-trust / agnosys-storage wrappers which are arch-portable.
- The pre-1.2.0 main.cyr → src/lib/ refactor (log.cyr extraction) inverts a class of bug: previously, adding a `klog` call to a src/lib/ module produced a runtime crash under test (warning-only at compile). 1.2.0 onward, every src/lib/ module that needs logging includes `lib/log.cyr` transitively via the inclusion at the top of main / test / bench. The compile-time error path is preserved (cc5 still emits `undefined function 'klog'` if log.cyr is missing); the runtime-crash path is closed.

---

## [1.1.5] — 2026-05-11

**P(-1) audit pass.** Per-roadmap pre-1.2.0 review of `src/main.cyr` + every `src/lib/*.cyr`. Full report at [`docs/audit/2026-05-11-audit.md`](docs/audit/2026-05-11-audit.md). Summary: **7 CRITICAL / 3 HIGH / 1 MEDIUM / 2 LOW** — 12 closed in this cut, 1 LOW deferred with documented mitigation.

The headline finding was a class — **raw `syscall(N, ...)` calls with x86_64-specific N**. These cross-build fine on aarch64 (cc5_aarch64 doesn't validate syscall numbers per arch) but route to completely different syscalls at runtime. The harness test runs only on x86_64 KVM (sakshi invariant-TSC requirement, transitive via libro/patra), so aarch64 production deployments would have been the first to surface the breakage. 7 sites across `src/main.cyr` + `src/lib/privdrop.cyr` + `src/lib/notify.cyr` were affected.

The remaining findings are pattern-recurrences of 0.95.0 audit lessons: undersized stack/BSS buffers (`status_buf[1]`, `_mount_skipped[16]`) and a missed PID-1 exit path (`default: return 0` in the event loop on unknown epoll tokens — kernel panics when reached). The MEDIUM finding is the Str↔cstr type confusion class that 1.1.4 caught point-only — this pass closes the rest of the surface.

### Security
- **CRITICAL × 7 — raw syscall numbers vs aarch64**:
  - `src/main.cyr:224` `syscall(88, target, path)` (TMP_SYMLINK) → `sys_symlink(target, path)`. SYS_SYMLINK is 88 on x86_64, not on aarch64 (uses SYMLINKAT=36).
  - `src/main.cyr:267, 270` `syscall(59, ...)` (emergency shell `execve`) → `sys_execve(...)`. SYS_EXECVE is 59 on x86_64, 221 on aarch64.
  - `src/main.cyr:271` `syscall(60, 1)` (emergency shell child `exit`) + `src/main.cyr:762` `syscall(60, r)` (kybernet final exit) → `sys_exit(...)`. SYS_EXIT is 60 on x86_64, 93 on aarch64. The final-exit case meant **kybernet on aarch64 would never actually exit** — `syscall(60, r)` would invoke an unallocated syscall, return EINVAL, and the program would fall off the end of the runtime epilogue.
  - `src/lib/privdrop.cyr:58` local enum `SYS_PRCTL = 157` shadowed the stdlib's per-arch definition (157 on x86_64, **167 on aarch64**). On aarch64 every `drop_cap` / `set_no_new_privs` call hit `setpriority`+1 instead of `prctl` → silent capability-drop failure. Local enum entry removed; stdlib's per-arch value now wins.
  - `src/lib/notify.cyr:10-12` local enum `SYS_SOCKET=41, SYS_BIND=49, SYS_RECVFROM=45` (x86_64) — sd_notify socket creation/bind/recv on aarch64 routed to `pipe2` / `setsockopt` / `getsockopt`. Wrapped in `#ifdef CYRIUS_ARCH_*` per-arch enum (aarch64: 198/200/207). Upstream issue filed for stdlib wrappers (`cyrius/docs/development/issues/2026-05-11-kybernet-socket-syscall-wrappers.md`); local fix folds out when stdlib catches up.
- **HIGH-1 — `status_buf[1]` stack overflow** in `reap_zombies` (`src/lib/reaper.cyr:14`). `sys_waitpid` writes a 4-byte Linux `int wstatus` into a 1-byte stack array — 3-byte stack overflow that worked in practice only because cyrius's 8-byte stack alignment puts the spill in padding. Same class as 0.95.0's `signalfd_siginfo buf[16]→[128]` fix. Fixed: `var status_buf[8]`.
- **HIGH-2 — `_mount_skipped[16]` BSS overflow** in `mount.cyr:72`. 16-byte global array (capacity 2 i64 ptrs); loop bound-checked at `< 16` and stored up to 16 ptrs at offsets `0..120` for a 128-byte total span — 112-byte BSS overflow. Same class as 0.95.0's `_mount_table[8]→[240]` fix. Fixed: `var _mount_skipped[128]` (16 slots × 8 bytes).
- **HIGH-3 — PID-1 exit path regression** in event loop default case (`main.cyr:741`). On any unexpected epoll event token, `default: return 0` returned from `kybernet_run` → `main` → `sys_exit(0)` while PID 1 — kernel panic ("Attempted to kill init!"). Same class as 0.95.0's "PID 1 exit paths now call do_shutdown() instead of returning" — the case was missed at the time. Fixed: log a warning via `klog` and continue the loop.

### Fixed
- **MEDIUM-1 — `Str` vs `cstr` type confusion** across the logging surface. 12+ `klog2 / slog / cgroup_*` call sites passed argonaut-returned `Str` (boxed) values where `cstr` was expected — the receiver read the Str header bytes as ASCII chars (garbage output) or as path-construction input (cgroup paths derived from header layout). Latent because the default config has no services so none of the sites fire. **1.1.4 fixed one site** (`run_boot_stages` `klog2("boot: ", desc)`) point-only; this pass closes `handle_sigchld` (4 sites), `start_services` (3 sites including `create_service_cgroup(name)` / `move_to_cgroup(name, pid)`), `handle_health_tick`, and `handle_watchdog_tick`. Each loop iteration calls `str_data()` once at the top and reuses the cstr ptr for all downstream operations — preserves the 1.1.3 cgroup cache LRU hit (which keys on cstr pointer identity).

### Documented (not source-patched)
- **LOW-1 — `_logbuf` no `plen` bounds check** in `_log_write` / `klog2`. If a caller passes a prefix longer than 254 bytes, `copylen = 254 - plen` underflows and `memcpy` blows out the 256-byte `_logbuf`. Every current caller passes a short literal (longest is 35 chars) so the bug isn't reachable. Inline comment block documents the `plen ≤ 254` precondition + the current-caller audit table; promote to MEDIUM the moment a non-literal prefix shows up. Defensive bounds-check deferred — would have diluted the audit-doc signal.
- **LOW-2 — `_mount_table[288]` at exact capacity**. 6 entries × 48 bytes per entry = 288 bytes exactly. Adding a 7th mount entry without growing the array overflows. Inline comment documents the size↔count invariant + next-bump target (`[480]` for 10 entries). Same class as the 0.95.0 `[8]→[240]` fix. The `test_mount_required_flag` regression in `src/test.cyr` is the canary — it asserts the per-entry classification at offset +40, so a stride change without re-doing the test offsets fails immediately.

### Standing rules added (per the audit-doc trailer)
- No literal `syscall(N, ...)`. Use a stdlib wrapper or `#ifdef CYRIUS_ARCH_*`-gated enum.
- `var X[N]` is N **bytes**, not N slots. Sites that hold N i64 ptrs need `[N * 8]`. Write the math inline at the declaration.
- `Str` vs `cstr` — argonaut surface is mostly `Str`; kybernet logging + cgroup path helpers are cstr-only. `vec_get`-derived names need `str_data()` before being passed downstream.
- PID-1 exit paths must call `do_shutdown()` or log-and-continue. Never `return 0` from `kybernet_run` directly.
- Mount table size and stride comments must be updated together; `test_mount_required_flag` is the canary.

### Stats
- x86_64 DCE binary: 1.027 MB → **1.028 MB** (+1 KB for the cstr-wrapping plumbing)
- aarch64 cross-build: clean — and now actually correct (the cross-build was compiling but linking to wrong syscall numbers pre-1.1.5)
- Local harness end-to-end: 768 ms wall time (vs. 3000 ms budget); all 6 markers
- 160 / 160 tests; fmt / vet / bench clean
- Files audited: 11 (`src/main.cyr` + 10 × `src/lib/*.cyr`); LOC reviewed: ~1700

### Notes
- One upstream filing landed alongside this audit: `cyrius/docs/development/issues/2026-05-11-kybernet-socket-syscall-wrappers.md`. Pairs with the 2026-05-10 kavach `prctl/seccomp/setresuid/...` post-fork-syscall request — schedule both in the same stdlib-wrapper batch if cyrius scheduling allows.
- Roadmap consequence: 1.1.5 inserted between 1.1.4 (QEMU harness) and 1.2.0 (edge boot). The audit fixes in privdrop / notify make 1.2.0 work safer to start (those modules will gain new call sites for `agnosys-trust` / `agnosys-storage` integration).

---

## [1.1.4] — 2026-05-11

**QEMU PID-1 boot harness.** Closes a 1.0.1-era roadmap item that had been blocked on argonaut shipping a PID-1 harness pattern — argonaut 1.6.x landed it, and kybernet now lifts the pattern to validate that the actual kybernet binary boots clean as real PID 1 under KVM, with marker assertions and a boot-time budget rather than the previous "grep stdout and hope" shape.

### Added
- **`fn kybernet_harness_requested()`** in `src/main.cyr` — reads `/proc/cmdline`, looks for `kybernet.harness=1` with substring + start-/end-boundary checks (so `nokybernet.harness=1` or `kybernet.harness=11` don't trigger). Pattern lifted directly from argonaut 1.6.x's `pid1_harness_requested()`. Includes the same boundary-character set: SOF / SPACE / TAB on the left, EOF / SPACE / TAB / LF on the right.
- **Harness exit path** wired into `kybernet_run()` between phase 8 (services started) and phase 9 (event loop). When the flag is set, kybernet emits a `harness done — shutting down clean` marker and calls `do_shutdown(SHUTDOWN_POWEROFF)`, skipping the event-loop wait. The clean-shutdown sequence (stop services → sync → reboot) still runs.
- **`qemu/build-initramfs.sh`** — rewritten. Replaced the stale `scripts/build.sh` reference (removed in 1.1.0) with a direct `CYRIUS_DCE=1 cyrius build` invocation. Adds the dynamic-loader + libc bundling that argonaut 1.6.2 introduced when busybox is dynamically linked (Arch's `/usr/lib/initcpio/busybox` needs `ld-linux` + libc; without bundling, the auxiliary boot-shutdown/boot-crash tests fail with "exec format error").
- **`qemu/boot-test.sh`** — rewritten. Mounts kybernet as `/sbin/init`, boots qemu with `kybernet.harness=1`, asserts six specific `klog`-emitted markers (`kybernet: starting`, `... filesystems mounted`, `... argonaut initialized`, `... services started`, `... harness done`, `... shutdown`), measures wall-clock boot time, and gates on a configurable `BUDGET_MS` (default 3000 ms — local KVM hits ~800 ms with headroom for slower hardware). KVM detection mirrors argonaut's: warns and falls back to TCG if `/dev/kvm` isn't readable, but documents that sakshi's `clock_init` will panic under TCG (transitive pull-in via libro/patra).
- **CI job `qemu-harness`** in `.github/workflows/ci.yml`. `continue-on-error: true` — GitHub-hosted runners rarely expose `/dev/kvm`, and sakshi panics under TCG; the job runs the harness if all prereqs (`/dev/kvm`, qemu, a kernel image) are present and surfaces a `::warning::` if any are missing. Uses `BUDGET_MS: 5000` on CI (vs. the 3000 ms local default) to absorb the slower runner wall time. Needs `[build]`, so it doesn't fire if x86_64 build fails.

### Fixed
- **`klog2("boot: ", desc)` + `kmsg(desc)`** in `run_boot_stages` were passing a `Str` (boxed) where a `cstr` was expected — they ended up printing the Str header bytes as if they were chars, surfacing as garbage on the boot console (`kybernet: boot: ӆO`). Now passes `str_data(desc)` to extract the underlying cstr ptr. Pre-existing latent bug; surfaced because the harness assertions made the boot stage output a load-bearing signal.
- **`qemu/boot-crash-test.sh` + `qemu/boot-shutdown-test.sh`** referenced `scripts/build.sh` (removed in 1.1.0). Patched to call `cyrius build src/main.cyr build/kybernet` directly. The scripts are auxiliary shell-init-wrapped tests (not real PID-1 tests like `boot-test.sh`), but they're useful for testing service crash recovery and SIGTERM handling so they stay in tree.

### Removed
- **`qemu/initramfs/` and `qemu/initramfs.cpio.gz` untracked** — `.gitignore` adds `/qemu/initramfs/` and `/qemu/initramfs.cpio.gz` so the staging tree and the bundled cpio (build artifacts of `qemu/build-initramfs.sh`) don't churn the git index. The checked-in shape lives in `qemu/build-initramfs.sh` only. Matches argonaut's `qemu/` convention; same rationale as the 1.1.0 `lib/` untrack — `cyrius.lock`-style reproducibility lives in the source script, not the generated bytes.

### Stats
- x86_64 DCE binary: 1.026 MB → **1.027 MB** (+1.3 KB for `kybernet_harness_requested()` + 1024-byte cmdline buffer alloc — only allocated on the harness path)
- aarch64 cross-build: clean
- Local harness validation: **boot wall time 789–860 ms** (kernel hand-off → phase 8 → clean shutdown) on a dev host with KVM, vs. 3000 ms local budget / 5000 ms CI budget — comfortable headroom in both
- 160/160 tests; fmt/vet clean

### Notes
- The roadmap entry called for separate "minimal < 3s" and "desktop < 3s" boot gates. The current harness measures one boot mode (whatever `argonaut_config_default()` selects, which is `BOOT_DESKTOP`); kybernet doesn't yet thread `kybernet.boot_mode=...` from cmdline to the config, so per-mode gates are deferred until that wiring lands. The single-mode 860 ms result already proves boot-time is comfortably under both targets.
- Harness mode does NOT exercise the event loop (signals, health ticks, watchdog, notify), the emergency-shell drop, or the SIGHUP reload path. Those have unit-test coverage in `src/test.cyr` but no PID-1 validation; if a future regression breaks them, the harness will not catch it. Documented; intentional scope choice for 1.1.4 (validate boot reaches services-started; defer steady-state behavior to dedicated harness variants).
- argonaut's L3 (controlling-TTY + setsid) and M3 (orphan reaper) self-tests have no kybernet analogue — kybernet delegates service-lifecycle behavior to argonaut, so those tests live in argonaut's harness and are already validated there. Our harness only needs to prove "kybernet wakes up, mounts, hands off to argonaut, and shuts down clean."

---

## [1.1.3] — 2026-05-11

**Cgroup path precomputation.** `cgroup_file()` was a hot path (every service start writes 4-5 limits + moves the pid into the cgroup; shutdown reads/writes more). 1.0.x bench had it at 911 ns/op; on 5.10.44 stdlib it was already down to 800 ns/op via toolchain improvements alone, but it was still doing 6 `str_builder_*` calls per invocation, all in PID 1's startup hot loop.

The fix is precomputation: cache the path strings by `(service, filename)` after first build. Cgroup paths are deterministic functions of the pair, and the same pairs get hit repeatedly across a service's lifecycle.

### Changed
- **`src/lib/cgroup.cyr`** — added a layered path cache:
  - **Two-key LRU** (1 slot) on `cgroup_file()`. Pointer-compares `(service, filename)` against the last-call pair; hit short-circuits before any hashmap touch. Catches the same-pair-repeat case (read-then-write same control file).
  - **Per-service inner hashmap** keyed on filename, with a 1-slot LRU on the inner-map pointer keyed on service. The realistic burst pattern (apply 4-5 different limits for one service in a row) lands here: the 2-key LRU misses on each filename change, but the 1-slot service LRU skips the outer map lookup so each call is just one filename → fullpath hashmap_get.
  - **`cgroup_path()`** gets the same 1-slot LRU on service → prefix.
  - `_cg_cache_drop(service)` invalidates all three caches for a service; called from `remove_service_cgroup()`. Cached strings stay in memory (cyrius is gc-less); only the cache indices drop their references.

### Stats — bench delta vs. 1.1.2 (cyrius 5.10.44, x86_64)

| | 1.1.2 baseline | 1.1.3 |   |
|---|---:|---:|---:|
| `cgroup_path` (repeat-svc) | 417 ns/op | **3 ns/op** | **139× faster** |
| `cgroup_file` (same pair, best case) | 800 ns/op | **3 ns/op** | **267× faster** |
| `cgroup_file` (5-file burst, realistic) | 800 ns/op | **97 ns/op** | **8.2× faster** |

The realistic-burst number is the one to trust for live PID 1 use — `cgroup_apply_limits` writes memory.max → memory.high → cpu.weight → pids.max → cgroup.procs, exactly the pattern the burst bench measures. Same-pair best-case is only hit by read-modify-write loops, which kybernet does on shutdown but not at start.

The roadmap target was "~10× shrink under load." Realistic 8.2× hits within tolerance; same-pair 267× exceeds it. Cold path (first call for a new pair) is unchanged at ~800 ns — the cache only changes the warm case.

### Added
- **`test_cgroup_path_cache`** (5 assertions): exercises cold call → warm hit → different-filename-same-service → invalidation → re-build. Verifies content correctness across the cache lifecycle (cold and warm produce identical strings; different filenames produce different paths; re-build after invalidation produces the same string the cold call did). Catches future cache-key mismatches that would silently return stale paths.
- **`bench_cgroup_file_burst`** in `src/bench.cyr` — measures the 5-different-files-per-service pattern that mirrors `cgroup_apply_limits`. The pre-existing `bench_cgroup_file` measures the best case (same pair every iter); both numbers stay in the bench output so future changes show drift in either direction.
- Total: **153 → 160 tests** pass.

### Notes
- Two globals × two LRU slots = four extra `var` cells (32 bytes BSS). No allocation on the hot path; the only heap work is the str_builder + str_builder_build on cold-path misses, same as before.
- Cache keys are cstr (default `map_new()` mode), so any caller passing `Str`-shape names would need to drop to `str_data()` first. All current callers pass cstr literals or cstr-from-vec, so no change needed. Documented in the cache block comment.
- Pointer-identity assumption (the 1-slot LRU compares ptrs, not contents) is safe because: (a) string literals in cyrius have stable addresses, and (b) service-name cstrs from argonaut come from a single allocation per service that's stable across the service's lifetime. Misses on pointer-equal-but-different-contents are impossible; misses on pointer-different-but-content-equal degrade to the slow path (correct, just slower) and are caught by the inner hashmap on hit.

---

## [1.1.2] — 2026-05-11

**CLOEXEC sweep + mount graceful degradation.** Two long-standing items on the v1.0.1/v1.1.0 slate that didn't have a forcing function but are necessary hygiene for a PID 1: fd-leak audit across `sys_open` call sites, and mount-table classification so optional filesystems don't wedge boot on minimal hardware.

### Security
- **CLOEXEC audit** across every `sys_open` call site in `src/main.cyr` and `src/lib/*.cyr`. PID 1 inherits no fds — but any fd it opens leaks into every spawned service via `fork+execve` unless `O_CLOEXEC` is set at open time (or `FD_CLOEXEC` is set via `fcntl(F_SETFD)` before exec). The kybernet/argonaut split puts the open-side discipline in kybernet's lap.
  - **`src/main.cyr:105`** — `g_log_fd` (`/var/log/kybernet.log`): **highest-risk** site. The fd is global, open for PID 1's entire lifetime, and absent CLOEXEC would have been inherited by every service argonaut spawned. Adding `O_CLOEXEC` here is the load-bearing fix.
  - **`src/main.cyr:60`** — `kmsg()` on `/dev/kmsg`: short-lived (open → write → close in-frame), but the frame is reentered from signal handlers and pre-fork code paths. Adding `O_CLOEXEC` is defensive against fork-between-open-and-close races.
  - **`src/main.cyr:223`** — tmpfile `TMP_TOUCH` create: same short-lived-but-defensive shape.
  - **`src/lib/cgroup.cyr:57, 71, 115`** — cgroup-control writes (`cgroup.procs`, `cgroup.kill`, generic u64 writes): all called from PID 1's parent side of `fork()`. Without CLOEXEC, an interleaving spawn would have inherited the cgroup-control fd into the child, allowing the child to move processes between cgroups or kill its own peers.
  - **`src/lib/console.cyr:21, 25, 27`** — fds 0/1/2: **intentionally NOT CLOEXEC.** Standard I/O must pass through exec to spawned services. A comment block at the call site documents the reason so a future audit doesn't "fix" it.
  - `src/lib/sandbox.cyr` already had `O_CLOEXEC_FLAG` on its two Landlock path opens (carried over from 0.90.0).
  - `signalfd`, `timerfd`, `socket` (notify), `epoll_create` all already CLOEXEC: the stdlib wrappers wrap `signalfd4`/`timerfd_create`/`socket`/`epoll_create1` with `SFD_CLOEXEC`/`TFD_CLOEXEC`/`SOCK_CLOEXEC`/`EPOLL_CLOEXEC` set, and the call sites pass the right flags. No fix needed; verified in the audit.

### Added
- **Mount graceful degradation** in `src/lib/mount.cyr`. The mount table grew a sixth `required` field per entry; `mount_essential()` now hard-fails only on required-mount errors and records optional-mount failures in a separate accessor-exposed list. `src/main.cyr` boot phase 3 iterates the skipped list after `mount_essential()` returns and emits a `klog2()` line per skipped target, so the operator sees `kybernet: skipped optional mount: /dev/pts` rather than a silent disappearance.
  - Classification: `/proc` `/sys` `/run` `/sys/fs/cgroup` = required (1); `/dev/pts` `/dev/shm` = optional (0).
  - The motivating use case is **minimal embedded boot** — RPi-class boards without a serial console can boot the rest of the AGNOS stack without `/dev/pts`, and POSIX-shm-free service sets don't need `/dev/shm`. Both were previously fatal at boot.
  - Entry stride moved 40 → 48 bytes (5 → 6 i64 slots); backing array `_mount_table[240]` → `[288]`.
  - New API surface (visible to test + future consumers): `mount_skipped_count()` and `mount_skipped_target(idx)`. Out-of-bounds indices return 0 rather than crashing.

### Tests
- **`test_cloexec_fcntl_probe`** (4 assertions): opens `/dev/null` once with `O_CLOEXEC` and once without, calls `syscall(SYS_FCNTL, fd, F_GETFD=1, 0)`, asserts the returned flags' `FD_CLOEXEC` bit (= 1) matches expectations. The without-CLOEXEC control proves the probe distinguishes set from unset — a bogus probe returning 1 for everything would still pass the first assertion. No `sys_fcntl` wrapper in stdlib at 5.10.44; `SYS_FCNTL` constant is defined on both x86_64 (72) and aarch64 (25), so the raw call is portable.
- **`test_mount_required_flag`** (9 assertions): verifies `required` field is stored at offset +40 for each entry, with the per-entry classification matching the design (`/proc` `/sys` `/run` `/sys/fs/cgroup` = 1; `/dev/pts` `/dev/shm` = 0). Catches stride mistakes or re-orderings on future edits. Also exercises `mount_skipped_count()` returning 0 + accessor returning 0 for OOB indices (positive and negative).
- Total: **140 → 153 tests** pass.

### Stats
- x86_64 DCE binary: 1.02 MB → **1.02 MB** (+1.4 KB; new mount-skipped tracking + classification overhead)
- aarch64 cross-build: clean
- fn_table / identifier buffer: still under warn thresholds (1.1.1 headroom holds)
- fmt / vet / bench: clean

### Notes
- Upstream issue filed at `cyrius/docs/development/issues/2026-05-11-kybernet-fn-table-identifier-buffer-caps.md` requesting `fn_table` and `identifier buffer` cap doubling. Rated P2: 1.1.1 trim shipped clean, but the next minor (1.2.0 edge boot) will press back into the warn band. This isn't a 1.1.2 fix, just adjacent diligence.

---

## [1.1.1] — 2026-05-11

**Compiler-headroom cliff + size pass.** 1.1.0 shipped at `fn_table 92% (3779/4096)` and `identifier buffer 85% (112094/131072)` — both ceilings are hard, and the next dep bump (agnosys 1.2.4 → 1.2.5 landed mid-cut) would have tipped past them. Roadmap had this as the 1.1.1 slot with 1.1.2 sequenced afterward for the DCE/size pass; one fix collapsed both.

Audit of `CYRIUS_DCE=1` dead-code reports showed **3116 dead functions** out of ~3779 registered — kybernet was paying compiler-table cost for the full agnosys dist bundle (350 fns) while calling **zero agnosys-prefixed functions from its own source**. The libro / agnostik / argonaut dist bundles also make no agnosys-domain calls (libro's TPM path is gated behind `-D LIBRO_TPM`, off by default). Switching `[deps.agnosys] modules` from `dist/agnosys.cyr` → `dist/agnosys-core.cyr` reclaimed ~290 fn_table slots without breaking any consumer.

### Changed
- **agnosys profile bundle**: `dist/agnosys.cyr` → **`dist/agnosys-core.cyr`** (56 fns vs. 350 — syscall + error + logging only). Mirrors the kavach pattern (`core` + per-domain profile); the storage/trust/security/system profiles aren't needed at the PID-1 layer.

### Dependencies
- agnosys 1.2.4 → **1.2.5** (matches the new agnosys tag landed alongside this cut; cyrius pin already at 5.10.44, no toolchain change)

### Stats
- **fn_table warning gone** (was 92% — now below the 90% warn threshold; cyrius stops emitting the line)
- **identifier buffer warning gone** (was 85%)
- **Dead-fn count**: 3116 → **2430** (down 686 — the difference is the 290 agnosys-non-core fns plus DCE-driven secondary trims)
- **Binary x86_64 (`CYRIUS_DCE=1`)**: 1.29 MB → **1.02 MB** (−21%). Parity with argonaut's 1.0 MB DCE binary.
- **Binary aarch64**: cross-build clean; ELF check passes
- **140 / 140 tests** pass; vet clean; bench runs; fmt OK

### Notes
- The 1.0.x roadmap had "Binary size optimization" as gated on "dead-code elimination pending cc3 4.0" — that gate became moot in 1.1.0 (cc5 has `CYRIUS_DCE`), and the actual win here was upstream of DCE: trimming surface that the compiler had to register at all. DCE just makes the choice cheaper to validate (smaller binary = same correctness signal).
- agnosys-core surface check (regression guard): kybernet calls **only** `sys_*` syscall wrappers from the agnosys/stdlib boundary. If a future change adds a `log_*` / `mac_*` / `audit_*` / `tpm_*` / `luks_*` etc. call, swap `agnosys-core.cyr` for `agnosys.cyr` (or add the specific profile via a second `[deps.agnosys-<profile>]` entry).
- Roadmap consequence: 1.1.2 (DCE + size pass) was folded into this cut. 1.1.3/1.1.4/1.1.5 renumber down by one slot (now 1.1.2/1.1.3/1.1.4).

---

## [1.1.0] — 2026-05-10

**Foundation refresh.** Cyrius toolchain bumped, all four AGNOS deps moved to current tags, manifest modernized to use dist bundles where the dep ships one. The forcing function was upstream renames (agnosys moved `lib/syscalls_linux.cyr` → `src/syscall.cyr`, retiring the path the 1.0.2 manifest pinned) — once the rebase started, several previously-deferred items unblocked, so they're collapsed into this cut and the 1.1.x arc is rewritten around what's now in reach.

### Changed
- **Cyrius language**: 5.7.12 → **5.10.44**. Pinned to match argonaut 1.6.2 — argonaut's `health.cyr`/`process_mgmt.cyr` call `exec_vec_str`/`exec_env_str`, which only exist in the 5.10.44+ stdlib `process.cyr`. The 5.10.x toolchain is also where `cc5` lives (cc3 retired); cc5 lifts the 64-struct compilation ceiling that previously forced selective module imports for the heavy deps.
- **Manifest** (`cyrius.cyml`): stdlib pin order reordered to `argonaut`-style (syscalls early, before `io`/`process`) — the pre-existing layout tripped a cyrius transitive-dedup bug that was silently dropping `syscalls.cyr` from the preprocessed output, segfaulting `cc5` on link.
- **Stdlib pins**: dropped `sakshi` and `sigil` (libro 2.5+ promoted both to external git-pinned deps; patra 1.9+ pulls sakshi as its own dep — they land in `lib/` via transitive resolve and would otherwise duplicate-define against the version-pinned stdlib copy). Added `slice`, `result`, `trait`, `net`, `fs`, `ct`, `keccak`, `thread`, `random` — required by the new dist bundles.
- **`src/main.cyr`**: renamed `fn run()` → `fn kybernet_run()`. The stdlib `process.cyr` now exports its own `run(cmd, arg1, arg2)` and the dist-bundle pull made the collision a duplicate-fn warning under `cc5`.
- **`src/bench.cyr`**: header comment "deps resolved via cyrb.toml" → "stdlib + deps auto-included via cyrius.cyml" (cyrb retired in 1.0.0).

### Added
- **patra 1.9.3** declared explicitly under `[deps.patra]` (rather than inheriting whatever libro's pin transitively pulls). Mirrors argonaut 1.6+'s pattern of surfacing transitively-resolved deps so the version is under direct local control.
- **argonaut imports extended** with `resolver.cyr` / `notify.cyr` / `audit_ext.cyr` / `tmpfiles.cyr` — back the symbols (`resolve_host_ipv4`, `notify_bind`, `audit_log_*persistent`, `pal_chain`) that 1.6.x `init.cyr`/`health.cyr`/`process_mgmt.cyr` reference. `pid1_harness.cyr` intentionally **not** imported — it's argonaut's own QEMU PID-1 graduation harness, not a consumer-facing module.

### Dependencies
- agnosys 1.0.2 → **1.2.4** (now via `dist/agnosys.cyr` bundle — was selective `lib/syscalls_linux.cyr` only)
- agnostik 1.0.0 → **1.2.1** (now via `dist/agnostik.cyr` — was selective error/types/security/agent)
- libro 2.0.5 → **2.6.2** (now via `dist/libro.cyr` — was selective error/hasher/entry/verify/query/retention/chain/export)
- argonaut 1.5.0 → **1.6.2** (selective; argonaut ships no dist bundle. 1.6.x adds PID-1 harness internals, sigmask hardening for spawned services, `PATH` envp default, and the `audit_ext` persistence layer. 1.6.2 is the latest tagged release; argonaut's working tree is at unreleased VERSION 1.6.3.)
- patra newly declared at **1.9.3** (transitive via libro)
- sigil **3.0.1** + sakshi (transitive via libro/patra; pinned in `cyrius.lock`)

### Removed
- `scripts/build.sh`, `scripts/test.sh`, `scripts/bench.sh`, `scripts/bench-compare.sh` — all referenced `${ROOT}/../cyrius/build/cc2` (cc2 retired with 1.0.0). The modern path is `cyrius build`/`test`/`bench` directly. Roadmap had flagged these for removal since 1.0.1; the removal landed here so the test/release surface only points at one toolchain.
- `scripts/version-bump.sh` no longer touches `Cargo.toml` (Rust era; the file hasn't existed since 0.9.0). It now only rewrites `VERSION`; `cyrius.cyml` already pulls `package.version` from `${file:VERSION}`.
- **`lib/` untracked from git** (`.gitignore` adds `/lib/`). `cyrius.lock` already pins every resolved dep file by sha256 — checked-in `lib/*.cyr` was duplicating that contract. Aligns with the AGNOS-wide convention: agnosys / agnostik / libro / argonaut all gitignore `lib/`. `cyrius deps --verify` against the locked hashes is the reproducibility guarantee.

### Notes
- Build green on cyrius 5.10.44; **140 / 140 tests pass**, vet clean, bench runs.
- Binary x86_64 with `CYRIUS_DCE=1`: **1.29 MB** (was 447 KB at 1.0.2). The growth is from full agnosys/agnostik/libro/patra dist bundles vs. the prior selective-import slim cuts; 1.1.2 plans a profile-bundle vs. full-bundle audit to reclaim the headroom.
- `cc5` reports `fn_table at 92% (3773/4096)` and `identifier buffer at 85%` — these are hard ceilings; v1.1.1 is sequenced first in the 1.1.x arc to trim before the next dep bump tips past them.
- Compile-time warning catalogue (all carried up from dep dist bundles, not kybernet-introduced): one `match arms span multiple enums` in `agnosys.cyr`, four `duplicate fn 'err_*'` in `agnostik.cyr` (last-definition-wins is intentional), one `duplicate fn 'health_check_new'` in `argonaut_types.cyr`, one `duplicate fn '_hex_nibble'` in `sigil.cyr`.
- CI/release workflows carried forward unchanged except for a comment update to the lock-verify step (pins now include patra and the transitive sigil/sakshi entries).

---

## [1.0.2] — 2026-04-27

### Changed
- **Cyrius language**: bumped requirement from 4.5.0 → **5.7.12** for consistency with the rest of the AGNOS base OS (daimon and agnostik already pin 5.7.12).
- **Manifest format**: renamed `cyrius.toml` → `cyrius.cyml` to match the current `cyrius deps` resolver. Package version now interpolates from `VERSION` via `${file:VERSION}`.
- **Stdlib**: dropped `sakshi_full` from `[deps]` — it is no longer shipped in the 5.7.x stdlib (functionality folded into `sakshi`).

### Dependencies
- agnosys 0.97.2 → **1.0.2** (still imports `lib/syscalls_linux.cyr` only — the dist bundle would push past the 64-struct compiler limit)
- agnostik 0.97.1 → **1.0.0** (selective: src/error, types, security, agent)
- libro is now declared directly (was previously transitive via argonaut): pinned to **2.0.5** with src/error, hasher, entry, verify, query, retention, chain, export
- argonaut 1.2.0 → **1.5.0** (src/types, audit, services, health, process_mgmt, boot, init)

### Notes
- Build green on cyrius 5.7.12; **140 tests pass**.
- Stayed on selective `src/<module>.cyr` imports for the heavy deps rather than switching to `dist/<dep>.cyr` bundles — full bundles overflow the compiler's 64-struct ceiling for kybernet's combined unit. daimon/argonaut can use dist bundles because their dep graphs are lighter.

---

## [1.0.1] — 2026-04-12

### Fixed
- Release pipeline / CI version handling (versioning fixups, no source-level changes from 1.0.0).

---

## [1.0.0] — 2026-04-12

### Added

#### Config Loading
- **JSON config** — loads /etc/kybernet/config.json at boot (boot_mode, timeouts, log_to_console)
- **SIGHUP reload** — `handle_sighup()` reloads config and updates argonaut instance
- Fallback to `argonaut_config_default()` when config file missing or parse fails

#### Service Lifecycle
- **Exponential backoff restart** — uses argonaut's `backoff_delay()` from `CrashAction` instead of fixed 5s delay
- **Restart limit enforcement** — `restart_limit_exceeded()` triggers `CRASH_GIVE_UP` with reason string
- **Crash action logging** — logs `CRASH_RESTART` (with delay), `CRASH_GIVE_UP` (with reason), `CRASH_IGNORE`
- Shutdown uses `config_shutdown_timeout()` from loaded config

#### Emergency Shell
- **`drop_to_emergency()`** — fork+exec emergency shell on boot failure
- Uses argonaut's `emergency_shell_default()` (agnoshi, with banner and env)
- Fallback to `/bin/sh` if primary shell exec fails
- Waits for shell exit, then continues boot

#### Tmpfile Directives
- **`execute_tmpfiles()`** — walks `config_tmpfiles()` vec before service startup
- Supports `TMP_DIR` (mkdir), `TMP_SYMLINK` (symlink), `TMP_TOUCH` (create empty file)

#### Structured Logging
- **JSON lines** to `/var/log/kybernet.log` via `slog()` function
- `slog_init()` opens log file after filesystems mounted
- All klog/klog2 messages also emitted as structured JSON (`{"level":"...","msg":"..."}`)
- Log fd closed during shutdown

#### P(-1) Hardening (v0.95.0 work)
- signals.cyr: buffer overflow fix (buf[16] → buf[128] for signalfd_siginfo)
- console.cyr: checked sys_dup2 returns
- eventloop.cyr: checked epoll_add_read for signal fd
- main.cyr: PID 1 exit paths now call do_shutdown() instead of returning
- main.cyr: eventloop_add_notify return checked with cleanup
- mount.cyr: array overflow fix (_mount_table[8] → [240])
- mount.cyr: integer underflow guard in is_mounted()
- klog/klog2 batched to single sys_write (~2.7x faster)
- is_mounted() mount cache (145µs → 92ns, 1583x faster)
- 140 tests (was 98), 46 benchmarks (was 22)

### Changed
- Build tool: `cyrius build` with auto-include from `cyrius.toml` (was `cyrb build`)
- Source files contain only project includes — stdlib + deps auto-prepended by build tool
- Compiler: cc3 3.9.6+ required (was 1.9.1)
- Binary size: 447KB (includes argonaut + libro + sigil + sakshi transitive deps)
- CI: `cyrius deps` + `cyrius build` with fallback rebuild if tool binary is stale

### Dependencies
- Declared in `cyrius.toml` `[deps]` section, resolved via `cyrius deps`
- Namespaced: `lib/{depname}_{basename}` (e.g. `agnostik_types.cyr`)
- agnosys 0.97.2 — `lib/syscalls_linux.cyr`
- agnostik 0.97.1 — types, security, agent, error
- argonaut 1.1.0 — libro (error, entry, hasher, chain, query, verify, retention, export), types, audit, services, health, process_mgmt, boot, init
- 22 stdlib modules (string, fmt, alloc, io, vec, str, fnptr, tagged, callback, hashmap, json, freelist, process, sakshi, sakshi_full, sigil, syscalls, mmap, bigint, chrono, bench, assert)

---

## [0.90.0] — 2026-04-07

### Added

#### Security Modules
- **seccomp.cyr** — seccomp BPF filter builder and loader
  - Builder pattern: `seccomp_builder_new()` → `seccomp_allow(nr)` → `seccomp_build()` → `seccomp_load()`
  - Generates raw BPF bytecode with JEQ instructions, default KILL_PROCESS
  - `seccomp_basic_service()` preset with 37 safe syscalls
  - Agnostik integration: `seccomp_from_profile()`, `seccomp_apply_profile()`
- **sandbox.cyr** — Landlock filesystem sandboxing (new, not in Rust version)
  - Builder pattern: `sandbox_builder_new()` → `sandbox_allow_read/write/exec(path)` → `sandbox_apply()`
  - Graceful fallback on kernels < 5.13 (ENOSYS/EOPNOTSUPP → Ok(1))
  - `sandbox_basic_service()` preset: /usr (exec), /lib (read), /etc (read), /tmp+/var+/run (read-write)
  - Agnostik integration: `sandbox_from_ruleset()`, `sandbox_from_config()`
- **privdrop.cyr** — capability dropping and no_new_privs
  - `drop_capabilities(keep_set)` via PR_CAPBSET_DROP prctl
  - `set_no_new_privs()` (required before seccomp/landlock)
  - `secure_pre_exec(uid, gid, keep_caps)` orchestrating full security setup
  - Agnostik integration: `privdrop_from_context()`, `drop_caps_from_set()`, `secure_from_context()`
- **notify.cyr** — sd_notify socket for service readiness
  - Unix datagram socket at /run/kybernet/notify
  - Parses READY=1, STOPPING=1, WATCHDOG=1, RELOADING=1, STATUS=
  - Integrated with epoll event loop via TOKEN_NOTIFY

#### Agnostik Integration
- Consume agnostik security types: `security_context`, `capability_set`, `seccomp_profile`, `landlock_ruleset`, `sandbox_config`, `cgroup_limits`, `resource_limits`, `agent_config`
- **privdrop.cyr** — `secure_from_context(ctx, caps)` accepts agnostik security context
- **seccomp.cyr** — `seccomp_apply_profile(profile)` accepts agnostik seccomp profile
- **sandbox.cyr** — `sandbox_from_ruleset(ruleset)` accepts agnostik landlock ruleset
- **cgroup.cyr** — `cgroup_apply_limits()`, `cgroup_apply_resource_limits()`, `cgroup_setup_agent()` accept agnostik limits and agent config
- 34 new tests covering all agnostik type construction, access, and integration bridges

#### Dependency Management
- **cyrb.toml** — TOML-based dependency resolution via Cyrius 1.9.1
  - `[deps] stdlib = [...]` for stdlib modules
  - `[deps.agnosys] git + tag + modules` for pinned git dependencies
  - `[deps.agnostik] git + tag + modules` for pinned git dependencies
  - `cyrb build` auto-prepends resolved includes before source
- Removed vendored `lib/agnosys/` — resolved from git tag at build time
- Removed manual `include` directives for stdlib and agnosys from all source files

#### Boot & Event Loop
- kmsg logging at each boot phase for QEMU serial console visibility
- Notify socket integrated with epoll event loop (TOKEN_NOTIFY)
- Event loop handles READY, STOPPING, WATCHDOG, STATUS notify messages

#### Benchmarks & Testing
- **src/bench.cyr** — 22 microbenchmarks across 8 categories
- **scripts/bench.sh** — build and run benchmarks with history tracking
- **scripts/bench-compare.sh** — side-by-side Cyrius vs Rust comparison table
- **benches/rust_compare.rs** — standalone Rust benchmark (raw syscalls, no libc)
- QEMU boot tests ported from rust-old: boot-test, boot-crash-test, boot-shutdown-test
- 98 integration tests (was 33)

### Changed
- **Cyrius 1.9.1** language features throughout:
  - `switch/case` with dense jump table optimization (classify_signal, handle_signal, priv_error_print, _access_to_flags)
  - `for` loops with step expressions replacing `while` + manual counter
  - `elif/else` chains replacing nested `if` blocks
  - `&&` and `||` operators replacing nested conditionals
  - `break/continue` in loops replacing flag variables
- Binary size: 93,800 bytes (was 47,888 at 0.9.0, increase from agnostik types)
- Rust comparison: 71x smaller binary, 2x faster boot, 1.06x syscall parity

### Dependencies
- agnosys 0.90.0 (git tag, modules: lib/syscalls_linux.cyr)
- agnostik 0.95.0 (git tag, modules: src/security.cyr, src/agent.cyr, src/error.cyr)
- Cyrius stdlib: string, fmt, alloc, io, vec, str, fnptr, tagged, callback, assert, bench

### Not Yet Ported from Rust
- Service lifecycle management (wave-based startup, restart with backoff)
- Health check enforcement and watchdog timeout handling
- Configuration loading from JSON / SIGHUP reload
- Edge boot (dm-verity, LUKS, PCR binding)
- Emergency shell with authentication
- Coordinated shutdown (service stop ordering)
- Tmpfile directive execution

These features depend on argonaut (service manager) which is being ported to Cyrius separately.

---

## [0.9.0] — 2026-04-05

### Changed
- **Complete rewrite from Rust to Cyrius** — 727 lines (was 1649 Rust)
- All 7 modules + main entry point in Cyrius
- Result/Option error handling throughout (via tagged.cyr)
- String builder for path construction
- Data-driven mount table (not hardcoded calls)
- Callback library for functional patterns (vec_map, vec_filter, fork_with_pre_exec)
- OwnedFd pattern, structured EpollEvent returns
- PrivError enum with specific error codes and verification
- 33 integration tests

### Added
- src/main.cyr — full boot sequence + event loop + signal dispatch + shutdown
- scripts/build.sh, scripts/test.sh — Cyrius build tooling
- rust-old/ — preserved Rust implementation for reference

## [0.51.0] — 2026-04-03

### Fixed
- **console.rs**: Use `into_raw_fd()` instead of `as_raw_fd()` when opening `/dev/console` — prevents the `File` destructor from closing the fd while it's still in use as stdout
- **main.rs**: Corrected boot phase comments (phase 6/7 → phase 8/9) to match actual ordering

### Changed
- **main.rs**: Signal handling now drains all queued signals per epoll wake (`while let` loop instead of single `if let`) — prevents signal loss under burst
- **main.rs**: `process_pending_restarts` uses `retain` + collect instead of front-popping — the queue is not sorted by `restart_at`, so the old approach could skip ready items behind a future one

### Added
- **eventloop.rs**: Test `drain_timerfd_returns_nonzero_after_expiration` — validates timerfd expiration count
- **eventloop.rs**: Test `into_raw_fd_keeps_fd_open` — documents the console.rs fd ownership fix

---

## [0.50.0] — 2026-04-03

### Added

#### Scaffold
- Project scaffold per AGNOS first-party standards
- `console.rs` — /dev/console + /dev/null stdio setup (after devtmpfs mount)
- `mount.rs` — essential filesystem mounting (/proc, /sys, /dev, /run, cgroup2)
- `mount_devtmpfs()` — standalone devtmpfs mount (must run before console setup)
- `signals.rs` — signalfd setup for SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGPWR
- `reaper.rs` — zombie reaping via waitpid(-1, WNOHANG) loop
- `cgroup.rs` — cgroup v2 per-service isolation (create, move, kill, remove)
- `privdrop.rs` — privilege drop via pre_exec setuid/setgid/setgroups
- `eventloop.rs` — epoll event loop with timerfd, OwnedFd RAII wrapper
- `main.rs` — PID 1 entrypoint: boot flow, service startup, event loop, shutdown

#### Hardening (P(-1) audit)
- Fixed 11 audit findings: fd leaks (OwnedFd), no assert/panic, /proc mount ordering, etc.
- 27 unit tests across all modules
- Delayed restart via timerfd with PendingRestart queue (exponential backoff)
- Config reload on SIGHUP (registers new services from reloaded config)
- Edge boot wired: rootfs lockdown + dm-verity + LUKS via argonaut::execute_edge_boot
- NOTIFY_SOCKET bound and set in environment before service startup
- Cgroup cleanup on service exit (kill_cgroup + remove_service_cgroup)
- Health-driven restart: poll_health results trigger restart when threshold exceeded
- Watchdog-killed services automatically scheduled for restart
- Emergency shell authentication via argonaut::verify_emergency_auth
- Reap ordering: reap_services BEFORE reap_zombies (prevents waitpid race)
- kmsg output for QEMU serial console debugging

#### QEMU Boot Testing
- Minimal mode: 2.98s kernel+init, 140ms init-to-event-loop
- Desktop mode with real daimon binary: 2.9s total, 120ms init-to-event-loop
- Wave-based parallel startup: postgres+redis (Wave 0) → daimon+dependents (Wave 1)
- Crash recovery: service crash → SIGCHLD → reap → delayed restart with backoff → GiveUp after limit
- Clean shutdown: SIGTERM → plan → stop services → sync → reboot(RB_POWER_OFF)
- QEMU test scripts: boot-test.sh, boot-crash-test.sh, boot-shutdown-test.sh, boot-desktop-test.sh
- build-initramfs.sh: creates QEMU-bootable initramfs with kybernet + busybox

#### Infrastructure
- cargo vet initialized (Mozilla, ISRG, Google, Zcash audit imports)
- CI workflow: fmt, clippy, test, audit, deny, msrv
- Release workflow: version verification, multi-arch build, GitHub release
- deny.toml with AGNOS git source allowlist
