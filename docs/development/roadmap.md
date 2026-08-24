# Kybernet Roadmap

## v1.1.0 — Foundation refresh (current)

- [x] cyrius pin bump 5.7.12 → **5.10.44** (matches argonaut 1.6.2)
- [x] Dep bumps: agnosys 1.0.2 → 1.2.4, agnostik 1.0.0 → 1.2.1, libro 2.0.5 → 2.6.2, argonaut 1.5.0 → 1.6.2, patra newly declared at 1.9.3
- [x] Dist-bundle adoption for agnosys / agnostik / libro / patra (cc5 lifts the cc3 64-struct ceiling that previously forced selective imports)
- [x] Stdlib pins refreshed; sakshi + sigil dropped (transitive via libro/patra)
- [x] Argonaut imports extended (resolver, notify, audit_ext, tmpfiles) — backs symbols 1.6.x services/init now reference
- [x] `kybernet_run()` rename — was colliding with stdlib `process.run()` after the dist-bundle pull
- [x] Cleanup: removed `scripts/{build,test,bench,bench-compare}.sh` (cc2-era), fixed `cyrb.toml` reference in `src/bench.cyr`, rewrote `version-bump.sh` (was touching `Cargo.toml`)
- [x] CI/release: lock-verify comment updated for patra; rest of pipeline (cyrius pin auto-parse, DCE build, ELF check, aarch64 best-effort, version consistency) carried forward unchanged
- [x] 140/140 tests, vet clean, bench runs

## v1.1.x arc — modernization

Sequenced patches; no item below is gated on roadmap work outside the current dep set.

### v1.1.1 — Compiler-headroom cliff + size pass (done, 2026-05-11)

cc5 was at `fn_table 92%` / `identifier buffer 85%` against the 1.1.0 build — next dep bump would have tipped the hard ceilings. The trim and the size pass (originally sequenced as 1.1.2) collapsed into one fix: switched `[deps.agnosys]` from `dist/agnosys.cyr` (350 fns) to `dist/agnosys-core.cyr` (56 fns). Kybernet calls zero agnosys-prefixed functions from its own source, and the libro/agnostik/argonaut dist bundles make no agnosys-domain calls either, so the trim was lossless.
- [x] Dead-fn audit: 3116 dead out of ~3779 registered — almost entirely from agnosys storage/trust/security/system domains kybernet never touches
- [x] `dist/agnosys.cyr` → `dist/agnosys-core.cyr` (kavach-style profile pattern)
- [x] agnosys 1.2.4 → 1.2.5
- [x] Result: fn_table + identifier buffer warnings gone; binary 1.29 MB → **1.02 MB** (−21%, parity with argonaut); dead-fn count 3116 → 2430; 140/140 tests, aarch64 cross-build clean

### v1.1.2 — CLOEXEC audit + mount graceful degradation (done, 2026-05-11)

- [x] CLOEXEC sweep: every `sys_open` in `src/main.cyr` + `src/lib/*.cyr` either sets `O_CLOEXEC` or has a documented reason (fds 0/1/2 in console.cyr intentionally pass through exec)
- [x] `mount.cyr` — graceful degradation: `required` field per mount-table entry; required failures fatal, optional failures logged + skipped. `/dev/pts` `/dev/shm` are optional; `/proc` `/sys` `/run` `/sys/fs/cgroup` are required
- [x] Regression tests: `test_cloexec_fcntl_probe` (fcntl F_GETFD probe with control), `test_mount_required_flag` (per-entry classification + skipped accessor bounds). 140 → 153 tests
- [x] Upstream filing: `cyrius/docs/development/issues/2026-05-11-kybernet-fn-table-identifier-buffer-caps.md` requesting fn_table + identifier buffer cap doubling (adjacent to 1.1.1 headroom work; not a fix for 1.1.2)

### v1.1.3 — Cgroup path precomputation (done, 2026-05-11)

- [x] Baseline: `cgroup_path` 417 ns/op, `cgroup_file` 800 ns/op on cyrius 5.10.44 (already down from the 1.0.x 911 ns figure via toolchain improvement)
- [x] Layered path cache: 2-key LRU (`cgroup_file`) → 1-slot service LRU → per-service inner hashmap. `cgroup_path` gets the 1-slot LRU. Invalidation via `_cg_cache_drop(service)` wired into `remove_service_cgroup()`
- [x] Results: same-pair best case 267× (3 ns), realistic 5-file burst 8.2× (97 ns), cold path unchanged. Hit the ~10× target on the realistic case
- [x] Regression test: `test_cgroup_path_cache` covers cold → warm → mixed-filename → invalidation → re-build. New burst bench `bench_cgroup_file_burst` reflects the `cgroup_apply_limits` shape. 153 → 160 tests

### v1.1.4 — QEMU PID-1 boot harness (done, 2026-05-11)

- [x] `kybernet_harness_requested()` reads `/proc/cmdline` for `kybernet.harness=1` (substring + boundary-char checks, lifted from argonaut 1.6.x)
- [x] Harness exit path wired into `kybernet_run()` — clean `do_shutdown(SHUTDOWN_POWEROFF)` after services start; skips event loop
- [x] `qemu/build-initramfs.sh` rewritten — direct `cyrius build`, dynamic-loader + libc bundling for Arch's dynamically-linked busybox
- [x] `qemu/boot-test.sh` rewritten — asserts 6 klog markers (starting → filesystems mounted → argonaut initialized → services started → harness done → shutdown), enforces `BUDGET_MS` (default 3000; CI 5000)
- [x] CI job `qemu-harness` added: `continue-on-error: true`, skips with `::warning::` if `/dev/kvm` / qemu / kernel image is missing
- [x] Fixed latent `klog2("boot: ", desc)` bug — was passing Str where cstr expected, printing garbage. Now passes `str_data(desc)`
- [x] Local validation: boot wall time **789–860 ms** (KVM, kernel hand-off → phase 8 → clean shutdown) on a dev host. Single boot mode for now — per-mode gates deferred to when `kybernet.boot_mode=...` cmdline plumbing lands
- [x] Auxiliary `boot-crash-test.sh` / `boot-shutdown-test.sh` repaired (stale `scripts/build.sh` refs; not PID-1 tests but still useful)

### v1.1.5 — P(-1) audit pass (done, 2026-05-11)

Pre-1.2.0 review. Full report at [`docs/audit/2026-05-11-audit.md`](../audit/2026-05-11-audit.md).
- [x] **7 CRITICAL** — raw `syscall(N, ...)` calls with x86_64-specific N. aarch64 cross-built fine but routed to wrong syscalls at runtime. Closed: 4 sites in `main.cyr` (SYS_EXIT/EXECVE/SYMLINK), `privdrop.cyr` `SYS_PRCTL=157` shadowing stdlib's 167, `notify.cyr` `SYS_SOCKET/BIND/RECVFROM` enum. New rule: no literal syscall numbers.
- [x] **3 HIGH** — `status_buf[1]` 4-byte stack overflow in `reap_zombies`, `_mount_skipped[16]` 112-byte BSS overflow in `mount.cyr`, PID-1-exit `default: return 0` regression in event loop. All same-class as 0.95.0 audit lessons.
- [x] **1 MEDIUM** — Str↔cstr type confusion across 12+ `klog2 / slog / cgroup_*` sites (1.1.4 fixed one point-only; this closes the rest).
- [x] **2 LOW** — `_logbuf` no plen check (documented; not reachable under current callers); `_mount_table[288]` at exact capacity (inline invariant comment).
- [x] Upstream issue: `cyrius/docs/development/issues/2026-05-11-kybernet-socket-syscall-wrappers.md` requests stdlib `sys_socket / sys_bind / sys_recvfrom / ...` wrappers — kybernet's `notify.cyr` workaround folds out when those land.
- [x] 160/160 tests, harness end-to-end clean, x86_64 1.028 MB / aarch64 clean

## v1.2.x arc — edge boot

### v1.2.0 — Edge boot scaffolding + capability detection (done, 2026-05-11)

First 1.2.x minor. Pulls agnosys 1.2.5's `agnosys-storage` + `agnosys-trust` profile bundles alongside `agnosys-core`. Scope: orchestration + detection + PCR read. Real-device verify/unlock deferred to 1.2.1 because argonaut's `EdgeBootConfig` doesn't yet carry deployment-specific device paths.
- [x] `[deps.agnosys-storage]` + `[deps.agnosys-trust]` blocks in cyrius.cyml; fn_table headroom held (no warn)
- [x] `src/lib/edge_boot.cyr` — `edge_boot_run(config)`, capability detection (`tpm_detect` + `dmverity_supported`), PCR read measurement, hard-prerequisite gating, `max_boot_ms` budget, stub LUKS/dm-verity calls
- [x] Phase 6c wired into `kybernet_run`; drops to emergency on hard-prereq failure
- [x] `src/lib/log.cyr` factor-out (forcing function: edge_boot needed klog without main.cyr dependency); pure refactor
- [x] 17 new tests (6 PCR parser + 6 deterministic gating + 5 from 1.1.5 miscount); 160 → 177
- [x] x86_64 1.028 MB → 1.148 MB (+120 KB), aarch64 cross-build clean, harness 751 ms

### v1.2.1 — Real-device verify + edge harness variant

Needs argonaut-side `EdgeBootConfig` extension first. Tracking in argonaut's roadmap.
- [ ] argonaut: extend `EdgeBootConfig` with `data_device` / `hash_device` / `root_hash` / `luks_device` / `expected_pcrs` (vec of PCR baselines)
- [ ] kybernet: `dmverity_verify(data, hash, root_hash)` against real devices
- [ ] kybernet: `luks_open` + `luks_mount` against the configured LUKS volume; key from TPM unseal OR initramfs passphrase
- [ ] kybernet: `tpm_verify_measured_boot(expected)` against the baseline vec
- [ ] `qemu/build-initramfs.sh` edge variant — synthetic LUKS volume + dm-verity device staged into the cpio
- [ ] `kybernet.harness=edge` cmdline path; assert edge-specific markers in boot-test.sh

### v1.2.2 — Real hardware boot validation

Hardware-in-the-loop; not CI-runnable.
- [ ] RPi4 boot with verified rootfs + LUKS-encrypted data partition
- [ ] NUC boot with TPM 2.0 PCR-sealed LUKS key
- [ ] Hardware-validation report under `docs/audit/<date>-edge-hw.md` (mirror the P(-1) audit-doc pattern)

## v1.5.x arc — make the delivered surface real

Swept out of the 1.4.2/1.4.3 audits and the source itself. The through-line:
kybernet's *mechanisms* are now correct and gated, but several of them are
wired to nothing. 1.5.x is about closing the gap between what the code can
do and what it actually does on a booted system.

Ordered by what unblocks what.

### v1.5.0 — services actually come from config ✅ (2026-08-24)

- [x] JSON array/object parsing for `services` in `load_config` — via bayan's
      value tree (`json_v_parse_buf`), in `src/lib/svc_config.cyr`
- [x] Populate `svc_def` from each entry: binary, args, deps, restart policy,
      health check, type, enabled, pid_file
- [x] Fixed the latent `Str`/cstr mismatch — `init_start_service` /
      `init_restart_service` now get `str_data(name)`
- [x] Fixed: waves resolved over `config_services` only, so the boot-mode
      defaults were never started — now `init_service_defs(init)`
- [x] Fixed: `init_start_service` is tri-state, so every successful oneshot
      was logged as "FAILED to start"
- [x] Regression tests + a QEMU harness that stages a real config and asserts
      both a config service and its dependent actually ran
- [x] argonaut 1.10.0: enum `*_parse` inverses, `init_service_defs`,
      `svc_def_set_*`, `svc_hc_*`, and the oneshot-dependency fix

### v1.5.1 — boot stages that do something

`execute_boot_stage(stage)` is `return 1` for all 11 arms plus `default` — it
is semantically `return 1;`. `run_boot_stages` therefore always takes the
success branch, `init_mark_step_failed` is unreachable, and the caller's
`if (boot_r < 0)` emergency path can never fire. The whole boot-stage
apparatus reports success it never earned. 1.4.2 audit MEDIUM.

- [ ] Implement the stages that have real work (mounts, udev, security policy
      apply, database + service waves) and return honest status
- [ ] Delete or explicitly no-op the stages that genuinely have nothing to do,
      so "success" means something per stage
- [ ] Test that a failing required stage reaches `drop_to_emergency`

### v1.5.2 — per-service security profiles (completes audit HIGH-1)

1.4.3 delivered the *mechanism*: argonaut 1.9.0's pre-exec hook plus
kybernet's `kyb_pre_exec`, applying no_new_privs → capabilities → Landlock →
seccomp per service, fail-closed. No default AGNOS service carries a profile
yet, so the hook is a no-op in practice — deliberately, since a uniform
allowlist applied to every service is how you make a system unbootable.

- [ ] Author seccomp + Landlock + capability profiles for the default AGNOS
      services (daimon, hoosh, agnoshi, aethersafha, Synapse)
- [ ] Express them in config so profiles are data, not code
- [ ] **Validate `drop_cap_sets()` on privileged hardware** — the `capset(2)`
      path added at 1.4.2 cannot be exercised by the suite, which runs
      unprivileged where every path short-circuits on the euid check
- [ ] **Validate the aarch64 seccomp syscall table on real hardware** — eight
      values (`mprotect`, `rt_sigreturn`, `accept`, `sendto`, `sigaltstack`,
      `clock_gettime`, `set_robust_list`, `rseq`) come from asm-generic and are
      not cross-checkable against the cyrius stdlib
- [ ] Harness variant that boots a service under a real profile and asserts it
      both starts and is actually confined

### v1.5.3 — lifecycle cleanup and observability

Smaller items with real operational consequences.

- [ ] **Service cgroups are never removed.** `create_service_cgroup` mkdirs per
      service; `remove_service_cgroup` and `kill_cgroup` exist but have no call
      site outside tests/benches. Cgroup dirs accumulate for the life of the
      system and `CRASH_GIVE_UP` leaves a populated one behind (1.4.2 audit LOW)
- [ ] **`reload_config` leaves argonaut half-updated.** SIGHUP does
      `store64(g_init, new_cfg)`, overwriting only field 0 of `ArgonautInit`;
      the boot sequence and service map that `argonaut_init_new` derived from
      the *old* config are never rebuilt, so a reload silently mixes new config
      with old derived state (1.4.2 audit MEDIUM)
- [ ] **Edge-boot gate decisions are not auditable.** Both refusal reasons use
      `klog` only, which reaches stderr and slog but never `/dev/kmsg` — the one
      sink that survives to `dmesg` on a headless board. The operator gets a
      generic phase marker, not the reason (1.4.2 audit MEDIUM)
- [ ] **The edge-boot time budget cannot bound anything.** `max_boot_ms` is
      measured *after* all the work it is meant to bound, and is warn-only. The
      work it wraps includes unbounded blocking waits on external programs
      (`veritysetup`, `tpm2_pcrread`) with no timeout (1.4.2 audit MEDIUM)
- [ ] **The cgroup path cache has no production hits.** Only two call sites
      reach it, both in `start_services`; every other consumer
      (`kill_cgroup`, `_cgroup_write_u64`, `remove_service_cgroup`) bypasses it.
      Either route them through it or drop the cache (1.4.2 audit MEDIUM)

### v1.5.4 — close the remaining edge-boot deferrals

Folds in the long-stalled v1.2.1 scope, which is still the honest state of
`edge_boot.cyr`: it *detects* TPM and dm-verity but verifies neither. LUKS
unlock, dm-verity verify and PCR-baseline comparison all log "lands in 1.2.1"
and skip. Blocked on the same argonaut `EdgeBootConfig` extension listed under
v1.2.1 above; now that argonaut is in scope for edits, that is unblocked.

- [ ] Everything under v1.2.1, re-dated
- [ ] Re-state the deferrals in `edge_boot.cyr`'s header against real versions
      rather than "1.2.1"

## Deferred (no movement until trigger surfaces)

- **Validate `drop_cap_sets()` on privileged hardware** — the `capset(2)` path added at 1.4.2 cannot be exercised by the suite (it runs unprivileged, where every path short-circuits on the euid check). Gates enabling the security stack, not a release.

- **Control socket for agnoshi runtime commands** — separate transport surface; pinned until an agnoshi consumer drives the protocol shape
- **Binary signing on release** — pinned until libro 2.6+ signing/timestamping is consumer-driven from outside kybernet's tree

## History

### v1.5.0 — Config-driven services (2026-08-24)
services parsed from JSON; three defects fixed in the start path that had never executed; argonaut 1.10.0 for the enum parsers, service-set accessors and the oneshot-dependency fix. Harness now boots real services. 235 tests.

### v1.4.2 — P(-1) audit pass (2026-08-24)
Fifth P(-1) sweep; first since 1.1.5. 2 CRITICAL / 5 HIGH / 7 MEDIUM / 6 LOW, 19 of 20 closed. Both CRITICALs were gate-invisible: undrained level-triggered timerfds (PID 1 spinning at 100% CPU ~10s after every boot, then a kernel panic) and an x86_64-only `struct epoll_event` layout (kernel-written heap overflow + signals never handled on aarch64). Added the `kybernet.harness=loop` reactor gate — verified to fail on the unfixed tree — because no release gate had ever executed an event-loop iteration. 194 tests.

### v1.4.1 — Toolchain 6.5.35 + dependency refresh (2026-08-24)
cyrius 6.4.62 → 6.5.35; sigil 3.12.9 / agnostik 1.4.0 / libro 2.8.12 / argonaut 1.8.6. Retired the `[deps.patra]` git block (it was downgrading the newer stdlib fold) and the `path = "../…"` fields (they made the tag pins inert locally). Manifest trimmed 6,924 → 2,784 bytes. CI format gate repaired for `cyrius fmt`'s in-place rewrite. No functional source change; 177 tests, harness green (673–911 ms of a 3000 ms budget).

### v1.0.2 — Toolchain rebase (2026-04-27)
cyrius 4.5.0 → 5.7.12, manifest renamed `cyrius.toml` → `cyrius.cyml`, agnosys 1.0.2 / agnostik 1.0.0 / libro 2.0.5 / argonaut 1.5.0. 140 tests.

### v1.0.1 — Release-pipeline patches (2026-04-12)
Versioning fixups, no source-level changes.

### v1.0.0 — Argonaut-integrated release (2026-04-12)
JSON config + SIGHUP reload, exponential-backoff restarts, emergency shell, tmpfile directives, structured JSON logging. P(-1) hardening (5 CRITICAL + 3 HIGH). klog batching (2.7x), mount cache (1583x). 140 tests, 46 benchmarks.

### v0.95.0 — Production hardening
P(-1) audit pass: signals.cyr buffer overflow, console.cyr unchecked dup2, eventloop.cyr unchecked epoll_add, main.cyr PID 1 exit paths, mount.cyr array overflow + underflow guard.

### v0.90.0 — Security + argonaut integration
seccomp BPF, Landlock sandbox, capability dropping, sd_notify socket, full argonaut integration.

### v0.9.0 — Cyrius rewrite
Complete port from Rust to Cyrius. 727 lines (was 1,649 Rust).

### v0.50.0 — Rust-era hardening + QEMU boot
P(-1) audit, QEMU boot testing, crash recovery, clean shutdown.

### v0.1.0 — Scaffold
Project scaffold, console, mount, signals, reaper, cgroup, privdrop, epoll.
