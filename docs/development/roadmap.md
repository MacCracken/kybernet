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

## v1.2.0 — Edge boot

**Unblocked** by agnosys 1.2.5's `agnosys-trust` profile bundle (tpm + ima + secureboot + certpin) and `agnosys-storage` (luks + dmverity + fuse). The 1.0.x roadmap blocked this on dep surface; the surface now exists. Will be the first kybernet release to pull a second `[deps.agnosys-*]` profile alongside `agnosys-core`.
- [ ] dm-verity rootfs verify at boot (uses `agnosys/dmverity.cyr` via `agnosys-storage`)
- [ ] LUKS unlock path (uses `agnosys/luks.cyr` via `agnosys-storage`)
- [ ] TPM PCR binding for `EdgeBootConfig.pcr_bindings` ("7+14" default already in argonaut types; needs `agnosys-trust`)
- [ ] Real hardware boot validation: RPi4, NUC

## Deferred (no movement until trigger surfaces)

- **Control socket for agnoshi runtime commands** — separate transport surface; pinned until an agnoshi consumer drives the protocol shape
- **Binary signing on release** — pinned until libro 2.6+ signing/timestamping is consumer-driven from outside kybernet's tree

## History

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
