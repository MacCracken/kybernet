# Kybernet Roadmap

What is still to do. What shipped is in [CHANGELOG.md](../../CHANGELOG.md), and what is
true right now, gate counts included, is in [state.md](state.md). A finished item is
deleted from here, not ticked.

**Open: 18** (`grep -c '^- \[ \]'` against this file).

---

## Next

In the order they would be taken.

- [ ] **Every config load, SIGHUP included, costs about 4 bytes of arena per config
      byte.** `json_v_parse_buf` allocates 35,904 bytes to parse an 8,983-byte config
      (measured at 1.7.8), and PID 1's arena is never reset. The 256 KiB config limit
      bounds one reload at about 1 MiB. Fix: parse into a region the reload can release,
      `bayan_json_v_parse_ctx_a` into an `arena_new` arena, reset once the scalars and
      the credential are copied out.
- [ ] **`hashmap(3 set+4 get/has)` and `agent_config(new+get+set)` measure string-literal
      layout.** An unused string literal in `src/bench.cyr` moves `agent_config` from 110
      to 131–134 ns/op and `hashmap` from about 1,000 to 1,199 (CHANGELOG [1.7.7] has the
      experiment). Make them layout-insensitive, or exempt them in `LAYOUT_SENSITIVE` with
      the experiment in the same commit, as `strlen(52 chars)` is.
- [ ] **agnostik's `_hex_nibble` collides with sigil `hex.cyr`'s.** The behaviour is
      identical, so it is harmless, but it is the one duplicate-fn warning in the build
      that is not sigil's own `crypto_scratch` family. Rename it in agnostik, release, then
      move kybernet's agnostik pin.
- [ ] **Use the stdlib's `sys_ioctl` in `src/lib/termios.cyr`.** cyrius 6.5.36 added it
      (the resolved `2026-08-24-sys-ioctl-wrapper-missing.md` filing). `termios.cyr` still
      calls `syscall(SYS_IOCTL, …)` and says no wrapper exists, and so does standing
      rule 21.
- [ ] **Source comments that point at roadmap entries that no longer exist.** The
      sd_notify policy block above `handle_notify_msg` (`src/main.cyr`) says `WATCHDOG=1`
      and `MAINPID=` are refused and "roadmapped"; the code below it has handled both since
      1.6.8 and 1.6.10. `src/lib/edge_boot.cyr` sends readers to a "Blocked on hardware"
      section (the `veritysetup open`, LUKS and TPM work is under Harness work below) and
      still describes the unbounded `tpm_read_pcr` path, dead since 1.6.16.
      `src/lib/seccomp.cyr` cites "roadmap v1.6.0" and a hardware section for the aarch64
      numbers, which the aarch64 boot gate executes. Comments only.

## Needs a decision

- [ ] **Give the AGNOS default services a non-root uid.** `security.uid` /
      `security.gid` work end to end (1.6.9), and agnos-init makes the runtime
      directories (1.7.6), but nothing in the shipped config or in argonaut's
      `default_services` sets a uid, so every real service runs as root. Needs a uid per
      service (aethersafha, daimon, agnoshi, ...), agnos-init owning each service's
      runtime paths to match (`/run/agnos/agents` and `/run/agnos/plugins` are root-owned
      today), and the numeric ids in agnosticos' config. A service with
      `"seccomp": "basic"` and a uid works only because the drop precedes the filter:
      none of setuid/setgid/setgroups/setresuid are in that allowlist.
- [ ] **A dynamic memory ceiling for the KDF.** `m_cost` is capped statically at
      64 MiB. `system_free_memory()` exists (`~/.cyrius/lib/sys.cyr:458`), but a bound
      that depends on free RAM at boot makes a credential valid on one board and invalid
      on another. Revisit if a board under 512 MB appears.
- [ ] **Config keys for `socket_activation`, `log_config` and `required_for_modes`**, the
      three `ServiceDefinition` fields with none. Socket activation is a listening-socket
      protocol, not a scalar, and argonaut's defaults for the other two fit every shape
      kybernet ships. `resource_limits` stays unexposed on purpose (standing rule 14).

## Harness work

- [ ] **TPM attestation, PCR read and LUKS2 token unlock under `swtpm`.** QEMU exposes
      `tpm-tis` and `tpm-crb`, and `swtpm` and `tpm2-tools` are in Arch `extra`: a real
      TPM 2.0 with real PCRs and sealing, enough to exercise `tpm_detect`, the PCR read
      and compare, and a sealed LUKS2 token end to end. No harness pass covers them.
- [ ] **`veritysetup open` and a read-only mount of the verified target.** The edge
      passes prove `veritysetup verify` only. The host has `dm-verity.ko.zst` and
      `dm-mod`; the blocker is that Arch's initcpio busybox has no `insmod`/`modprobe`.
      Stage a static loader or the modules, or boot a kernel with DM built in. Never a
      module loader inside PID 1.

## Needs real hardware

- [ ] **RPi4 / NUC boot validation.**
- [ ] **Argon2 cost measured on real ARM.** TCG runs it (about 2.7 s at phase 6c), but
      its timings mean nothing, and the work cap is about time.

## Waiting on cyrius

Filed in the cyrius repo's `docs/development/issues/`.

- [ ] **`file_read_whole` has no ceiling, does not check its growth `alloc()`, and
      allocates a new 64 KiB buffer per call**
      (`2026-09-23-kybernet-file-read-whole-no-ceiling-unchecked-growth-alloc.md`). When it
      is fixed, config.json and the mount table move onto it and `src/lib/read_whole.cyr`
      goes.
- [ ] **The hashmap seed blocks PID 1 at phase 6 until the kernel CRNG seeds**, about
      0.9 s under TCG with no entropy source
      (`2026-09-23-kybernet-hashseed-getrandom-blocks-pid1-before-crng-seeds.md`). When a
      toolchain with the fix is pinned, the aarch64 gate's phase 4 → 6 span should drop
      by that much.
- [ ] **`fl_alloc` faults at address -12 when its mmap is refused**
      (`2026-09-23-kybernet-fl-alloc-unchecked-fl-mmap-faults-at-minus-12.md`). kybernet's
      Argon2 already avoids that path (standing rule 24), so nothing changes here when it
      lands.
- [ ] **The mixed-return warning misfires on a nullary `None()`**
      (`2026-09-23-kybernet-mixed-return-diagnostic-misfires-on-nullary-none.md`).
      `read_signal` returns a `Result` since 1.7.0, so nothing changes here when it lands.

## Waiting on a consumer

- [ ] **Control socket for agnoshi runtime commands**, once an agnoshi consumer drives
      the protocol shape.
- [ ] **Binary signing on release**, once libro signing and timestamping are driven from
      outside kybernet.
