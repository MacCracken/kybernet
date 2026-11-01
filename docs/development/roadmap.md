# Kybernet Roadmap

Forward work only. What shipped is in [CHANGELOG.md](../../CHANGELOG.md), and what is true
right now, gate counts included, is in [state.md](state.md).

**Current release: 1.8.3** (cyrius 6.7.18, argonaut 1.18.0, libro 2.11.3, agnostik 2.0.0,
sigil 3.13.15).

**Every open item has a target release.** The order is the dependency order: a later release
may assume everything above it. An item whose start depends on something outside these repos
is in [Gated](#gated), names its gate, and gets a number when the gate opens. A new item goes
under a release or under Gated, never in a list of its own. A finished item is deleted, and
a finished release's section goes with it. A version is for code: docs and roadmap changes
never take one, and a comment-only item ships with a release that has code in it.

**Open: 17** (`grep -c '^- \[ \]'` against this file).

---

## Release plan

| Release | Theme | Items | Waits on |
|---|---|---:|---|
| [1.9.0](#190--what-pid-1-pays) | What PID 1 pays: memory, size, boot wait | 5 | a sigil tag, a libro tag, and argonaut carrying both |
| [1.10.0](#1100--service-config-surface) | Service config surface | 3 | 1.9.0's reload path |
| [1.11.0](#1110--edge-boot-under-emulation) | Edge boot under emulation | 3 | `swtpm` in the harness and in CI |
| [1.12.0](#1120--non-root-default-services) | Non-root default services | 1 | agnosticos' config, argonaut's `default_services` |
| [Gated](#gated) | Unnumbered until the gate opens | 5 | hardware, or a consumer |

**Every release:** the full release gates in CLAUDE.md, including the benchmark gate, then the
sibling-free reproduction.

**A cyrius pin move** has no number until one is wanted, because 6.7.18 is the latest release.
It ships as its own patch, or with whatever release is next. The bench gate's A/B cannot span
a pin change, so a flag on that run stays red until someone explains it (standing rule 6). Scan for the changes that alter
what already-compiling code computes, diff the DCE list knowing it cannot see a
compiler-emitted call, and replay `ci.yml` in the runner's image (CHANGELOG [1.8.0], [1.8.1]).

---

## 1.9.0 — What PID 1 pays

The memory, file size and boot time PID 1 spends and never gets back. A minor, because the
reload path changes. The Unicode and entropy items are dep-first: the dep's fix, then **the
user tags it**, then kybernet takes the tag.

- [ ] **`strlen(52 chars)` can lose its layout exemption.** The sweep behind 1.8.3 shows the same
      cause as `agent_config`: 36-38 or 25-26 ns by the literal's alignment, period 8 bytes.
      `_bench_aligned` should make it gateable. Re-sweep, then drop it from `LAYOUT_SENSITIVE`.
- [ ] **Every config load, SIGHUP included, costs about 4 bytes of arena per config
      byte.** `json_v_parse_buf` allocates 35,904 bytes to parse an 8,983-byte config
      (measured at 1.7.8), and PID 1's arena is never reset. The 256 KiB config limit
      bounds one reload at about 1 MiB. Fix: parse into a region the reload can release,
      `bayan_json_v_parse_ctx_a` into an `arena_new` arena, reset once the scalars and
      the credential are copied out.
- [ ] **bayan's Unicode tables cost PID 1 about 284 KB of file size it never reads.** cyrius
      6.7.18's bayan added a markdown parser whose `# Requires` pulls seven `lib/unicode/`
      files of top-level string `var`s, and bayan reaches kybernet through sigil-mldsa's
      `# Requires`, for the legacy `u256_*` names only. DCE removes functions, not global
      initializers, so kybernet went 787,336 → 1,095,824 B from the toolchain alone, the
      data segment 209 → 493 KB. libro and argonaut measured the same. Fix it in sigil:
      require `bayan-bigint` and call `bayan_u256_*`. Or have DCE drop unread initializers.
- [ ] **kybernet and argonaut now carry the same Argon2id verifier.** argonaut 1.16.2's
      `verify_emergency_auth` verifies the `v1$` record with kybernet's bounds, on a
      private `mmap` it unmaps before the verdict, so a verification grows the arena by
      0 bytes. kybernet's `_emerg_verify_argon2id` still uses `alloc()`, which PID 1 never
      gets back, and both are linked. Decide whether to delegate; standing rules 24 to 26
      are written around kybernet's copy.
- [ ] **PID 1 waits about 0.9 s for entropy at the first service start on an RNG-less
      board.** cyrius 6.6.7 stopped the stdlib hash seed blocking at phase 6, and the wait
      moved to libro's `uuid_v4` (`getrandom(…, 0)`), reached from argonaut's
      `audit_log_record` on the first `init_start_service`: 914 ms under TCG at 1.7.10,
      about 870 ms at 1.8.0 and 1.8.1 (standing rule 51). libro also exits 74 there if
      `getrandom` fails, which in PID 1 is a panic. Decide in libro whether an audit
      record's id needs a seeded CRNG, or whether it can draw with `GRND_INSECURE` as the
      hash seed does.

## 1.10.0 — Service config surface

What argonaut now offers and config.json cannot reach. It follows 1.9.0 because new keys go
through the reload path that release changes.

- [ ] **A config key for argonaut's 90 s start timeout.** argonaut 1.16.1 kills a
      oneshot or forking start after 90 s, which bounds what was an unbounded wait in
      PID 1. A oneshot that legitimately runs longer now fails, and kybernet has no key
      for `argonaut_set_start_timeout_ms`. Decide whether one is wanted, and its bounds.
- [ ] **Move `env_files` onto argonaut's loader.** argonaut 1.17.0 reads a service's env
      files at spawn (`svc_def_set_env_files`), refusing FIFOs and non-regular files.
      kybernet still reads them itself at config load and merges them into `environment`, so
      a file changed after load is not seen until a reload. Decide which time is the right one.
- [ ] **Config keys for `socket_activation`, `log_config` and `required_for_modes`**, the
      three `ServiceDefinition` fields with none. Socket activation is a listening-socket
      protocol, not a scalar, and argonaut's defaults for the other two fit every shape
      kybernet ships. `resource_limits` stays unexposed on purpose (standing rule 14), though
      argonaut has applied it at spawn since 1.17.0.

## 1.11.0 — Edge boot under emulation

The edge paths no gate executes, in this order: the `swtpm` pass is what the other two run on.
`swtpm` and `tpm2-tools` have to be CI installs, not host capabilities (standing rule 39).

- [ ] **TPM attestation, PCR read and LUKS2 token unlock under `swtpm`.** QEMU exposes
      `tpm-tis` and `tpm-crb`, and `swtpm` and `tpm2-tools` are in Arch `extra`: a real
      TPM 2.0 with real PCRs and sealing, enough to exercise `tpm_detect`, the PCR read
      and compare, and a sealed LUKS2 token end to end. No harness pass covers them.
- [ ] **Measure the verified root hash before the LUKS unlock, and cap it after.**
      argonaut's architecture note 005 (CVE-2026-32606 class) leaves this to kybernet:
      a key sealed only to PCR 7 + 11 is released to any root that boots under the same
      signed kernel. Extend the verified hash into PCR 15 before `unlock_luks`, extend a
      fixed marker after it, and enrol tokens to PCR 7 + 15. Needs the `swtpm` pass above.
- [ ] **`veritysetup open` and a read-only mount of the verified target.** The edge
      passes prove `veritysetup verify` only. The host has `dm-verity.ko.zst` and
      `dm-mod`; the blocker is that Arch's initcpio busybox has no `insmod`/`modprobe`.
      Stage a static loader or the modules, or boot a kernel with DM built in. Never a
      module loader inside PID 1.

## 1.12.0 — Non-root default services

Last, because it changes what every real service runs as, and it is the one release that
spans the distribution: argonaut's `default_services` and agnosticos' config move with it.

- [ ] **Give the AGNOS default services a non-root uid.** `security.uid` /
      `security.gid` work end to end (1.6.9), and agnos-init makes the runtime
      directories (1.7.6), but nothing in the shipped config or in argonaut's
      `default_services` sets a uid, so every real service runs as root. Needs a uid per
      service (aethersafha, daimon, agnoshi, ...), agnos-init owning each service's
      runtime paths to match (`/run/agnos/agents` and `/run/agnos/plugins` are root-owned
      today), and the numeric ids in agnosticos' config. A service with
      `"seccomp": "basic"` and a uid works only because the drop precedes the filter:
      none of setuid/setgid/setgroups/setresuid are in that allowlist.

---

## Gated

Each takes the next free number when its gate opens.

**Gate: real hardware on the bench.**

- [ ] **RPi4 / NUC boot validation.**
- [ ] **Argon2 cost measured on real ARM.** TCG runs it (about 2.7 s at phase 6c), but
      its timings mean nothing, and the work cap is about time.

**Gate: a board under 512 MB.**

- [ ] **A dynamic memory ceiling for the KDF.** `m_cost` is capped statically at
      64 MiB. `system_free_memory()` exists (`~/.cyrius/lib/sys.cyr:458`), but a bound
      that depends on free RAM at boot makes a credential valid on one board and invalid
      on another. Revisit if a board under 512 MB appears.

**Gate: an agnoshi consumer that drives the protocol shape.**

- [ ] **Control socket for agnoshi runtime commands.**

**Gate: libro signing and timestamping driven from outside kybernet.**

- [ ] **Binary signing on release.**
