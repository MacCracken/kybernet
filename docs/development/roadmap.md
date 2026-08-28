# Kybernet Roadmap

**Current: v1.6.16** — [CHANGELOG.md](../../CHANGELOG.md) is the record of what each
release actually did. This file carries only what is **not** done.

This file now carries two intakes. The 1.5.9 sweep opened **38** items (counted at the
`1.6.0` tag) and **14 of those remain** — seventeen releases of attrition. **The
2026-08-26 P(-1) audit is closed**: 21 items were added to this file and 20 are done,
leaving only MEDIUM-10, which is partial on purpose. Plus two opened by the 1.6.14
work (one argonaut allocation finding, one cyrius filing split out of CRITICAL-1).
Total open: **17**. Every number is `grep -c '^- \[ \]'` against
this file at the relevant tag, not an estimate.

⚠ The item count went UP at v1.6.13, and that is the audit working rather than the
project regressing — and it has come back down. v1.6.16 consumed argonaut 1.13.10 and
sigil 3.12.11 (closing MEDIUM-4 and MEDIUM-8) and closed all six LOWs, one of which
(LOW-6) turned out to have been closed already at 1.6.14 by HIGH-3's fixture —
verified rather than assumed before ticking it. v1.6.15 closed all ten MEDIUMs — six here, two in deps awaiting
tags, one by filing upstream, and **one deliberately left partial** (MEDIUM-10: the
obvious fix breaks a contract libro's own suite asserts, and half-closing it is
exactly what that finding complained about). v1.6.14 closed all five of the audit's
HIGH findings — four here
and one in argonaut 1.13.9, which is written and tested but **not yet tagged**, so
kybernet still pins 1.13.8 and HIGH-6 stays open below until it is. v1.6.14 also
closed the long-standing `is_mounted` / `strlen(52 chars)` benchmark question, by
DEMONSTRATING that both measure binary layout: an inert BSS pad in `src/bench.cyr`
moves `strlen(52 chars)` +37%, which is larger than any regression the gate ever
flagged on it. They are now reported and not gated, with the reason recorded in
`scripts/bench-history.sh`.

Every item names the file that proves it. Where a claim was verified by running
something rather than by reading, it says so — and where it was verified by *injecting
the defect and watching the gate go red*, it says that too, because this project has
repeatedly found that a gate nobody has seen fail is a gate nobody should trust.

**Pins:** `v1.6.x` is scoped work with a clear finish line. `v1.x.x` is real but needs
a design decision or is too large to date. The last two sections are blocked on
something outside this repo.

`cyrius lint` reports **0 untracked deferrals and 0 warnings** across the tree, and as
of v1.6.1 **CI fails on either** — so this file cannot quietly drift back into fiction.

**Gate counts at v1.6.16** (a next agent must not let these shrink; each is enforced):
725 test assertions (**on both arches**) · 67 harness properties · 56 benchmarks (two
reported-not-gated, declared) · the aarch64 execution gate · the committed-lock gate. See
[state.md](state.md) for the full current-state handoff.

---

## v1.6.13+ — the P(-1) audit's deferred findings

The 2026-08-26 P(-1) audit found **31** issues; 9 were closed and 1 mitigated at
v1.6.13, and the **21 below are open**. Full evidence for each — including the
adversarial verification each one survived — is in
[`docs/audit/2026-08-26-audit.md`](../audit/2026-08-26-audit.md); this list is the
tracker, not the report.

⚠ **Read the audit's own caveat before acting on any of these.** The verification pass
let a finding survive if fewer than two of its two skeptics refuted it, so a single
refutation did not kill it — a weaker bar than 1.4.2's, which refuted 13 of 39
candidates. This one refuted none, and that is a property of the threshold, not
evidence that every candidate is airtight. Ten findings were re-verified by hand and
are marked as such in the report; **none of the 21 below is among them.** Each carries
detailed, specific evidence — check the evidence, not the severity label.

Grouped by where the fix lands: **16 kybernet**, 2 argonaut, 1 sigil, 1 libro, 1
cyrius. The dep ones cannot ship from here — dep first, **the user tags it**, consumer
second (see the release order below).

- [ ] **MEDIUM-10 — PARTIAL. 224 -> 192 bytes per audit record; the remaining 176
      needs a libro API change.** argonaut 1.13.10 caches the two constant Strs
      (`source` is always "argonaut"; `event_type_str` returns a literal), which is
      32 of the 224. The rest is inside libro's `entry_new`: an 88-byte struct plus
      the timestamp, hash and algorithm Strs.
      ⚠ **The obvious fix was implemented and REVERTED, so do not simply retry it.**
      Having a streaming chain reuse one scratch entry — sound in principle, since a
      streaming chain retains nothing and the struct is dead once `_chain_retain` has
      taken its hash — breaks `chain_append`'s contract that the returned entry
      belongs to the caller. libro's own suite asserts two returned entries are
      independent, and four tests go red (verified, then reverted; libro is unchanged
      at 2.8.12). That is a real contract, not a test artifact.
      THE DESIGN THAT WORKS: an opt-in libro API — an append that returns the head
      HASH rather than an entry, using a per-chain scratch internally — which
      existing callers ignore and argonaut's `audit_log_record` adopts. That is a
      libro MINOR release with consumer review, not a patch. Separately,
      `execute_health_check`'s 64-byte result should be written into a
      caller-supplied slot on the polling path.
      ⚠ This item is deliberately still OPEN. Its original complaint was that it had
      been recorded as closed in four documents while still being there.

- [x] **MEDIUM-9 — CLOSED BY FILING (2026-08-27).** aarch64 `sys_pause()` issues
      `flock(0,0)` and returns immediately. Same cyrius codegen defect as CRITICAL-1,
      same filing:
      `docs/development/issues/2026-08-27-aarch64-esysxlat-eats-native-signalfd4-and-ppoll.md`.
      cyrius is off-limits to this repo and filing an issue is the only permitted
      action; there is no consumer-side workaround (five failed attempts are recorded
      in the filing). Tracked to completion by the aarch64 execution gate's
      `AARCH64_KNOWN_BROKEN` declaration, which fails if the entry ever becomes stale.

---

- [ ] **`check_command` allocates 232 bytes per health check, on PID 1's reactor
      path.** Measured during the 1.6.14 work (`alloc_used()` delta over two calls
      = 464 B). At a 5 s interval that is ~4 MB/day/service in the arena init never
      resets — the same class as 1.6.3 / 1.6.5 / 1.6.6 / 1.6.12 / 1.6.13 HIGH-4.
      It comes from `str_from` boxes, `safe_cmd_new`, `run_safe_cmd_timeout`'s argv
      buffer and `_resolve_safe_binary`'s path builder, so it is pre-existing and
      shared with the edge-boot callers — which run once per boot, where it does not
      matter. Removing it means reworking `SafeCommand`'s allocation rather than
      patching one call site, so it was filed rather than rushed into 1.13.9.
      Lands in argonaut.

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
- [ ] **⚠ FILED 2026-08-27: the aarch64 ESYSXLAT collision behind CRITICAL-1 and
      MEDIUM-9.** `docs/development/issues/2026-08-27-aarch64-esysxlat-eats-native-signalfd4-and-ppoll.md`
      in the cyrius repo, with a runnable repro under `issues/repros/`. **cyrius is
      off-limits to this repo — filing an issue is the only permitted action, and
      that is done.** Root cause read out of `src/backend/aarch64/emit.cyr`:
      `lib/syscalls_aarch64_linux.cyr` defines `SYS_FSYNC = 74` (the x86 number,
      deliberately, awaiting translation `74→82` at `emit.cyr:1125`) and
      `SYS_SIGNALFD4 = 74` (the NATIVE aarch64 number, expecting passthrough) —
      two constants, one value, opposite expectations, and the flat rewrite cannot
      tell them apart. Same shape for `SYS_PPOLL = 73` vs the `flock 73→32` row at
      `:1033`, whose own comment already warns about re-catching a remapped
      `poll(73)` while leaving a DIRECT `syscall(SYS_PPOLL, …)` — which is
      `sys_pause()` — unprotected. **No consumer workaround exists**, established by
      five failed attempts recorded in the filing (literal, global, runtime-computed,
      and both x86 numbers, which have no rows). Proposed fix (A) is the ≥1000
      private-alias band the tree already uses for `SYS_CHDIR = 1049` /
      `SYS_FCHOWNAT = 1054`. kybernet's side is contained: the aarch64 execution gate
      carries these as a DECLARED known-broken pair, and `release.yml` refuses to
      publish a binary that fails the boot-critical probe. **Close this item by
      pinning a fixed cycc and dropping the two entries from
      `AARCH64_KNOWN_BROKEN`** — the gate then fails if they are dropped early.

- [ ] **cyrius stdlib filings, genuinely off-limits from here.** ioctl / termios /
      poll — `2026-08-24-sys-ioctl-wrapper-missing.md`, behind `src/lib/termios.cyr` and
      `_read_line_fd`'s `sleep_ms` poll loop. And `fl_alloc`'s unchecked `_fl_mmap`
      return in two places (`freelist.cyr:404-406`, `:231-241`), which is why sigil's
      own `if (mem == 0)` guards are dead code.
      (The socket-wrapper filing is **closed and the follow-through has SHIPPED** —
      `sys_socket`/`sys_bind`/`sys_recvfrom` landed upstream and `notify.cyr`'s
      hand-rolled per-arch `enum SockSysNr` was deleted at **v1.6.3**, not v1.6.2 as
      this line used to predict. `notify.cyr:8` records the retirement.)
- [ ] **Control socket for agnoshi runtime commands** — a separate transport surface,
      pinned until an agnoshi consumer drives the protocol shape.
- [ ] **Binary signing on release** — pinned until libro signing/timestamping is
      consumer-driven from outside kybernet's tree.

---

## History

One line per release. Detail lives in [CHANGELOG.md](../../CHANGELOG.md).

- **v1.6.16** — The last of the P(-1) audit. Consumed argonaut 1.13.10 and sigil
  3.12.11, closing MEDIUM-4 (the HTTP health check's unbounded `connect`, ~127 s of
  frozen reactor per tick) and MEDIUM-8 (`tpm2_pcrread` unbounded AND
  status-discarding, so a wedged TPM hung PID 1 at phase 6c and a missing tool became
  a zero-filled PCR bank). Then all six LOWs: a rejected `edge` block left its device
  paths committed so verification ran on a board just told it was disabled; a typo in
  `depends_on` became a phantom service with its own cgroup and a `FAILED` line naming
  a service nobody configured; a fail-closed guard used F_OK and passed a `chmod 000`
  binary; `mkcred.sh --check` blessed a record kybernet classifies INVALID; and the
  watchdog KILL ran on every gate run with nothing asserting it. LOW-6 was already
  closed at 1.6.14. 718 -> 725 assertions, 66 -> 67 harness properties.
  ⚠ Worth keeping: the first injection used to verify the watchdog assertion was
  itself broken — a stub in `lib/` is restored by `cyrius build`'s re-resolve, so the
  gate stayed green for the wrong reason. **`lib/` is not a valid injection point.**
- **v1.6.15** — All ten deferred MEDIUMs. A `landlock` block that granted nothing
  confined nothing while reporting "applied"; a config service whose name collided
  with a built-in was counted, dropped and never mentioned; unvalidated health-check
  integers derived a SIGKILL deadline, so `"retries": 0` flapped a healthy service
  forever and a negative `timeout_ms` reached `poll(2)` as INFINITE; a quoted number
  in `security` fell back to permissive defaults and started the service as root,
  unfiltered; `"uid": N` alone left it as group root; and `require_auth` with no
  credential prompted for a password nothing could match and then halted PID 1
  permanently. Consumed argonaut 1.13.9 (closing HIGH-6). MEDIUM-4 and MEDIUM-8 are
  fixed in argonaut 1.13.10 / sigil 3.12.11 awaiting tags, MEDIUM-9 was closed by
  filing upstream, and **MEDIUM-10 is partial and stays open** — 224 -> 192 bytes,
  with the remaining fix needing a libro API change that its own tests refuse.
  702 -> 718 assertions.
- **v1.6.14** — All five HIGH findings from the P(-1) audit. Landlock was frozen at
  ABI v1, so `truncate(2)` was **entirely unchecked** for every confined service while
  the sandbox reported "applied" — measured: open denied, truncate allowed, a 16-byte
  file reduced to 0. `capabilities` and `uid` could not be used together at all: the
  capability drop surrendered CAP_SETUID/CAP_SETGID before the privilege drop needed
  them, so the canonical "bind a low port as an unprivileged user" policy was accepted
  by the parser and exited 126 every time; the fix raises AMBIENT capabilities, the
  only set that survives execve of a plain binary. Every SIGHUP leaked ~38 KB, and did
  so even with no config file. dm-verity verification borrowed an undocumented
  hardcoded 10 s, so a board with an INTACT rootfs powered off blaming a veritysetup
  that was present and running. argonaut 1.13.9 fixes the health-command exec (found
  en route: it could never run a command with an argument, on either implementation).
  Also settled the benchmark question three releases old, by proving with inert
  padding that `strlen`/`is_mounted` measure layout. 681 -> 702 assertions,
  62 -> 67 harness properties.
- **v1.6.13** — The P(-1) audit, ten releases late, and the arch half of the product
  could not boot. 31 findings (2 CRITICAL, 9 HIGH, 13 MEDIUM, 7 LOW); 9 closed, 1
  mitigated, 21 deferred with evidence. **CRITICAL-1: `sys_signalfd()` issues
  `fsync(-1)` on aarch64**, so phase 4 takes its FATAL arm and every aarch64 board
  powers itself off before loading config — a published artifact that was 100%
  non-functional while every gate was green, because no gate had ever executed one
  aarch64 instruction. Exactly two of 34 syscall wrappers are wrong; the fix is
  upstream in cyrius, so kybernet added the execution gate and made `release.yml`
  refuse to publish a binary that cannot boot. **CRITICAL-2: the PCR comparison read
  sigil's raw cstr digest as a boxed `Str`** and dereferenced eight ASCII hex
  characters as a pointer — SIGSEGV in PID 1, on the SUCCESS path of an attesting edge
  board, in a function no fixture had ever executed. Also: a default boot SIGKILLed
  healthy services (the health cadence ignored argonaut's defaults — the same bug 1.5.0
  fixed for the start path); an 8 KiB-per-datagram OOM primitive against PID 1;
  `kybernet.edge=permissive` dropped the board into an emergency shell three lines
  after saying it would continue; the harness aborted silently whenever kybernet failed
  to boot; and standing rule 2 had been half wrong since 1.1.5 (`var X[N]` is N BYTES
  local, N SLOTS global — measured). 676 → 681 assertions, now green on aarch64 too.
- **v1.6.12** — argonaut 1.13.8 redep: three things unobservable, unschedulable or
  unbounded in the long-lived path. The orphan-reap count is logged, so the `kyb-orphan`
  fixture is **asserted** after eleven releases documented "NOT ASSERTED" — argonaut
  discarded the count and kybernet had no way to ask, so reparented children were reaped
  correctly and invisibly. Health probes are now scheduled per service (`interval_ms` was
  parsed, stored, exposed, and read by nothing), so kybernet's poll timer is a tick
  resolution rather than the cadence every service got. The in-memory audit chain streams
  by default — it retained 240 bytes per record, ~0.68 MB/day/service in the one arena PID 1
  never resets; `chain_with_capacity` was checked and does NOT free (rotation archives into
  `overflow`), while streaming keeps linkage byte-identical. Also: the harness had **never
  built what it tests**, so "edit src/, run boot-test.sh" graded the previous binary — found
  by an inject-the-defect run that returned 62 OK / 0 FAIL when it had to fail. 676 tests,
  62 harness properties.
- **v1.6.11** — Deleted a benchmark of dead code without weakening the gate that forbids
  it. `sandbox_from_ruleset` and `_ll_access_to_kernel` had no production caller; the latter
  had justified standing rule 9 for seven releases as "the per-service Landlock path where a
  miscompile is a PID-1 crash" while its only caller chain terminated in `bench.cyr`. The
  bench gate fails on a shrinking suite, so the removal is *declared* (`BENCH_REMOVED=1`),
  verified to still fail when undeclared. 57 → 56 benchmarks.
- **v1.6.10** — `MAINPID=` honoured behind two independent checks, and the difference
  between authentication and authorisation: `SCM_CREDENTIALS` proves who *sent* a datagram,
  not which pid it may speak for, so a forged MAINPID is refused on cgroup membership.
  Reject reasons are counted separately — a single "rejected: N" cannot distinguish
  "SO_PASSCRED is broken" from "the sender was not a live service". 58 → 61 properties.
- **v1.6.9** — Services can run as something other than root. The entire uid/gid half of
  `privdrop.cyr` was unreachable — `drop_privileges` had no caller. Ordering is
  load-bearing: the drop must precede seccomp, because none of
  setuid/setgid/setgroups/setresuid are in the `basic` allowlist. 56 → 58 properties.
- **v1.6.8** — sd_notify READY and WATCHDOG *honoured*, not merely observed. 1.6.3 built
  the whole substrate and then dropped every message on the floor. argonaut 1.13.5 → 1.13.7.
- **v1.6.7** — `health_check.interval_ms` was parsed, stored, and never reached the timer:
  the reactor polled on a hardcoded 30 s, so a service asking for 5 s got 30 — and argonaut
  sizes the watchdog deadline from the service's OWN interval, so a mis-sized watchdog can
  kill a healthy service. 667 → 676 assertions.
- **v1.6.6** — The last confinement mechanism with no fixture, and a gate that had been
  passing by luck. Picks up argonaut 1.13.4's two per-tick arena leaks. 53 → 55 properties.
- **v1.6.5** — A per-SIGCHLD arena leak needing no socket, no credentials and no config:
  `reap_zombies` allocated 152 bytes on **every** SIGCHLD, idle or not. Measured 304,000
  bytes over 2000 idle calls, now 152 total.
- **v1.6.4** — Config keys parsed and never consulted, and code with no callers.
  `log_to_console` had exactly two readers in the tree: its own definition and the copy in
  reload. 660 → 667 assertions.
- **v1.6.3** — sd_notify was received, classified, logged and **discarded** — and leaked
  doing it: `notify_read` allocated 512 bytes per datagram on the reactor hot path, a
  root-triggerable memory-exhaustion DoS against PID 1. Retired the hand-rolled per-arch
  socket syscall table. 632 → 660 assertions.
- **v1.6.2** — Code that does nothing, and docs that say it does. Boot phase 6b was a
  provable no-op carrying three defects; argonaut's import list dropped 13 → 12 modules
  (`tmpfiles.cyr` had no call site in the link set).
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
