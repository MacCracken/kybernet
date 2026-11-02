# Kybernet Roadmap

Forward work only. What shipped is in [CHANGELOG.md](../../CHANGELOG.md), and what is true
right now, gate counts included, is in [state.md](state.md).

**Current release: 1.9.0** (cyrius 6.7.18, argonaut 1.18.0, libro 2.11.3, agnostik 2.0.0,
sigil 3.13.15).

**Every open item has a target release.** The order is the dependency order: a later release
may assume everything above it. An item whose start depends on something outside these repos
is in [Gated](#gated), names its gate, and gets a number when the gate opens. A new item goes
under a release or under Gated, never in a list of its own. A finished item is deleted, and
a finished release's section goes with it. A version is for code: docs and roadmap changes
never take one, and a comment-only item ships with a release that has code in it.

**Open: 15** (`grep -c '^- \[ \]'` against this file).

---

## Release plan

| Release | Theme | Items | Waits on |
|---|---|---:|---|
| [1.10.0](#1100--service-config-surface) | Service config surface | 4 | nothing |
| [1.11.0](#1110--edge-boot-under-emulation) | Edge boot under emulation | 3 | `swtpm` in the harness and in CI |
| [1.12.0](#1120--non-root-default-services) | Non-root default services | 1 | agnosticos' config, argonaut's `default_services` |
| [Gated](#gated) | Unnumbered until the gate opens | 7 | hardware, a consumer, or a dep's release |

**Every release:** the full release gates in CLAUDE.md, including the benchmark gate, then the
sibling-free reproduction.

**A cyrius pin move** has no number until one is wanted, because 6.7.18 is the latest release.
It ships as its own patch, or with whatever release is next. The bench gate's A/B cannot span
a pin change, so a flag on that run stays red until someone explains it (standing rule 6). Scan for the changes that alter
what already-compiling code computes, diff the DCE list knowing it cannot see a
compiler-emitted call, and replay `ci.yml` in the runner's image (CHANGELOG [1.8.0], [1.8.1]).

---

## 1.10.0 — Service config surface

What argonaut now offers and config.json cannot reach. New keys go through the reload path
1.9.0 changed, so a key that keeps a string has to obey standing rule 30.

- [ ] **A reload still adds 574 to 1,476 bytes to PID 1's arena.** The parse no longer does:
      this is what is allocated around it, and the credential accounts for the difference.
      Small next to the 54,580 it replaces, but it is still per SIGHUP for the life of the
      system, and this release adds keys to that path.

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

**Gate: a sigil tag, and then a decision about the other two routes.**

- [ ] **bayan's Unicode tables cost PID 1 about 284 KB of file size it never reads.** cyrius
      6.7.18's bayan added a markdown parser whose `# Requires` pulls seven `lib/unicode/`
      files of top-level string `var`s, and DCE removes functions, not global initializers.
      kybernet went 787,336 → 1,095,824 B from the toolchain alone, the data segment 209 →
      493 KB, and libro and argonaut measured the same. sigil's half is filed in its repo,
      `docs/development/issues/2026-11-01-sigil-mldsa-pulls-bayans-unicode-tables.md`. It is
      necessary, not sufficient: `lib/bayan.cyr` also arrives through `dist/agnostik.cyr`'s
      `# Requires` and through kybernet's own `bayan` stdlib entry, which it needs for JSON.
      DCE dropping unread initializers would settle all three at once.

**Gate: libro's answer on what an audit id needs.**

- [ ] **PID 1 waits about 0.9 s for entropy at the first service start on an RNG-less
      board.** cyrius 6.6.7 stopped the stdlib hash seed blocking at phase 6, and the wait
      moved to libro's `uuid_v4` (`getrandom(…, 0)`), reached from argonaut's
      `audit_log_record` on the first `init_start_service`: 914 ms under TCG at 1.7.10,
      about 870 ms at 1.8.0 and 1.8.1 (standing rule 51). libro also exits 74 there if
      `getrandom` fails, which in PID 1 is a panic. Filed in its repo,
      `docs/development/issues/2026-11-01-uuid-v4-waits-for-the-crng-in-pid-1.md`, because
      its comment says a predictable id makes the chain forgeable, and that is its call.

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
