# Kybernet Roadmap

Forward work only. What shipped is in [CHANGELOG.md](../../CHANGELOG.md), and what is true
right now, gate counts included, is in [state.md](state.md).

**Current release: 1.11.0** (cyrius 6.7.18, argonaut 1.19.0, libro 2.11.3, agnostik 2.0.0,
sigil 3.13.15).

**Every open item has a target release.** The order is the dependency order: a later release
may assume everything above it. An item whose start depends on something outside these repos
is in [Gated](#gated), names its gate, and gets a number when the gate opens. A new item goes
under a release or under Gated, never in a list of its own. A finished item is deleted, and
a finished release's section goes with it. A version is for code: docs and roadmap changes
never take one, and a comment-only item ships with a release that has code in it.

**Open: 11** (`grep -c '^- \[ \]'` against this file).

---

## Release plan

| Release | Theme | Items | Waits on |
|---|---|---:|---|
| [1.11.1](#1111--the-tpm-board-on-aarch64) | The TPM board on aarch64 | 1 | nothing outside these repos |
| [1.12.0](#1120--non-root-default-services) | Non-root default services | 1 | agnosticos' config, argonaut's `default_services` |
| [Gated](#gated) | Unnumbered until the gate opens | 9 | hardware, a consumer, or a dep's release |

**Every release:** the full release gates in CLAUDE.md, including the benchmark gate, then the
sibling-free reproduction.

**A cyrius pin move** has no number until one is wanted, because 6.7.18 is the latest release.
It ships as its own patch, or with whatever release is next. The bench gate's A/B cannot span
a pin change, so a flag on that run stays red until someone explains it (standing rule 6). Scan for the changes that alter
what already-compiling code computes, diff the DCE list knowing it cannot see a
compiler-emitted call, and replay `ci.yml` in the runner's image (CHANGELOG [1.8.0], [1.8.1]).

---

## 1.11.1 — The TPM board on aarch64

1.11.0's edge paths run on x86 only, and kybernet ships aarch64 (standing rule 44).

- [ ] **Boot the TPM board on aarch64.** The measure, unlock, cap, `veritysetup open` and
      read-only mount execute only in the x86 harness's TPM pass. The aarch64 edge pass
      verifies with a Cyrius stand-in and boots no TPM. The new code is arch-neutral
      (`run_safe_cmd_timeout`, `sys_mount`, `sys_mkdir`), and rule 44 says that is not
      evidence. It needs arm64 builds of cryptsetup, veritysetup, tpm2-tools and systemd's
      LUKS2 token plugin with their libraries, from URLs that do not move:
      snapshot.debian.org's arm64 pool, sha256-pinned, because Alpine's mirror deletes a
      rebuilt version (rule 52). It also needs the pinned kernel's dm-crypt and dm-verity
      from its versioned modloop, QEMU's `tpm-tis-device` on `virt`, and an aarch64 arm in
      the pre-init's loader. `finit_module` is 273 there and the stdlib has no wrapper, and
      x86 273 is `set_robust_list`, so check the native number under `qemu-aarch64
      -strace` (rule 1).

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

**Gate: an AGNOS service that reads `LISTEN_FDS`, and then a design in argonaut.**

- [ ] **Socket activation.** `ServiceDefinition.socket_activation` has no setter and no
      reader, and nothing creates or passes a socket, so a config key would do nothing.
      No service reads `LISTEN_FDS`: daimon's fd-3 note is a comment. `LISTEN_PID` also
      needs the child's pid in envp, which is built before `kyb_pre_exec` runs, so kybernet
      cannot supply it through the hook. argonaut gates the same work.

**Gate: a sink for service output.**

- [ ] **`log_config`.** `LogConfig` has no setter and no reader, and a service's stdout and
      stderr go to `/dev/null`, so there is nothing to rotate and a key would do nothing.
      It needs the design argonaut's roadmap names: where output goes, and who rotates it.

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
