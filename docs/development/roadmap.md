# Kybernet Roadmap

**Current: v1.6.1** — [CHANGELOG.md](../../CHANGELOG.md) is the record of what each
release actually did. This file carries only what is **not** done.

Everything below came out of a deliberate sweep of the tree after 1.5.9 shipped;
v1.6.0 and v1.6.1 closed the first two sections — twenty-two items. Every item names the file that
proves it. Where a claim was verified by running
something rather than by reading, it says so.

**Pins:** `v1.6.x` is scoped work with a clear finish line. `v1.x.x` is real but needs
a design decision or is too large to date. The last two sections are blocked on
something outside this repo.

`cyrius lint` reports **0 untracked deferrals and 0 warnings** across the tree, and as
of v1.6.1 **CI fails on either** — so this file cannot quietly drift back into fiction.

---

## v1.6.2 — code that does nothing, and docs that say it does

- [ ] **Boot phase 6b is a provable no-op.** `execute_tmpfiles()` (`main.cyr:316-361`)
      iterates `config_tmpfiles(cfg)`, which only `argonaut_config_default()` ever
      writes — as an empty `vec_new()`. No `tmpfiles` key is parsed anywhere in
      `src/lib/`, so the loop body has never executed. It would not work if it did:
      main.cyr declares its own `enum TmpfileType` that silently collides with
      argonaut's (`TMP_TOUCH == TMP_DEVICE == 2`; cyrius does not warn on duplicate
      enums), reads `mode` at the offset where argonaut keeps `target`, and hands a
      boxed `Str` to `sys_mkdir` as a cstr (rule 3). Advertised at `main.cyr:10` and
      `overview.md:55`. Either build it or delete the phase and the enum.
- [ ] **sd_notify is received, classified, logged, and discarded.** `handle_notify_msg`
      (`main.cyr:1080-1099`) is five `klog` calls and a `default: return 0`; nothing
      reaches `g_init`. `READY=1` marks nothing ready, `WATCHDOG=1` refreshes nothing
      (a correctly pinging service is still killed on schedule), `MAINPID=` is not
      parsed, and **any process on the box can forge any message** — `notify_read`
      passes a NULL `src_addr` and the socket never sets `SO_PASSCRED`. argonaut already
      ships the finished version (`notify_try_recv_authenticated`, `notify_parse`,
      `init_notify_bind`); all of it has zero kybernet call sites. README and
      `overview.md` advertise the feature. argonaut deferred its own half of the
      propagation, so this is a two-repo item.
- [ ] **`log_to_console` is parsed, stored, copied on reload, and never acted upon.**
      `config_log_console` has two readers in the tree: its definition and the reload
      copy. `klog`/`klog2` write to `STDERR_FD` unconditionally. The 1.5.0 comment says
      the value "was ignored entirely" — only the *spelling* was fixed.
- [ ] **`boot_timeout_ms` and every per-stage `timeout_ms` are parsed and never
      enforced.** No reader of `config_boot_timeout` outside the reload copy; `step + 24`
      is never loaded. A boot stage can hang indefinitely with its timeout sitting unread
      beside it. Enforcing it under PID 1 needs a real mechanism — the reactor is not
      running at phase 7 — so at minimum say the values are advisory.
- [ ] **Orphan reaping is correct but completely invisible, and unattributable.**
      argonaut's `proc_table_reap_orphans()` does `waitpid(-1, WNOHANG)` in a loop and
      **discards the count it computes**; `init_reap_services` calls it and ignores the
      return. Since kybernet calls `init_reap_services` before its own `reap_and_log`,
      argonaut collects every orphan first — so a service leaking children produces no
      evidence anywhere, and kybernet's own reaper is unreachable on that path. The
      number already exists; it just needs returning and logging. An argonaut change
      plus a consumer bump, and then the `kyb-orphan` fixture (added at 1.6.1) becomes
      assertable instead of merely exercised.
- [ ] **The cgroup teardown sweep kills and immediately `rmdir`s, without waiting for
      the processes to actually die.** `remove_all_service_cgroups` calls `kill_cgroup(nm)`
      then `remove_service_cgroup(nm)` on the next line; a SIGKILL is asynchronous, so the
      `rmdir` can hit a still-populated cgroup and return EBUSY. Observed at v1.6.1: with
      a child alive in one service's cgroup at shutdown, `services parsed: 9` but
      `removed service cgroups: 8`, and the directory is leaked. The count is logged, so
      the symptom is visible — but nothing acts on it and no gate asserts the two numbers
      match. Wants a bounded wait on `cgroup.procs` emptying (or a retry) between the two
      calls, and a harness assertion that created == removed.
- [ ] **Dead chains to delete or wire.** `cgroup_setup_agent` (zero references anywhere)
      → `move_to_cgroup` + `cgroup_apply_resource_limits`, all superseded at 1.5.5 by the
      child-side `_kyb_join_cgroup`; `any_failures` (`reaper.cyr:69`);
      `edge_boot_elapsed_ms` / `edge_boot_verity_ok` / `edge_boot_pcr_mismatches` (zero
      callers, and two comments claim "main reads these … in the boot summary" — there is
      no boot summary); `edge_hash_device` / `edge_luks_device` / `edge_expected_pcrs`.
      `src/tmpfiles.cyr` is the one argonaut module with no call site in the entire link
      set — one manifest line.
- [ ] **Stale comments that mislead about live behaviour.** `seccomp.cyr:228` says the
      module "is not yet wired into the boot path" — it has been since 1.4.3, and that
      claim is what let the aarch64 validation lapse. `edge_boot.cyr:218-219` names
      `_eb_dmverity_supported` as unbounded; 1.5.7 gave it `run_safe_cmd_timeout(cmd,
      3000)`. `edge_boot.cyr:40,287` point at "roadmap v1.2.2", renumbered twice since.
      CLAUDE.md rule 9 justifies the `if`-ladder as "the per-service Landlock path"; the
      live path is `sandbox_from_config` → `_access_to_flags`, and `_ll_access_to_kernel`
      is reached only from `sandbox_from_ruleset`, which nothing but a benchmark calls.

- [ ] **`notify.cyr` hand-rolls a socket syscall table whose stated fold-out trigger has
      fired.** The header promises "fold these out when `sys_socket`/`sys_bind`/
      `sys_recvfrom` land in the stdlib". **They have landed** —
      `~/.cyrius/lib/syscalls_linux_common.cyr:470`, `:521`, `:531`. This is no longer
      an upstream wait; it is deletable code.
- [ ] **A standing `duplicate symbol … conflicting value` warning on every build.**
      argonaut's `enum SocketType { SOCK_STREAM; SOCK_DGRAM; SOCK_SEQPACKET; }` is
      unvalued, so cyrius numbers it from **0** while the kernel and
      `~/.cyrius/lib/net.cyr` use 1/2. Harmless today only because every call site in
      both repos passes the literals — argonaut's own `sys_socket(1, 2, 0)` included —
      so the enum is decorative. It is still a trap for the next person who uses it, and
      CLAUDE.md's capability rule says a `conflicting value` warning means the two
      definitions have diverged. Fix in argonaut: give the enum kernel values or drop
      it. A build with a permanent warning trains people to ignore warnings.
- [ ] **`health_check.interval_ms` does not control polling frequency.** The key is
      parsed onto the `HealthCheck` struct, but the reactor polls on its own fixed timer,
      so a service asking for a 5 s check gets the global interval.
- [ ] **Unbounded arena growth on two reactor hot paths** — the 1.4.2 MEDIUM-7 class,
      reopened. In the one arena rule 8 says PID 1 never resets.

---

## v1.x.x — real, but needs a decision or is too large to date

- [ ] **No service can run as non-root.** The whole uid/gid half of `privdrop.cyr` is
      unreachable: `secure_from_context` and `has_cap` have no references anywhere,
      `privdrop_from_context` is called only by the former, `drop_privileges` only by
      those two. There is no `user`/`group` key in `svc_apply_security_json`, and
      argonaut's `ServiceDefinition` has no such field either — the agnostik
      `security_context` bridge is a bridge to nothing. Wants a config key, numeric-uid
      resolution (this tree has no `/etc/passwd` reader), a `drop_privileges` call as
      step 5 of `kyb_pre_exec` — after Landlock, before seccomp — and a fixture that
      prints its own `Uid:`.
- [ ] **The audit chain never rotates and is never drained.** Measured, not estimated:
      **242 arena bytes per record**, `max_capacity` 0 so `_chain_auto_rotate` returns
      immediately, 2000 records → 2000 retained, 0 rotations. argonaut writes on
      kybernet's behalf once per health-checked service per tick, so at the shipped 30 s
      interval that is ~0.68 MB/day/service in the one arena rule 8 says PID 1 never
      resets. Latent only because no shipped config uses `health_check`; it arms the
      first time an operator adds one.
- [ ] **A P(-1) audit.** The last was cut at 1.4.2, seven releases ago. Everything that
      is now the attack surface — `edge_boot`'s exec path, `emergency_auth`'s KDF, the
      security/limits parsers, `restart_queue`, `termios`, and the live
      seccomp/Landlock/capset path — landed after it. Both prior audits found CRITICALs
      every gate was blind to.
- [ ] **Landlock is pinned to ABI 1.** `_landlock_handled_mask()` covers bits 0-12, so
      `REFER` (ABI 2), `TRUNCATE` (ABI 3) and `IOCTL_DEV` (ABI 5) are unrestricted for
      every sandboxed service. The 8-byte `landlock_ruleset_attr` pins ABI 1
      deliberately; nothing records that as a scope decision. Wants a version probe.
- [ ] **No hard CPU bandwidth cap.** kybernet can express `cpu.weight` (relative share)
      but not `cpu.max`, so a service cannot be capped at 0.5 CPU. Mechanical blocker:
      `_cgroup_write_u64` (`cgroup.cyr:425`) emits one integer and `cpu.max` takes
      `"<quota> <period>"`. The same block also documents "plain integers only — no
      `64M` suffixes".
- [ ] **Move the emergency credential out of the world-readable config.**
      `/etc/kybernet/emergency.cred` at 0600 costs almost nothing and defeats a local
      unprivileged reader. It does **not** defeat the image-holder adversary, which is
      why it complements the 1.5.9 KDF rather than replacing it. Changes the config
      surface, so it is its own release.
- [ ] **A dynamic memory ceiling for the KDF.** 1.5.9 caps `m_cost` statically at
      64 MiB, the bottom edge of the band where an anonymous mmap succeeds and the touch
      OOMs. `system_free_memory()` exists (`~/.cyrius/lib/sys.cyr:366`). Deliberately not
      shipped: a bound that depends on free RAM at boot makes a credential valid on one
      board and invalid on another. Revisit if a board under 512 MB appears.

- [ ] **Seven `ServiceDefinition` fields have no config key at all.** `ready_check` and
      `restart_config` are the notable two: argonaut supports them, kybernet's parser
      offers no way to set them, so the readiness and restart-policy surfaces are
      argonaut defaults on every AGNOS board. Needs a decision about how much of
      argonaut's model kybernet intends to expose.

---

## Needs real silicon — and it is only two things

⚠ **This section used to hold six items and claim all six were hardware-blocked. Four of
them were not** — they were harness investment mislabelled as a hardware wall, which is
the same shape as the "blocked upstream" framing the 2026-08-24 audit retracted for
argonaut. Checked, not assumed:

- [ ] **RPi4 / NUC boot validation.** Genuinely needs the board.
- [ ] **Argon2 cost measured on real ARM.** Genuinely needs ARM silicon or an ARM CI
      runner — `qemu-system-aarch64` under TCG will run the code but its *timings* mean
      nothing, and timing is the whole point of the 1.5.9 work cap. Correctness on
      aarch64 is a different question and is **not** blocked (see v1.6.1).

### Reclassified — harness work, not hardware

Moved into the v1.6.1 gate line. Recording why here so the claim is not re-made:

- **TPM attestation, PCR read, and LUKS2 token unlock.** This QEMU already exposes
  `tpm-tis` and `tpm-crb` (`qemu-system-x86_64 -device help`), and `swtpm` (0.10.1) and
  `tpm2-tools` (5.8) are both in Arch `extra`. `swtpm` is a real TPM 2.0 with real PCRs
  and real sealing — enough to exercise `tpm_detect`, `tpm_read_pcr`, PCR comparison,
  and a sealed LUKS2 token end to end. What a board would add beyond that is a *trusted*
  root, not a *testable* one.
- **`veritysetup open` + read-only mount of the verified target.** `dm-verity.ko.zst`
  and `dm-mod` are present on this host under `/usr/lib/modules/$(uname -r)/`. The
  actual blocker is narrower than "no device-mapper": Arch's `/usr/lib/initcpio/busybox`
  ships **no `insmod`/`modprobe`** (`busybox --list` confirms), so the initramfs has no
  way to load them. Stage a static loader or the modules, or boot a kernel with DM
  built in. Note this does **not** mean putting a module loader inside PID 1 — that
  remains scaffolding in the one process that must never crash, and stays rejected.
- **Executing the aarch64 seccomp table.** `qemu-system-aarch64` is installed. Whether
  the eight hand-copied syscall numbers are right is a correctness question TCG answers
  perfectly well.

## Blocked upstream / on an external consumer

- [ ] **sigil's `exec_capture` / `exec_vec` fail open and wait unbounded.**
      `agnosys_run_capture` checks only `n < 0`, so an absent or failing `tpm2_pcrread`
      returns `Ok(0)` and sigil zero-fills every PCR — an attestation "pass" from a tool
      that never ran. `agnosys_run_checked` uses `exec_vec`, which standing rule 17
      forbids outright. kybernet's `tpm_read_pcr` call (`edge_boot.cyr:473`) is the last
      unbounded exec in PID 1; `edge_boot.cyr:222` declines it as "not kybernet's to add".
      **That framing is the mistake the 2026-08-24 audit already retracted once** —
      HIGH-1 was filed deferred as "blocked upstream", and the correct fix was to add the
      seam to argonaut. sigil is first-party. This is a sigil release, then a kybernet
      bump.
- [ ] **cyrius stdlib filings, genuinely off-limits from here.** ioctl / termios /
      poll — `2026-08-24-sys-ioctl-wrapper-missing.md`, behind `src/lib/termios.cyr` and
      `_read_line_fd`'s `sleep_ms` poll loop. And `fl_alloc`'s unchecked `_fl_mmap`
      return in two places (`freelist.cyr:404-406`, `:231-241`), which is why sigil's
      own `if (mem == 0)` guards are dead code.
      (The socket-wrapper filing is **closed** — `sys_socket`/`sys_bind`/`sys_recvfrom`
      have landed, so `notify.cyr`'s hand-rolled table moved to v1.6.2 as deletable
      code rather than an upstream wait.)
- [ ] **Control socket for agnoshi runtime commands** — a separate transport surface,
      pinned until an agnoshi consumer drives the protocol shape.
- [ ] **Binary signing on release** — pinned until libro signing/timestamping is
      consumer-driven from outside kybernet's tree.

---

## History

One line per release. Detail lives in [CHANGELOG.md](../../CHANGELOG.md).

- **v1.6.1** — Gates that could not fail, and the kernel panic the first new one found.
  A fixture with a failing health check made PID 1 SIGSEGV on its first tick: argonaut's
  `init_enforce_watchdog` passed a cstr to `proc_table_pid`, which takes a boxed `Str` —
  and the function had never executed in any release of either repo, because nothing had
  ever configured a `health_check` (so there was no watchdog at all). Fixed in argonaut
  1.13.3 with a test verified to SIGSEGV on the unfixed source. Six gates made able to go
  red: the QEMU harness (was `continue-on-error`, and skipped silently without KVM), the
  bench gate (never run by CI at all), the aarch64 build (no-oped, and release shipped
  without the artifact), the test count (a shrinking suite passed), CI's `raw system()`
  scan (BRE vs ERE — always "clean"), and `cyrius lint`, now hard at 0 deferrals and 0
  warnings. 28 of the harness assertions had never run in CI for want of two apt packages;
  `HARNESS_STRICT=1` makes a skip a failure there. New coverage for orphan reaping,
  structured logging, main.cyr's extracted helpers, and the credential path. Retired two
  broken orphan scripts. 632 tests, 45 harness properties.
- **v1.6.0** — The confinement path did not confine, and one of the four ways was
  fatal: `"seccomp": "basic"` had no `execve` on its 37-syscall allowlist and denied
  with `KILL_PROCESS`, so it killed every service it was applied to from 1.4.3 onward
  (verified: SIGSYS). The allowlist gained the measured exec+loader set and the default
  action became `ERRNO(EPERM)` — a hand list is never complete, so an omission must
  degrade rather than execute. Landlock now fails closed instead of reporting success on
  a kernel without it; `_stage_verify_rootfs` is keyed on the verification RESULT (rule
  18) instead of the dm probe; `edge_apply_defaults` clears all five fields so nobody
  inherits a 3-second poweroff budget; a malformed config no longer replaces a running
  one on SIGHUP, and the silent 16 KiB read cliff is a readable error; `enabled: false`
  is skipped rather than counted as a failure that drops the board to an emergency
  shell; unsafe service names are refused at load and on kill/rmdir. New `kyb-seccomp`
  harness fixture — its absence is why this shipped for three releases. 608 tests, 44
  harness properties.
- **v1.5.9** — Salted, memory-hard emergency credential. Argon2id in a self-describing
  `v1$t$m$p$salt$tag` record (agnostic's format, adopted rather than invented);
  `scripts/mkcred.sh` over `openssl kdf`, byte-identical to sigil; parameter bounds are
  rejections, never clamps. sigil 3.12.10 moved the Argon2 lane onto the caller's arena
  (+377 KB link → +25 KB) and took the toolchain 6.5.21 → 6.5.35. Legacy digests still
  verify; both formats gated. 567 tests, 42 harness properties.
- **v1.5.8** — The emergency-auth gate did not work at all: the prompt read fd 0, which
  is `/dev/null` by design, so no password could ever authenticate — and 1.5.7's forced
  `require_auth` made that a reboot loop. Interactive reads now open their own console;
  echo suppression in a new `termios.cyr`; a rejection halts instead of rebooting.
- **v1.5.7** — Edge boot actually verifies, via `veritysetup verify` (pure userspace). An
  absent `edge` block now means detection-only rather than an un-overridable demand.
- **v1.5.6** — Consumed argonaut 1.13.1's arch repairs; no forked service had its own
  session on ARM. Restored two dropped commit pins.
- **v1.5.5** — Cgroup limits actually applied: no controller was ever enabled, and
  `ResourceLimits` is defined twice with incompatible layouts.
- **v1.5.4** — Rust port complete, `rust-old/` removed. Eight dropped behaviours closed,
  including deferred restarts and `$NOTIFY_SOCKET`.
- **v1.5.3** — Lifecycle cleanup: cgroup teardown wired, `reload_config` narrowed,
  refusals reach dmesg.
- **v1.5.2** — Per-service security profiles as config data; capability numbers corrected
  across agnostik and argonaut (both disagreed with the kernel).
- **v1.5.1** — Boot stages that do something; `execute_boot_stage` had been `return 1`
  for all eleven arms.
- **v1.5.0** — Config-driven services; three defects in a start path that had never run.
- **v1.4.3** — 686 lines of security code reachable from nothing reached a production
  path, via argonaut 1.9.0's pre-exec hook.
- **v1.4.2** — P(-1) audit: 20 findings, both CRITICALs gate-invisible (spinning
  timerfds, an x86_64-only `epoll_event` layout). Added the reactor gate.
- **v1.4.1** — Toolchain 6.5.35 + dependency refresh; retired the `path` overrides that
  made tag pins inert.
- **v1.4.0** — THIN sigil surface: 14.35 MB → 0.96 MB.
- **v1.3.x** — Benchmarks became a regression-gated release gate; the 6.0.x → 6.2.11
  leap; agnosys dropped for sigil.
- **v1.2.x** — Edge boot scaffolding: capability detection, PCR reads, the flag gate.
- **v1.1.x** — Modernization: the QEMU PID-1 harness, cgroup path precomputation, the
  fourth P(-1) audit.
- **v1.0.x** — The Rust → Cyrius port and its toolchain rebases.

⚠ The roadmap ITEMS once numbered v1.2.1 and v1.2.2 were never what shipped under those
tags. That work is now v1.5.7 (real verification) and the hardware section above.

**Closed and removed from this file:** the v1.5.9 KDF items (all five shipped);
`drop_cap_sets()` privileged validation (the 1.5.2 `kyb-confined` harness service asserts
`CapEff=0` / `NoNewPrivs=1` as real root under QEMU).
