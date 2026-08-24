# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.5.0] — 2026-08-24

**Services actually come from config.** Requires **argonaut 1.10.0**. Suite
203 → 235 assertions, 0 failures; both arches clean; the QEMU harness now
boots with real services and asserts on them.

This is the largest gap the 1.4.2 audit surfaced. `load_config()` parsed four
scalar fields and never touched the services array — main.cyr said so in a
comment — so `config_services(cfg)` was always the empty vec argonaut's
default returns, `resolve_service_waves` short-circuited on it, and
**`start_services()`'s wave-loop body had never executed in a real boot.**
Everything downstream of it was untested by construction, and three separate
defects were hiding there. Running the code for the first time found all
three.

### Added — JSON service definitions

- **`src/lib/svc_config.cyr`** (new) — `svc_defs_from_json` /
  `svc_def_from_json`, mapping a config document to argonaut
  `ServiceDefinition`s: `name`, `description`, `binary`, `args`,
  `depends_on`, `type`, `restart`, `enabled`, `pid_file`, and a nested
  `health_check`. In its own module so `test.cyr` can drive it with literal
  documents instead of needing a file on disk.
- `load_config` now parses the **value tree** (`json_v_parse_buf`) rather
  than the flat `json_parse` pair list. The array was structurally out of
  reach of the old call — bayan has had `json_v_*` the whole time.
- Enum fields go through argonaut 1.10.0's `*_parse` inverses rather than a
  hand-rolled mapping, and an unrecognised value **rejects the service**
  rather than defaulting it. A typo in `restart` should not silently become
  `RESTART_ALWAYS`.
- Type-strict accessors: `"enabled": "false"` is a *string*, and treating it
  as truthy because the key exists would enable a service the operator
  disabled. Relatedly, `log_to_console` is now read as a real JSON bool —
  the old code compared it against the **string** `"false"`, so `false`, the
  spelling any operator would actually write, was ignored.
- A malformed service entry is skipped with a log line rather than aborting
  the whole config: losing one misconfigured service is recoverable, losing
  every service to one typo is a dead boot.

### Fixed — three defects in the never-executed start path

- **Every `init_start_service` call would have returned -1.**
  `resolve_service_waves` returns waves of boxed `Str`, but argonaut keys its
  service map by cstr (`str_data(svc_def_name(sd))`), so passing the box made
  `map_get` miss silently. kybernet already computed `name_cs` one line
  above and passed `name` anyway. Same fix on the restart path in
  `handle_sigchld`. Filed in the 1.4.2 audit as reachable-only-in-theory;
  1.5.0 is when it became reachable.
- **The boot-mode default services were never started.** `start_services`
  resolved waves over `config_services(config)` — the config half only —
  while `argonaut_init_new` registers the defaults *and* the config
  services. Now resolves over argonaut 1.10.0's `init_service_defs(init)`,
  which returns the full registered set.
- **Every successful oneshot was logged as "FAILED to start".**
  `init_start_service` is tri-state, not a pid: `>0` a live process, `==0` a
  `SVC_ONESHOT` that ran to completion with exit 0 (there is no surviving
  process to place in a cgroup), `<0` failure. The `pid > 0` test collapsed
  the middle case into the failure arm.

### Changed — the QEMU harness starts real services

`build-initramfs.sh` stages an actual `/etc/kybernet/config.json` with two
oneshots where `kyb-svc` depends on `kyb-dep`, and `boot-test.sh` asserts
three new markers: `config: services parsed: 2`, and
`completed (oneshot):` for **both** services. The dependent's marker is the
load-bearing one — it only appears if wave ordering worked *and* a completed
oneshot satisfied a dependency.

**Boot budget raised 3000 → 6000 ms, and it is not a regression.** This is
the first release where the harness forks anything at all. Measured: ~2000 ms
of the new cost is `daimon`, a `BOOT_MINIMAL` default whose ready check is
10 retries × 200 ms of TCP connects against port 8090, which nothing listens
on because its binary is not staged in the initramfs. That is argonaut
behaving correctly for a service that fails to come up. Typical run is now
~2700 ms; a spin or hang still blows well past 6000 ms.

### Upstream — argonaut 1.10.0

Driven entirely by this release; see argonaut's changelog. Headline: a
**completed oneshot could never satisfy a dependency**, because the check
required `STATE_RUNNING` and a oneshot ends `STATE_STOPPED` — so nothing
could depend on a oneshot, which is exactly how you express "run this setup
step before X". Found by this harness on its first boot with a real
dependency. Plus the enum `*_parse` inverses, `init_service_defs`, the
`svc_def_set_*` setters, and `svc_hc_*` HealthCheck accessors (prefixed to
avoid a silent collision with agnostik's same-named `hc_*` for a different
struct layout).

### Tests

- `test_svc_config_parse` — field mapping, arg/dep arrays, `enabled: false`
  honoured, defaults for a minimal entry, malformed entries skipped, and an
  unrecognised enum rejecting the service rather than defaulting it.
- `test_svc_config_health_check` — nested health-check construction, and a
  malformed one rejecting the service rather than starting it unmonitored.
- `test_config_services_reach_argonaut` — the end-to-end property: N services
  in config become N registered with argonaut, the registered set includes
  the defaults, names resolve by cstr, and every wave name resolves via
  `str_data` (the seam that made every start return -1).

---

## [1.4.3] — 2026-08-24

**Closes the one finding 1.4.2 deferred, and turns the rest of the codebase's
deferrals into a roadmap.** Requires **argonaut 1.9.0**. Suite 194 → 203
assertions, 0 failures; both arches clean; harness green including the reactor
gate (21 wakeups of a 500 ceiling).

1.4.2 filed audit **HIGH-1** — 686 lines of seccomp / Landlock / privilege-drop
code, ~26 % of kybernet's source, reachable from no production path — and
deferred it as *"not source-fixable in this repo"*. That was wrong. argonaut is
first-party; the correct fix was to add the missing seam rather than wait for
one. **All 20 findings from the 2026-08-24 audit are now closed.**

### Added — per-service sandbox at pre_exec (audit HIGH-1, closed)

- **argonaut 1.9.0** contributes the seam: `argonaut_set_pre_exec_hook(fp)`,
  invoked in the **child** after the signal-mask reset and immediately before
  `execve`, receiving the `ServiceDefinition`. It **fails closed** — a non-zero
  return aborts the child with **exit 126** (distinct from 127, "exec failed")
  instead of exec'ing the service unconfined. argonaut does not interpret the
  policy; it supplies the window and the definition.
- argonaut also exposes `svc_def_seccomp` / `svc_def_landlock` /
  `svc_def_capabilities` (+ setters). These three fields had been sitting in
  `ServiceDefinition` at offsets 144/152/160, zero-initialised, since the struct
  was written — with no accessors, so no consumer could reach them. Adding them
  is **layout-neutral and additive**.
- **`src/lib/service_sandbox.cyr`** (new) — `kyb_pre_exec`, registered in phase 6
  before any service can spawn. Applies, in this order:
  **no_new_privs → capabilities → Landlock → seccomp.** The order is
  load-bearing: seccomp goes last because an installed filter would otherwise
  kill the prctl/capset/landlock calls above it unless every one were
  allowlisted.

  **Policy is opt-in per service.** All three fields default to 0; a service with
  no policy gets a strict no-op and behaves exactly as it did in 1.4.2. This is
  deliberate — a uniform allowlist applied to every service is an efficient way
  to make a system unbootable, and PID 1 is the wrong place to discover that.
  Authoring profiles for the default AGNOS services is the **v1.5.2** roadmap
  item.

  The hook was factored into its own module rather than left in `main.cyr` so
  `test.cyr` can exercise it directly.

### Fixed — `sandbox_from_config` was fail-open (MEDIUM-1)

Found while making this function load-bearing. It returned a **bare `0`** — not
a `Result` — for `case 0` and `default`, and `return` exits the whole function
rather than the iteration. So a single `FS_NO_ACCESS` rule (0 is a legitimate
agnostik `FsAccess` value) **silently discarded the entire sandbox**: every other
rule in the config went unapplied, `sandbox_apply` was never reached, and the
caller got `0`, which `is_err_result` reports as success.

Now: access 0 skips only its own rule (fail-closed — a path absent from a
Landlock ruleset is denied), 1/2 map as before, 3 (read+exec) is wired to the
handler `_access_to_flags` already supported, and anything unrecognised returns
`Err(EINVAL)`.

### Tests

- `test_pre_exec_hook` — no-policy service is a strict no-op; null `svc_def` is
  safe (this runs in a forked child of PID 1, where a fault is a dead service);
  and a capability policy while unprivileged **fails closed**, so argonaut aborts
  the child rather than exec'ing unconfined.
- `test_sandbox_from_config_fail_closed` — empty config is `Ok`, an
  `FS_NO_ACCESS` rule returns a real `Result`, and an unrecognised access fails
  closed.
- argonaut side: `tests/tcyr/pre_exec_hook.tcyr` (18 assertions) covers field
  defaults, setter round-trips, neighbour fields provably undisturbed, hook
  registration returning the prior value, the hook running with exec still
  happening (child exits 0), the fail-closed path (child exits 126, binary never
  runs), and clearing the hook.

### Added — v1.5.x roadmap arc

A sweep of the source and of the 1.4.2 audit's survived-but-unfixed findings,
organised into an arc. The through-line: kybernet's *mechanisms* are now correct
and gated, but several are wired to nothing.

- **v1.5.0 — services actually come from config.** `load_config()` never
  populates the services array, so `config_services()` is always empty,
  `resolve_service_waves` short-circuits, and **`start_services()` is a no-op on
  every real boot**. Everything downstream is untested-by-construction —
  including a latent `Str`/cstr mismatch where `init_start_service` receives a
  boxed `Str` and treats it as a cstr.
- **v1.5.1 — boot stages that do something.** `execute_boot_stage` is
  `return 1` for all 11 arms plus `default`, so `init_mark_step_failed` is
  unreachable and the emergency path can never fire.
- **v1.5.2 — per-service security profiles.** Completes HIGH-1 by authoring real
  profiles; also the two validations 1.4.2 flagged (`capset` on privileged
  hardware, the eight asm-generic aarch64 seccomp numbers on real hardware).
- **v1.5.3 — lifecycle cleanup and observability.** Service cgroups never
  removed; `reload_config` leaving argonaut half-updated on SIGHUP; edge-boot
  refusal reasons never reaching `/dev/kmsg`; the edge-boot time budget measured
  after the work it is meant to bound; the cgroup path cache having no production
  hits.
- **v1.5.4 — close the remaining edge-boot deferrals.** Folds in the stalled
  v1.2.1 scope — `edge_boot.cyr` still detects TPM and dm-verity but verifies
  neither. Unblocked now that argonaut is in scope for edits.

### Changed

- `[deps.argonaut]` `1.8.6` → **`1.9.0`**.
- README.md and CLAUDE.md no longer describe the security stack as unwired;
  they now state that the mechanism is delivered and the profiles are v1.5.2.
- CLAUDE.md's "do not modify dep repos" rule is corrected: every AGNOS dep is
  first-party and editable — **only the cyrius language repo is off-limits**.
  Deferring a fix as "blocked upstream" when the upstream is first-party is the
  mistake this release exists to correct.

---

## [1.4.2] — 2026-08-24

**P(-1) security / correctness / hardening pass — the fifth, and the first
since 1.1.5.** Full report in
[`docs/audit/2026-08-24-audit.md`](docs/audit/2026-08-24-audit.md).

**2 CRITICAL / 5 HIGH / 7 MEDIUM / 6 LOW — 19 of 20 closed**, one deferred on an
upstream blocker. Eight independent audit lenses swept the full source; every
finding was then handed to a separate pass instructed to **refute** it, and 13 of
39 candidates did not survive (listed in the report so they are not re-filed).
Suite **177 → 194 assertions**, 0 failures, both arches clean, QEMU harness green.

Both CRITICALs were invisible to every existing gate, and that — not the code —
is the real finding. Fixed structurally, not just patched.

### Security / correctness — CRITICAL

- **CRITICAL-1 — the health and watchdog timerfds were never drained, so PID 1
  span at 100 % CPU ~10 seconds after every boot and eventually panicked the
  kernel.** `epoll_add_read` registers with plain `EPOLLIN` (level-triggered) and
  a timerfd stays readable until its 8-byte expiration counter is `read()` — but
  both fds were consumed inline as call arguments (`epoll_add_read(epfd,
  result_unwrap(hfd_r), TOKEN_HEALTH)`) and bound to nothing, so nothing in the
  tree *could* drain them. **Measured** against the real reactor: 1,019,588
  iterations with `epoll_wait` never blocking once, and 269,171,480 bytes of heap
  consumed, in 3 seconds (~90 MB/s of unreclaimable bump-arena growth). PID 1 is
  exempt from the OOM killer, so the kernel kills every other process first; when
  mmap finally fails `alloc()` returns 0 and the next `store64` writes to address
  0 → SIGSEGV in PID 1 → *"Attempted to kill init!"*. Fixed by retaining both fds
  and draining via the stdlib's `timerfd_drain()` as the **first** statement of
  each handler, ahead of the `g_init == 0` early return.
- **CRITICAL-2 — `struct epoll_event` layout was hardcoded to x86_64.** x86_64 is
  the only arch that packs it (stride 12, `data` at +4); aarch64 uses the natural
  layout (stride 16, `data` at +8). The cyrius stdlib already dispatches on this
  when *building* an event, so the read side was provably inconsistent with the
  write side. On aarch64 the kernel filled 128 bytes into a 96-byte buffer — a
  kernel-written heap overflow — and every token decoded from the wrong offset,
  so all events fell through to "unknown epoll token": **SIGCHLD and SIGTERM were
  never processed**, meaning no reaping and no shutdown. Now `#ifdef
  CYRIUS_ARCH_*`-gated, matching the notify.cyr precedent.

### Security — HIGH

- **HIGH-2 — the edge-boot trust gate fell through to a full boot.**
  `edge_boot_run()` is fail-closed internally, but `drop_to_emergency()` *returns*
  when the shell exits, and the caller then continued into phases 7 and 8. On a
  device demanding `tpm_attestation`, removing the TPM produced a FATAL log, a
  root recovery shell, and then a completely normal boot of every service. Now
  powers off after the recovery shell rather than continuing.
- **HIGH-3 — the seccomp filter had no architecture check.** It loaded
  `seccomp_data.nr` as instruction 0 and never examined `seccomp_data.arch`.
  Syscall numbers are per-ABI (x86_64 nr 11 is `munmap`; i386 nr 11 is `execve`),
  so a process switching ABI via `int 0x80` or x32 was matched against an
  allowlist built for different numbering — the textbook seccomp bypass. The
  filter now emits `LD arch` / `JEQ AUDIT_ARCH → else KILL` / `LD nr` ahead of the
  allowlist, and `test_seccomp_builder` asserts each of those three instructions.
- **HIGH-4 — seccomp jump offsets truncated past 254 syscalls.** BPF `jt`/`jf` are
  u8; the only guard was against `BPF_MAXINSNS` (4096), so larger filters had
  offsets silently truncated by `store8` and jumped to arbitrary instructions.
  Capped at `SECCOMP_MAX_ALLOW = 254` with boundary tests both ways.
- **HIGH-5 — `seccomp_basic_service()` hardcoded x86_64 syscall numbers.** On
  aarch64 those numbers name unrelated calls, so the filter denied `read`/`write`/
  `exit` (killing every sandboxed service on its first `read()`) while allowing
  calls nobody intended. Now a per-arch table that also handles the real ABI
  differences — no `dup2`, no `arch_prctl`, `epoll_pwait` not `epoll_wait`.

### Deferred — HIGH-1: the advertised security stack is applied to nothing

`seccomp.cyr` + `sandbox.cyr` + `privdrop.cyr` — **686 lines, ~26 % of kybernet's
source** — are referenced from `test.cyr` and `bench.cyr` only. seccomp and
Landlock must be installed in the child between `fork` and `exec`, and argonaut
(which owns spawning) exposes **no pre_exec hook**, so there is no seam for
kybernet to run code in the child. Not fixable in this repo.

README.md and CLAUDE.md previously advertised this as delivered; both now state
plainly that the modules are built and tested but **not applied**. The defects
found *inside* that code (HIGH-3/4/5, MEDIUM-1) are fixed now so it is correct
whenever the hook lands.

### Security / correctness — MEDIUM

- **MEDIUM-1 — `drop_capabilities()` dropped only the bounding set.**
  `PR_CAPBSET_DROP` bounds what can be *regained* on exec; it takes away nothing
  the process holds. `secure_pre_exec(0, 0, 0)` therefore returned `Ok` while
  leaving the caller fully privileged. Now also issues `capset(2)` to clear
  effective/permitted/inheritable, and stops swallowing drop failures.
- **MEDIUM-2 — TPM PCR read failed open.** sigil's `exec_capture` returns the
  captured byte count and discards the child's wait status, so a missing
  `/usr/bin/tpm2_pcrread` surfaces as `Ok(0)` and PCRs come back zero-filled — an
  attestation "pass" from a tool that never ran. Checked consumer-side.
- **MEDIUM-3 — service names were interpolated raw into the cgroup path**, so
  `/` or `..` walked out of the slice into an arbitrary cgroup directory that
  kybernet then created and wrote `cgroup.procs` into. Same defect argonaut closed
  at 1.8.6; `cgroup_name_is_safe()` now gates both entry points.
- **MEDIUM-4 — the emergency shell inherited PID 1's blocked signal mask**
  (inherited across fork, preserved across execve), so Ctrl-C was inert in the one
  shell where an operator most needs it.
- **MEDIUM-5 — crash-restarted services escaped their cgroup.**
  `init_restart_service()` returns a live PID and it was discarded, so the first
  restart left the service outside its cgroup for the rest of uptime — no limits,
  and `cgroup.kill` misses it at shutdown.
- **MEDIUM-6 — `slog()` did no JSON escaping**, so a service name containing a
  quote or newline produced malformed JSON and could forge log fields.
- **MEDIUM-7 — unbounded arena growth in the reactor and logging hot paths.** The
  allocator is a bump arena with no free; `epoll_wait_events` allocated on every
  wakeup and `klog2` built two `str_builder`s per call *even with slog disabled*.
  Reactor scratch moved to BSS with a `vec_truncate`-reused result vec; the
  structured-log line is now built in a static buffer with zero allocation.

### Fixed — LOW

- `_log_write`'s `copylen = 254 - plen` went **negative** for a prefix longer than
  254 (a negative memcpy length from PID 1). Latent; now clamped. The 1.1.5 audit
  bounded `msg` but not `plen`.
- The literal `syscall(26, 0x30)` boot checkpoint documented only its x86_64
  fallback; on aarch64 it lands on `inotify_init1(0x30)`. Equally inert, now
  equally documented.
- `timer_new` ignored `timerfd_settime`'s result (an armed-looking fd that never
  fires — health/watchdog silently dead), and `eventloop_setup` discarded
  `epoll_add_read`'s Result, leaking the fd. Both checked, closed and logged.
- `do_shutdown` closed `g_log_fd` without zeroing it; since that global doubles as
  slog's open-flag, the following `klog` wrote to a closed, eventually recycled
  descriptor.
- `_mount_table[288]` sat at **exact** capacity — the 1.1.5 audit's deferred LOW-2.
  Grown to `[480]`; the next entry added would have overflowed BSS silently.
- **The benchmark regression gate had a blind spot**: it split CSV rows on comma,
  so the two benchmark labels containing a comma never matched their history row
  and were silently exempt — 2 of 51.

### Added — the reactor gate (`kybernet.harness=loop`)

The root cause behind CRITICAL-1 surviving four audits: **no release gate had ever
executed a single event-loop iteration.** `kybernet.harness=1` shuts down at
phase 9, before the reactor starts, so the entire defect lived past the gate's
last instruction.

`qemu/boot-test.sh` now runs a second QEMU pass with `kybernet.harness=loop`,
which runs the real loop for 5 s with shortened timer intervals and prints its
wakeup count. A reactor that sleeps between ticks wakes ~21 times; the ceiling is
500. **Verified to fail on the unfixed shape** — with the drains commented out the
gate reports `FAIL: reactor gate produced no wakeup count` followed by `FAIL:
kernel panicked in reactor mode`, reproducing the full predicted chain in a real
PID-1 environment.

Also added: `test_timerfd_drain_clears_readiness`, which asserts an undrained
timerfd *stays* ready (proving the test exercises the real condition) and that a
drain clears it.

### Verification

- **194/194 tests pass** (was 177; +17 assertions, all regression coverage for
  findings above).
- x86_64 and aarch64 both build clean under `CYRIUS_DCE=1`.
- `cyrius deps --verify`: 68 verified, 0 failed.
- **QEMU harness OK** — all markers, 682 ms of a 3000 ms budget, **reactor
  wakeups 21** of a 500 ceiling.
- **Benchmarks: 25 improved, 0 real regressions.** `epoll_wait(timeout=0)`
  **365 → 302 ns/op (−17 %)** from removing the per-wakeup allocations;
  `event_token+flags` −20 %; `klog2_sim` −8 %. The gate flagged two items which
  were confirmed as **noise, not regressions**: `cgroup_file (best case, same
  pair)` measured 3/3/4 ns across three re-runs against a flagged 5 (at 3–5 ns/op
  a single nanosecond exceeds the 15 % threshold, and its code path is untouched
  — this was also the first run it was ever compared, the comma bug having
  exempted it), and `is_mounted(/proc)` measured 55/57/56 against a flagged 60,
  dominated by `/proc/self/mounts` read variance.

### Standing rules added to the audit checklist

1. **Kernel struct *layout* is as arch-specific as the syscall number** — rule 1's
   sibling, and the class behind CRITICAL-2.
2. **Every level-triggered epoll registration needs a drain** — register the fd,
   *retain* the fd, drain it before any early return.
3. **A release gate that stops before the event loop does not test the event
   loop** — keep `kybernet.harness=loop` green and in CI.

---

## [1.4.1] — 2026-08-24

**Toolchain bump to cyrius 6.5.35, every dep to its latest tag, and a
manifest that stopped silently downgrading its own dependencies.** The
cyrius pin moves **6.4.62 → 6.5.35** (matching argonaut 1.8.6 / agnostik
1.4.0 / libro 2.8.12), all four git deps advance, and two manifest defects
are closed: kybernet's `[deps.patra]` pin was **overriding the newer
stdlib fold with an older patra**, and `path = "../…"` fields meant local
builds never resolved the pinned tags at all. **No functional source change was
required** — 177/177 tests, both arches, QEMU harness green.

### Fixed — the patra pin was silently downgrading the stdlib fold

cyrius 6.5.20+ **folds** patra, sakshi and sigil into the stdlib snapshot.
`cyrius deps` overlays a git dep's resolution on top of that snapshot on
*every* build, so a `[deps.<name>]` pin that lags the fold **downgrades the
file**, and `deps --verify` cannot catch it (the lock is written from disk,
recording the downgraded hash). The toolchain said so out loud:

```
warning: ./lib/ shadows version-pinned .../lib — 2 bundled lib(s) differ:
      sakshi 2.4.3 (pinned: 2.4.6), patra 1.12.9 (pinned: 1.12.10)
```

- **`[deps.patra]` git block removed; `patra` added to `[deps].stdlib`.**
  `lib/patra.cyr` is now byte-identical to the fold *and* to patra
  1.13.10's `dist/patra.cyr` (`7cdc24d8…`). The transitive sakshi
  downgrade cleared with it (2.4.3 → 2.4.11, byte-identical to the fold),
  helped by sigil 3.12.7+ dropping its own stale `deps.sakshi` block.
  Mirrors **argonaut 1.8.5**, which retired the identical two blocks for
  the identical reason.

### Fixed — `path = "../…"` made the tag pins inert locally

`[deps.agnostik]`, `[deps.libro]` and `[deps.argonaut]` each carried a
`path` alongside `git`/`tag`. When `path` resolves, cyrius makes the
`git`/`tag` fields **fully inert and skips commit-pin verification** — so
local builds compiled against whatever the sibling working tree happened
to contain, and an unreleased tag would pass every local gate then
hard-fail CI. Measured: `cyrius.lock` carried **3** `commit` lines before,
**5** after.

All three `path` fields are dropped. Local resolution now *is* the CI
resolution — verified in a sibling-free tree: identical lock and a
byte-identical 1,354,272-byte binary.

### Changed — dependency pins

| Dep | 1.4.0 | 1.4.1 |
|-----|-------|-------|
| cyrius | 6.4.62 | **6.5.35** |
| sigil | 3.11.1 | **3.12.9** |
| agnostik | 1.3.4 | **1.4.0** |
| libro | 2.8.0 | **2.8.12** |
| argonaut | 1.8.4 | **1.8.6** |
| patra | 1.12.9 (git dep) | **1.13.10** (stdlib fold) |
| sakshi | 2.4.3 (transitive) | **2.4.11** (stdlib fold) |

The thin sigil surface is unchanged in shape (`dist/sigil-mldsa.cyr` +
`src/sha_ni.cyr` + `src/sha256.cyr` + `src/hex.cyr` + `dist/sigil-tpm.cyr`)
and still mirrors libro's own sigil block, which it must: cyrius dedups
both same-named `sigil` deps to kybernet's root list. Verified still thin —
`.bss` **94,568 B** and **zero** x509/RSA/authenticode symbols in the
binary, against the ~13 MB the monolith would add.

### Changed — cyrius.cyml is documentation, not a ledger

Trimmed **6,924 → 2,784 bytes**. Per-entry archaeology moved here, to the
changelog; the manifest keeps short statements of fact and pointers.

- **No `#` comments inside the `[deps].stdlib` array.** The manifest
  parser stops collecting entries at one and silently truncates the list —
  it does not error. The 1.4.0 array carried five such comments.
- Every `[deps.*]` section now sits at bytes **1,746–2,438**, was
  **5,408–6,557**. cyrius ≤ 6.5.27 read only the first **4,095** bytes of a
  manifest and resolved a `[deps]` section past that window to *zero*
  dependencies, silently; 6.5.28 raised the window to 65,535 and made it
  fail-closed. The trimmed file clears it by a wide margin either way.

### Fixed — CI format gate (broken by the toolchain bump)

cyrius 6.5.28 made **`cyrius fmt` rewrite files in place and print
nothing** (flagged BREAKING upstream; `--dry` is the old stdout
behaviour). The existing gate — `diff -q <(cyrius fmt "$f") "$f"` —
therefore diffs an **empty stream** against every file: it reports drift
unconditionally *and* silently reformats the CI checkout underneath the
later build/test steps. Replaced with `cyrius fmt "$f" --check`, which
sets the exit code and is verified non-mutating at 6.5.35. Matches
argonaut CI. Stale `agnosys` references in both workflows removed.

### Upstream breaking changes — both inert for kybernet

- **argonaut** `audit_log_verify_inclusion` / `audit_log_verify_consistency`
  now take the trusted root explicitly. kybernet calls **neither**, and
  cyrius 6.5.1 makes a wrong-arity call a hard compile error, so a stale
  call site could not have survived the build.
- **libro 2.8.11/2.8.12** change the audit-chain **on-disk preimage**;
  chains written by libro ≤ 2.8.10 will not verify. Affects only
  deployments with `config.audit_persist` enabled (default off). kybernet
  makes zero direct `audit_*` calls — it imports argonaut's audit modules
  only to close the compile-time symbol graph.

### Security — argonaut 1.8.6 fixes that do reach PID 1

argonaut's fourth P(-1) pass (0 CRITICAL / 0 HIGH / 9 MEDIUM / 6 LOW).
Two land directly in kybernet's event loop, which calls `init_poll_health`
→ `execute_health_check`:

- **MEDIUM-2 / MEDIUM-7 — two NULL-pointer dereferences in the health
  loop.** `execute_health_check` returned a bare `0` for a non-`http://`
  target and dereferenced `target` with no null check for every type
  except `HC_PROCESS_ALIVE`, while callers immediately do
  `load64(result + 16)`. Both regression tests crashed argonaut's test
  binary outright before the fix. In kybernet that is a PID-1 fault —
  a kernel panic — reachable by configuring a service with an `https://`
  health URL.

argonaut's MEDIUM-1 (`notify_parse` buffer over-read) and MEDIUM-5
(`verify_emergency_auth` failing open) do **not** reach kybernet: it uses
its own `src/lib/notify.cyr` and its own `drop_to_emergency()`.

### Changed — source (comments only)

- `_ll_access_to_kernel` (`src/lib/sandbox.cyr`) keeps its explicit
  `if`-ladder, but the comment no longer describes the `switch` miscompile
  as live: **cyrius 6.5.20 fixed it.** Root cause was the v5.6.27 regalloc
  NOP-harvest compactor, which deleted the register picker's 4-byte NOPs and
  repaired jump displacements but did not know the switch jump table existed
  — shifting every entry **+4 per preceding case body**. That is exactly why
  bodies of `{ return N; }` were never affected (no local store ⇒ no NOP ⇒ no
  shift) and the accumulating form always was. The ladder stays: correct on
  every toolchain, and this is the per-service Landlock path where a
  miscompile is a PID-1 crash.

### Verification

- **177/177 tests pass**; no functional source change.
- x86_64 **1,354,272 B** (was 1,011,264); aarch64 **1,775,984 B** (was
  1,355,160). Growth is `.text` from the newer agnostik/libro/patra;
  `.bss` holds at 94,568 B.
- `cyrius deps --verify`: **68 verified, 0 failed**, 5 commit-pinned.
- **Benchmarks: no regression ≥ 15 %**; 51 recorded, 18 improved
  (`timerspec_new` −37 %, `capability_set(new+3push)` −25 %,
  `epoll_event_new` −27 %).
- **QEMU PID-1 harness: OK**, all markers, **911 ms** and **673 ms** on two
  runs against a 3000 ms budget (1.4.0 recorded 951 ms).
- **Sibling-free reproduction**: identical `cyrius.lock`, identical binary
  size, 177/177 — so CI resolves exactly what was built locally.

---

## [1.4.0] — 2026-07-13

**Toolchain leap to cyrius 6.4.62 + full dependency refresh, and a THIN sigil
surface: the PID-1 binary drops 14.35 MB → 0.96 MB (x86_64) / 1.29 MB (aarch64).**
The cyrius pin jumps **6.2.11 → 6.4.62** (the whole AGNOS boot pack — argonaut
1.8.4 / libro 2.8.0 — moved with it), every sibling dep advances to its latest
tag, and kybernet stops pulling the monolithic `dist/sigil.cyr`. Two consumer-side
source migrations were forced by the new toolchain/dep graph (both below); after
them the binary is 93 % smaller, **177/177 tests pass**, both arches build clean,
and the QEMU PID-1 harness is green (**951 ms** / 3000 ms budget).

### Changed — manifest

- **`[package].cyrius` pin `6.2.11` → `6.4.62`.** Clears the toolchain-drift
  warning; matches argonaut 1.8.4 / libro 2.8.0.
- **Dep tags → latest:** agnostik `1.3.1` → `1.3.4`, libro `2.7.5` → `2.8.0`,
  patra `1.11.2` → `1.12.9`, argonaut `1.8.3` → `1.8.4`, sigil `3.9.0` → `3.11.1`
  (transitive sakshi → 2.4.3). All 11 argonaut source modules kybernet imports
  are unchanged.
- **`[deps] stdlib` — added `atomic`, `sync`, `sakshi`.** patra 1.12.9's dep
  sidecar now requires `atomic`+`sync` (its WAL/object-store locking moved onto
  the stdlib `sync` mutex, built on `atomic`); libro 2.8.0's sidecar lists
  `sakshi` as a stdlib leaf (previously transitive via agnosys, now gone).
  Without these `cyrius deps` aborts resolving patra/libro. `atomic` precedes
  `sync`; `sigil` stays an external git dep (not a stdlib pin).

### Changed — THIN sigil surface (the headline)

- **`[deps.sigil]`: `dist/sigil.cyr` → `dist/sigil-mldsa.cyr` + `src/sha_ni.cyr`
  + `src/sha256.cyr` + `src/hex.cyr` + `dist/sigil-tpm.cyr`.** At 3.11.1 the full
  bundle inlines the x509/RSA/authenticode path, whose bignum tables carry
  **~13 MB of static `.bss` that DCE cannot strip** and kybernet never touches —
  a full-bundle build measured **14.35 MB** (`.bss` 13,057,440 B). kybernet's
  real sigil surface is two disjoint pieces: (1) the crypto set libro's
  merkle/audit path needs transitively via the argonaut audit modules
  (`sigil-mldsa` = ed25519 + ML-DSA + SHA-512 + crypto_scratch, plus `sha_ni` /
  `sha256` / `hex`) — this **mirrors libro 2.8.0's own sigil block**, and is
  mandatory because cyrius dedups the two same-named `sigil` deps to kybernet's
  root list, so it must satisfy libro's `ed25519`/`hex`/`SIG_ALG_ED25519` or
  `lib/libro.cyr` fails to compile; and (2) kybernet's own TPM surface via
  sigil's per-primitive **`tpm` distlib profile** (`dist/sigil-tpm.cyr` =
  `tpm_detect` / `tpm_read_pcr` / `TPM_SHA256`). Result: **0.96 MB** x86_64
  (`.bss` 90,320 B) / **1.29 MB** aarch64, with **zero** duplicate-symbol
  warnings from sigil (the old full-bundle `run_capture`/`_hex_nibble` warnings
  are gone).
- **dm-verity capability probe is now local** (`src/lib/edge_boot.cyr`,
  `_eb_dmverity_supported`). sigil ships **no dm-verity distlib profile**, and
  its raw `src/dmverity.cyr` cannot be pulled cross-repo (unguarded internal
  `include "src/error.cyr"`). The probe is byte-for-byte sigil's
  `dmverity_supported()` (sysfs `/sys/module/dm_verity`, then a `veritysetup
  --version` fallback via `exec_vec`) — no behavior change to the
  `readonly_rootfs` boot gate. When 1.2.1 wires real dm-verity *verify* (needs
  sigil's `dmverity_open`/`verify` with device paths), revisit sourcing a sigil
  dm-verity profile.

### Fixed — consumer-side migrations for the new dep graph

- **`src/test.cyr` agnostik error-kind clash (was 3 failing assertions).** The
  test built errors with bare `ERR_PERMISSION_DENIED` / `ERR_TIMEOUT`. Under the
  1.4.0 graph those bare names no longer resolve to agnostik (which namespaced
  its kinds to `STIK_ERR_*`) — they now bind to **sigil's** `ERR_PERMISSION_DENIED
  = 3` and **sakshi's** `ERR_TIMEOUT = 5`, the wrong kinds for
  `agnostik_err_new`'s kind→code map (PERMISSION_DENIED mapped onto
  `STIK_ERR_TIMEOUT` → code 1004 + inverted retriability). Switched the test to
  agnostik's `STIK_ERR_*`; `CODE_PERMISSION_DENIED` is unique to agnostik and
  unchanged. Test-only; no production code referenced the bare names.
- **`src/lib/sandbox.cyr` `_ll_access_to_kernel` — cyrius 6.4.62 `switch`
  MISCOMPILE (a PID-1 crash risk).** 6.4.62 miscompiles a `switch` of this exact
  shape — many cases whose bodies **accumulate** (`mask = mask | CONST`) inside a
  loop, closed by a `default: return` — into a **SIGSEGV** at the call site.
  (A `switch` of `case N: return K` bodies compiles fine — the boot-stage switch
  at `main.cyr:427` and the others are unaffected; only this accumulate-in-loop
  form breaks. Verified: the switch segfaults on the first call, the if-ladder
  is correct.) Rewrote it as an explicit `if`-ladder. This is the Landlock mask
  kybernet applies to **every sandboxed service**, so the miscompile would have
  crashed init on first service sandbox — not merely a bench failure. Surfaced
  by `bench_sandbox_from_ruleset`, which the 177 tests never exercised (they
  cover ruleset *construction*, not the `sandbox_from_ruleset` syscall path).

### Benchmarks

- `bash scripts/bench-history.sh`: the 6.4.62 codegen + thin binary move nearly
  every microbench **-60 % to -82 %** (e.g. `capability_set` -72 %, `Ok+is_ok`
  -79 %, `alloc(4 sizes burst)` -82 %, `sandbox(new+3 rules+count)` -71 %). One
  flagged **regression: `alloc(3)+reset+init` 202 → 554 ns/op (+174 %)** — a
  6.4.62 allocator-internals change to the `alloc_reset()`+`alloc_init()` pair.
  **Bench/test-only, zero production impact**: PID 1 initialises the arena once
  at boot and never resets it (audit rule #8). Explained, not fixed (the
  allocator is cyrius stdlib; not modified from here).

### Verification

- `cyrius deps` clean (66 deps locked, 3 commit-pinned). x86_64 + aarch64 build
  clean under DCE. `cyrius test src/test.cyr` **177/0**. `qemu/boot-test.sh` all
  markers, **951 ms**. (CI resolution needs the sigil 3.11.1 / libro 2.8.0 /
  patra 1.12.9 / agnostik 1.3.4 / argonaut 1.8.4 tags live — all confirmed.)

## [1.3.5] — 2026-06-19

**Re-sourced the edge-boot trust/storage primitives from sigil; dropped agnosys
(agnosys → agnodrm decomposition).** kybernet's edge-boot path used agnosys's TPM
+ dm-verity + LUKS primitives (`tpm_detect` / `tpm_read_pcr` /
`dmverity_supported`, …). The decomposition moved that trust+storage stack into
**sigil** (promoted to first-class in `dist/sigil.cyr` at 3.9.0).

### Changed
- **Dropped `[deps.agnosys]` / `[deps.agnosys-storage]` / `[deps.agnosys-trust]`.**
  agnosys-core was vestigial — kybernet references no error/syscall/logging symbol
  from it (the old "56 fns" comment was stale; kybernet uses its own
  `src/lib/log.cyr` + argonaut + cyrius stdlib). Storage+trust → a new
  **`[deps.sigil]` 3.9.0**. This also fixes the broken `path = "../agnosys"` (the
  repo folder was renamed to `../agnodrm`).
- **`[deps.libro]` 2.7.4 → 2.7.5** (libro's own agnosys → sigil rewire; keeps the
  transitive sigil aligned at 3.9.0).
- Verified locally: `cyrius deps` clean, `cyrius test src/test.cyr` **177/0**.
  (CI resolution needs the libro 2.7.5 + sigil 3.9.0 tags live.)

## [1.3.4] — 2026-06-15

**Toolchain leap to cyrius 6.2.11 + full dependency refresh.** The cyrius pin
jumps **6.0.56 → 6.2.11** (the 6.0.x / 6.1.x / 6.2.x arc — ~90 minors), every
sibling dep moves to its latest tag, and the stdlib reorganization that landed
in the 6.1.x line (the `json`→`bayan` carve, sigil self-containing bigint, and
the end of implicit stdlib auto-include) is adopted. Four small source changes
were required this cut — the first kybernet `src/` movement since 1.2.0 — all
forced by toolchain behavior changes, not feature work. Both arches build
clean, **177/177 tests pass**, QEMU PID-1 harness green (812 ms / 3000 ms), and
the bench gate flags a broad-but-explained microbenchmark shift (below).

### Changed — manifest

- **`[cyrius]` pin 6.0.56 → 6.2.11.** Matches the rest of the AGNOS boot pack
  (agnosys / agnostik / libro / argonaut all pin 6.2.11).
- **`[deps] stdlib` — `json` → `bayan`, `bigint` removed.** The standalone
  `json` stdlib module was retired in cyrius 6.1.25 and folded into the new
  **`bayan`** serialization bundle (base64 + csv + json). `bayan` ships
  back-compat `json_parse` / `json_get` / `json_get_int` aliases, which is what
  `src/main.cyr`'s `/proc`-cmdline config parser calls — so swapping the pin is
  enough, no caller change. **`bigint`** is gone as a standalone module (sigil
  3.7.x bundles its own); kybernet never referenced `bigint_*` directly — it was
  only pinned to satisfy sigil's old transitive need — so it's dropped. Mirrors
  libro 2.7.x / argonaut 1.8.x stdlib lists.
- **`[deps.agnosys]` / `-storage` / `-trust`: 1.3.2 → 1.4.3.** Bundle module
  names (`agnosys-core` / `-storage` / `-trust`) unchanged; the edge-boot
  surface (TPM/dm-verity/LUKS) and the F-13 IMA-truncation fix carry forward.
- **`[deps.agnostik]`: 1.3.0 → 1.3.1.** Type vocabulary byte-compatible —
  kybernet's security-config use (`security_context`, `capability_set`,
  landlock/seccomp bridges) unaffected.
- **`[deps.libro]`: 2.7.1 → 2.7.4.** Brings **sigil 3.7.14** (was 3.6.0) and
  **patra 1.11.2**; libro's own tpm_seal/unseal surface unchanged.
- **`[deps.patra]`: 1.10.3 → 1.11.2.** Aligns kybernet's explicit pin with the
  1.11.2 libro/argonaut now pull internally.
- **`[deps.argonaut]`: 1.8.2 → 1.8.3.** Same 11-module selective-import list
  (`types`/`boot`/`services`/`process_mgmt`/`resolver`/`health`/`notify`/
  `tmpfiles`/`audit`/`audit_ext`/`init`); `compat.cyr` stays retired (1.8.1).
- **`cyrius.lock`** — regenerated: **62 locked units** (was 60), reflecting the
  6.2.11 stdlib snapshot (`bayan`, `sys`, `ganita`, the split `tls_native_*`,
  the `*_agnos` platform peers) less the retired `json` / `bigint`.

### Changed — source (all toolchain-forced)

- **Explicit `include "lib/thread_local.cyr"` in `src/main.cyr`, `src/test.cyr`,
  `src/bench.cyr`** (ahead of the module chain that pulls sigil). Under cyrius
  6.2.x the manifest `stdlib` pin still resolves `thread_local.cyr` into `lib/`
  but **no longer auto-includes** it into sigil's dependency chain. sigil 3.7.x
  banks per-thread crypto scratch via `thread_local_{init,get,set}`; without the
  explicit include the binary links but the call sites resolve to nothing and it
  **SIGILLs/SIGSEGVs at runtime**. Matches argonaut 1.8.3's `src/main.cyr`
  convention. (The `thread_local` *pin* added at 1.3.2 stays; only the include
  is new.)
- **`src/bench.cyr` — new `arena_reset_clean()` helper; replaces the 24
  in-`main()` `alloc_reset(); alloc_init();` pairs.** The bench reclaims its
  arena between cold-path benchmarks. Two 6.1.x allocator changes made the bare
  reset unsafe: (a) 6.0.64 gave `str_builder` a cached default allocator
  (`_default_allocator`) whose 40-byte vtable lives at the arena base, and
  (b) 6.1.19 switched the allocator from incremental `brk` to a single mmap
  chunk that `alloc_reset()` rewinds to its base. So after a reset the next
  allocation overwrites the still-referenced vtable and the first `str_builder`
  faults (SIGSEGV — surfaced as a bench crash right after `cgroup_path`).
  `arena_reset_clean()` clears `_default_allocator` (forcing a rebuild in the
  fresh arena) and drops the cgroup path cache. **Bench-only**: PID 1 never
  resets the arena, so the live init path was never at risk. Pre-6.2 the
  reclaimed region stayed mapped, so the dangling read hit stale-but-mapped
  bytes and didn't fault — which is why this only surfaced on the jump.
- **`src/lib/cgroup.cyr` — added `_cg_cache_reset_all()`.** Zeroes all cgroup
  path-cache globals (maps + LRU pointers, all arena-resident). Called by the
  bench's `arena_reset_clean()`; documented as a test/bench aid (PID 1 never
  resets the arena). No hot-path change.
- **`qemu/boot-test.sh` — VM RAM `-m 256M` → `512M`.** The 6.1.19+ allocator
  reserves a **256 MB** mmap chunk at `alloc_init()`. In a 256 MB VM that left
  no headroom over kernel + initramfs + page tables, so the kernel's overcommit
  heuristic **rejected the mapping → `alloc_init` `exit(1)` → "Attempted to kill
  init"** before the first boot marker. The mapping is virtual/overcommitted and
  lazily faulted — real AGNOS targets (RPi4/NUC, GBs of RAM) map it trivially;
  only the undersized test VM was affected. 512 M restores a clean boot.

### Performance — bench gate

51 benchmarks recorded; **23 flagged ≥15% "regressions", 5 improvements** vs the
1.3.2-era baseline. **Explained, not a logic regression** (disposition per audit
rule #6, same shape as 1.3.2's `strlen` note — now broader):

- The flagged set is almost entirely **allocate-and-discard microbenchmarks**
  (`epoll_event_new` 15→60, `Ok+is_ok` 16→69, `Some+is_some+unwrap` 27→77,
  `owned_fd_new+raw` 13→64, `alloc(4 sizes burst)` 23→213, `sigset_new+add+has`
  23→66, the agnostik type constructors, `str_builder*`). The 6.0.56 compiler
  dead-code-eliminated these discarded allocations down to near loop-overhead;
  6.2.11 executes them. They **all converge on the real cost of one small
  allocation (~40–77 ns)** — the tell that the prior numbers were folded, not
  fast. The 6.0.64 allocator-vtable indirection (`alloc_via(default_alloc())`
  per allocation) adds the rest.
- Corroborated by the **improvements**: `alloc(3)+reset+init` 1142→202 (−82%,
  idempotent `alloc_init` from 6.1.23), `strlen(52)` 38→27 (−28%), `hashmap`
  1188→1047 (−11%), `is_mounted` 54→46 (−14%).
- **The genuine PID-1 hot paths are unchanged or better**: `classify_signal`
  3 ns, `is_handled_signal` 8 ns, `cgroup_path` 4 ns, `cgroup_file` warm-cache
  best case unchanged, `knotify_classify` 17 ns, syscall baselines ~300 ns. The
  812 ms harness boot (vs 1.3.2's 882 ms) is the real-world confirmation.

### Stats

- x86_64 DCE binary: 1.374 MB → **1.709 MB** (1,709,080 B; +334,872 B, +24%)
- aarch64 DCE binary: 1.511 MB → **1.948 MB** (1,948,208 B; +437,104 B, +29%)
- **Size note:** as at 1.3.2, the bulk is **dead, NOP-retained non-Linux code** —
  the 6.2.11 stdlib snapshot vendors more platform peers (`*_agnos`, `*_win`,
  `*_macos`, the split `tls_native_*`, `bayan`/`sys`/`ganita`) plus the larger
  sigil 3.7.x. They are unreachable on a Linux x86_64/aarch64 PID-1 build; DCE
  NOPs but keeps their bytes. Functionally inert.
- 177 / 177 tests pass (unchanged); 51 benchmarks recorded (23 explained shifts /
  5 improvements vs 1.3.2)
- both arches build clean (DCE); QEMU PID-1 harness OK (all six markers,
  812 ms / 3000 ms budget)

### Verification

- All five pinned sibling tags confirmed real git tags and each the highest in
  its repo (agnosys 1.4.3, agnostik 1.3.1, libro 2.7.4, patra 1.11.2,
  argonaut 1.8.3) — none ahead of the latest tag.
- `cyrius deps` clean (9 deps, 62 locked); fresh-`lib/` resolve.
- `CYRIUS_DCE=1 cyrius build` clean (x86_64 + aarch64).
- `cyrius test src/test.cyr` — **177 passed, 0 failed**.
- `bash scripts/bench-history.sh` — 51 recorded; flagged deltas reviewed +
  explained above.
- `bash qemu/boot-test.sh` (KVM) — **OK**, all six markers, 812 ms.

### Audit-checklist pass

Standing 1.1.5 P(-1) rules re-applied. The source touched this cut is the
`thread_local` includes (no syscalls, no buffers), `cgroup.cyr`'s cache-reset
helper (no syscalls, only global zeroing), and bench/harness scaffolding — none
touch the mount table, PID-1 exit paths, or introduce literal `syscall(N, …)` in
live boot code. `test_mount_required_flag` (mount-table canary) green.

---

## [1.3.3] — 2026-06-03

**Toolchain pin alignment to cyrius 6.0.56.** The cyrius pin moves
6.0.53 → **6.0.56** to stay on the same toolchain as the rest of the
agnos boot pack (agnos 1.41.4 / agnoshi 1.3.5 / argonaut) now that
6.0.55/6.0.56 landed the `CYRIUS_TARGET_AGNOS` stdlib peer that unblocked
boot-to-agnsh. No kybernet `src/` changes and no sibling-dep version
changes — the cut is the pin + the regenerated `lib/` snapshot + lock.
Builds clean, **177/177 tests pass**.

### Changed

- **`[cyrius]` pin 6.0.53 → 6.0.56.** The vendored `lib/` stdlib snapshot
  is regenerated against the 6.0.56 toolchain (`cyrius update`); the only
  `cyrius.lock` movement is the `lib/*.cyr` content hashes (the 6.0.54–56
  arc — Windows args, the agnos `args_agnos`/`process_agnos`/`io` peer,
  chrono/exit normalization). The git-tagged sibling deps (agnosys 1.3.2,
  libro 2.7.1, argonaut 1.8.1, sigil 3.6.0, sakshi 2.2.3, agnostik 1.3.0,
  patra 1.10.3) are unchanged from 1.3.2 — this is a pure toolchain align.

### Validated

- `src/test.cyr` — **177 passed, 0 failed** on the 6.0.56 build.

## [1.3.2] — 2026-06-03

**Toolchain leap to cyrius 6.0.53 + dependency refresh.** The cyrius pin jumps
6.0.26 → **6.0.53** (27 minors), and the three sibling deps with new tags are
pulled: agnosys 1.3.0 → **1.3.2**, libro 2.6.2 → **2.7.1**, argonaut 1.8.0 →
**1.8.1**. agnostik (1.3.0) and patra (1.10.3) are already at their latest tags
and unchanged. No kybernet `src/` changes — the cut is dependency + lock + a
single new stdlib pin + docs. Both arches build clean, 177/177 tests pass, QEMU
PID-1 harness green (882 ms / 3000 ms budget), bench gate broadly improved
(50/51 faster; the one flagged outlier is explained below).

### Changed

- **`[cyrius]` pin 6.0.26 → 6.0.53.** Made true — the wrapper is at 6.0.53 and
  the pack front (kybernet / argonaut / libro) is now 6.0.53. The 6.0.25–6.0.52
  codegen arc is a broad hot-path win (see Performance). The vendored `lib/`
  stdlib snapshot is regenerated against the 6.0.53 toolchain (`cyrius deps`
  from an empty `lib/`), which also pulls the new platform-peer modules below.
- **`[deps] stdlib` — `thread_local` added** (ordered after `thread`, before the
  external sigil bundle). **Required by sigil 3.6.0** (pulled transitively via
  libro 2.7.1): sigil's `crypto_scratch` banks per-thread arrays over cyrius
  6.0.52 thread-local storage and calls `thread_local_init/get/set`. Without the
  module included before sigil the binary **links but SIGILLs at runtime**
  (reads an uninitialised thread pointer) — it does not fail to compile. Tracked
  in libro 2.7.1's CHANGELOG; adopted here because kybernet links sigil.
- **`[deps.agnosys]` / `-storage` / `-trust`: 1.3.0 → 1.3.2.** Pure cyrius
  6.0.24 → 6.0.52 toolchain refresh, **zero agnosys source change**, API
  byte-compatible. Carries forward the 1.3.0 F-13 IMA-truncation fix that backs
  kybernet's edge-boot attestation. Bundle module names unchanged.
- **`[deps.libro]`: 2.6.2 → 2.7.1.** Cyrius 6.0.14 → 6.0.53, sigil 3.5.7 → 3.6.0
  (lock-free `sv_verify_batch`), agnosys → 1.3.2; patra unchanged (1.10.3).
  libro's own surface (tpm_seal/tpm_unseal + syscall wrappers) is unchanged. The
  sigil 3.6.0 bump is the reason for the `thread_local` pin above.
- **`[deps.argonaut]`: 1.8.0 → 1.8.1.** Cyrius 6.0.26 → 6.0.53; the only source
  change is **removing `src/compat.cyr`** (the `ct_eq` shim, now redundant with
  libro 2.7.1). `compat.cyr` is not in kybernet's selective-import list, so the
  11 imported modules (`types`/`boot`/`services`/`process_mgmt`/`resolver`/
  `health`/`notify`/`tmpfiles`/`audit`/`audit_ext`/`init`) are byte-identical to
  1.8.0. argonaut's internal patra (1.10.3) + libro (2.7.1) pins now match
  kybernet's.
- **`cyrius.lock`** — regenerated: **60 locked units** (was 55). The net +5 is
  the 6.0.53 snapshot's platform peers (`alloc_agnos`, `syscalls_x86_64_agnos`,
  `syscalls_macos`, `process_win`, `thread_win`) plus `thread_local`, less the
  retired `argonaut_compat_compat.cyr`. None of the new peers are reachable on
  Linux x86_64/aarch64.

### Unchanged (already at latest tag)

- **agnostik 1.3.0** — VERSION runs ahead but the latest *tag* is 1.3.0 (pins
  cyrius 6.0.26; builds clean under 6.0.53, drift note benign).
- **patra 1.10.3** — latest tag; pulled explicitly + transitively via libro.

### Performance

The 6.0.25–6.0.52 codegen window is a broad hot-path improvement — **50 of 51
benchmarks faster**, mirroring agnosys 1.3.2's report. Representative: `getuid`
316 → 278 ns (−12%), `seccomp_from_profile` 283 → 243 ns (−14%), `vec(push*3…)`
159 → 140 ns (−11%), `security_context(new+4 get)` 221 → 193 ns (−12%),
`capability_set(new+3push)` 600 → 530 ns (−11%), `klog2_sim` 1482 → 1331 ns
(−10%).

- **One flagged regression — `strlen(52 chars)` 29 → 38 ns/op (+31%), explained,
  not fixed.** `lib/string.cyr` is byte-identical stale-vs-6.0.53, so the strlen
  *source* did not change. The benchmark calls `strlen()` on a string **literal
  with the result discarded** in a hot loop; the 6.0.26 compiler elided/folded
  that dead call (artificially fast 29 ns), 6.0.53 actually executes the 52-byte
  scan (~38–42 ns over three raw reruns — stable, not noise). The ~40 ns is the
  honest cost of the scan; every *real* string consumer improved (`str_builder`
  −6%, `klog_sim` −9%, `klog2_sim` −10%). Disposition per audit rule #6:
  explained, no stdlib/toolchain change.

### Stats

- x86_64 DCE binary: 1.154 MB → **1.374 MB** (1,374,208 B; **+219,984 B, +19%**)
- aarch64 DCE binary: 1.266 MB → **1.511 MB** (1,511,104 B; **+245,008 B, +19%**)
- **Size note:** the increase is entirely **dead, NOP-retained non-Linux code.**
  The 6.0.53 stdlib snapshot vendors 5 new platform-peer modules (~34 KB source:
  Windows process/thread, macOS + AGNOS-target syscalls, AGNOS allocator). They
  are unreachable on a Linux x86_64/aarch64 PID-1 build; DCE NOPs them but
  *keeps their bytes* (NOP ≠ strip), so the binary carries them as dead weight.
  Functionally inert — mirrors agnosys 1.3.2's "25 → 29 files, none affect the
  Linux build" snapshot expansion. Flagged for awareness; trimming non-target
  peers is an upstream-toolchain matter, out of scope for this refresh.
- 177 / 177 tests pass (unchanged); 51 benchmarks recorded, 50 improved /
  1 explained regression vs 1.3.1
- both arches build clean (DCE); QEMU PID-1 harness OK (all 6 markers,
  882 ms / 3000 ms budget — faster than 1.3.1's 956 ms)

---

## [1.3.1] — 2026-06-01

**Dependency refresh — agnostik 1.3.0 + argonaut 1.8.0.** The two sibling
deps held back at 1.3.0 (pending their own cuts) are now pulled. Both are
toolchain-refresh + refactor-closeout minors on the dep side (each advanced
its own cyrius pin to **6.0.26**, matching kybernet) with byte-compatible
public API / type vocabulary — no kybernet source changes. The cut is
dependency + lock + doc only. Both arches clean, 177/177 tests pass, bench
gate green (no regression vs 1.3.0).

### Changed

- **`[deps.agnostik]`**: 1.2.3 → **1.3.0**. Cyrius pin 6.0.14 → 6.0.26 plus a
  refactor/optimization closeout (OTLP + audit hot paths, hex-decode
  consolidation, a buffer-safety hardening); `dist/agnostik.cyr` re-bundled.
  Type vocabulary byte-for-byte compatible — kybernet's security-config use
  (`security_context`, `capability_set`, landlock/seccomp bridges) is unaffected.
- **`[deps.argonaut]`**: 1.7.1 → **1.8.0**. Cyrius pin 6.0.14 → 6.0.26 +
  closeout refactor: `src/health.cyr` consolidated its six open-coded
  `HealthCheckResult` allocations onto a new `health_result_new` helper, and a
  leftover `/child.marker` debug write was removed from `fork_exec_service`
  (it touched the root fs on **every** PID-1 service spawn). Same module set as
  1.7.1, so kybernet's selective-import list is unchanged; argonaut's internal
  patra (1.10.3) and libro (2.6.2) pins already match kybernet's.
- **`cyrius.lock`**: regenerated — 55 locked units (count unchanged; content
  hashes refreshed for agnostik/argonaut).

### Notes

- **`[cyrius]` pin held at 6.0.26.** The local wrapper has since advanced to
  6.0.27, but the AGNOS pack front (kybernet / argonaut / agnostik) is at
  6.0.26 and no sibling pins 6.0.27 yet, so the pin stays at 6.0.26 (6.0.27
  builds it cleanly — the drift warning is benign). A 6.0.27 adoption waits on
  the pack.

### Stats

- x86_64 DCE binary: 1.157 MB → **1.154 MB** (1,154,224 B; −3,088 B — argonaut's
  DRY closeout + agnostik trims slightly outweigh the refreshed content)
- aarch64 DCE binary: 1.270 MB → **1.266 MB** (1,266,096 B; −3,872 B)
- 177 / 177 tests pass (unchanged); 51 benchmarks recorded, no regressions vs 1.3.0
- both arches build clean; QEMU PID-1 harness OK (all markers, 956 ms / 3000 ms budget)

---

## [1.3.0] — 2026-06-01

**A real minor — toolchain 6.0.26, agnosys 1.3.0 + patra 1.10.3, and a
refactor/optimization pass.** The cyrius pin is made true (6.0.14 → 6.0.26,
already the active wrapper), the two sibling deps with new tags are pulled,
four internal refactors land (cross-module dedup + a hot-path cleanup,
mirroring agnosys 1.3.0's own pass), and **benchmarks become a mandatory,
regression-checked release gate**. Both arches clean, 177/177 tests pass.

### Security (carried)

- **agnosys F-13 (IMA log truncation)** reaches kybernet via `agnosys-trust`.
  Upstream the IMA measurement log was truncated at 64 KB, silently hiding
  measurements from attestation; 1.3.0 grows it to EOF with a 32 MB ceiling.
  kybernet's edge-boot pre-flight (`src/lib/edge_boot.cyr`) consumes the trust
  bundle, so its PCR/IMA attestation now sees the full log.

### Changed

- **`[cyrius]` toolchain pin**: 6.0.14 → **6.0.26**. The wrapper already ran
  6.0.26 (the manifest pin was in drift); this makes the pin true and silences
  the drift warning. The 6.0.15–6.0.26 window required no kybernet source change.
- **`[deps.agnosys]` / `-storage` / `-trust`**: 1.2.8 → **1.3.0**. Upstream is a
  correctness/security + refactor minor (its own cyrius pin 6.0.14 → 6.0.24);
  API-compatible for kybernet — additive only (+5 `agnosys_*` util helpers now
  in `agnosys-core`, public names retained as thin wrappers). All three profile
  bundles regenerated.
- **`[deps.patra]`**: 1.9.3 → **1.10.3**. Additive (`patra_bind_int` /
  `patra_bind_text`, TEXT/VARLEN columns, rowid/AUTOINCREMENT) plus a SQL
  string-escaping fix. Aligns kybernet's explicit pin with the 1.10.3 that
  argonaut 1.7.1 already used internally (see the 1.2.3 note) — build, tests,
  and benches are clean against patra-1.10.3 + libro-2.6.2.
- libro 2.6.2 / agnostik 1.2.3 / argonaut 1.7.1 **held** — those bumps land in 1.3.1.
- **`cyrius.lock`**: regenerated — 55 locked units (count unchanged; content
  hashes refreshed for agnosys/patra).

### Refactor / optimization

Mirrors agnosys 1.3.0's dedup pass; all behavior-preserving, 177/177 tests
green on both arches.

- **`src/lib/privdrop.cyr`** (188 → 175) — removed dead `priv_error_print`
  (defined, never called), which also held the last bare-integer
  `syscall(1, 2, ...)` in live code (audit-checklist rule #1; SYS_WRITE is 1 on
  x86_64 but 64 on aarch64).
- **`src/lib/sandbox.cyr`** (306 → 289) — the three `sandbox_allow_*` presets
  collapsed onto a private `_sandbox_push` helper; the Landlock plumbing shared
  by `sandbox_apply` and `sandbox_from_ruleset` (the 13-flag handled mask,
  ruleset creation, and the per-rule `O_PATH`-open/add/close) extracted into
  `_landlock_handled_mask` / `_landlock_create_ruleset` / `_landlock_add_path`.
  Each entry point keeps its own access derivation and loop; only the syscall
  sequence is now shared. (Note: Landlock nrs 444/445/446 are arch-identical,
  so no `#ifdef` gating is needed.)
- **`src/lib/reaper.cyr`** — `reap_and_log` builds each line in one stack buffer
  and emits a single `sys_write` per pid (5 → 1), matching log.cyr's `_logbuf`
  style.

### Process

- **Benchmarks are now a mandatory release gate.** `scripts/bench-history.sh`
  was a boot-time placeholder; it now runs `cyrius bench src/bench.cyr`, records
  per-benchmark ns/op to `benches/history.csv`, and exits non-zero on a ≥15%
  regression vs the previous run (mirrors agnosys 1.3.0). Codified in CLAUDE.md
  (audit checklist #6 + Development Process 5b). The prior binary-size CSV was
  archived to `benches/history-binsize-legacy.csv` (different schema, one stale
  cc2-era row).

### Stats

- x86_64 DCE binary: 1.150 MB → **1.157 MB** (1,157,312 B; +7,512 B from the
  agnosys-1.3.0 util additions + patra-1.10.3 content)
- aarch64 DCE binary: 1.262 MB → **1.270 MB** (1,269,968 B; +7,560 B)
- 177 / 177 tests pass (unchanged); 51 benchmarks recorded, no regressions
- both arches build clean; warning catalogue unchanged (pre-existing dep-bundle
  duplicate-fn + `agnosys-core` match-arm notes)

---

## [1.2.3] — 2026-05-28

**Dependency refresh — agnosys 1.2.8, agnostik 1.2.3, argonaut 1.7.1.**
Consumer bump that picks up the sibling pack's own 6.0.14 adoptions (all
three are toolchain-refresh patches on the dep side — no public API, wire
format, or type-vocabulary changes). No kybernet source changes; the cut
is dependency + lock + doc only.

### Changed

- **`[deps.agnosys]` / `-storage` / `-trust`**: 1.2.5 → **1.2.8**. Upstream
  is a cyrius 6.0.1 → 6.0.14 pin bump + workaround audit (hand-rolled JSON
  serializers and the CI fmt diff-gate remain required under 6.0.14 — none
  repairable yet). The 6.0.14 stdlib snapshot adds `syscalls_linux_common.cyr`
  (shared Linux syscall numbers), now pulled transitively.
- **`[deps.agnostik]`**: 1.2.1 → **1.2.3**. Toolchain-refresh patch (5.10.44
  → 6.0.14); type vocabulary and wire formats byte-identical. Note: agnostik
  1.2.3 moved stdlib population from `cyrius deps` to the new `cyrius lib
  sync` command under 6.0.x — verified kybernet is **unaffected** (a clean
  `./lib/` resolve via `cyrius deps` alone still lands the stdlib here, so no
  `cyrius lib sync` CI step is needed).
- **`[deps.argonaut]`**: 1.7.0 → **1.7.1**. Toolchain pin to 6.0.14 +
  aarch64 cross-build restoration on argonaut's side. Argonaut 1.7.1 bumps
  its own patra to 1.10.3 internally; **kybernet holds its explicit patra
  pin at 1.9.3** (the manifest's source-of-truth pin governs) — build, tests,
  and harness are clean against the 1.9.3 + argonaut-1.7.1 combination.
- **`cyrius.lock`**: regenerated — 54 → **55** locked units (the new
  `syscalls_linux_common.cyr` stdlib file).

### Stats

- x86_64 DCE binary: 1.146 MB → **1.150 MB** (1,149,800 B; +2,880 B from
  refreshed dep content)
- aarch64 DCE binary: 1.258 MB → **1.262 MB** (1,262,408 B; +4,296 B)
- 177 / 177 tests pass (unchanged from 1.2.2)
- fmt / vet clean; warning catalogue identical (pre-existing dep-bundle
  duplicates documented since 1.1.0)

### Verification

- All three requested tags confirmed to exist as released git tags
  (`git tag --list`) and to match their repos' VERSION files before pinning
  — none ahead of the latest tag.
- `cyrius deps` clean resolution (10 deps, 55 locked); fresh-`./lib/` resolve
  verified (no `cyrius lib sync` dependency).
- `CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet` clean; 1.150 MB.
- `cyrius test src/test.cyr` — 177 passed, 0 failed.
- `CYRIUS_DCE=1 cyrius build --aarch64 …` — clean; 1.262 MB.
- QEMU PID-1 harness (`bash qemu/boot-test.sh`, KVM available): **OK** — all
  six boot markers, boot wall time 746 ms within the 3000 ms budget.

### Audit-checklist pass

Standing 1.1.5 P(-1) rules re-applied — no kybernet source changed, so all
five (no literal syscall(N, ...); var X[N] sizing; Str vs cstr; PID-1 exit
paths; mount-table size↔stride) hold by inheritance from 1.2.2.

---

## [1.2.2] — 2026-05-28

**Cyrius toolchain bump to 6.0.14 — both arches clean, aarch64
cross-build restored.** First kybernet cut to leapfrog the sibling AGNOS
pack on the toolchain pin: argonaut + patra still at 5.10.44, agnosys +
libro at 5.11.4, kybernet now at 6.0.14. The "matches argonaut's pin"
rationale carried since 1.1.0 no longer holds — kybernet leads on this
one. The aarch64 `cycc_aarch64` codegen hang that blocked the original
6.0.1 attempt (see below) is resolved upstream; 1.2.2 ships dual-arch.

### Changed

- **`[cyrius]` toolchain pin**: 5.10.44 → **6.0.14**. The cc5→cycc rename
  ceremony in the 6.0.x arc landed alongside new peer binaries (`cybs`,
  `cyaudit`, `ts_test_runner`); cc5 / cc5_aarch64 are retained as
  symlinks to `cycc` / `cycc_aarch64`. No kybernet source changes — the
  bump is toolchain-only.

### Stats

- x86_64 DCE binary: 1.148 MB → **1.146 MB** (−2 KB; codegen wash)
- aarch64 DCE binary: **1.258 MB** (restored; cross-build was broken
  under 6.0.1)
- 177 / 177 tests pass (unchanged from 1.2.1)
- fmt / vet clean
- Compile-time warning catalogue identical to 1.2.1 (all pre-existing
  dep-bundle duplicates documented since 1.1.0)
- New compile-time note from cyrius 6.0.x: `cwd ./lib/ shadows
  version-pinned /home/macro/.cyrius/versions/6.0.14/lib/` — informational
  only; the 6.0.x wrapper ships a bundled stdlib snapshot and notes when
  a project's `lib/` (populated by `cyrius deps`) takes precedence. Set
  `CYRIUS_NO_WARN_SHADOW_LIB=1` to silence. Kybernet's per-dep tag pins
  in `cyrius.cyml` are the source of truth; the note is expected.

### Fixed

- **aarch64 cross-build no longer hangs.** Under `cycc_aarch64` 6.0.1 the
  cross-build pinned at 99.9% CPU after parse/typecheck and never emitted
  output (killed at the 4-minute mark on four consecutive attempts);
  filed upstream as the
  `2026-05-20-kybernet-cycc_aarch64-6.0.1-codegen-hang` issue, adjacent
  to the 2026-05-19 `cycc 6.0.0 emits ud2 at every fncallN site`
  regression — both surfaced in the cc5→cycc rename cycle. As of 6.0.14
  the codegen hang is gone: `cyrius build --aarch64` completes in ~1.2 s
  and emits a 1.258 MB binary. This unblocks the aarch64 release artifact
  that 1.2.2 originally deferred.

### Verification

- `cyrius deps` clean resolution (10 deps).
- `CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet` clean; binary
  1.146 MB.
- `cyrius test src/test.cyr` — 177 passed, 0 failed.
- `CYRIUS_DCE=1 cyrius build --aarch64 src/main.cyr build/kybernet-aarch64`
  — clean; binary 1.258 MB; ~1.2 s.
- QEMU PID-1 harness (`bash qemu/boot-test.sh`, KVM available this cut):
  **OK** — all six boot markers present, boot wall time 807 ms within the
  3000 ms budget.

### Audit-checklist pass

Standing 1.1.5 P(-1) rules re-applied — no kybernet source changed, so
all five (no literal syscall(N, ...); var X[N] sizing; Str vs cstr;
PID-1 exit paths; mount-table size↔stride) hold by inheritance from
1.2.1. The x86_64 DCE delta (−2 KB) is consistent with a no-source-change
cut.

---

## [1.2.1] — 2026-05-11

**Pin argonaut 1.7.0 — boot-to-shell MVP path lit.** Consumer bump
that picks up argonaut's new `BOOT_MINIMAL` agnoshi registration.
Kybernet in BOOT_MINIMAL mode now launches agnoshi as a console
shell with no `aethersafha` dependency, enabling the AGNOS
closed-beta MVP (kernel + kybernet + shell prompt on real iron
without the desktop compositor stack).

### Changed

- **`[deps.argonaut]` tag**: 1.6.2 → 1.7.0. Picks up argonaut's
  `default_services(BOOT_MINIMAL)` agnoshi addition + the
  `STAGE_SHELL` step in `build_boot_sequence(BOOT_MINIMAL)`.
- Rebuilt against Cyrius 5.10.44 + argonaut 1.7.0. Binary size:
  ~1.15 MB (was ~1.1 MB at 1.2.0; +~50 KB from agnoshi service
  registration + STAGE_SHELL boot step in the argonaut bundle).

### Tests

- **177 passed, 0 failed** — full kybernet test suite clean against
  argonaut 1.7.0. No kybernet-side changes; this is purely a
  consumer pin bump.

### Motivation

The AGNOS closed-beta MVP is **boot-to-shell on real hardware**.
Previously kybernet's BOOT_MINIMAL mode registered only daimon —
no shell — and BOOT_DESKTOP required `aethersafha` (Wayland
compositor, not yet Cyrius-ported). argonaut 1.7.0 unblocks the
minimal-mode-with-shell path; this kybernet release picks it up.

### Verification

- `cyrius deps` clean resolution.
- `CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet` clean.
- Test suite 177/177.
- Static linkage preserved (no glibc dependency).

---

## [1.2.0] — 2026-05-11

**Edge boot — first 1.2.x minor.** Lifts the verified-and-sealed boot machinery into kybernet via agnosys 1.2.5's `agnosys-storage` and `agnosys-trust` profile bundles, alongside the existing `agnosys-core`. First kybernet release to pull more than one agnosys profile; first to declare a `[deps.agnosys-*]` block per profile. The 1.1.1 CHANGELOG flagged this as the moment fn_table headroom would press back into the warn band — measured this cut: still under, no warning emitted.

This cut is **scaffolding + capability detection + measurement**, not full verification. Real-device dm-verity / LUKS verify needs deployment-specific paths (data device, hash device, root hash, LUKS device) that argonaut's `EdgeBootConfig` doesn't carry yet. Those land in **1.2.1** alongside the argonaut-side struct extension. **1.2.2+** wires the real hardware boot validation (RPi4, NUC).

### Added
- **`[deps.agnosys-storage]` + `[deps.agnosys-trust]`** in `cyrius.cyml`. Both pin agnosys 1.2.5 (matches the existing `[deps.agnosys]` core entry). cyrius's dep resolver de-dupes the underlying git clone (one checkout, three profile-bundle reads). New `lib/agnosys-storage.cyr` + `lib/agnosys-trust.cyr` files in the resolved tree.
- **`src/lib/edge_boot.cyr`** — new module. Provides:
  - `edge_boot_run(config)` — orchestration entry point. Gates on `boot_mode == BOOT_EDGE && verify_on_boot != 0`. Returns 1 to continue boot, 0 to abort to emergency.
  - **Capability detection** via `tpm_detect()` (checks `/dev/tpmrm0` / `/dev/tpm0`) and `dmverity_supported()` (checks `/sys/module/dm_verity` + veritysetup binary). Logs both.
  - **PCR read** per `EdgeBootConfig.pcr_bindings` spec ("7+14" → indices 7, 14; tolerates any non-digit separator). Reads SHA-256 PCRs via agnosys-trust's `tpm_read_pcr`. Measurement-only — baseline comparison via `tpm_verify_measured_boot` lands in 1.2.1.
  - **Hard-prerequisite gating**: when `tpm_attestation == 1` and TPM is unavailable, returns 0 (FATAL → emergency shell). Same for `readonly_rootfs == 1` and dm-verity unavailable.
  - **`max_boot_ms` wall-clock budget** measured via `monotonic_ms()` deltas, warn-only.
  - **LUKS unlock + dm-verity verify stubs** that log "config land in 1.2.1; skipped" — placeholder for real-device wiring.
  - **Status accessors**: `edge_boot_tpm_present()`, `edge_boot_dmverity_supp()`, `edge_boot_pcr_count()`, `edge_boot_elapsed_ms()` for the boot-phase summary.
- **Phase 6c** in `kybernet_run` — wired between `execute_tmpfiles()` and `run_boot_stages()`. Skips when not in EDGE mode. Drops to emergency shell on hard-prerequisite failure (same path as boot-stage failures).
- **`src/lib/log.cyr`** — factored `klog` / `klog2` / `kmsg` / `slog` / `slog_init` / `_logbuf` / `_log_write` out of `src/main.cyr`. The forcing function was edge_boot.cyr's `klog` calls: src/lib/* modules can't take a circular dependency on main.cyr, and test/bench compiles emitted `error: undefined function 'klog' (will crash at runtime)` when edge_boot was included without main. Pure refactor — no behavior change at the boot path. `g_log_fd` stays in main's globals (shutdown still closes it directly).

### Tests
- **`test_edge_boot_pcr_parser`** (6 assertions) — exercises `_eb_parse_pcr_indices` against `"7+14"`, `"0,7,14,23"` (comma), `"  3  "` (space-padded), `""` (empty), and `"23"` (multi-digit boundary; must not split as 2+3).
- **`test_edge_boot_gating`** (6 assertions) — covers the three deterministic skip paths (`config=0`, non-EDGE boot_mode, `verify_on_boot=0`) plus the accessor initial-state invariants. The host-environment-dependent run path (`EDGE + verify_on_boot=1 + tpm_attestation=1`) is intentionally NOT asserted at the unit-test level — its outcome depends on `/dev/tpm0` + `/usr/bin/tpm2_pcrread` + veritysetup presence. End-to-end coverage is the qemu boot harness's job once a future variant carries `kybernet.harness=edge` on the cmdline (1.2.1 task).
- Total: **160 → 177 tests** pass (+17 — 6 parser + 6 gating + 5 from the 1.1.5 audit that I miscounted in the prior release notes).

### Stats
- x86_64 DCE binary: 1.028 MB → **1.148 MB** (+120 KB — `agnosys-storage` + `agnosys-trust` profile surfaces plus the new edge_boot module and the log-factor-out)
- aarch64 cross-build: clean
- fn_table: well under the 90% warn threshold — the 1.1.1 prediction that two new agnosys profiles would tip past was conservative. Upstream cap-raise (`cyrius/docs/development/issues/2026-05-11-kybernet-fn-table-identifier-buffer-caps.md`) tracking on the 5.11.x arc still relevant for the next round of growth.
- Harness end-to-end: 751 ms wall time (within 3000 ms budget); all six markers
- fmt / vet clean

### Deferred to 1.2.1
- argonaut-side: extend `EdgeBootConfig` with `data_device`, `hash_device`, `root_hash`, `luks_device`, `expected_pcrs` (vec of PCR baseline values). Out of kybernet's tree.
- kybernet-side once 1.2.1 lands the config extension:
  - `dmverity_verify(data_device, hash_device, root_hash)` against real devices
  - `luks_open(config, key_ptr, key_len)` + `luks_mount(device, mount_point, fs)` against a configured LUKS volume; key sourced from TPM unseal or initramfs passphrase
  - `tpm_verify_measured_boot(expected)` against the baseline vec from the extended config
  - Edge-mode qemu harness variant (`kybernet.harness=edge`) — boots with synthetic LUKS volume + dm-verity device produced by `qemu/build-initramfs.sh`

### Deferred to 1.2.2
- Real hardware boot validation: RPi4 + NUC. Needs hardware-in-the-loop testing infra that isn't on the CI runner. Will be a dedicated cut with a hardware-validation report attached to the audit-doc folder.

### Notes
- The 1.1.5 audit's "no literal `syscall(N, ...)`" standing rule paid off here. edge_boot.cyr was written from scratch in 1.2.0 and went through the audit checklist before commit — no raw syscalls; all dep calls go through agnosys-trust / agnosys-storage wrappers which are arch-portable.
- The pre-1.2.0 main.cyr → src/lib/ refactor (log.cyr extraction) inverts a class of bug: previously, adding a `klog` call to a src/lib/ module produced a runtime crash under test (warning-only at compile). 1.2.0 onward, every src/lib/ module that needs logging includes `lib/log.cyr` transitively via the inclusion at the top of main / test / bench. The compile-time error path is preserved (cc5 still emits `undefined function 'klog'` if log.cyr is missing); the runtime-crash path is closed.

---

## [1.1.5] — 2026-05-11

**P(-1) audit pass.** Per-roadmap pre-1.2.0 review of `src/main.cyr` + every `src/lib/*.cyr`. Full report at [`docs/audit/2026-05-11-audit.md`](docs/audit/2026-05-11-audit.md). Summary: **7 CRITICAL / 3 HIGH / 1 MEDIUM / 2 LOW** — 12 closed in this cut, 1 LOW deferred with documented mitigation.

The headline finding was a class — **raw `syscall(N, ...)` calls with x86_64-specific N**. These cross-build fine on aarch64 (cc5_aarch64 doesn't validate syscall numbers per arch) but route to completely different syscalls at runtime. The harness test runs only on x86_64 KVM (sakshi invariant-TSC requirement, transitive via libro/patra), so aarch64 production deployments would have been the first to surface the breakage. 7 sites across `src/main.cyr` + `src/lib/privdrop.cyr` + `src/lib/notify.cyr` were affected.

The remaining findings are pattern-recurrences of 0.95.0 audit lessons: undersized stack/BSS buffers (`status_buf[1]`, `_mount_skipped[16]`) and a missed PID-1 exit path (`default: return 0` in the event loop on unknown epoll tokens — kernel panics when reached). The MEDIUM finding is the Str↔cstr type confusion class that 1.1.4 caught point-only — this pass closes the rest of the surface.

### Security
- **CRITICAL × 7 — raw syscall numbers vs aarch64**:
  - `src/main.cyr:224` `syscall(88, target, path)` (TMP_SYMLINK) → `sys_symlink(target, path)`. SYS_SYMLINK is 88 on x86_64, not on aarch64 (uses SYMLINKAT=36).
  - `src/main.cyr:267, 270` `syscall(59, ...)` (emergency shell `execve`) → `sys_execve(...)`. SYS_EXECVE is 59 on x86_64, 221 on aarch64.
  - `src/main.cyr:271` `syscall(60, 1)` (emergency shell child `exit`) + `src/main.cyr:762` `syscall(60, r)` (kybernet final exit) → `sys_exit(...)`. SYS_EXIT is 60 on x86_64, 93 on aarch64. The final-exit case meant **kybernet on aarch64 would never actually exit** — `syscall(60, r)` would invoke an unallocated syscall, return EINVAL, and the program would fall off the end of the runtime epilogue.
  - `src/lib/privdrop.cyr:58` local enum `SYS_PRCTL = 157` shadowed the stdlib's per-arch definition (157 on x86_64, **167 on aarch64**). On aarch64 every `drop_cap` / `set_no_new_privs` call hit `setpriority`+1 instead of `prctl` → silent capability-drop failure. Local enum entry removed; stdlib's per-arch value now wins.
  - `src/lib/notify.cyr:10-12` local enum `SYS_SOCKET=41, SYS_BIND=49, SYS_RECVFROM=45` (x86_64) — sd_notify socket creation/bind/recv on aarch64 routed to `pipe2` / `setsockopt` / `getsockopt`. Wrapped in `#ifdef CYRIUS_ARCH_*` per-arch enum (aarch64: 198/200/207). Upstream issue filed for stdlib wrappers (`cyrius/docs/development/issues/2026-05-11-kybernet-socket-syscall-wrappers.md`); local fix folds out when stdlib catches up.
- **HIGH-1 — `status_buf[1]` stack overflow** in `reap_zombies` (`src/lib/reaper.cyr:14`). `sys_waitpid` writes a 4-byte Linux `int wstatus` into a 1-byte stack array — 3-byte stack overflow that worked in practice only because cyrius's 8-byte stack alignment puts the spill in padding. Same class as 0.95.0's `signalfd_siginfo buf[16]→[128]` fix. Fixed: `var status_buf[8]`.
- **HIGH-2 — `_mount_skipped[16]` BSS overflow** in `mount.cyr:72`. 16-byte global array (capacity 2 i64 ptrs); loop bound-checked at `< 16` and stored up to 16 ptrs at offsets `0..120` for a 128-byte total span — 112-byte BSS overflow. Same class as 0.95.0's `_mount_table[8]→[240]` fix. Fixed: `var _mount_skipped[128]` (16 slots × 8 bytes).
- **HIGH-3 — PID-1 exit path regression** in event loop default case (`main.cyr:741`). On any unexpected epoll event token, `default: return 0` returned from `kybernet_run` → `main` → `sys_exit(0)` while PID 1 — kernel panic ("Attempted to kill init!"). Same class as 0.95.0's "PID 1 exit paths now call do_shutdown() instead of returning" — the case was missed at the time. Fixed: log a warning via `klog` and continue the loop.

### Fixed
- **MEDIUM-1 — `Str` vs `cstr` type confusion** across the logging surface. 12+ `klog2 / slog / cgroup_*` call sites passed argonaut-returned `Str` (boxed) values where `cstr` was expected — the receiver read the Str header bytes as ASCII chars (garbage output) or as path-construction input (cgroup paths derived from header layout). Latent because the default config has no services so none of the sites fire. **1.1.4 fixed one site** (`run_boot_stages` `klog2("boot: ", desc)`) point-only; this pass closes `handle_sigchld` (4 sites), `start_services` (3 sites including `create_service_cgroup(name)` / `move_to_cgroup(name, pid)`), `handle_health_tick`, and `handle_watchdog_tick`. Each loop iteration calls `str_data()` once at the top and reuses the cstr ptr for all downstream operations — preserves the 1.1.3 cgroup cache LRU hit (which keys on cstr pointer identity).

### Documented (not source-patched)
- **LOW-1 — `_logbuf` no `plen` bounds check** in `_log_write` / `klog2`. If a caller passes a prefix longer than 254 bytes, `copylen = 254 - plen` underflows and `memcpy` blows out the 256-byte `_logbuf`. Every current caller passes a short literal (longest is 35 chars) so the bug isn't reachable. Inline comment block documents the `plen ≤ 254` precondition + the current-caller audit table; promote to MEDIUM the moment a non-literal prefix shows up. Defensive bounds-check deferred — would have diluted the audit-doc signal.
- **LOW-2 — `_mount_table[288]` at exact capacity**. 6 entries × 48 bytes per entry = 288 bytes exactly. Adding a 7th mount entry without growing the array overflows. Inline comment documents the size↔count invariant + next-bump target (`[480]` for 10 entries). Same class as the 0.95.0 `[8]→[240]` fix. The `test_mount_required_flag` regression in `src/test.cyr` is the canary — it asserts the per-entry classification at offset +40, so a stride change without re-doing the test offsets fails immediately.

### Standing rules added (per the audit-doc trailer)
- No literal `syscall(N, ...)`. Use a stdlib wrapper or `#ifdef CYRIUS_ARCH_*`-gated enum.
- `var X[N]` is N **bytes**, not N slots. Sites that hold N i64 ptrs need `[N * 8]`. Write the math inline at the declaration.
- `Str` vs `cstr` — argonaut surface is mostly `Str`; kybernet logging + cgroup path helpers are cstr-only. `vec_get`-derived names need `str_data()` before being passed downstream.
- PID-1 exit paths must call `do_shutdown()` or log-and-continue. Never `return 0` from `kybernet_run` directly.
- Mount table size and stride comments must be updated together; `test_mount_required_flag` is the canary.

### Stats
- x86_64 DCE binary: 1.027 MB → **1.028 MB** (+1 KB for the cstr-wrapping plumbing)
- aarch64 cross-build: clean — and now actually correct (the cross-build was compiling but linking to wrong syscall numbers pre-1.1.5)
- Local harness end-to-end: 768 ms wall time (vs. 3000 ms budget); all 6 markers
- 160 / 160 tests; fmt / vet / bench clean
- Files audited: 11 (`src/main.cyr` + 10 × `src/lib/*.cyr`); LOC reviewed: ~1700

### Notes
- One upstream filing landed alongside this audit: `cyrius/docs/development/issues/2026-05-11-kybernet-socket-syscall-wrappers.md`. Pairs with the 2026-05-10 kavach `prctl/seccomp/setresuid/...` post-fork-syscall request — schedule both in the same stdlib-wrapper batch if cyrius scheduling allows.
- Roadmap consequence: 1.1.5 inserted between 1.1.4 (QEMU harness) and 1.2.0 (edge boot). The audit fixes in privdrop / notify make 1.2.0 work safer to start (those modules will gain new call sites for `agnosys-trust` / `agnosys-storage` integration).

---

## [1.1.4] — 2026-05-11

**QEMU PID-1 boot harness.** Closes a 1.0.1-era roadmap item that had been blocked on argonaut shipping a PID-1 harness pattern — argonaut 1.6.x landed it, and kybernet now lifts the pattern to validate that the actual kybernet binary boots clean as real PID 1 under KVM, with marker assertions and a boot-time budget rather than the previous "grep stdout and hope" shape.

### Added
- **`fn kybernet_harness_requested()`** in `src/main.cyr` — reads `/proc/cmdline`, looks for `kybernet.harness=1` with substring + start-/end-boundary checks (so `nokybernet.harness=1` or `kybernet.harness=11` don't trigger). Pattern lifted directly from argonaut 1.6.x's `pid1_harness_requested()`. Includes the same boundary-character set: SOF / SPACE / TAB on the left, EOF / SPACE / TAB / LF on the right.
- **Harness exit path** wired into `kybernet_run()` between phase 8 (services started) and phase 9 (event loop). When the flag is set, kybernet emits a `harness done — shutting down clean` marker and calls `do_shutdown(SHUTDOWN_POWEROFF)`, skipping the event-loop wait. The clean-shutdown sequence (stop services → sync → reboot) still runs.
- **`qemu/build-initramfs.sh`** — rewritten. Replaced the stale `scripts/build.sh` reference (removed in 1.1.0) with a direct `CYRIUS_DCE=1 cyrius build` invocation. Adds the dynamic-loader + libc bundling that argonaut 1.6.2 introduced when busybox is dynamically linked (Arch's `/usr/lib/initcpio/busybox` needs `ld-linux` + libc; without bundling, the auxiliary boot-shutdown/boot-crash tests fail with "exec format error").
- **`qemu/boot-test.sh`** — rewritten. Mounts kybernet as `/sbin/init`, boots qemu with `kybernet.harness=1`, asserts six specific `klog`-emitted markers (`kybernet: starting`, `... filesystems mounted`, `... argonaut initialized`, `... services started`, `... harness done`, `... shutdown`), measures wall-clock boot time, and gates on a configurable `BUDGET_MS` (default 3000 ms — local KVM hits ~800 ms with headroom for slower hardware). KVM detection mirrors argonaut's: warns and falls back to TCG if `/dev/kvm` isn't readable, but documents that sakshi's `clock_init` will panic under TCG (transitive pull-in via libro/patra).
- **CI job `qemu-harness`** in `.github/workflows/ci.yml`. `continue-on-error: true` — GitHub-hosted runners rarely expose `/dev/kvm`, and sakshi panics under TCG; the job runs the harness if all prereqs (`/dev/kvm`, qemu, a kernel image) are present and surfaces a `::warning::` if any are missing. Uses `BUDGET_MS: 5000` on CI (vs. the 3000 ms local default) to absorb the slower runner wall time. Needs `[build]`, so it doesn't fire if x86_64 build fails.

### Fixed
- **`klog2("boot: ", desc)` + `kmsg(desc)`** in `run_boot_stages` were passing a `Str` (boxed) where a `cstr` was expected — they ended up printing the Str header bytes as if they were chars, surfacing as garbage on the boot console (`kybernet: boot: ӆO`). Now passes `str_data(desc)` to extract the underlying cstr ptr. Pre-existing latent bug; surfaced because the harness assertions made the boot stage output a load-bearing signal.
- **`qemu/boot-crash-test.sh` + `qemu/boot-shutdown-test.sh`** referenced `scripts/build.sh` (removed in 1.1.0). Patched to call `cyrius build src/main.cyr build/kybernet` directly. The scripts are auxiliary shell-init-wrapped tests (not real PID-1 tests like `boot-test.sh`), but they're useful for testing service crash recovery and SIGTERM handling so they stay in tree.

### Removed
- **`qemu/initramfs/` and `qemu/initramfs.cpio.gz` untracked** — `.gitignore` adds `/qemu/initramfs/` and `/qemu/initramfs.cpio.gz` so the staging tree and the bundled cpio (build artifacts of `qemu/build-initramfs.sh`) don't churn the git index. The checked-in shape lives in `qemu/build-initramfs.sh` only. Matches argonaut's `qemu/` convention; same rationale as the 1.1.0 `lib/` untrack — `cyrius.lock`-style reproducibility lives in the source script, not the generated bytes.

### Stats
- x86_64 DCE binary: 1.026 MB → **1.027 MB** (+1.3 KB for `kybernet_harness_requested()` + 1024-byte cmdline buffer alloc — only allocated on the harness path)
- aarch64 cross-build: clean
- Local harness validation: **boot wall time 789–860 ms** (kernel hand-off → phase 8 → clean shutdown) on a dev host with KVM, vs. 3000 ms local budget / 5000 ms CI budget — comfortable headroom in both
- 160/160 tests; fmt/vet clean

### Notes
- The roadmap entry called for separate "minimal < 3s" and "desktop < 3s" boot gates. The current harness measures one boot mode (whatever `argonaut_config_default()` selects, which is `BOOT_DESKTOP`); kybernet doesn't yet thread `kybernet.boot_mode=...` from cmdline to the config, so per-mode gates are deferred until that wiring lands. The single-mode 860 ms result already proves boot-time is comfortably under both targets.
- Harness mode does NOT exercise the event loop (signals, health ticks, watchdog, notify), the emergency-shell drop, or the SIGHUP reload path. Those have unit-test coverage in `src/test.cyr` but no PID-1 validation; if a future regression breaks them, the harness will not catch it. Documented; intentional scope choice for 1.1.4 (validate boot reaches services-started; defer steady-state behavior to dedicated harness variants).
- argonaut's L3 (controlling-TTY + setsid) and M3 (orphan reaper) self-tests have no kybernet analogue — kybernet delegates service-lifecycle behavior to argonaut, so those tests live in argonaut's harness and are already validated there. Our harness only needs to prove "kybernet wakes up, mounts, hands off to argonaut, and shuts down clean."

---

## [1.1.3] — 2026-05-11

**Cgroup path precomputation.** `cgroup_file()` was a hot path (every service start writes 4-5 limits + moves the pid into the cgroup; shutdown reads/writes more). 1.0.x bench had it at 911 ns/op; on 5.10.44 stdlib it was already down to 800 ns/op via toolchain improvements alone, but it was still doing 6 `str_builder_*` calls per invocation, all in PID 1's startup hot loop.

The fix is precomputation: cache the path strings by `(service, filename)` after first build. Cgroup paths are deterministic functions of the pair, and the same pairs get hit repeatedly across a service's lifecycle.

### Changed
- **`src/lib/cgroup.cyr`** — added a layered path cache:
  - **Two-key LRU** (1 slot) on `cgroup_file()`. Pointer-compares `(service, filename)` against the last-call pair; hit short-circuits before any hashmap touch. Catches the same-pair-repeat case (read-then-write same control file).
  - **Per-service inner hashmap** keyed on filename, with a 1-slot LRU on the inner-map pointer keyed on service. The realistic burst pattern (apply 4-5 different limits for one service in a row) lands here: the 2-key LRU misses on each filename change, but the 1-slot service LRU skips the outer map lookup so each call is just one filename → fullpath hashmap_get.
  - **`cgroup_path()`** gets the same 1-slot LRU on service → prefix.
  - `_cg_cache_drop(service)` invalidates all three caches for a service; called from `remove_service_cgroup()`. Cached strings stay in memory (cyrius is gc-less); only the cache indices drop their references.

### Stats — bench delta vs. 1.1.2 (cyrius 5.10.44, x86_64)

| | 1.1.2 baseline | 1.1.3 |   |
|---|---:|---:|---:|
| `cgroup_path` (repeat-svc) | 417 ns/op | **3 ns/op** | **139× faster** |
| `cgroup_file` (same pair, best case) | 800 ns/op | **3 ns/op** | **267× faster** |
| `cgroup_file` (5-file burst, realistic) | 800 ns/op | **97 ns/op** | **8.2× faster** |

The realistic-burst number is the one to trust for live PID 1 use — `cgroup_apply_limits` writes memory.max → memory.high → cpu.weight → pids.max → cgroup.procs, exactly the pattern the burst bench measures. Same-pair best-case is only hit by read-modify-write loops, which kybernet does on shutdown but not at start.

The roadmap target was "~10× shrink under load." Realistic 8.2× hits within tolerance; same-pair 267× exceeds it. Cold path (first call for a new pair) is unchanged at ~800 ns — the cache only changes the warm case.

### Added
- **`test_cgroup_path_cache`** (5 assertions): exercises cold call → warm hit → different-filename-same-service → invalidation → re-build. Verifies content correctness across the cache lifecycle (cold and warm produce identical strings; different filenames produce different paths; re-build after invalidation produces the same string the cold call did). Catches future cache-key mismatches that would silently return stale paths.
- **`bench_cgroup_file_burst`** in `src/bench.cyr` — measures the 5-different-files-per-service pattern that mirrors `cgroup_apply_limits`. The pre-existing `bench_cgroup_file` measures the best case (same pair every iter); both numbers stay in the bench output so future changes show drift in either direction.
- Total: **153 → 160 tests** pass.

### Notes
- Two globals × two LRU slots = four extra `var` cells (32 bytes BSS). No allocation on the hot path; the only heap work is the str_builder + str_builder_build on cold-path misses, same as before.
- Cache keys are cstr (default `map_new()` mode), so any caller passing `Str`-shape names would need to drop to `str_data()` first. All current callers pass cstr literals or cstr-from-vec, so no change needed. Documented in the cache block comment.
- Pointer-identity assumption (the 1-slot LRU compares ptrs, not contents) is safe because: (a) string literals in cyrius have stable addresses, and (b) service-name cstrs from argonaut come from a single allocation per service that's stable across the service's lifetime. Misses on pointer-equal-but-different-contents are impossible; misses on pointer-different-but-content-equal degrade to the slow path (correct, just slower) and are caught by the inner hashmap on hit.

---

## [1.1.2] — 2026-05-11

**CLOEXEC sweep + mount graceful degradation.** Two long-standing items on the v1.0.1/v1.1.0 slate that didn't have a forcing function but are necessary hygiene for a PID 1: fd-leak audit across `sys_open` call sites, and mount-table classification so optional filesystems don't wedge boot on minimal hardware.

### Security
- **CLOEXEC audit** across every `sys_open` call site in `src/main.cyr` and `src/lib/*.cyr`. PID 1 inherits no fds — but any fd it opens leaks into every spawned service via `fork+execve` unless `O_CLOEXEC` is set at open time (or `FD_CLOEXEC` is set via `fcntl(F_SETFD)` before exec). The kybernet/argonaut split puts the open-side discipline in kybernet's lap.
  - **`src/main.cyr:105`** — `g_log_fd` (`/var/log/kybernet.log`): **highest-risk** site. The fd is global, open for PID 1's entire lifetime, and absent CLOEXEC would have been inherited by every service argonaut spawned. Adding `O_CLOEXEC` here is the load-bearing fix.
  - **`src/main.cyr:60`** — `kmsg()` on `/dev/kmsg`: short-lived (open → write → close in-frame), but the frame is reentered from signal handlers and pre-fork code paths. Adding `O_CLOEXEC` is defensive against fork-between-open-and-close races.
  - **`src/main.cyr:223`** — tmpfile `TMP_TOUCH` create: same short-lived-but-defensive shape.
  - **`src/lib/cgroup.cyr:57, 71, 115`** — cgroup-control writes (`cgroup.procs`, `cgroup.kill`, generic u64 writes): all called from PID 1's parent side of `fork()`. Without CLOEXEC, an interleaving spawn would have inherited the cgroup-control fd into the child, allowing the child to move processes between cgroups or kill its own peers.
  - **`src/lib/console.cyr:21, 25, 27`** — fds 0/1/2: **intentionally NOT CLOEXEC.** Standard I/O must pass through exec to spawned services. A comment block at the call site documents the reason so a future audit doesn't "fix" it.
  - `src/lib/sandbox.cyr` already had `O_CLOEXEC_FLAG` on its two Landlock path opens (carried over from 0.90.0).
  - `signalfd`, `timerfd`, `socket` (notify), `epoll_create` all already CLOEXEC: the stdlib wrappers wrap `signalfd4`/`timerfd_create`/`socket`/`epoll_create1` with `SFD_CLOEXEC`/`TFD_CLOEXEC`/`SOCK_CLOEXEC`/`EPOLL_CLOEXEC` set, and the call sites pass the right flags. No fix needed; verified in the audit.

### Added
- **Mount graceful degradation** in `src/lib/mount.cyr`. The mount table grew a sixth `required` field per entry; `mount_essential()` now hard-fails only on required-mount errors and records optional-mount failures in a separate accessor-exposed list. `src/main.cyr` boot phase 3 iterates the skipped list after `mount_essential()` returns and emits a `klog2()` line per skipped target, so the operator sees `kybernet: skipped optional mount: /dev/pts` rather than a silent disappearance.
  - Classification: `/proc` `/sys` `/run` `/sys/fs/cgroup` = required (1); `/dev/pts` `/dev/shm` = optional (0).
  - The motivating use case is **minimal embedded boot** — RPi-class boards without a serial console can boot the rest of the AGNOS stack without `/dev/pts`, and POSIX-shm-free service sets don't need `/dev/shm`. Both were previously fatal at boot.
  - Entry stride moved 40 → 48 bytes (5 → 6 i64 slots); backing array `_mount_table[240]` → `[288]`.
  - New API surface (visible to test + future consumers): `mount_skipped_count()` and `mount_skipped_target(idx)`. Out-of-bounds indices return 0 rather than crashing.

### Tests
- **`test_cloexec_fcntl_probe`** (4 assertions): opens `/dev/null` once with `O_CLOEXEC` and once without, calls `syscall(SYS_FCNTL, fd, F_GETFD=1, 0)`, asserts the returned flags' `FD_CLOEXEC` bit (= 1) matches expectations. The without-CLOEXEC control proves the probe distinguishes set from unset — a bogus probe returning 1 for everything would still pass the first assertion. No `sys_fcntl` wrapper in stdlib at 5.10.44; `SYS_FCNTL` constant is defined on both x86_64 (72) and aarch64 (25), so the raw call is portable.
- **`test_mount_required_flag`** (9 assertions): verifies `required` field is stored at offset +40 for each entry, with the per-entry classification matching the design (`/proc` `/sys` `/run` `/sys/fs/cgroup` = 1; `/dev/pts` `/dev/shm` = 0). Catches stride mistakes or re-orderings on future edits. Also exercises `mount_skipped_count()` returning 0 + accessor returning 0 for OOB indices (positive and negative).
- Total: **140 → 153 tests** pass.

### Stats
- x86_64 DCE binary: 1.02 MB → **1.02 MB** (+1.4 KB; new mount-skipped tracking + classification overhead)
- aarch64 cross-build: clean
- fn_table / identifier buffer: still under warn thresholds (1.1.1 headroom holds)
- fmt / vet / bench: clean

### Notes
- Upstream issue filed at `cyrius/docs/development/issues/2026-05-11-kybernet-fn-table-identifier-buffer-caps.md` requesting `fn_table` and `identifier buffer` cap doubling. Rated P2: 1.1.1 trim shipped clean, but the next minor (1.2.0 edge boot) will press back into the warn band. This isn't a 1.1.2 fix, just adjacent diligence.

---

## [1.1.1] — 2026-05-11

**Compiler-headroom cliff + size pass.** 1.1.0 shipped at `fn_table 92% (3779/4096)` and `identifier buffer 85% (112094/131072)` — both ceilings are hard, and the next dep bump (agnosys 1.2.4 → 1.2.5 landed mid-cut) would have tipped past them. Roadmap had this as the 1.1.1 slot with 1.1.2 sequenced afterward for the DCE/size pass; one fix collapsed both.

Audit of `CYRIUS_DCE=1` dead-code reports showed **3116 dead functions** out of ~3779 registered — kybernet was paying compiler-table cost for the full agnosys dist bundle (350 fns) while calling **zero agnosys-prefixed functions from its own source**. The libro / agnostik / argonaut dist bundles also make no agnosys-domain calls (libro's TPM path is gated behind `-D LIBRO_TPM`, off by default). Switching `[deps.agnosys] modules` from `dist/agnosys.cyr` → `dist/agnosys-core.cyr` reclaimed ~290 fn_table slots without breaking any consumer.

### Changed
- **agnosys profile bundle**: `dist/agnosys.cyr` → **`dist/agnosys-core.cyr`** (56 fns vs. 350 — syscall + error + logging only). Mirrors the kavach pattern (`core` + per-domain profile); the storage/trust/security/system profiles aren't needed at the PID-1 layer.

### Dependencies
- agnosys 1.2.4 → **1.2.5** (matches the new agnosys tag landed alongside this cut; cyrius pin already at 5.10.44, no toolchain change)

### Stats
- **fn_table warning gone** (was 92% — now below the 90% warn threshold; cyrius stops emitting the line)
- **identifier buffer warning gone** (was 85%)
- **Dead-fn count**: 3116 → **2430** (down 686 — the difference is the 290 agnosys-non-core fns plus DCE-driven secondary trims)
- **Binary x86_64 (`CYRIUS_DCE=1`)**: 1.29 MB → **1.02 MB** (−21%). Parity with argonaut's 1.0 MB DCE binary.
- **Binary aarch64**: cross-build clean; ELF check passes
- **140 / 140 tests** pass; vet clean; bench runs; fmt OK

### Notes
- The 1.0.x roadmap had "Binary size optimization" as gated on "dead-code elimination pending cc3 4.0" — that gate became moot in 1.1.0 (cc5 has `CYRIUS_DCE`), and the actual win here was upstream of DCE: trimming surface that the compiler had to register at all. DCE just makes the choice cheaper to validate (smaller binary = same correctness signal).
- agnosys-core surface check (regression guard): kybernet calls **only** `sys_*` syscall wrappers from the agnosys/stdlib boundary. If a future change adds a `log_*` / `mac_*` / `audit_*` / `tpm_*` / `luks_*` etc. call, swap `agnosys-core.cyr` for `agnosys.cyr` (or add the specific profile via a second `[deps.agnosys-<profile>]` entry).
- Roadmap consequence: 1.1.2 (DCE + size pass) was folded into this cut. 1.1.3/1.1.4/1.1.5 renumber down by one slot (now 1.1.2/1.1.3/1.1.4).

---

## [1.1.0] — 2026-05-10

**Foundation refresh.** Cyrius toolchain bumped, all four AGNOS deps moved to current tags, manifest modernized to use dist bundles where the dep ships one. The forcing function was upstream renames (agnosys moved `lib/syscalls_linux.cyr` → `src/syscall.cyr`, retiring the path the 1.0.2 manifest pinned) — once the rebase started, several previously-deferred items unblocked, so they're collapsed into this cut and the 1.1.x arc is rewritten around what's now in reach.

### Changed
- **Cyrius language**: 5.7.12 → **5.10.44**. Pinned to match argonaut 1.6.2 — argonaut's `health.cyr`/`process_mgmt.cyr` call `exec_vec_str`/`exec_env_str`, which only exist in the 5.10.44+ stdlib `process.cyr`. The 5.10.x toolchain is also where `cc5` lives (cc3 retired); cc5 lifts the 64-struct compilation ceiling that previously forced selective module imports for the heavy deps.
- **Manifest** (`cyrius.cyml`): stdlib pin order reordered to `argonaut`-style (syscalls early, before `io`/`process`) — the pre-existing layout tripped a cyrius transitive-dedup bug that was silently dropping `syscalls.cyr` from the preprocessed output, segfaulting `cc5` on link.
- **Stdlib pins**: dropped `sakshi` and `sigil` (libro 2.5+ promoted both to external git-pinned deps; patra 1.9+ pulls sakshi as its own dep — they land in `lib/` via transitive resolve and would otherwise duplicate-define against the version-pinned stdlib copy). Added `slice`, `result`, `trait`, `net`, `fs`, `ct`, `keccak`, `thread`, `random` — required by the new dist bundles.
- **`src/main.cyr`**: renamed `fn run()` → `fn kybernet_run()`. The stdlib `process.cyr` now exports its own `run(cmd, arg1, arg2)` and the dist-bundle pull made the collision a duplicate-fn warning under `cc5`.
- **`src/bench.cyr`**: header comment "deps resolved via cyrb.toml" → "stdlib + deps auto-included via cyrius.cyml" (cyrb retired in 1.0.0).

### Added
- **patra 1.9.3** declared explicitly under `[deps.patra]` (rather than inheriting whatever libro's pin transitively pulls). Mirrors argonaut 1.6+'s pattern of surfacing transitively-resolved deps so the version is under direct local control.
- **argonaut imports extended** with `resolver.cyr` / `notify.cyr` / `audit_ext.cyr` / `tmpfiles.cyr` — back the symbols (`resolve_host_ipv4`, `notify_bind`, `audit_log_*persistent`, `pal_chain`) that 1.6.x `init.cyr`/`health.cyr`/`process_mgmt.cyr` reference. `pid1_harness.cyr` intentionally **not** imported — it's argonaut's own QEMU PID-1 graduation harness, not a consumer-facing module.

### Dependencies
- agnosys 1.0.2 → **1.2.4** (now via `dist/agnosys.cyr` bundle — was selective `lib/syscalls_linux.cyr` only)
- agnostik 1.0.0 → **1.2.1** (now via `dist/agnostik.cyr` — was selective error/types/security/agent)
- libro 2.0.5 → **2.6.2** (now via `dist/libro.cyr` — was selective error/hasher/entry/verify/query/retention/chain/export)
- argonaut 1.5.0 → **1.6.2** (selective; argonaut ships no dist bundle. 1.6.x adds PID-1 harness internals, sigmask hardening for spawned services, `PATH` envp default, and the `audit_ext` persistence layer. 1.6.2 is the latest tagged release; argonaut's working tree is at unreleased VERSION 1.6.3.)
- patra newly declared at **1.9.3** (transitive via libro)
- sigil **3.0.1** + sakshi (transitive via libro/patra; pinned in `cyrius.lock`)

### Removed
- `scripts/build.sh`, `scripts/test.sh`, `scripts/bench.sh`, `scripts/bench-compare.sh` — all referenced `${ROOT}/../cyrius/build/cc2` (cc2 retired with 1.0.0). The modern path is `cyrius build`/`test`/`bench` directly. Roadmap had flagged these for removal since 1.0.1; the removal landed here so the test/release surface only points at one toolchain.
- `scripts/version-bump.sh` no longer touches `Cargo.toml` (Rust era; the file hasn't existed since 0.9.0). It now only rewrites `VERSION`; `cyrius.cyml` already pulls `package.version` from `${file:VERSION}`.
- **`lib/` untracked from git** (`.gitignore` adds `/lib/`). `cyrius.lock` already pins every resolved dep file by sha256 — checked-in `lib/*.cyr` was duplicating that contract. Aligns with the AGNOS-wide convention: agnosys / agnostik / libro / argonaut all gitignore `lib/`. `cyrius deps --verify` against the locked hashes is the reproducibility guarantee.

### Notes
- Build green on cyrius 5.10.44; **140 / 140 tests pass**, vet clean, bench runs.
- Binary x86_64 with `CYRIUS_DCE=1`: **1.29 MB** (was 447 KB at 1.0.2). The growth is from full agnosys/agnostik/libro/patra dist bundles vs. the prior selective-import slim cuts; 1.1.2 plans a profile-bundle vs. full-bundle audit to reclaim the headroom.
- `cc5` reports `fn_table at 92% (3773/4096)` and `identifier buffer at 85%` — these are hard ceilings; v1.1.1 is sequenced first in the 1.1.x arc to trim before the next dep bump tips past them.
- Compile-time warning catalogue (all carried up from dep dist bundles, not kybernet-introduced): one `match arms span multiple enums` in `agnosys.cyr`, four `duplicate fn 'err_*'` in `agnostik.cyr` (last-definition-wins is intentional), one `duplicate fn 'health_check_new'` in `argonaut_types.cyr`, one `duplicate fn '_hex_nibble'` in `sigil.cyr`.
- CI/release workflows carried forward unchanged except for a comment update to the lock-verify step (pins now include patra and the transitive sigil/sakshi entries).

---

## [1.0.2] — 2026-04-27

### Changed
- **Cyrius language**: bumped requirement from 4.5.0 → **5.7.12** for consistency with the rest of the AGNOS base OS (daimon and agnostik already pin 5.7.12).
- **Manifest format**: renamed `cyrius.toml` → `cyrius.cyml` to match the current `cyrius deps` resolver. Package version now interpolates from `VERSION` via `${file:VERSION}`.
- **Stdlib**: dropped `sakshi_full` from `[deps]` — it is no longer shipped in the 5.7.x stdlib (functionality folded into `sakshi`).

### Dependencies
- agnosys 0.97.2 → **1.0.2** (still imports `lib/syscalls_linux.cyr` only — the dist bundle would push past the 64-struct compiler limit)
- agnostik 0.97.1 → **1.0.0** (selective: src/error, types, security, agent)
- libro is now declared directly (was previously transitive via argonaut): pinned to **2.0.5** with src/error, hasher, entry, verify, query, retention, chain, export
- argonaut 1.2.0 → **1.5.0** (src/types, audit, services, health, process_mgmt, boot, init)

### Notes
- Build green on cyrius 5.7.12; **140 tests pass**.
- Stayed on selective `src/<module>.cyr` imports for the heavy deps rather than switching to `dist/<dep>.cyr` bundles — full bundles overflow the compiler's 64-struct ceiling for kybernet's combined unit. daimon/argonaut can use dist bundles because their dep graphs are lighter.

---

## [1.0.1] — 2026-04-12

### Fixed
- Release pipeline / CI version handling (versioning fixups, no source-level changes from 1.0.0).

---

## [1.0.0] — 2026-04-12

### Added

#### Config Loading
- **JSON config** — loads /etc/kybernet/config.json at boot (boot_mode, timeouts, log_to_console)
- **SIGHUP reload** — `handle_sighup()` reloads config and updates argonaut instance
- Fallback to `argonaut_config_default()` when config file missing or parse fails

#### Service Lifecycle
- **Exponential backoff restart** — uses argonaut's `backoff_delay()` from `CrashAction` instead of fixed 5s delay
- **Restart limit enforcement** — `restart_limit_exceeded()` triggers `CRASH_GIVE_UP` with reason string
- **Crash action logging** — logs `CRASH_RESTART` (with delay), `CRASH_GIVE_UP` (with reason), `CRASH_IGNORE`
- Shutdown uses `config_shutdown_timeout()` from loaded config

#### Emergency Shell
- **`drop_to_emergency()`** — fork+exec emergency shell on boot failure
- Uses argonaut's `emergency_shell_default()` (agnoshi, with banner and env)
- Fallback to `/bin/sh` if primary shell exec fails
- Waits for shell exit, then continues boot

#### Tmpfile Directives
- **`execute_tmpfiles()`** — walks `config_tmpfiles()` vec before service startup
- Supports `TMP_DIR` (mkdir), `TMP_SYMLINK` (symlink), `TMP_TOUCH` (create empty file)

#### Structured Logging
- **JSON lines** to `/var/log/kybernet.log` via `slog()` function
- `slog_init()` opens log file after filesystems mounted
- All klog/klog2 messages also emitted as structured JSON (`{"level":"...","msg":"..."}`)
- Log fd closed during shutdown

#### P(-1) Hardening (v0.95.0 work)
- signals.cyr: buffer overflow fix (buf[16] → buf[128] for signalfd_siginfo)
- console.cyr: checked sys_dup2 returns
- eventloop.cyr: checked epoll_add_read for signal fd
- main.cyr: PID 1 exit paths now call do_shutdown() instead of returning
- main.cyr: eventloop_add_notify return checked with cleanup
- mount.cyr: array overflow fix (_mount_table[8] → [240])
- mount.cyr: integer underflow guard in is_mounted()
- klog/klog2 batched to single sys_write (~2.7x faster)
- is_mounted() mount cache (145µs → 92ns, 1583x faster)
- 140 tests (was 98), 46 benchmarks (was 22)

### Changed
- Build tool: `cyrius build` with auto-include from `cyrius.toml` (was `cyrb build`)
- Source files contain only project includes — stdlib + deps auto-prepended by build tool
- Compiler: cc3 3.9.6+ required (was 1.9.1)
- Binary size: 447KB (includes argonaut + libro + sigil + sakshi transitive deps)
- CI: `cyrius deps` + `cyrius build` with fallback rebuild if tool binary is stale

### Dependencies
- Declared in `cyrius.toml` `[deps]` section, resolved via `cyrius deps`
- Namespaced: `lib/{depname}_{basename}` (e.g. `agnostik_types.cyr`)
- agnosys 0.97.2 — `lib/syscalls_linux.cyr`
- agnostik 0.97.1 — types, security, agent, error
- argonaut 1.1.0 — libro (error, entry, hasher, chain, query, verify, retention, export), types, audit, services, health, process_mgmt, boot, init
- 22 stdlib modules (string, fmt, alloc, io, vec, str, fnptr, tagged, callback, hashmap, json, freelist, process, sakshi, sakshi_full, sigil, syscalls, mmap, bigint, chrono, bench, assert)

---

## [0.90.0] — 2026-04-07

### Added

#### Security Modules
- **seccomp.cyr** — seccomp BPF filter builder and loader
  - Builder pattern: `seccomp_builder_new()` → `seccomp_allow(nr)` → `seccomp_build()` → `seccomp_load()`
  - Generates raw BPF bytecode with JEQ instructions, default KILL_PROCESS
  - `seccomp_basic_service()` preset with 37 safe syscalls
  - Agnostik integration: `seccomp_from_profile()`, `seccomp_apply_profile()`
- **sandbox.cyr** — Landlock filesystem sandboxing (new, not in Rust version)
  - Builder pattern: `sandbox_builder_new()` → `sandbox_allow_read/write/exec(path)` → `sandbox_apply()`
  - Graceful fallback on kernels < 5.13 (ENOSYS/EOPNOTSUPP → Ok(1))
  - `sandbox_basic_service()` preset: /usr (exec), /lib (read), /etc (read), /tmp+/var+/run (read-write)
  - Agnostik integration: `sandbox_from_ruleset()`, `sandbox_from_config()`
- **privdrop.cyr** — capability dropping and no_new_privs
  - `drop_capabilities(keep_set)` via PR_CAPBSET_DROP prctl
  - `set_no_new_privs()` (required before seccomp/landlock)
  - `secure_pre_exec(uid, gid, keep_caps)` orchestrating full security setup
  - Agnostik integration: `privdrop_from_context()`, `drop_caps_from_set()`, `secure_from_context()`
- **notify.cyr** — sd_notify socket for service readiness
  - Unix datagram socket at /run/kybernet/notify
  - Parses READY=1, STOPPING=1, WATCHDOG=1, RELOADING=1, STATUS=
  - Integrated with epoll event loop via TOKEN_NOTIFY

#### Agnostik Integration
- Consume agnostik security types: `security_context`, `capability_set`, `seccomp_profile`, `landlock_ruleset`, `sandbox_config`, `cgroup_limits`, `resource_limits`, `agent_config`
- **privdrop.cyr** — `secure_from_context(ctx, caps)` accepts agnostik security context
- **seccomp.cyr** — `seccomp_apply_profile(profile)` accepts agnostik seccomp profile
- **sandbox.cyr** — `sandbox_from_ruleset(ruleset)` accepts agnostik landlock ruleset
- **cgroup.cyr** — `cgroup_apply_limits()`, `cgroup_apply_resource_limits()`, `cgroup_setup_agent()` accept agnostik limits and agent config
- 34 new tests covering all agnostik type construction, access, and integration bridges

#### Dependency Management
- **cyrb.toml** — TOML-based dependency resolution via Cyrius 1.9.1
  - `[deps] stdlib = [...]` for stdlib modules
  - `[deps.agnosys] git + tag + modules` for pinned git dependencies
  - `[deps.agnostik] git + tag + modules` for pinned git dependencies
  - `cyrb build` auto-prepends resolved includes before source
- Removed vendored `lib/agnosys/` — resolved from git tag at build time
- Removed manual `include` directives for stdlib and agnosys from all source files

#### Boot & Event Loop
- kmsg logging at each boot phase for QEMU serial console visibility
- Notify socket integrated with epoll event loop (TOKEN_NOTIFY)
- Event loop handles READY, STOPPING, WATCHDOG, STATUS notify messages

#### Benchmarks & Testing
- **src/bench.cyr** — 22 microbenchmarks across 8 categories
- **scripts/bench.sh** — build and run benchmarks with history tracking
- **scripts/bench-compare.sh** — side-by-side Cyrius vs Rust comparison table
- **benches/rust_compare.rs** — standalone Rust benchmark (raw syscalls, no libc)
- QEMU boot tests ported from rust-old: boot-test, boot-crash-test, boot-shutdown-test
- 98 integration tests (was 33)

### Changed
- **Cyrius 1.9.1** language features throughout:
  - `switch/case` with dense jump table optimization (classify_signal, handle_signal, priv_error_print, _access_to_flags)
  - `for` loops with step expressions replacing `while` + manual counter
  - `elif/else` chains replacing nested `if` blocks
  - `&&` and `||` operators replacing nested conditionals
  - `break/continue` in loops replacing flag variables
- Binary size: 93,800 bytes (was 47,888 at 0.9.0, increase from agnostik types)
- Rust comparison: 71x smaller binary, 2x faster boot, 1.06x syscall parity

### Dependencies
- agnosys 0.90.0 (git tag, modules: lib/syscalls_linux.cyr)
- agnostik 0.95.0 (git tag, modules: src/security.cyr, src/agent.cyr, src/error.cyr)
- Cyrius stdlib: string, fmt, alloc, io, vec, str, fnptr, tagged, callback, assert, bench

### Not Yet Ported from Rust
- Service lifecycle management (wave-based startup, restart with backoff)
- Health check enforcement and watchdog timeout handling
- Configuration loading from JSON / SIGHUP reload
- Edge boot (dm-verity, LUKS, PCR binding)
- Emergency shell with authentication
- Coordinated shutdown (service stop ordering)
- Tmpfile directive execution

These features depend on argonaut (service manager) which is being ported to Cyrius separately.

---

## [0.9.0] — 2026-04-05

### Changed
- **Complete rewrite from Rust to Cyrius** — 727 lines (was 1649 Rust)
- All 7 modules + main entry point in Cyrius
- Result/Option error handling throughout (via tagged.cyr)
- String builder for path construction
- Data-driven mount table (not hardcoded calls)
- Callback library for functional patterns (vec_map, vec_filter, fork_with_pre_exec)
- OwnedFd pattern, structured EpollEvent returns
- PrivError enum with specific error codes and verification
- 33 integration tests

### Added
- src/main.cyr — full boot sequence + event loop + signal dispatch + shutdown
- scripts/build.sh, scripts/test.sh — Cyrius build tooling
- rust-old/ — preserved Rust implementation for reference

## [0.51.0] — 2026-04-03

### Fixed
- **console.rs**: Use `into_raw_fd()` instead of `as_raw_fd()` when opening `/dev/console` — prevents the `File` destructor from closing the fd while it's still in use as stdout
- **main.rs**: Corrected boot phase comments (phase 6/7 → phase 8/9) to match actual ordering

### Changed
- **main.rs**: Signal handling now drains all queued signals per epoll wake (`while let` loop instead of single `if let`) — prevents signal loss under burst
- **main.rs**: `process_pending_restarts` uses `retain` + collect instead of front-popping — the queue is not sorted by `restart_at`, so the old approach could skip ready items behind a future one

### Added
- **eventloop.rs**: Test `drain_timerfd_returns_nonzero_after_expiration` — validates timerfd expiration count
- **eventloop.rs**: Test `into_raw_fd_keeps_fd_open` — documents the console.rs fd ownership fix

---

## [0.50.0] — 2026-04-03

### Added

#### Scaffold
- Project scaffold per AGNOS first-party standards
- `console.rs` — /dev/console + /dev/null stdio setup (after devtmpfs mount)
- `mount.rs` — essential filesystem mounting (/proc, /sys, /dev, /run, cgroup2)
- `mount_devtmpfs()` — standalone devtmpfs mount (must run before console setup)
- `signals.rs` — signalfd setup for SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGPWR
- `reaper.rs` — zombie reaping via waitpid(-1, WNOHANG) loop
- `cgroup.rs` — cgroup v2 per-service isolation (create, move, kill, remove)
- `privdrop.rs` — privilege drop via pre_exec setuid/setgid/setgroups
- `eventloop.rs` — epoll event loop with timerfd, OwnedFd RAII wrapper
- `main.rs` — PID 1 entrypoint: boot flow, service startup, event loop, shutdown

#### Hardening (P(-1) audit)
- Fixed 11 audit findings: fd leaks (OwnedFd), no assert/panic, /proc mount ordering, etc.
- 27 unit tests across all modules
- Delayed restart via timerfd with PendingRestart queue (exponential backoff)
- Config reload on SIGHUP (registers new services from reloaded config)
- Edge boot wired: rootfs lockdown + dm-verity + LUKS via argonaut::execute_edge_boot
- NOTIFY_SOCKET bound and set in environment before service startup
- Cgroup cleanup on service exit (kill_cgroup + remove_service_cgroup)
- Health-driven restart: poll_health results trigger restart when threshold exceeded
- Watchdog-killed services automatically scheduled for restart
- Emergency shell authentication via argonaut::verify_emergency_auth
- Reap ordering: reap_services BEFORE reap_zombies (prevents waitpid race)
- kmsg output for QEMU serial console debugging

#### QEMU Boot Testing
- Minimal mode: 2.98s kernel+init, 140ms init-to-event-loop
- Desktop mode with real daimon binary: 2.9s total, 120ms init-to-event-loop
- Wave-based parallel startup: postgres+redis (Wave 0) → daimon+dependents (Wave 1)
- Crash recovery: service crash → SIGCHLD → reap → delayed restart with backoff → GiveUp after limit
- Clean shutdown: SIGTERM → plan → stop services → sync → reboot(RB_POWER_OFF)
- QEMU test scripts: boot-test.sh, boot-crash-test.sh, boot-shutdown-test.sh, boot-desktop-test.sh
- build-initramfs.sh: creates QEMU-bootable initramfs with kybernet + busybox

#### Infrastructure
- cargo vet initialized (Mozilla, ISRG, Google, Zcash audit imports)
- CI workflow: fmt, clippy, test, audit, deny, msrv
- Release workflow: version verification, multi-arch build, GitHub release
- deny.toml with AGNOS git source allowlist
