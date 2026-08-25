# Kybernet Roadmap

**Current: v1.5.9** — [CHANGELOG.md](../../CHANGELOG.md) is the record of what each
release actually did. This file carries only what is **not** done.

Everything below came out of a deliberate sweep of the tree after 1.5.9 shipped, and
every item names the file that proves it. Where a claim was verified by running
something rather than by reading, it says so.

**Pins:** `v1.6.x` is scoped work with a clear finish line. `v1.x.x` is real but needs
a design decision or is too large to date. The last two sections are blocked on
something outside this repo.

`cyrius lint` reports **0 untracked deferrals** across all 23 source files as of this
revision — every deferral comment in the tree now cross-references this file or a
CHANGELOG entry. Keeping that at zero is a v1.6.1 item, because the linter is advisory
in CI today.

---

## v1.6.0 — the confinement path does not confine

Four defects in the security path 1.4.3–1.5.2 built. Each is reachable from a
documented config key, none is covered by a gate, and the first is not a degradation —
it is a guarantee of failure.

- [ ] **`"seccomp": "basic"` kills every service it is applied to.**
      `seccomp_basic_service()` (`src/lib/seccomp.cyr:264`) allowlists 37 syscalls.
      **`execve` is not one of them** — `BS_EXECVE` exists in neither `#ifdef` arm —
      and the default action is `SECCOMP_RET_KILL_PROCESS` (`seccomp.cyr:127`).
      `kyb_pre_exec` loads the filter as step 4 and argonaut execs on the very next
      line (`lib/argonaut_process_mgmt.cyr:443-449`).

      **Verified by execution**, through kybernet's own code in `kyb_pre_exec`'s order
      (`set_no_new_privs()` → `seccomp_apply(seccomp_basic_service())` →
      `execve("/bin/true")`): *killed by SIGSYS (31)*. A dynamically linked binary
      needs at least `execve`, `access`, `newfstatat`, `pread64`, `prlimit64` before it
      reaches `main`.

      README advertises the key (`README.md:89-95`). Nothing catches it because
      `grep -rn seccomp qemu/` returns nothing — no fixture sets it, so
      `kyb_policy_kind` is `SECCOMP_NONE` on every gated boot and `seccomp_apply` has
      never executed in a release gate on either arch. **The deliverable is the
      fixture, not the syscall list** — the preset's real footprint is only
      discoverable empirically.

- [ ] **Landlock fails OPEN inside a hook documented as fail-closed.**
      `sandbox.cyr:151-163`/`:237-248` return `Ok(1)` for "kernel has no Landlock";
      `service_sandbox.cyr:117-119` tests only `is_err_result`. On a pre-5.13 kernel a
      service carrying an explicit rule list starts with **no filesystem confinement**
      and the hook reports success — the outcome that file's own header calls "worse
      than not running it", and README says "fails closed".

- [ ] **`_stage_verify_rootfs` re-keys a boot refusal to `_eb_dmverity_supported`,
      which standing rule 18 forbids in as many words.** `boot_stages.cyr:68-76` fails
      a *required* boot step when the kernel cannot instantiate a dm target — exactly
      the refusal 1.5.7 removed from `edge_boot.cyr:437-445` because it failed boards
      that verify perfectly well. Concrete case: edge board, no dm module, no
      `veritysetup`. Phase 6c logs "not verified" and continues; phase 7 then drops to
      the emergency shell. The honest signal exists and is ignored —
      `edge_boot_verity_ok()` (`edge_boot.cyr:566`) returns the real
      `veritysetup verify` result and has **zero callers**.

- [ ] **`edge_apply_defaults` clears 3 of `EdgeBootConfig`'s 5 fields**
      (`svc_config.cyr:254-259`), so `max_boot_ms` keeps argonaut's **3000** and
      `pcr_bindings` keeps `"7+14"` on every path — absent block, partial block, and
      the malformed-block reset. An operator who never set a budget can be refused and
      **powered off** by one: `veritysetup verify` hashes the whole rootfs against an
      inherited 3 s deadline. This is rule 19's exact sentence — "never one they
      inherit from a struct default they never saw" — and 1.5.7 fixed it for the three
      booleans and stopped. The edge fixture sets `"max_boot_ms": 20000`, the one value
      that hides it.

- [ ] **A malformed config on SIGHUP silently swaps in defaults and drops the emergency
      credential.** `reload_config` cannot fail: `load_config()` falls back to
      `argonaut_config_default()` on a parse error and returns it, so a truncated or
      mistyped `/etc/kybernet/config.json` replaces the live config wholesale — and
      because `g_emerg_hash` is a side effect of the same function, the recovery
      credential goes with it. 1.5.9 made that change *visible* in the log; it did not
      make the reload refuse. A reload that cannot fail should at least keep the old
      config when the new one does not parse.
- [ ] **The config read is a silent 16 KiB cliff.** `load_config` reads into
      `alloc(16384)` and `file_read_all` truncates without saying so, so a config that
      grows past the buffer becomes a JSON parse error and takes the defaults path
      above. Needs a size check and a readable error.
- [ ] **`"enabled": false` is counted as a boot failure.** A service explicitly
      disabled by the operator is reported as a failed start, and enough of them can
      route the board to the emergency shell. Disabled is not failed.
- [ ] **Service names are not sanitized on the teardown paths.** The 2026-08-24 audit's
      MEDIUM-3 added validation on the create path; the teardown sweep and the registry
      still accept a name with `/` or `..` in it. Same traversal, different door.

---

## v1.6.1 — gates that cannot fail

The gates are the reason to trust any of the above. Several cannot currently go red.

- [ ] **The bench regression gate is never run by CI.** `grep -rn bench-history
      .github/` returns nothing; CI runs bare `cyrius bench` under
      `continue-on-error: true`. Standing rule 6 calls it a release gate that "blocks
      the cut" — today that is human discipline only, and `release.yml` adds no step.
- [ ] **The QEMU harness cannot fail the build.** `ci.yml:249` is
      `continue-on-error: true`, and an unreadable `/dev/kvm` sets `skip=1` so every
      later step no-ops and the job goes green having executed nothing. The workflow
      comment carries the standing instruction ("flip it off … once reliably green")
      with no tracking item. Rule 23 says this is the only gate that executes a reactor
      iteration.
- [ ] **28 of the harness's 46 assertions never run in CI.** The qemu job installs
      `qemu-system-x86 cpio` only — no `cryptsetup-bin`, no OpenSSL 3.2 — so
      `build-initramfs.sh` drops all three edge/auth fixtures and passes 3, 4a and 4b
      skip. Rule 26 says both credential formats are gated; in CI neither is. One
      `apt-get` line fixes the verity half.
- [ ] **Turn `cyrius lint` into a hard gate — its untracked-deferral detector is the
      thing that keeps this file honest, and it is disabled.** `ci.yml:72-75` keeps Lint
      advisory "once the standing dead-code warnings are addressed". Measured across all
      23 files: **0 dead-code warnings** — the stated blocker does not exist.
      The 12 untracked deferrals it did find (edge_boot 5, eventloop 4, mount 1,
      seccomp 1, termios 1) **are now 0**: every one has been cross-referenced to this
      roadmap or to a CHANGELOG entry, which is what the linter asks for. Note it
      matches **per line** — the reference has to share the line with the deferral word.
      What is left before `continue-on-error` can come off: **23 warnings, all
      over-length lines in `src/test.cyr`.**
- [ ] **CI's "raw system()" scan is vacuous.** `ci.yml:217` passes `\bsystem\s*\(` to
      BRE `grep`, an unclosed group; grep exits 2, stderr is discarded, and the check
      always reports clean. The neighbouring `syscall(59/60)` checks do work.
- [ ] **The aarch64 build can silently no-op** (`ci.yml:99-102` → `exit 0` + warning),
      and `release.yml:100-102` then publishes a release with no aarch64 artifact.
- [ ] **`cyrius test` asserts `0 failed` but not the count**, so a suite that silently
      shrinks still passes. `bench-history.sh` has the same hole — it never compares
      the recorded benchmark count against the previous run, and two benches self-skip
      under root.
- [ ] **No gate has ever executed `handle_health_tick` or `handle_watchdog_tick`.** No
      fixture carries a `health_check` block, so both drain empty vecs forever and every
      1.5.4 restart-on-threshold and watchdog path is unexercised. Corollary worth
      stating plainly: **with no `health_check` configured there is no watchdog at all.**
- [ ] **`test_reload_config_is_narrow` never calls `reload_config`**
      (`test.cyr:743-768`) — it asserts that its own two `store64`s did what stores do.
      Root cause: `test.cyr` includes `src/lib/*` but not `src/main.cyr`, so **none of
      main.cyr's 25 functions is under unit test.** The pure helpers (`_read_line_fd`'s
      new `-2` overflow path, `_emerg_envp`'s 7-slot bound) are trivially extractable.

- [ ] **The edge gate skips on exactly the regression class it exists to catch.** If
      `veritysetup` is missing on the build host the fixtures are dropped and the pass
      reports SKIP — which is correct locally and useless as a gate, because a change
      that breaks verity detection produces the same SKIP as a machine without the tool.
- [ ] **The structured-logging path has zero coverage and its init failure is invisible
      for the life of the boot.** `slog_init` failing leaves `g_log_fd` at 0 and nothing
      says so again.
- [ ] **There is no Argon2 benchmark on x86_64 either.** 1.5.9's work cap is defended by
      one-off measurements taken during that release and never re-run; `bench.cyr` has
      no credential entry, so a parameter or toolchain change that doubles the cost
      passes every gate silently.
- [ ] **Two orphaned QEMU scripts.** `boot-crash-test.sh` and `boot-shutdown-test.sh`
      are busybox-based, run nothing from `build/`, cannot fail, and use less than the
      512 MB that rule 8 says `alloc_init` needs. Wire them or delete them.

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

## Blocked on hardware (was v1.5.10 / v1.2.2)

Not a version pin — these need a real device-mapper stack or a real TPM, and the QEMU
gate provably cannot cover them: the harness kernel has `CONFIG_BLK_DEV_DM=m`, no
`CONFIG_DM_INIT`, and the initramfs busybox has no `insmod`. Putting a module loader
inside PID 1 to make a test pass is scaffolding in the one process that must never
crash.

- [ ] `veritysetup open` + read-only mount of the verified target — catches corruption
      at READ time, not just once at boot
- [ ] LUKS unlock against a TPM-sealed LUKS2 token
- [ ] PCR baseline **enforcement**, rooted in TPM sealing rather than in a userspace tool
      that lives on the filesystem being verified. (Comparison is implemented and called;
      only enforcement is deferred — `edge_boot.cyr:28-40` is stale on this.)
- [ ] RPi4 / NUC boot validation
- [ ] **Argon2 has never been measured on ARM.** Every timing behind 1.5.9's work cap is
      x86_64; the RPi4 figures are extrapolated and `benches/history.csv` has no aarch64
      row. The cross-build is release-gated but never *executed*.
- [ ] **The aarch64 seccomp table has never been executed anywhere.** Eight numbers
      (`mprotect`, `rt_sigreturn`, `accept`, `sendto`, `sigaltstack`, `clock_gettime`,
      `set_robust_list`, `rseq`) were taken from `asm-generic/unistd.h` rather than the
      stdlib. They check out on inspection; no gate has run them. Folds into v1.6.0's
      fixture work if an aarch64 QEMU pass ever exists.

---

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
