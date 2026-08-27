# Kybernet Roadmap

**Current: v1.6.14** — [CHANGELOG.md](../../CHANGELOG.md) is the record of what each
release actually did. This file carries only what is **not** done.

This file now carries two intakes. The 1.5.9 sweep opened **38** items (counted at the
`1.6.0` tag) and **14 of those remain** — fifteen releases of attrition. The
2026-08-26 P(-1) audit added 21, of which **17 remain**. Plus one new item opened by
the 1.6.14 work. Total open: **32**. Every number is `grep -c '^- \[ \]'` against
this file at the relevant tag, not an estimate.

⚠ The item count went UP at v1.6.13, and that is the audit working rather than the
project regressing. v1.6.14 closed all five of the audit's HIGH findings — four here
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

**Gate counts at v1.6.14** (a next agent must not let these shrink; each is enforced):
702 test assertions (**on both arches**) · 66 harness properties · 56 benchmarks (two
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

- [ ] **HIGH-6 — FIXED IN argonaut 1.13.9, AWAITING A TAG.** `health_check.type =
      "command"` blocked PID 1's reactor in an unbounded `waitpid`, discarded the
      configured `timeout_ms`, and exec'd with an empty envp so a bare command name
      was ENOENT forever. Found while fixing it: it **could never run a command with
      an argument at all** — `str_split` returns views into the original buffer
      (measured: word[0] of `"/bin/sleep 5"` has str_len 10 and its next byte is 32,
      not 0) and `execve`'s argv needs NUL-terminated strings, so argv[0] was the
      whole command line. Both the old and new code had that defect, which is why
      the pre-1.13.9 suite only ever tried single-word targets.
      argonaut's `check_command` now uses `run_safe_cmd_timeout` and splits in place
      in a static buffer; its suite went 23 -> 33 assertions. **kybernet still pins
      argonaut 1.13.8**: the 1.13.9 tag does not exist yet and a manifest naming an
      untagged version fails CI resolution. Bump after the user tags it.

- [ ] **MEDIUM-1 (MEDIUM) — A `landlock` block whose rules all resolve to no access installs NO ruleset and returns Ok(0) "applied" — the service runs with zero filesystem confinement**
      `src/lib/sandbox.cyr:212` — fails open — "nothing to do" indistinguishable
      from "applied".
      TRIGGER: `"security": { "landlock": [ {"path": "/etc", "access": "none"} ],
      "landlock_optional": false }` — an operator expressing "deny /etc". Or
      `"landlock": []` as a placeholder. Both are accepted and both produce a
      completely unconfined service.
      CONSEQUENCE: The exact outcome service_sandbox.cyr's own header calls "worse
      than not running it": the operator sees a service that started, kyb_pre_exec
      reported success, and the filesystem policy they wrote is not merely weaker
      than intended, it is absent. Note the asymmetry with the sibling key
      documented ten lines away: `"capabilities": []` means "drop everything", the
      maximally restrictive reading; `"landlock": []` means "restrict nothing". No
      harness fixture sets an empty or all-"none" block (rule 27), so this has never
      run in a gate.
      FIX: An empty effective rule set must still create the ruleset and call
      `landlock_restrict_self` — a ruleset with zero PATH_BENEATH rules denies every
      handled access, which is what "none"/[] should mean. Delete the `count == 0`
      early return in `sandbox_apply` (its only production caller is
      `sandbox_from_config`; `sandbox_basic_service` is bench/test-only, so the
      blast radius is contained) and the `rlen == 0` early return in
      `sandbox_from_config` for the config-derived path, since the caller already
      gates on `ll != 0`. ⚠ Document the consequence rather than let it be
      discovered: restricting over an empty rule set denies FS_EXECUTE beneath every
      path, so such services will then fail to execve — the

- [ ] **MEDIUM-10 (MEDIUM) — The 1.6.12 audit-chain fix removed retention but not allocation — a streaming chain still costs ~224 of the 240 bytes per record, so the growth recorded as closed in four documents is still there** **Fix lands in `libro`.**
      `src/main.cyr:1109` — unbounded per-tick allocation; a closed roadmap item
      that was not actually closed.
      TRIGGER: Any board where a service with a `health_check` reaches STATE_RUNNING
      — the default AGNOS set. argonaut attaches a health check to all seven default
      services. No attacker, no config, no unusual state.
      CONSEQUENCE: Steady unbounded growth of PID 1's resident set over the multi-
      month uptimes this project targets. Rate is tick-dependent: with no config
      health check kybernet's poll timer sits at 30 s (see HIGH-1), giving ~9 MB/day
      / ~800 MB over 90 days; a config declaring a fast interval puts it in the
      20-25 MB/day range. The specific harm beyond the bytes is that the item is
      recorded as closed in CHANGELOG.md, state.md, roadmap.md and CLAUDE.md, so the
      next agent has no reason to look — the shape standing rule 9 was rewritten
      about.
      FIX: In libro: on a streaming chain (`load64(c + 32) == 1`), hash into a
      single reusable per-chain entry slot instead of calling `entry_new`, since the
      entry is by definition unreachable the moment the head hash is taken — linkage
      stays byte-identical, which is the property 1.6.12 already verified. In
      argonaut: have `audit_log_record` build its three `str_from` only when the
      chain will retain, or hold them as cached `Str` constants (`source` is the
      literal "argonaut" on every call and `event_type_str` returns a literal).
      Separately, `execute_health_check`'s 64-byte result should be written into a
      caller-supplied slot on the polling path — fixing the chain alone closes only
      ~72%. Then correct CHAN

- [ ] **MEDIUM-2 (MEDIUM) — A config service whose name collides with an argonaut default is parsed, counted in `services parsed: N`, and then silently discarded — the operator's binary never runs and their whole `security` block vanishes**
      `src/main.cyr:270` — silent config drop; security policy discarded with no
      diagnostic.
      TRIGGER: `/etc/kybernet/config.json` containing a `services` entry named
      `daimon` (or any of the other six) under any non-recovery boot mode.
      CONSEQUENCE: kybernet reports `config: services parsed: 1` and starts a
      service that is not the one in the config. Every field the operator set is
      discarded — binary, args, restart policy, cgroup limits, and the `security`
      block — with no log line admitting the collision. Note the honest scoping: the
      built-in was never confined, so nothing ends up with MORE privilege than the
      pre-existing baseline; what is silently lost is the operator's intended
      hardening and their entire definition, and their binary never executes at all.
      Reload is NOT affected (`reload_config` logs "service definitions require a
      reboot - NOT applied" and never rebuilds the map), so this is boot-path only.
      Structurally invisible to the
      FIX: Detect the collision on kybernet's side, where the operator's intent is
      known. Before pushing into `config_services`, check the name against
      `default_services(config_boot_mode(cfg))` — or register config services first
      and let argonaut's `map_has` guard drop the DEFAULT, which is what an operator
      writing an override expects and is the only version that lets a `security`
      block be added to a built-in at all. At minimum refuse the silence: log
      `config: service "<name>" collides with a built-in — config definition
      IGNORED` on console and dmesg, and make `services parsed: N` count only
      definitions that actually reached the registry. Note roadmap.md:87-88 already
      records the inability to override

- [ ] **MEDIUM-3 (MEDIUM) — `health_check` fields are parsed with zero validation while `interval_ms * retries + timeout_ms` drives a SIGKILL — `"retries": 0` gives a 2 s watchdog deadline and `"retries": -1` a negative one that fires unconditionally**
      `src/lib/svc_config.cyr:97` — unvalidated config integer feeding a kill
      decision; multiplicative derivation with no bounds or overflow check.
      TRIGGER: `"health_check": {"type":"process-alive", "interval_ms":10000,
      "timeout_ms":2000, "retries":0}` — a plausible spelling of "do not retry".
      `elapsed` is uptime while `last_hc == 0` and non-negative thereafter, so any
      negative `watchdog_ms` fires on the first watchdog tick after STATE_RUNNING;
      `retries: 0` gives a 2000 ms deadline against a `last_hc` refreshed at best
      every 10 s.
      CONSEQUENCE: A healthy service is SIGKILLed by PID 1 on essentially every
      watchdog tick, restart-queued 2 s later by src/main.cyr:1166, restarted, and
      killed again — a permanent kill/restart flap driven by a config integer that
      reads as reasonable, with the log saying only `watchdog killed: <name>` and
      never why. Aggravating sub-case: a negative `timeout_ms` also reaches
      `ag_sys_poll(&pollfd, 1, timeout_ms)` in argonaut's `tcp_connect_ip`, and
      poll(2) treats a negative timeout as INFINITE — so a `"type":"tcp"` check
      against a SYN-blackholed target blocks the reactor forever from one config
      integer. `port: 999999` is harmless (truncated by the byte-swap). Note
      `retries` as a health-failure THRESHOLD is al
      FIX: Validate at load and REFUSE, never clamp, matching the `watchdog_ms` arm
      50 lines up and rule 25's reasoning. Suggested bounds stated in-source next to
      the parse: `1000 <= interval_ms <= 3600000`, `1 <= timeout_ms <= interval_ms`,
      `1 <= retries <= 10`, `0 <= port <= 65535`, and reject when `interval_ms *
      retries` overflows before the add, or when the derived deadline is less than
      twice the health tick period the config will produce. Log the reason on
      console and dmesg and drop the whole service. Add a harness fixture with
      `"retries": 0` and assert the service is refused, not started.

- [ ] **MEDIUM-4 (MEDIUM) — `"health_check": {"type": "http"}` uses a BLOCKING `connect(2)` with no timeout, stalling PID 1's reactor for the kernel's full SYN-retry window** **Fix lands in `argonaut`.**
      `lib/argonaut_health.cyr:335` — unbounded (kernel-bounded) blocking syscall on
      the reactor path.
      TRIGGER: `"health_check": {"type": "http", "target":
      "http://10.0.0.5:8080/healthz", "timeout_ms": 200}` where 10.0.0.5 silently
      drops SYN — host down, firewall DROP rather than REJECT, cable pulled.
      Ordinary for a service whose health endpoint lives on another box.
      CONSEQUENCE: The reactor blocks inside `connect(2)` for ~127 s per health tick
      despite the operator having configured `timeout_ms: 200`. kybernet blocks all
      signals into a signalfd and installs no handler, so the connect cannot even be
      cut short by EINTR. During each stall PID 1 reaps no zombies, handles no
      SIGTERM/SIGCHLD, services no watchdog and drains no notify socket; with a poll
      interval shorter than the stall the board is unresponsive essentially
      continuously and a shutdown request sits unhandled for minutes. Less severe
      than MEDIUM-4's sibling HIGH-6 only because the kernel eventually returns.
      Scope note: `execute_ready_check` funnels into the same function, but
      kybernet's parser never builds a r
      FIX: In the HC_HTTP_GET arm, do what `tcp_connect_ip` already does:
      `ag_sys_fcntl(fd, 4, 2048)` before `sys_connect`, treat -115 as EINPROGRESS,
      bound it with `ag_sys_poll(&pollfd, 1, timeout)` plus the SO_ERROR check.
      Better, factor the bounded connect out of `tcp_connect_ip` and call it from
      both arms so the two cannot drift again. Then fixture `"type": "http"` against
      a blackholed address and assert in the `harness=loop` pass that the reactor
      keeps ticking.

- [ ] **MEDIUM-5 (MEDIUM) — Every scalar key in the `security` block silently falls back to its default on a TYPE mismatch — a quoted uid and a non-string seccomp value discard the whole policy and the service starts as root, unfiltered, with no diagnostic**
      `src/lib/svc_config.cyr:54` — fails open on malformed input; contradicts the
      module's own documented "malformed security block rejects the service"
      contract.
      TRIGGER: A quoted number in the security block — `"uid": "65534"` instead of
      `"uid": 65534` — the single most common JSON authoring mistake, or `"seccomp":
      true` / `"seccomp": 1`.
      CONSEQUENCE: An operator who wrote a uid drop and a seccomp profile gets a
      service running as root with the full capability set and no filter, and every
      observable signal says the config loaded cleanly. The board looks correctly
      hardened and is not. The failure is also non-uniform and cannot be reasoned
      about from outside: `no_new_privs` and `landlock_optional` fall back to their
      RESTRICTIVE defaults while uid/gid/seccomp fall back to permissive ones. No
      fixture and none of the 676 assertions covers a type mismatch inside
      `security`.
      FIX: Give the security block strict accessors that distinguish absent from
      wrong-typed: if `json_v_obj_get(sec, key) != 0` and the type predicate fails,
      klog the key name and `return 0` so the service is refused — the contract
      svc_config.cyr:178-181 already claims and `_cfg_limit` already implements.
      Apply to `uid`, `gid`, `seccomp`, `no_new_privs` and `landlock_optional`
      alike; keys inside a security block are not the place for lenient parsing. Add
      config-parse unit tests asserting each wrong-typed security key refuses the
      service.

- [ ] **MEDIUM-6 (MEDIUM) — A uid-only privilege drop leaves the service running as GID 0 — setgroups and setgid are both gated on `gid > 0`**
      `src/lib/privdrop.cyr:26` — incomplete privilege drop (missing setgid on the
      uid path) — CWE-273.
      TRIGGER: `"security": { "uid": 65534 }` with no `gid` key — a config that
      reads as "run this unprivileged".
      CONSEQUENCE: The service is not unprivileged. It runs with real, effective,
      saved-set and fs GID all 0, so group-class access to every root-group file
      (the 0640/0660/0770 class) is retained and files it creates are group-root —
      while `kyb_pre_exec` returns 0 and nothing is logged. A security primitive
      reporting a success it did not achieve, the same class as the previous audit's
      MEDIUM-1 in this same file. The shipped fixture cannot see it: kyb-nonroot
      sets uid AND gid together and boot-test.sh asserts both, so the one uid path
      that has a fixture is the one that works (rule 27). Latent today in the sense
      that no shipped config sets `security.uid`, which roadmap.md records as an
      open item — so this is a h
      FIX: Prefer refusing at load: per rule 19, a config that cannot express a
      complete drop should be a readable config error, so reject `uid` without `gid`
      in svc_config.cyr:547-560 (or default the gid to the uid's). As defence in
      depth also widen the gate to `uid > 0 || gid > 0` for `sys_setgroups(0, 0)` —
      it costs nothing, and PID 1's empty group list is a property of the boot path
      rather than an invariant kybernet enforces. Add a uid-only fixture asserting
      the `Gid:` line of /proc/self/status from inside the child.

- [ ] **MEDIUM-7 (MEDIUM) — `emergency_require_auth` with no usable credential prompts for a password nothing can match and then halts PID 1 forever — the guard that prevents this exists at only 1 of 3 `drop_to_emergency` call sites**
      `src/main.cyr:457` — fail-closed into an unrecoverable halt; missing load-time
      cross-validation.
      TRIGGER: `"emergency_require_auth": true` plus either an omitted
      `emergency_password_hash` or one `emerg_cred_usable` rejects (a digest one
      character short, a PHC record from another tool, a wrong-typed value), AND a
      required boot step failing so `init_should_drop_to_emergency` returns 1.
      CONSEQUENCE: PID 1 prints `Password: `, waits up to 120 s, denies whatever is
      typed (a timeout returns -1, which is neither >=0 nor -2, so `granted` stays
      0), prints AUTHENTICATION FAILED and enters `while (1 == 1) { sys_pause(); }`
      — permanently, with all signals blocked and PID 1 unkillable. The board is
      dead until someone reaches the bootloader, across reboots. On aarch64 it is
      worse still: per MEDIUM-9 the halt is a 100% CPU spin, not a halt. Note the
      honest scoping: without require_auth the same failure forks a shell and blocks
      in an unbounded `sys_waitpid` (src/main.cyr:559), so on an unattended board
      neither path reaches the reactor — the real delta is that an operator AT the
      console can recover i
      FIX: Two halves. (a) In load_config, after :246, cross-check the pair: if
      `g_emerg_require_auth == 1 && g_emerg_hash == 0`, log a hard config error to
      console AND kmsg naming the consequence — rule 19, and the only place a typo
      is still cheap. (b) Hoist the phase-6c guard into `drop_to_emergency` itself:
      at :457, if `g_emerg_require_auth == 1 && g_emerg_hash == 0`, log `emergency
      shell: authentication required but no credential configured - shell
      suppressed`, close `con`, and `return 0`. That is the whole fix — callers that
      must refuse to continue (phase 6c) already poweroff on their own after it
      returns, and callers that can continue then continue. Add a fixture pairing
      require_auth=true with a

- [ ] **MEDIUM-8 (MEDIUM) — The `tpm2_pcrread` exec is unbounded — a wedged TPM hangs PID 1 forever at phase 6c, with nothing reaping and nothing servicing a watchdog** **Fix lands in `sigil`.**
      `src/lib/edge_boot.cyr:494` — unbounded blocking exec in PID 1 before the
      reactor (standing rules 17, 22).
      TRIGGER: `tpm_attestation: true` with non-empty `pcr_bindings`,
      `/usr/bin/tpm2_pcrread` present, and the TPM in a state where the tool blocks
      — `/dev/tpm0` held open by another consumer, a tabrmd/D-Bus TCTI wait, or a
      wedged firmware TPM. `edge_apply_defaults` leaves `max_boot_ms` at 0, so the
      budget checkpoint typically does not even fire.
      CONSEQUENCE: PID 1 blocks indefinitely at phase 6c — before the event loop, so
      nothing reaps zombies, nothing services a watchdog, no service has started,
      and no signal can be delivered. The board looks dead with the last console
      line being `edge boot: reading PCRs`. One aggravator worth recording: the PCR
      read runs BEFORE `_eb_verity_verify`, so an attacker who has already tampered
      with the rootfs can plant a `tpm2_pcrread` that simply sleeps and wedge PID 1
      before verification ever executes.
      FIX: Do in sigil what argonaut 1.13.2 did for `run_safe_cmd`: give
      `agnosys_run_capture` a bounded, status-checked variant
      (`agnosys_run_capture_timeout`) modelled on `run_safe_cmd_timeout` — non-
      blocking pipe drain against a deadline, `ret > 0` before any status read,
      SIGKILL + reap on expiry, and the child's exit status actually returned so
      `Ok(0)` can no longer mean "the tool never ran". Thread a timeout through
      `tpm_run_capture` / `tpm_read_pcr` and have kybernet pass the remaining
      `max_boot_ms` slice, the way edge_boot.cyr:530 already does for the verity
      verify. This also closes LOW-3's structural half. Fix sigil's roadmap line
      reference while there: it names edge_boot.cyr:473, the call is a

- [ ] **MEDIUM-9 (MEDIUM) — aarch64: `sys_pause()` issues `flock(0,0)` and returns immediately, turning every deliberate PID-1 halt into a 100% CPU busy-spin and disarming four failure backstops** **Fix lands in `cyrius`.**
      `src/main.cyr:497` — arch-dependent syscall number hijacked by the ESYSXLAT
      ladder; a blocking primitive that does not block.
      TRIGGER: Any aarch64 board reaching `drop_to_emergency` with
      `emergency_require_auth` set and either a failed authentication or an
      unopenable /dev/console. Currently masked by CRITICAL-1 (the boot dies at
      phase 4); it becomes live the moment signalfd is fixed. x86_64 is unaffected.
      CONSEQUENCE: What the code and its own comments call a halt is on aarch64 an
      unkillable tight loop issuing `flock(0,0)` at syscall rate, pinning a core
      forever — on exactly the fanless, battery-constrained edge hardware AGNOS
      targets, with signals blocked and no way back, and with no diagnostic
      distinguishing it from the intended halt. Separately, the four
      post-`sys_reboot` guards stop guarding: if `sys_reboot` ever did return, :1523
      falls through to `return 1` -> `sys_exit(1)` = "Attempted to kill init"
      (standing rule 4's exact hazard, silently disarmed on this arch), and :1663
      falls straight through into phases 7/8/9 and boots every service on an edge
      board whose verification was just refused (the 1.4.
      FIX: Upstream (FILE, do not patch — cyrius is off-limits here): spell
      `sys_pause` on aarch64 with a source number the ladder does not claim, e.g.
      the private-alias band `1073 -> 73` with the arm placed last, matching
      `SYS_FCHOWNAT = 1054`. Consumer-side, and this is the actionable half: do not
      rely on a bare `sys_pause()` for "stop forever". Replace both halt loops with
      `while (1 == 1) { sleep_ms(60000); }` — verified to block correctly on BOTH
      arches (strace shows a real `ppoll`, since chrono's x86 poll(7) IS in the
      translated set, and `time` confirms the wall clock) — and apply the same loop
      form at :665, :1523, :1545 and :1663 so a failed `sys_reboot` cannot fall
      through. Add an assertion that

- [ ] **LOW-1 (LOW) — A rejected `edge` block leaves kybernet's device/hash globals committed, so verification still runs after the operator is told edge verification is DISABLED**
      `src/lib/svc_config.cyr:366` — partially-committed parse — the caller's reset
      covers the dep struct but not the module globals.
      TRIGGER: A config whose device triple is valid but whose PCR baselines are not
      — one bad character in one baseline string. Also fires on the SIGHUP path, and
      when an edge block is REMOVED (the `if (eb == 0)` early return at the top also
      clears nothing).
      CONSEQUENCE: The operator is told twice — console and dmesg — that edge
      verification is DISABLED, and edge_boot.cyr:529 then runs `_eb_verity_verify`
      anyway on the retained `_eb_root_device`, under the literal 10 s ceiling
      because `edge_apply_defaults` just zeroed their `max_boot_ms` (HIGH-8). If
      verification fails or veritysetup is absent, `_stage_verify_rootfs` (a
      REQUIRED stage) returns STAGE_FAIL and the board drops to the emergency shell
      — two subsystems reporting opposite verdicts about the same config on one
      boot, the exact shape boot_stages.cyr:76-84 documents having removed in the
      dm-verity-probe case. Secondary: `edge_boot_run`'s `kybernet.edge=off` handler
      keys on `_eb_root_hash != 0`, so the
      FIX: Make the commit atomic with the parse: stage `rd`/`hd`/`rh`/`ld`/`pv` in
      locals and call `edge_set_devices` + `edge_set_expected_pcrs` at a single
      commit point after ALL validation succeeds. Belt and braces, add an
      `edge_reset_devices()` zeroing all five globals and call it from the
      malformed-block arm in load_config, so the caller's documented "reset on
      malformed block" actually covers both halves of the edge state — and so a
      SIGHUP that removes the edge block clears it too.

- [ ] **LOW-2 (LOW) — An unknown `depends_on` target becomes a phantom entry in the startup waves: kybernet creates a cgroup for a service that does not exist, counts it FAILED, and never removes the directory**
      `src/main.cyr:1031` — unvalidated cross-reference; a name with no definition
      treated as a startable service.
      TRIGGER: A typo or stale entry in any service's `depends_on` array, e.g.
      `"depends_on": ["postgress"]`. Also fires without a typo when a config service
      depends on a name that only exists in a DIFFERENT boot mode.
      CONSEQUENCE: One stray empty cgroup directory per bad name per boot (cgroupfs
      is rebuilt each boot, so not cumulative), and `failed` incremented for a
      service nobody configured. The log line an operator sees is `FAILED to start:
      postgress`, naming a service that was never in their config, so the diagnostic
      points away from the typo that caused it. ⚠ The escalation the sweep claimed
      is REFUTED and must not be written up: `failed > 0 && started == 0` is gated
      on `init_should_drop_to_emergency`, which inspects failed BOOT STEPS with the
      required flag — not services — so the phantom cannot by itself reach
      `drop_to_emergency`. The operationally significant half the sweep understated:
      the REAL dependent is per
      FIX: Validate at load, which is the only place that fixes both halves: after
      the whole `services` array is parsed, refuse any service whose `depends_on`
      names a target that is neither another config service nor a
      `default_services(mode)` name, with the reason on console and dmesg (rule 19 —
      a typo should be a readable config error, not a boot-time surprise).
      Additionally, in `start_services`, treat `msd == 0` as a config error rather
      than a start failure — `if (msd == 0) { klog2(" unknown service in dependency
      graph (check depends_on): ", name_cs); continue; }`, placed BEFORE
      `_prepare_service_cgroup` so no cgroup is created and `failed` is not
      incremented.

- [ ] **LOW-3 (LOW) — The consumer-side guard against sigil's PCR zero-fill checks F_OK rather than X_OK and accepts a zero-byte capture as a successful read**
      `src/lib/edge_boot.cyr:484` — a fail-closed guard that is incomplete — a tool
      that ran and produced nothing is accepted as a successful attestation read.
      TRIGGER: `tpm_attestation: true` with `pcr_bindings` set, `/dev/tpm0` present
      and `/usr/bin/tpm2_pcrread` present but unrunnable — chmod 000 (F_OK passes,
      X_OK would not), tpm2-tss libraries missing (execve -> 127), resource manager
      busy, or any non-zero exit.
      CONSEQUENCE: A guard whose stated purpose is fail-closed passes a binary that
      cannot run, and kybernet logs `edge boot: PCR read complete` for a read that
      produced nothing. Diagnostic dishonesty rather than a bypass: nothing
      downstream is decisional. Worth fixing because the next person to make PCR
      comparison enforcing (which the roadmap plans) inherits a guard that does not
      mean what its comment says.
      FIX: Three cheap consumer-side changes: use `ARG_X_OK` (1) not 0 in the
      `sys_access` guard — as uid 0, `access(X_OK)` still fails when no x bit is
      set, so it catches chmod 000; treat an `Ok(n)` with `n == 0` from the capture
      as a FAILED read rather than a successful one; and reject an all-ASCII-'0'
      digest under `tpm_attestation: true` at the point of read rather than only as
      a report-only non-match. The structural fix is MEDIUM-8's: give sigil's
      `agnosys_run_capture` a bounded, status-checked exec so `Ok(0)` can no longer
      mean "the tool never ran".

- [ ] **LOW-4 (LOW) — `scripts/mkcred.sh --check` blesses a v1 record kybernet classifies INVALID: a cost field longer than 19 characters**
      `scripts/mkcred.sh:118` — generator/consumer validation divergence — a bounds
      "copy" that is not a copy (standing rule 25).
      TRIGGER: An operator or third-party tool hand-writing or zero-padding a cost
      field to more than 19 characters and validating it with `mkcred.sh --check`,
      which reports OK. mkcred's own GENERATION path normalises through `$((10#$X))`
      and can never emit this, so it is `--check`-only.
      CONSEQUENCE: The record is written into config.json, load_config classifies it
      INVALID, logs `emergency_password_hash is malformed - credential REJECTED` and
      zeroes `g_emerg_hash` — the same brick class the script's own header warns
      about ("A generator whose output its own consumer refuses is the 1.5.4-1.5.7
      brick class"). With `emergency_require_auth: true` it feeds directly into
      MEDIUM-7: an operator whose credential the validator blessed gets a permanent
      halt at the first boot-stage failure. The rejection is loud (console + dmesg),
      which is why this is LOW.
      FIX: Add the length rule to --check so the copy is a copy: after the non-
      numeric test and BEFORE the `10#` normalisation, reject any of $ct/$cm/$cp
      longer than 19 characters, with a message naming `_emerg_parse_bounded`'s
      bound. Phrase it as a LENGTH rule, not a leading-zero rule — the 64-bit wrap
      variant has no leading zeros. State in the script header that kybernet's
      parser caps a cost field at 19 digits, and add a long-digit case to CI's
      generator self-test.

- [ ] **LOW-5 (LOW) — The watchdog kill path executes on every reactor gate run and NOTHING asserts it — the path that SIGSEGV'd PID 1 at 1.6.1 is run but ungated**
      `qemu/boot-test.sh:746` — a gate that runs its subject without asserting it
      (standing rules 27, 32).
      TRIGGER: Any regression that stops `init_enforce_watchdog` killing while
      leaving the health probe intact — most concretely the one CLAUDE.md already
      warns against (writing `managed_svc_set_last_hc` on a FAILED probe, "writing
      it on failure would silence the watchdog"), a plausible edit while touching
      argonaut 1.13.8's new `_hc_is_due` scheduling. Also an early return in
      `handle_watchdog_tick`, or the watchdog timerfd not being re-armed.
      CONSEQUENCE: All 62 harness properties stay green while PID 1 has no runtime
      watchdog at all — a wedged service is never killed and never restarted, which
      on a real board is the failure mode the watchdog exists to prevent. The loud
      class IS caught (line 671 greps for `Attempted to kill init|Kernel panic`), so
      this is specifically about the silent class: `init_poll_health` and
      `init_check_watchdog` are independent paths, and no existing loop-pass
      assertion covers the second. Same shape as `"seccomp": "basic"` (rule 27)
      except that the fixture exists and drives the path — only the assertion is
      missing, which is strictly harder to notice.
      FIX: Add ONE assertion to the reactor pass, beside the existing `health check
      failed: kyb-health` check at line 746: `grep -aqF "watchdog killed: kyb-
      health"`, setting `fail=1` with a diagnostic ending in `|| true` (rule 40). Do
      NOT add the `watchdog restart scheduled` assertion — measured absent under
      this fixture and correctly so; the restart half is already covered by the
      existing `restarting:` / `restarted:` lines. Verify by injection (stub
      `init_enforce_watchdog` to return an empty vec and confirm the pass goes red)
      and bump the property count 62 -> 63 in docs/development/state.md.

- [ ] **LOW-6 (LOW) — No fixture ever sets a NON-EMPTY `capabilities` keep-list, so `capset(2)` has never run with a non-zero mask in any gate**
      `qemu/build-initramfs.sh:357` — a config key reaching a syscall with no
      harness fixture for its non-degenerate value (standing rule 27).
      TRIGGER: A service configured `"security": { "capabilities":
      ["cap_net_bind_service"] }` on a real board, after any future divergence in
      the capset(2) invocation or the two-word packing. Nothing in `cyrius test`,
      `bash qemu/boot-test.sh` or CI executes that combination.
      CONSEQUENCE: A regression in the mask-build loop or the 24-byte V3 two-struct
      layout presents either as fail-closed (child exits 126, service never starts)
      or as a wrong capability grant — argonaut's own comment at
      lib/argonaut_types.cyr:534-535 records the historical instance: "under the old
      values 'keep CAP_SYS_ADMIN' kept kernel capability 1 — CAP_DAC_OVERRIDE — and
      dropped CAP_SYS_ADMIN". Nothing in cyrius test, boot-test.sh or CI would see
      it.
      FIX: Add a `kyb-caps` fixture with a keep-list spanning BOTH capset words —
      `"capabilities": ["cap_net_bind_service", "cap_bpf"]` — whose command reports
      its own /proc/self/status CapEff to /dev/console, and assert the exact hex
      from inside the child: `0000008000000400` (validated above). That is the only
      assertion that distinguishes a correct mask build from a wrong one, and it is
      the same shape kyb-confined/kyb-seccomp/kyb-landlock already use. Update the
      `services parsed: N` and `removed service cgroups: N` markers and the counts
      in state.md. Note this fixture must NOT also set `uid`, or it hits HIGH-3.

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
  62 -> 66 harness properties.
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
