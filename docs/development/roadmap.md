# Kybernet Roadmap

## v1.1.0 — Foundation refresh (current)

- [x] cyrius pin bump 5.7.12 → **5.10.44** (matches argonaut 1.6.3)
- [x] Dep bumps: agnosys 1.0.2 → 1.2.4, agnostik 1.0.0 → 1.2.1, libro 2.0.5 → 2.6.2, argonaut 1.5.0 → 1.6.3, patra newly declared at 1.9.3
- [x] Dist-bundle adoption for agnosys / agnostik / libro / patra (cc5 lifts the cc3 64-struct ceiling that previously forced selective imports)
- [x] Stdlib pins refreshed; sakshi + sigil dropped (transitive via libro/patra)
- [x] Argonaut imports extended (resolver, notify, audit_ext, tmpfiles) — backs symbols 1.6.x services/init now reference
- [x] `kybernet_run()` rename — was colliding with stdlib `process.run()` after the dist-bundle pull
- [x] Cleanup: removed `scripts/{build,test,bench,bench-compare}.sh` (cc2-era), fixed `cyrb.toml` reference in `src/bench.cyr`, rewrote `version-bump.sh` (was touching `Cargo.toml`)
- [x] CI/release: lock-verify comment updated for patra; rest of pipeline (cyrius pin auto-parse, DCE build, ELF check, aarch64 best-effort, version consistency) carried forward unchanged
- [x] 140/140 tests, vet clean, bench runs

## v1.1.x arc — modernization

Sequenced patches; no item below is gated on roadmap work outside the current dep set.

### v1.1.1 — Compiler-headroom cliff

`cc5` reports `fn_table at 92% (3773/4096)` and `identifier buffer at 85% (111862/131072)` against the new dist-bundle build. Both ceilings are hard; the next dep-surface bump or new module addition will tip past them. Trim now while it's cheap.
- [ ] Audit dead-code reports from `CYRIUS_DCE=1` build — many sandbox/seccomp/health helpers are flagged unused after the 1.6.x argonaut import shape settled
- [ ] Decide: trim unused dist-bundle surface vs. split kybernet into compilation units (cyrius supports `#ifdef`-gated includes)
- [ ] Re-measure: target `fn_table < 80%`, `identifier buffer < 70%`

### v1.1.2 — DCE + size pass

Binary is 1.29 MB under `CYRIUS_DCE=1`. Argonaut's own DCE binary is ~1.0 MB on essentially the same dep tree, so 200–300 KB headroom looks tractable.
- [ ] Profile per-module contribution to final binary (use `nm`/`readelf` on the DCE output)
- [ ] Re-evaluate full agnosys dist bundle vs. `agnosys-core` profile — kybernet doesn't currently use `audit/pam/luks/dmverity/tpm/...`
- [ ] Move callers off any libro persistence surface kybernet doesn't actually exercise

### v1.1.3 — CLOEXEC audit + mount graceful degradation

Carried forward from old v1.1.0 slate. argonaut 1.6.3 closeout audit added `reset_child_signal_mask` and `build_default_envp`; the equivalent fd-hygiene sweep belongs at the kybernet layer (we own pre-exec).
- [ ] CLOEXEC sweep: every `sys_open` in `src/lib/*.cyr` either sets `O_CLOEXEC` or has a documented reason
- [ ] `mount.cyr` — graceful degradation on per-mount failure (today: hard fail except for `/sys/fs/cgroup` already retried)
- [ ] Add regression tests for both

### v1.1.4 — Cgroup path precomputation

Carried forward from old v1.1.0 slate. `cgroup_file()` measured at 911 ns/call in 1.0.x bench. Precompute common per-service paths at service-definition time; expected ~10x shrink under load.
- [ ] Bench baseline (current `bench.cyr` doesn't cover this hot path — add it)
- [ ] Precompute table at `argonaut_init_new` time keyed by service name
- [ ] Compare under desktop boot service set

### v1.1.5 — QEMU PID-1 boot harness

Carried forward from the old v1.0.1 slate; **unblocked** by argonaut 1.6.3's `pid1_harness.cyr` pattern (12 KB statically-linked helper + initramfs-staged marker file). We can lift that pattern directly.
- [ ] Port `qemu/build-initramfs.sh` from argonaut, swap the helper for a kybernet boot-stage marker
- [ ] Boot-time gate: `< 3s` to `STAGE_BOOT_COMPLETE` in minimal mode, `< 3s` desktop
- [ ] Wire into CI as a non-fatal `qemu-boot-test.sh` job (mirrors argonaut's pattern — failures are signal, not blocker)

## v1.2.0 — Edge boot

**Unblocked** by agnosys 1.2.4's `agnosys-trust` profile bundle (tpm + ima + secureboot + certpin) and `agnosys-storage` (luks + dmverity + fuse). The 1.0.x roadmap blocked this on dep surface; the surface now exists.
- [ ] dm-verity rootfs verify at boot (uses `agnosys/dmverity.cyr`)
- [ ] LUKS unlock path (uses `agnosys/luks.cyr`)
- [ ] TPM PCR binding for `EdgeBootConfig.pcr_bindings` ("7+14" default already in argonaut types)
- [ ] Real hardware boot validation: RPi4, NUC

## Deferred (no movement until trigger surfaces)

- **Control socket for agnoshi runtime commands** — separate transport surface; pinned until an agnoshi consumer drives the protocol shape
- **Compilation-unit split** — only if 1.1.1 trim-pass can't get back under the 80%/70% ceiling targets
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
