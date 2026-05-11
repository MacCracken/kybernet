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

### v1.1.2 — CLOEXEC audit + mount graceful degradation

Carried forward from old v1.1.0 slate. argonaut 1.6.2 closeout audit added `reset_child_signal_mask` and `build_default_envp`; the equivalent fd-hygiene sweep belongs at the kybernet layer (we own pre-exec).
- [ ] CLOEXEC sweep: every `sys_open` in `src/lib/*.cyr` either sets `O_CLOEXEC` or has a documented reason
- [ ] `mount.cyr` — graceful degradation on per-mount failure (today: hard fail except for `/sys/fs/cgroup` already retried)
- [ ] Add regression tests for both

### v1.1.3 — Cgroup path precomputation

Carried forward from old v1.1.0 slate. `cgroup_file()` measured at 911 ns/call in 1.0.x bench. Precompute common per-service paths at service-definition time; expected ~10x shrink under load.
- [ ] Bench baseline (current `bench.cyr` doesn't cover this hot path — add it)
- [ ] Precompute table at `argonaut_init_new` time keyed by service name
- [ ] Compare under desktop boot service set

### v1.1.4 — QEMU PID-1 boot harness

Carried forward from the old v1.0.1 slate; **unblocked** by argonaut 1.6.2's `pid1_harness.cyr` pattern (12 KB statically-linked helper + initramfs-staged marker file). We can lift that pattern directly.
- [ ] Port `qemu/build-initramfs.sh` from argonaut, swap the helper for a kybernet boot-stage marker
- [ ] Boot-time gate: `< 3s` to `STAGE_BOOT_COMPLETE` in minimal mode, `< 3s` desktop
- [ ] Wire into CI as a non-fatal `qemu-boot-test.sh` job (mirrors argonaut's pattern — failures are signal, not blocker)

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
