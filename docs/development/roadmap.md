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
- [ ] **Move config.json and the mount table onto the stdlib's `file_read_whole_into`, and
      delete `src/lib/read_whole.cyr`.** cyrius 6.6.7 resolved the filing behind the
      stopgap (`2026-09-23-kybernet-file-read-whole-no-ceiling-unchecked-growth-alloc.md`,
      archived): every allocation is checked, growth is clamped, and `_into(rb, path, max)`
      reads into a kept buffer. Check that it allocates nothing per call once the buffer
      exists, since PID 1's arena is never reset, before retiring the stopgap.
- [ ] **`json_v_obj_get` is deprecated in the bayan that cyrius 6.6.20 folds.** 21 call
      sites (20 in `src/lib/svc_config.cyr`, 1 in `src/main.cyr`) warn on every build. The
      alias forwards to `bayan_json_v_obj_get_by_cstr`; every key kybernet passes is a
      literal, so the rename is mechanical.
- [ ] **cyrius 6.6.20 flags `streq(str_data(…), …)`**: a `Str`'s bytes are not
      NUL-terminated at its length. Four sites in `src/main.cyr` compare service names
      that way (two in the default-service merge, two in dependency checks) and four in
      `src/test.cyr`. Find out whether every name reaching them is NUL-terminated (bayan's
      string values, argonaut's defaults) or compare as `Str`.

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
- [ ] **PID 1 waits about 0.9 s for entropy at the first service start on an RNG-less
      board.** cyrius 6.6.7 stopped the stdlib hash seed blocking at phase 6, and the wait
      moved to libro's `uuid_v4` (`getrandom(…, 0)`), reached from argonaut's
      `audit_log_record` on the first `init_start_service`: 914 ms under TCG at 1.7.10
      (standing rule 51). libro also exits 74 there if `getrandom` fails, which in PID 1 is
      a panic. Decide in libro whether an audit record's id needs a seeded CRNG, or whether
      it can draw with `GRND_INSECURE` as the hash seed does.
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

- [ ] **x86 DCE stops compacting past 4,096 dead-code runs, and agnos-init crossed it at
      1.7.10** (`2026-10-15-kybernet-dce-compaction-cap-agnos-init.md`). agnos-init links
      the whole dependency set and uses little of it: 4,180 unreachable fns, so the dead
      code is NOP-filled but kept, and the x86_64 binary went from 248,440 to 1,574,640
      bytes. kybernet itself has 3,351 and still compacts. Nothing to do here when it is
      fixed beyond recording the size.

## Waiting on a consumer

- [ ] **Control socket for agnoshi runtime commands**, once an agnoshi consumer drives
      the protocol shape.
- [ ] **Binary signing on release**, once libro signing and timestamping are driven from
      outside kybernet.
