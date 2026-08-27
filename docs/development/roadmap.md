# Kybernet Roadmap

**Current: v1.6.12** — [CHANGELOG.md](../../CHANGELOG.md) is the record of what each
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

## v1.6.13 — the P(-1) audit

- [ ] **A P(-1) audit.** The last was cut at 1.4.2, **ten releases ago**. Everything that
      is now the attack surface — `edge_boot`'s exec path, `emergency_auth`'s KDF, the
      security/limits parsers, `restart_queue`, `termios`, and the live
      seccomp/Landlock/capset path — landed after it. Both prior audits found CRITICALs
      every gate was blind to.
- [ ] **`cyrius deps --verify` cannot catch a STALE COMMITTED LOCK, because CI resolves
      first.** Found while cutting 1.6.12, and it very nearly shipped. The `Resolve
      dependencies` step runs `cyrius deps`, which **rewrites `cyrius.lock` from disk**;
      the next step then runs `cyrius deps --verify` against the file it just wrote. That
      is tautological — it verifies the resolve against itself and reports "70 verified,
      0 failed" no matter what was committed. Concretely: 1.6.12 was committed with
      `cyrius.cyml` at argonaut `tag = "1.13.8"` and a `cyrius.lock` still pinning
      1.13.7's commit (`7204b60`), because the tag did not exist yet at commit time. CI
      would have gone green on that tree. This is the same shape CLAUDE.md already
      documents for `path` overrides ("the lock is written from disk, so `deps --verify`
      can't catch it") — but the `path` note frames it as a hazard of that one feature,
      when it is a property of the STEP ORDER and applies to every release. A gate that
      would catch it: stash the committed lock, resolve, and diff. **All of this was
      run, not reasoned** — against the real stale tree the resolve rewrote
      `7204b60` to `8e98429` in place and verify still said "70 verified, 0 failed".
      ⚠ **A naive `diff` is a FALSE POSITIVE and must not be shipped:** `cyrius deps`
      does not emit the lock's hash lines in a stable ORDER, so a byte diff reports
      drift on a perfectly correct lock. Compare sorted —
      `diff -q <(sort "$SAVED") <(sort cyrius.lock)` — which was verified to pass on the
      correct lock (twice, for stability), fail on the stale one, and not false-positive.
      Left for 1.6.13 rather than folded into 1.6.12, whose scope is the redep itself.

---

## v1.6.x — code that does nothing, and docs that say it does

- [ ] **Port `agnos-init.sh`'s `setup_directories()` to a kybernet oneshot service.**
      Replaces the deleted phase 6b (1.6.2), and it is the *real* form of the need
      phase 6b pretended to serve. `/run` is a fresh tmpfs on every boot
      (`mount.cyr`), so `/run/agnos/{agents,plugins}` and `/run/user/1000` cannot be
      shipped in an image — and `aethersafha`, which kybernet starts **by default** in
      `BOOT_DESKTOP` (argonaut `services.cyr:216`), binds sockets in both
      (`aethersafha/src/apps.cyr:381`, `plugin_host.cyr:468`) and contains no `mkdir`.
      Today AGNOS covers this with a systemd oneshot
      (`agnosticos/config/init/agnos-init.sh:47-62`); kybernet is the PID 1 that
      replaces systemd (`agnosticos/README.md:64`), so the work lands here.
      **Do it as a `"type": "oneshot"` service definition, not as init-resident code** —
      that path is already parsed, wave-ordered, cgroup-placed, supervised and
      harness-gated (six of the nine QEMU fixtures are oneshots), and a service with no
      `security` block runs unconfined as root, so it can `mkdir`/`chown`/`chmod`
      freely. Putting the same capability inside PID 1 would mean a new root-privileged
      filesystem-mutation surface in the least recoverable process on the machine, plus
      a JSON schema, a path validator, a symlink-safe walk and a rule-27 fixture — to
      buy what one config object already buys. This is mostly an agnosticos change.
      ⚠ Two kybernet-side blockers to close first, both real:
        - **A failed prerequisite does not block its dependents.** `start_services`
          (`main.cyr`) starts waves in order, but a wave-N failure only increments
          `failed` — wave N+1 runs anyway. So a broken `agnos-init` would still let the
          confined compositor start and exit 126. This is the item that actually makes
          the oneshot approach trustworthy, and it is worth doing on its own merits.
        - **`aethersafha`'s `depends_on` is hardcoded** in argonaut's
          `default_services(BOOT_DESKTOP)`, so making it depend on a new `agnos-init`
          needs either an argonaut change or a config that replaces the default set.

- [ ] **`is_mounted` is the benchmark that keeps moving, and it is layout-sensitive.**
      Third intervention now. 1.6.1: it scanned the host's REAL mount table and read
      +641% on a CI runner; fixed with a 2 KiB synthetic table. 1.6.8: measured
      ~+12.6% (paired against a clean 1.6.7 worktree, same box: ~4130 vs ~4650 ns)
      from a release that never touched `mount.cyr` — almost certainly `.rodata`
      shift, since that release rewrote 52 log literals from UTF-8 to ASCII. It also
      oscillates between two stable modes on unchanged code. It scans 2 KiB and is
      the most cache-sensitive benchmark in the suite, so it measures binary layout
      as much as it measures the function. Either make it layout-insensitive (much
      smaller working set, or report a median across process restarts) or accept it
      is not a gateable figure and exempt it with the reason stated. The same
      question applies to `strlen(52 chars)`, which showed the identical shape at
      1.6.3 and was never explained.
- [ ] **`seccomp: basic` is measured against a dynamically linked binary only.**
      The dev box stages Arch's dynamic busybox; CI installs `busybox-static`, whose
      glibc start-up issues `readlinkat("/proc/self/exe")` and `prctl` that the
      dynamic path does not. Both are denied `EPERM` and glibc tolerates it, so
      nothing fails — but the local green and the CI green attest to two different
      syscall sets. Decide deliberately whether `basic` covers static linkage, and
      measure whichever answer is chosen rather than widening the list to quiet a
      harmless denial.

---

## v1.x.x — real, but needs a decision or is too large to date

- [ ] **Give the AGNOS default services a non-root uid.** 1.6.9 made
      `security.uid` / `security.gid` work and proved it end to end, but nothing in the
      shipped config or in argonaut's `default_services` actually uses it — so every
      real service still runs as root. The mechanism exists; the policy does not.
      Needs a uid allocation per service (aethersafha, daimon, agnoshi...), matching
      ownership on whatever runtime paths each one writes, and the numeric ids in
      agnosticos' config. Note the ordering constraint 1.6.9 established: a service
      with `"seccomp": "basic"` AND a uid works only because the drop precedes the
      filter, and none of setuid/setgid/setgroups/setresuid are in that allowlist.
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
  broken orphan scripts. The first cut failed its own new bench gate — `is_mounted` was
  scanning the host's real `/proc/self/mounts`, so it measured the runner's mount table
  (+641%) while every other benchmark improved; the calibration normalises CPU speed, not
  how much data the host hands you. Fixed hermetically, and the Argon2 benchmark (memory-
  bound, same class) with it. 632 tests, 45 harness properties, 57 benchmarks.
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
