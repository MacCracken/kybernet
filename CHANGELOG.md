# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.6.11] — 2026-08-26

**Deleting a benchmark of dead code, without weakening the gate that forbids it.**
Suite 676 assertions. Benchmarks 57 → 56 (declared). No dep change.

### Removed — `sandbox_from_ruleset` and `_ll_access_to_kernel`

Neither had a production caller. `_ll_access_to_kernel`'s only caller was
`sandbox_from_ruleset`, whose only caller in the entire tree was `src/bench.cyr` — a
chunk of the Landlock surface existing solely to be benchmarked.

What forced the decision rather than leaving it filed: at 1.6.10 that benchmark flagged
a **+20% regression** (2560 → 3075 ns, paired against the 1.6.9 tag) on a release that
never touched `sandbox.cyr`. Pure link-layout movement. **A benchmark of dead code that
fails release gates is worse than no benchmark** — it measures where the linker put
something nothing calls, and it costs a release cycle to prove that each time.

The live per-service path is untouched: `sandbox_from_config` → `_access_to_flags` is
what `kyb_pre_exec` uses, and `kyb-landlock` still proves denial from inside the child.

### Added — `BENCH_REMOVED=<n>`, a declared removal that cannot hide a real one

Deleting a benchmark trips `bench-history.sh`'s shrink check, which exists because a
deleted benchmark leaves the regression gate silently. The fix is not to weaken it.

`BENCH_REMOVED=<n>` declares "I removed exactly n benchmarks on purpose", and **must
match the shortfall exactly** — so a deliberate removal of 1 cannot absorb an unrelated
disappearance that lands in the same run. Verified both directions: undeclared it still
fails (`SHRANK — 56 < 57`), declared it passes with the shrink stated in the log.

### Changed — standing rule 9 rewritten, because its subject no longer exists

The rule kept `_ll_access_to_kernel`'s explicit `if`-ladder and justified it as "the
per-service Landlock path where a miscompile is a PID-1 crash". That was **false**, as
1.6.4 established: the function's only caller chain terminated in `src/bench.cyr`. It
guarded a benchmark while claiming to guard init, for seven releases.

Rule 9 now points at the path that IS live — `sandbox_from_config` → `_access_to_flags`,
a `switch` of `case N: return K` bodies, i.e. the shape the rule itself states was never
affected by the 6.4.62 miscompile — and keeps the actionable part: if a future
`_access_to_flags` ever needs to accumulate flags across cases, write an `if`-ladder
rather than trusting the fix, because that IS the path where a miscompile is a PID-1
crash.

**A rule defended by a false reason survives until someone checks, and then it is worth
less than nothing.**

## [1.6.10] — 2026-08-26

**The last sd_notify verb, and the difference between authentication and authorisation.**
Suite 676 assertions. Harness 58 → 61 properties. No dep change (argonaut 1.13.7).

### Added — `MAINPID=` is honoured, behind two independent checks

The last unhonoured verb, and the one that could not be done by parsing alone. Each
check rejects a different attack.

**1. A bounded parse.** `str_to_int` honours a leading `-` and silently skips
non-digits, so `MAINPID=-1` yields **-1** and `MAINPID=1abc` yields 1. `process_kill`
has no internal `pid > 0` guard — the check is duplicated across its five call sites —
so from PID 1 a claimed pid of -1 handed to `kill(2)` means **every process on the
machine**. `knotify_parse_pid` accepts plain decimal digits only, bounds DURING
accumulation (rule 25 — a long digit run would otherwise wrap onto a small value that
passes a ceiling test), and refuses anything at or above `PID_MAX_LIMIT`.

**2. ⚠ CGROUP MEMBERSHIP — and this is the conceptual half.** `SO_PASSCRED` proves
which process SENT a datagram. It says nothing whatsoever about the pid named INSIDE
it. A service that is authenticated, correctly attributed and entirely legitimate can
still claim `MAINPID=<another service's pid>`, and honouring that would aim kybernet's
supervision — and eventually its kill path — at an unrelated process.

`cgroup_has_pid` consults `cgroup.procs`, the kernel's own membership list for that
service, which the service cannot forge. It answers 0 on EVERY failure — unreadable
file, unsafe name, truncated read — because it gates a privileged action and "could
not tell" must never read as "yes". It compares whole lines, so pid 42 cannot satisfy
a claim for pid 4. The read carries one byte of headroom so a full read is
distinguishable from a truncated one (rule 30).

A refused claim is counted and logged, never fatal: a service naming a pid outside its
own cgroup is misconfigured or hostile, and either way the answer is to ignore the
claim rather than kill anything.

### Added — a fixture that forges a MAINPID from an honest sender

`kyb-notify` now sends `MAINPID=1` — kybernet itself, emphatically not in its cgroup —
and `MAINPID=-1`. It is authenticated and attributed throughout; only the claim is
false. That is precisely the case authentication cannot catch.

Three assertions, because the absence of a crash proves nothing: the cgroup refusal,
the malformed rejection, and a **non-zero `refused-mainpid` counter** confirming the
claims were seen and judged rather than dropped somewhere upstream. That last arm
exists because the first sd_notify harness run at 1.6.3 reported `rejected: 4` with no
way to tell why, and splitting the reasons is what made it diagnosable.

### Known — `sandbox_from_ruleset` is 20% slower, on code this release never touched

⚠ **Real, reproducible, and in a function with no production caller.** Paired samples
from a clean worktree at the 1.6.9 tag versus this tree, same box, back to back:

```
1.6.9:   2597, 2531 ns/op
1.6.10:  3069, 3078 ns/op        (~+20%)
```

`src/lib/sandbox.cyr` is untouched by this release. This is the third benchmark to
behave this way — `strlen(52 chars)` at 1.6.3, `is_mounted` at 1.6.8, now this — all
of them untouched code moving when unrelated code changes size. The likely mechanism is
the same: this release added `cgroup_has_pid` (~50 lines) to `cgroup.cyr` and widened
`NS_SIZE`, shifting layout for everything downstream.

**Zero product impact, by construction rather than by argument:**
`sandbox_from_ruleset`'s only caller in the entire tree is `src/bench.cyr`. Nothing in
production reaches it — that is the roadmap item filed at 1.6.4. Boot span is 182 ms
against a 1200 ms budget.

So a function nothing calls, benchmarked for its own sake, is now failing release
gates. That is a stronger argument for the removal that item already prescribes than
anything written when it was filed: the benchmark is not measuring kybernet, it is
measuring where the linker happened to put dead code. Left in place for this cut
because deleting it must land together with the recorded benchmark COUNT the gate
checks, and that is a separate change made deliberately rather than at the end of
another one.

### Fixed — widening `NS_SIZE` without widening its buffers

⚠ Introduced and caught within the same change, and worth recording because of how it
presented. Adding the MAINPID fields took `NS_SIZE` from 48 to 64 bytes while three
callers still declared `var sc[48]` — so `knotify_scan` wrote 16 bytes past each
buffer. Standing rule 2 exactly: `var X[N]` is N BYTES, not slots.

The test suite did not report a failing assertion. It **stopped**, mid-run, at
`--- notify ---`. A silent halt rather than a red line is what memory corruption looks
like from outside, and it is a far weaker signal than a failure. The buffers now carry
the `NS_SIZE` relationship in a comment rather than a bare number.

## [1.6.9] — 2026-08-26

**Services can finally run as something other than root.**
Suite 676 assertions. Harness 56 → 58 properties. No dep change (argonaut 1.13.7).

### Added — `security.uid` / `security.gid`, and the privilege drop that had no caller

The entire uid/gid half of `privdrop.cyr` was unreachable: `drop_privileges` had **no
caller anywhere in the tree**, there was no config key, and argonaut's
`ServiceDefinition` has no such field — so every service ran as root.

That is not a cosmetic gap. It is precisely why the 1.6.3 sd_notify forgery analysis
concluded the real exposure was **one compromised service forging notifications about
another**: with no uid separation, `SO_PASSCRED`'s uid check excludes nobody. There is
now an actual boundary to check against.

Verified from inside the dropped child, reading its own `/proc/self/status`:

```
NONROOT-Uid:	65534	65534	65534	65534
NONROOT-Gid:	65534	65534	65534	65534
```

All four fields — real, effective, saved-set, filesystem. The **saved-set** value is
the one that matters: had only the effective uid dropped, a compromised service could
`setuid(0)` straight back.

⚠ **THE POSITION IN `kyb_pre_exec` IS REQUIRED, NOT CONVENTIONAL.** The drop is step 4
of six: cgroup → no_new_privs → capabilities → Landlock → **privdrop** → seccomp.

- **After Landlock**, so ruleset construction and `landlock_restrict_self` still run
  as root — no question about whether an unprivileged process can open rule paths
  `O_PATH`, which is exactly how the 1.6.6 fixture failed.
- **Before seccomp**, and this is the constraint that bites: verified that **none** of
  `setuid` / `setgid` / `setgroups` / `setresuid` are in the `basic` allowlist.
  Installing the filter first would make the drop fail `EPERM` — and the service would
  then run as ROOT having been explicitly configured not to. A privilege drop that
  silently does not happen is worse than one never requested, so it also **fails
  closed**: the child exits rather than exec'ing.

**Numeric uids only.** This tree has no `/etc/passwd` reader and PID 1 is the wrong
place to gain one — name resolution at boot means parsing a file that may live on a
filesystem not yet mounted, on the path where failure is unrecoverable.

**`-1` means "not configured", not uid 0.** Conflating them would make an absent key
indistinguishable from an explicit request to stay root. Values are **refused**
outside 0..2^31-1 rather than clamped: a uid is an identity, and silently substituting
a different one is worse than refusing the service (rule 25's principle).

The ids ride on kybernet's own `KybSeccompPolicy`, hung off `svc_def_seccomp`, for the
same reason `landlock_optional` does — no argonaut change, no dep tag.

### Added — a fixture that proves the uid, not the survival

A service that merely starts proves nothing; a root service starts too. `kyb-nonroot`
reads its OWN `/proc/self/status`, so the value is observed from inside the child.

It **cannot** write `/dev/console` — that node is 0600 root, which is itself evidence
the drop worked — so it writes `/dev/shm` (tmpfs `mode=1777`) and a root reader with an
explicit `depends_on` surfaces it. The dependency is load-bearing, not decoration:
without it the wave order is whatever the resolver produces and the reader can run
first, which is the trap that made `kyb-limited` pass on luck from 1.5.5 to 1.6.6
(rule 36).

⚠ The first version of the reader used `sed`, which is **not** among the busybox
applets this initramfs symlinks (`sh ls cat mount ps kill sleep echo dmesg true false
awk cut grep printf`). Fourth fixture this cycle to assume something the environment
does not supply, after `/lib64`, `mawk` vs gawk, and OpenSSL 3.2's ARGON2ID. **When a
fixture shells out, the available command set is part of the environment contract.**

## [1.6.8] — 2026-08-26

**sd_notify READY and WATCHDOG are honoured, not merely observed.**
argonaut 1.13.5 → **1.13.7**.

### Changed — READY=1 now transitions a service, and WATCHDOG=1 refreshes a deadline

1.6.3 built the whole substrate — SO_PASSCRED authentication, pid → service
attribution, a zero-allocation line scanner, five harness assertions — and then had
to log the verbs and discard them, because argonaut had nowhere for them to land.
`init_start_simple` set `STATE_RUNNING` synchronously before returning, so **no
service was ever awaiting a notification.**

argonaut 1.13.6/1.13.7 added `SVC_NOTIFY`, `last_notify` and `watchdog_ms`. So:

- `READY=1` calls `init_notify_ready`, which promotes a `"type": "notify"` service
  from STARTING to RUNNING. It is idempotent and **one-way** — a compromised
  service cannot declare itself un-ready and cascade restarts through everything
  downstream. A `simple` service sending READY gets 0 back, which is normal rather
  than an error: it is just being polite.
- `WATCHDOG=1` calls `init_notify_watchdog`, which refreshes `last_notify` and
  **nothing else**.

⚠ **`last_health_check` remains untouchable by any ping, and that is the point.**
It means "a probe argonaut RAN and OBSERVED passing"; `last_notify` means "the
service SAID it was alive". Letting a self-report satisfy the health deadline would
let a wedged service silence a failure that was actually observed — and
authentication does not cure that, since SCM_CREDENTIALS proves the ping came from
the service, not that the service is honest about its own health.

`MAINPID=` is still parsed, logged and discarded: honouring it needs a bounded parse
(`str_to_int` accepts a leading `-`, so `MAINPID=-1` yields -1, and `process_kill`
has no internal `pid > 0` guard — from PID 1 that is `kill(-1, SIGKILL)`) plus proof
the pid is in the service's own cgroup. Roadmapped rather than half-done.

### Added — `watchdog_ms`, rejected rather than clamped

A per-service sd_notify watchdog deadline, independent of `health_check`. Before
this, the runtime watchdog arm was gated entirely on a health check existing, so
most services had no watchdog at all and `WATCHDOG=1` had nothing to refresh.

Bounded 100 ms … 1 hour and **refused** outside that range, not clamped. A watchdog
is a kill decision: too small and a healthy service is killed for not pinging fast
enough, too large and it is not a watchdog. Silently clamping a typo would hand an
operator a board that kills its own services on a schedule they never wrote — the
same reasoning as the Argon2 parameter bounds at 1.5.9 (rule 25). 0 or absent means
no notify watchdog, preserving pre-1.6.8 behaviour exactly.

`"type": "notify"` needed no parser change: argonaut extended `service_type_parse`,
so kybernet picked it up for free.

### Fixed — the benchmark gate demanded speedups the machine happened to provide

The gate flagged **eleven** regressions on this release, several with IDENTICAL raw
values — `alloc(4 sizes burst): 38 -> 38 ns/op (+15%)`. Not one lived in a file the
release touched. Two separate defects, both in the gate:

**1. Normalisation ran in both directions when it should only run in one.** It exists
(rule 6) so the gate survives a BUSY machine: when the box is slower everything is
slower, and raw comparison would flag dozens of untouched primitives. But an
unclamped ratio also works in reverse — the box quietened, `_calibration` fell
128 → 113, expectations dropped ~12%, and anything that did not speed up
proportionally was called a regression. **The scale may only forgive slowness, never
demand speedup**; it is clamped at 1000 now, so a faster box simply holds code to its
previous absolute figure.

**2. One reference cannot predict benchmarks with different bottlenecks.**
`_calibration` is pure ALU in L1; syscall-bound work is dominated by kernel entry and
the host's mitigations. They do not accelerate together. `getpid` is now a second
reference for the syscall-bound set (`getuid`, `is_root`, `drop_caps`,
`set_no_new_privs`, `secure_pre_exec`, the epoll/timer trio) — the cheapest real
syscall, so it tracks entry/exit cost and nothing else. This closes the roadmap item
filed at 1.6.1.

Together: 11 flagged → 1.

### Known — `is_mounted` really is ~13% slower, and it is layout, not logic

⚠ **Recorded rather than dismissed, because it is real.** Paired samples from a clean
worktree at the 1.6.7 tag versus this tree, same box, back to back:

```
1.6.7:  4302, 4061, 4029 ns/op
1.6.8:  4548, 4547, 4926, 4589 ns/op        (~+12.6%)
```

`mount.cyr` is untouched by this release. The cause is almost certainly layout: this
release added ~50 lines to `notify.cyr`, a helper to `svc_config.cyr`, and — most
relevantly — rewrote **52 log string literals** from UTF-8 em-dashes to ASCII, which
shrinks each by two bytes and shifts `.rodata` for everything after it. `is_mounted`
scans a 2 KiB table and is the most cache-sensitive benchmark in the suite.

**No product impact:** kybernet's own boot span is 166 ms against 167 ms at 1.6.7 —
the `KYB_MS` metric that exists precisely because microbenchmarks report properties of
the binary and the machine rather than of the code (rule 37).

I first leaned toward calling this bimodal noise, because the recorded history does
oscillate (3941 / 4479 / 4479 / 3942 / 4547) on unchanged code. The paired test
refuted that: the baseline tree is consistently ~4130 and this one consistently
~4650. Two modes exist AND the release moved between them. Roadmapped, because a
benchmark that has now needed three interventions — it read the host's real mount
table at 1.6.1 (+641% on a runner), got a fixed 2 KiB table, and is still the one
that moves — is telling us something about its design.

### Changed — the harness now asserts a STATE TRANSITION, not a log line

`kyb-notify` is `"type": "notify"` with `watchdog_ms: 30000`, so it is left
STARTING and its own authenticated READY=1 is what promotes it.

⚠ The assertion matches the PROMOTION string, with an explicit middle arm: if the
old observation line appears WITHOUT the promotion, that is a **failure**. Matching
the old string would have passed against a completely broken feature — which is not
hypothetical. **argonaut 1.13.6 shipped `SVC_NOTIFY` with no dispatcher arm routing
to it, so every notify service was marked STATE_FAILED with "unknown svc type", and
this assertion is what caught it.** argonaut's own test had simulated the start path
by setting the state directly, so 22 green assertions said the feature worked.

## [1.6.7] — 2026-08-26

**A config key that mis-sized a watchdog, and a dep bump that made a test fail correctly.**
Suite 667 → 676 assertions. argonaut 1.13.4 → **1.13.5**.

### Fixed — `health_check.interval_ms` was parsed, stored, and never reached the timer

The reactor polled on a hardcoded 30 s timer, so a service asking for 5 s got 30.
`config_log_console` and `boot_timeout_ms` were the same shape at 1.6.4; this is
the third key in that family.

⚠ **It is not merely a slow poll.** argonaut sizes the runtime watchdog deadline as
`interval * retries + timeout` from the service's OWN configured interval. A service
asking for 5 s and polled at 30 s therefore carried a watchdog sized for a cadence
it never received — **it could be killed for being late when it was the poller that
was late.** The key was silently load-bearing for something other than latency.

The health timerfd is necessarily created at phase 5, before the config is parsed at
phase 6, so `eventloop_rearm_health` re-arms the SAME fd afterwards — keeping the
epoll registration and the level-triggered drain contract (rule 13) untouched.

⚠ **This is a poll FLOOR, not per-service scheduling, and the code says so.**
argonaut's `init_poll_health` checks every service with a health check on each tick
and kybernet cannot ask it for a subset. The timer therefore takes the SMALLEST
interval any service requested:

- no service is polled more slowly than it asked for — the defect being fixed;
- a service that asked for a LONGER interval is polled more often than requested.
  Over-polling a health check is wasteful, not wrong.

True per-service scheduling needs argonaut to accept a due-time filter, and is
roadmapped rather than faked here. Clamped to [1, 30] s: below 1 s the reactor
spends its life polling, and 30 s is the historical default so a config with no
health checks behaves exactly as before. Intervals round UP, so 1500 ms polls at
2 s rather than 1 s.

The computation lives in `src/lib/svc_config.cyr`, not `main.cyr`, so the test
binary can reach it (standing rule 34) — six unit tests cover the min-selection,
both clamps, the rounding, and the two no-health-check paths.

### Changed — argonaut 1.13.5

Four fixes, all of which were argonaut discarding information it already had:

- **`enum SocketType` had no values.** cyrius numbered it from 0 against the
  kernel's 1/2, producing a `duplicate symbol … conflicting value` warning on every
  build of BOTH repos. Now gone.
- **The orphan sweep discarded its reaped pids**, so a service exiting between its
  own probe and the sweep kept a `STATE_RUNNING` entry holding a freed pid forever
  — and any process recycling that pid was then attributed to that service.
- **`notify_try_recv_authenticated` collapsed four outcomes into `0`** and threw
  away the authenticated sender pid. Its drain `break`s on `0`, so one forged
  datagram per tick starved every legitimate message behind it.
- **A zero-length datagram ended the drain early** — legal on `AF_UNIX SOCK_DGRAM`,
  consumed by `recvmsg`, and misread as "queue empty".

### Changed — a 1.6.3 test correctly went red, and that is the point

`test_knotify_socket_constants` asserted `SOCK_DGRAM == 1`, pinning the BROKEN
state: argonaut's unvalued enum made the bare name resolve to `SOCK_STREAM`'s real
value. argonaut 1.13.5 fixed it, so the assertion failed on the dep bump — exactly
what a test that documents a known-wrong value is for.

It now asserts the correct values, with the history in the comment so the change of
meaning is legible. kybernet's local `SOCK_DGRAM_TYPE = 2` is KEPT even though the
collision is gone: it costs nothing, states the intended value at the one call site
that matters, and means a future dep regression cannot silently turn kybernet's
datagram socket into a stream socket.

## [1.6.6] — 2026-08-26

**The last confinement mechanism with no fixture, and a gate that had been passing by luck.**
Suite 667 assertions. Harness 53 → 55 properties. argonaut 1.13.3 → **1.13.4**.

### Changed — argonaut 1.13.4

Picks up two per-tick arena leaks fixed there: `init_check_watchdog` (304 bytes per
10 s watchdog tick — 2.63 MB/day on a completely idle board) and `init_poll_health`
(a vec per 30 s health tick). Both now iterate their map in place and allocate
lazily; measured at 152 bytes total across 2000 calls each, i.e. one memoized vec
and nothing after. Verified present in the resolved lib rather than assumed from
the tag.

1.13.4 also repairs argonaut's test runner, which had been compiling and running
**nothing** since 1.13.0 while reporting success — see that CHANGELOG. Every
argonaut version kybernet has consumed for the last five releases had no test
coverage behind it.

⚠ Contract note carried across: argonaut's idle paths now return a SHARED memoized
empty vec. kybernet only reads it (`vec_len`/`vec_get` in `handle_health_tick` and
`handle_watchdog_tick`), which is safe; do not mutate a returned result vec.

### Added — `kyb-landlock`, the fixture standing rule 27 required

`grep -rn landlock qemu/` returned **nothing**. `kyb-confined` covered capabilities
and `no_new_privs`; `kyb-seccomp` covered the filter; the third confinement
mechanism reached `landlock_restrict_self` through `kyb_pre_exec` with nothing
asserting it did anything — the exact shape in which `"seccomp": "basic"` shipped
for three releases killing every service it was applied to.

⚠ **THE ASSERTION IS THE DENIAL, NOT THE SURVIVAL.** The service is granted
read-exec on `/bin`, `/lib64`, `/usr` and read-write on `/dev`, with `/etc`
deliberately excluded. It then reads one path inside the rule set and one outside,
reporting both from INSIDE the confined child. "The service ran" proves nothing —
an unconfined service also runs. Requiring both outcomes makes it falsifiable in
both directions: an inert sandbox fails the outside check, a wrong ruleset fails
the inside one.

It sets `"landlock_optional": false`, so on a pre-5.13 kernel the service fails
closed rather than starting unconfined — which surfaces as a missing line, not a
false pass. That is rule 29's middle arm, the one that looks like success.

**Getting this wrong twice was instructive, and CI caught what local runs could
not.** The first version granted `/bin` only; Landlock is default-deny, so the
child could not reach its loader or `/dev/console` and failed to start — correctly
and loudly, because `landlock_optional` was false. The second version added
`/lib64` and passed **here** while failing on **the runner**, and the reason is the
whole point of standing rule 39:

`/lib64` existed in the image only when the build host's busybox was DYNAMIC,
because the libc-staging branch created it. Arch (dynamic busybox) produced an
image with it; Ubuntu's `busybox-static`, which CI installs, produced one without.
Same script, two shapes. Since `_landlock_add_path` opens every rule path `O_PATH`
and fails the entire ruleset if it cannot, the fixture's rule set was a function of
the machine that built it.

The fix removes the dependency rather than papering over it: the fixture is now a
**cyrius binary** (`qemu/landlock-fixture.cyr`), which links no libc and needs no
loader, so its rule set collapses to `/usr` + `/dev` and holds on any host.
Verified under CI's shape by emptying `/lib64` and `/usr/lib` locally. `/lib64` is
still created unconditionally so the two images match, but nothing depends on it.

⚠ A wrong turn worth recording: the first attempt to reproduce the CI failure
emptied `/lib64` on an image with a DYNAMIC busybox — which breaks the exec itself,
not Landlock, and so proved nothing about a runner whose busybox is static. A
reproduction that fails for a different reason than the thing being reproduced is
worse than no reproduction.

### Fixed — a confinement failure that said nothing

`kyb_pre_exec` returned `1` on a Landlock failure with no diagnostic at all, so the
operator saw only `FAILED to start: <service>`. That cost a full CI round trip to
diagnose. It now `kmsg`s which mechanism failed and names the overwhelmingly common
cause — a rule path that cannot be opened — and separately reports the pre-5.13
"no Landlock and landlock_optional=false" case. `kmsg` rather than `klog` because
this runs in the pre-exec child, whose stdout belongs to the service.

### Fixed — a cgroup control-case assertion that had been passing by luck

Adding a service to the fixture set broke `LIMIT-unlimited`, and the cause was not
the new service. `kyb-limited` reads **another service's** cgroup
(`/sys/fs/cgroup/kybernet.slice/kyb-live/memory.max`) as its unlimited control case,
and had **no `depends_on`** — so it only ever worked because the wave resolver
happened to order `kyb-live` first. Adding an unrelated service reshuffled the waves
and the file was not there yet.

Standing rule 36 — *a gate must not assert the outcome of a race* — green since
1.5.5 purely on ordering luck. Fixed with an explicit `depends_on: ["kyb-live"]`
and a comment saying why it is load-bearing, rather than by re-ordering the config
so the luck holds.

Worth recording the shape: adding a fixture did not cause a bug, it **revealed**
one. A gate that passes for accidental reasons is indistinguishable from a gate
that passes for real reasons, right up until something perturbs it.

## [1.6.5] — 2026-08-26

**A per-SIGCHLD arena leak that needed no socket, no credentials and no config.**
Suite 667 assertions. Harness 53 properties. No dep bump — argonaut stays 1.13.3
here; its own 1.13.4 (two matching per-tick leaks) needs a tag before kybernet
can consume it.

### Fixed — `reap_zombies` leaked 152 bytes on EVERY SIGCHLD

`var results = vec_new();` sat BEFORE the waitpid loop, so a SIGCHLD that reaped
nothing still cost a full vec — a 24-byte header plus a 128-byte 16-slot backing
array. In the one arena PID 1 never resets (standing rule 8) that is permanent
growth, and `alloc` mmaps a fresh 256 MB chunk on overflow, so the terminal state
on real hardware is host OOM with an unkillable PID 1.

**It is the most reachable leak found so far.** The 1.6.3 notify leaks at least
required reaching a 0700 socket. This one needs no socket, no credentials and no
configuration: any process that forks a child and lets it die delivers a SIGCHLD
to PID 1, and a double-fork reparents grandchildren here forever.

The idle path now returns a memoized empty vec and allocates lazily — the exact
treatment argonaut's `proc_table_reap` already carried, commented "The idle path
now allocates nothing." kybernet's reaper was the same shape without it.

Measured: **152 bytes total across 2000 calls**, down from 304,000. Idle cost is
now zero; 168 bytes only when a process is genuinely reaped.

⚠ The returned empty vec is SHARED. It is never mutated and callers must not
mutate it; `reap_and_log` only reads it.

### How it was found, and why nothing caught it

By measurement, not reading — a probe diffing `alloc_used()` across 2000 calls.
Neither the 667-test suite nor the 53-property harness could see it: fixture-scale
traffic is a handful of SIGCHLDs, and 152 bytes each is invisible there. That is
the same blind spot that hid both 1.6.3 leaks.

Three further per-tick leaks were confirmed in argonaut by the same method and
fixed there (see argonaut 1.13.4): `init_check_watchdog` at 304 B per 10 s tick
and `init_poll_health` per 30 s tick. Combined with this one, roughly **1.7 MB/day
of permanent growth on a completely idle board.**

### Deliberately not fixed — `audit_log_record` retains

240 bytes per crash event, and it **retains** rather than merely leaking arena:
a probe ended with `audit_log_len == 1006`, i.e. live reachable data-structure
growth. Trimming an audit chain is a retention-policy decision with security
implications, not a mechanical fix. Roadmapped rather than decided in passing.

## [1.6.4] — 2026-08-26

**Config keys that were parsed and never consulted, and code with no callers.**
Suite 660 → 667 assertions. Harness 50 → 53 properties. No dep change (argonaut stays 1.13.3).

### Fixed — `log_to_console` was parsed, stored, copied on reload, and ignored

`config_log_console` had exactly **two readers in the whole tree**: its own definition and the
reload copy. `klog`/`klog2` wrote to `STDERR_FD` unconditionally, so `"log_to_console": false`
did nothing at all. The 1.5.0 note said the value "was ignored entirely" — only the *spelling*
was fixed then (a string compare against `"false"`), never the behaviour.

Measured in a real boot: **43 console lines with it on, 6 with it off**, and those six are
precisely the pre-config-load lines plus a final line announcing that logging is going quiet.

Deliberately NOT gated: `kmsg()` (dmesg is a separate channel with its own consumer, and
suppressing console chatter must not erase the record read after the fact), the structured log,
and the emergency password prompt, which opens its own descriptor via `console_open_rw()` and
never goes through `klog` (rule 20). The flag defaults ON because everything before phase 5 runs
before the config is parsed, and a board that fails there must still be able to say so.

### Changed — `boot_timeout_ms` is consulted, and honestly labelled a BUDGET not a timeout

`config_boot_timeout` previously had two readers, the reload copy and one unit test. It is
checked at every boot-stage boundary now, but the code says plainly what it cannot do:

- It **cannot interrupt a hung stage.** Phase 7 runs before the reactor and the signal mask is
  blocked in favour of signalfd, so there is nothing to deliver an alarm to.
- It **can** notice at each boundary that the boot has already overrun — the slow board, the
  retrying dependency, the degrading disk, which are the cases that actually occur.

It logs once and **continues** rather than dropping to the emergency shell: a boot that is
merely slow is still a boot, and turning a slow disk into an unbootable board would be a worse
failure than the one being reported.

### Removed — dead chains, after checking which ones were actually dead

⚠ **The roadmap entry overstated this, and deleting from it blind would have broken the build
twice.** Two named symbols were live:

- `edge_boot_verity_ok` — read by `boot_stages.cyr:89` since 1.5.7.
- `cgroup_apply_limits` (live, `cglim_*`) sits one word from `cgroup_apply_resource_limits`
  (dead, agnostik's `rlim_*`). Deleting by name similarity would have removed the limits path
  the harness asserts.

Actually removed: `cgroup_setup_agent` (zero callers) and the two functions only it reached,
`move_to_cgroup` and `cgroup_apply_resource_limits` — all superseded at 1.5.5 by the child-side
`_kyb_join_cgroup` (rule 16), since a parent-side move is unavoidably late and cgroup v2 charges
memory on first touch without migrating charges. `cgroup_apply_resource_limits` was **standing
rule 14's hazard in person**: it read agnostik's `rlim_*` accessors, while `svc_def_rlimits`
returns a struct argonaut fills to its own incompatible layout — a plausible-looking function
that reads `nofile` as `max_memory`. Also removed `any_failures` and five zero-caller accessors
(`edge_boot_elapsed_ms`, `edge_boot_pcr_mismatches`, `edge_hash_device`, `edge_luks_device`,
`edge_expected_pcrs`), two of which carried comments claiming "main reads these … in the boot
summary". There has never been a boot summary.

### Fixed — standing rule 9 was defended by a false reason

The rule kept the explicit `if`-ladder in `_ll_access_to_kernel` because it was "the per-service
Landlock path where a miscompile is a PID-1 crash". Verified: `_ll_access_to_kernel` has exactly
one caller, inside `sandbox_from_ruleset`, and **`sandbox_from_ruleset`'s only caller in the tree
is `src/bench.cyr`**. The live per-service path is `sandbox_from_config` → `_access_to_flags`,
which is a `switch` of `case N: return K` bodies — the shape rule 9 itself states was never
affected by the 6.4.62 miscompile.

So the rule was protecting a benchmark while describing it as guarding PID 1. The ladder stays
(it is correct and costs nothing) and the rationale is rewritten, because a rule defended by a
false reason is one bad day from being deleted for the right one. That the Landlock surface is
benchmark-only is now its own roadmap item.

### Added — the quiet harness pass, with a falsifiability guard

`log_to_console` reaches a syscall, so rule 27 applies. The pass boots a second image identical
to the first but for that one key.

⚠ **The guard is the whole design.** "kybernet printed nothing" is also exactly what a board
that died before phase 1 looks like, so an assertion that only counts absent lines cannot fail
correctly. The pass requires **both** that kybernet's own output collapses **and** that a line a
*service* wrote to `/dev/console` is still present — proving the boot reached phase 8 while
kybernet stayed quiet — plus that the transition was announced.

### Fixed — two harness helpers were defined below their callers

`_skip_or_fail` and `_assert_no_panic` lived below the boot and reactor passes. That is why the
`veritysetup` skip could not reach `_skip_or_fail` and silently ignored `HARNESS_STRICT` (noted
at 1.6.1), and adding the quiet pass put a third caller above the definitions. A shell function
used before its definition is not a syntax error — it is an unbound command at runtime, inside a
failure branch, under `set -e`. Both are now defined above every pass.

## [1.6.3] — 2026-08-25

**sd_notify was received, classified, logged and discarded — and leaked memory doing it.**
Suite 632 → 660 assertions. Harness 45 → 50 properties. No dep change (argonaut stays 1.13.3).

### Fixed — a root-triggerable memory-exhaustion DoS against PID 1

`notify_read` did `var buf = alloc(512);` on **every datagram**, on the reactor hot path,
in the one arena PID 1 never resets (standing rule 8). Every service runs as root —
argonaut's `ServiceDefinition` has no uid field — so any service could send datagrams in
a loop and permanently consume 512 bytes each until the 256 MB arena was gone, after
which every other allocation in PID 1 begins failing. It also fed an **unchecked** `alloc`
return straight into `store8(buf + n, 0)`; `alloc` returns 0 on exhaustion, so the failure
mode was a write through a null pointer in the one process the kernel will not let die.

One static buffer now, allocated once.

⚠ **The first version of this fix did not fix it, and an adversarial review of this
release caught that before it shipped.** Removing the 512-byte `alloc` from `notify_read`
left a *new* per-datagram allocation on the same path: `kyb_notify_service_for_pid` called
`init_service_names(g_init)` for every message, and that is `map_keys` — a `vec_new()` (24-byte
header + 128-byte backing array) plus a push per service, **every call, nothing freed**.
Measured at **152 bytes per datagram** with 8 services, and 408 above 16 once the vec grows.
Same arena, same root-only actor, same terminal failure; 70% smaller. **A reduction is not a
fix**, and the heading on this section would have been false.

Service names cannot change without a reboot — `reload_config` explicitly refuses service
changes — so the list is now built **once**, after services start, and reused. The
per-datagram path allocates **nothing**: receive buffer, status buffer and scan slot are all
static, and `klog2` does not allocate.

Also guarded `_u64_str` (`src/lib/console_io.cyr`), which did an **unchecked** `alloc(24)` and
then wrote through it — the identical shape this release removed from `notify_read`, one file
over, reached by every `klog2` that formats a number. It degrades to `"?"` instead of faulting.

⚠ **And the obvious fix would have made it worse.** Two of three investigation lanes
recommended routing through argonaut's `notify_parse`. Measured, that allocates **840
bytes per datagram** (a `NotifyMessage`, a str-keyed hashmap, then two `str_clone`s and up
to twelve `str_from`s per line, none freed) — replacing a 512-byte leak with an 840-byte
one while looking like the principled fix. kybernet scans the buffer in place instead,
with zero allocation.

### Fixed — any service could forge notifications about any other service

`notify_read` called `recvfrom` with a NULL `src_addr` and nothing anywhere set
`SO_PASSCRED`, so no datagram carried the sender's identity and every message was believed.
The roadmap described this as "any process on the box can forge any message"; the real
shape is narrower and worse. `/run/kybernet` is mode 0700, so non-root cannot reach the
socket at all — but every service runs as root, so the actual exposure was **one
compromised service forging notifications about a different service**.

Now: `SO_PASSCRED` at bind (failing closed — a socket that cannot authenticate is refused
rather than silently dropping 100% of legitimate traffic), and a `recvmsg` that requires
`SCM_CREDENTIALS`. Attribution is pid → service via the kernel-vouched ucred, never the
`MAINPID=` field inside the message, which is attacker-controlled by definition.

kybernet's receive is deliberately **stricter than argonaut's**: it checks `MSG_CTRUNC`
and `cmsg_len`, neither of which argonaut checks, and returns distinct codes for *empty*
versus *rejected*. That distinction is not cosmetic — argonaut's own drain `break`s on
rejection because it collapses both into `0`, so one forged datagram per tick would starve
every legitimate message queued behind it.

### Fixed — the parser could not see a readiness notification a real service sends

`knotify_classify` compared at offset 0 and returned the first match. An sd_notify datagram
is newline-separated `key=value` lines and carries several at once, so:

```
"STATUS=starting up\nREADY=1\n"  ->  NOTIFY_STATUS   (READY silently lost)
"READY=10"                        ->  NOTIFY_READY    (a prefix, not the value)
```

`STATUS=…\nREADY=1` is the ordering systemd's own documentation shows. Replaced with a
line-oriented, allocation-free scanner comparing whole values, plus
`knotify_status_sanitize` — `STATUS=` text reached `klog` **raw** before this, so a service
could emit terminal escapes or embedded newlines that forge additional log lines on PID 1's
console.

### Changed — WATCHDOG=1 and MAINPID= are refused, deliberately

Both are parsed, attributed and logged; neither changes state.

**WATCHDOG=1** — the only refreshable deadline is `managed_svc_last_hc`, which already
means *"the last health check PASSED"*. Refreshing it on a self-reported ping would let a
wedged service silence a probe kybernet actually ran and observed failing. Authentication
does not cure that: it proves the ping came from the service, not that the service is
honest about its own health. Needs a separate `last_notify` field in argonaut; roadmapped.

**MAINPID=** — verified by execution: `str_to_int` honours a leading `-` and silently skips
non-digits (`MAINPID=-1` parses to `-1`), and `process_kill` has no internal `pid > 0`
guard. From PID 1 that is `kill(-1, SIGKILL)` — every process on the machine.

Also honest about scope: at argonaut 1.13.3 **READY=1 cannot change managed state**.
`init_start_simple` sets `STATE_RUNNING` synchronously before returning and there is no
notify service type, so no service is ever left awaiting a notification. `init_service_ready`
is a read-only predicate that marks nothing — the roadmap entry's framing of it as a
readiness sink was wrong. READY is an authenticated, attributed, audited observation here.

### Removed — a hand-rolled per-arch syscall table whose fold-out trigger fired five releases ago

`enum SockSysNr` promised *"fold these out when sys_socket/sys_bind/sys_recvfrom land in the
stdlib"*. All three had landed, arch-dispatched, with byte-identical numbers — which is why
the duplication never warned. Closes a second roadmap item.

### Added — the harness pass that did not exist (standing rule 27)

`grep -rn notify qemu/` returned **nothing** before this: kybernet bound the socket,
registered it with epoll and wrote a handler, and no release gate had ever delivered a
single datagram to it. Identical shape to `"seccomp": "basic"`, which shipped for three
releases killing every service it was applied to.

`qemu/notify-fixture.cyr` sends four datagrams as a real supervised service so the kernel
stamps credentials kybernet can verify. Five assertions, in the **reactor** pass.

### Benchmarks — three notify microbenchmarks regressed, explained (standing rule 6)

The gate flagged these and they are real. Recorded here with numbers rather than waved off,
because rule 6 permits explaining a regression only if the explanation is evidenced.

```
knotify_classify(READY)    16 ->  71 ns/op
knotify_classify+value     52 -> 196 ns/op
notify_status_value(2)     21 -> 155 ns/op
```

**The old numbers were the cost of being wrong.** The 16 ns classifier was one 7-byte
`memcmp` at offset 0, and it silently lost `READY=1` whenever a `STATUS=` line preceded it
— the ordering systemd's own docs show — and accepted `READY=10` as readiness. Any correct
implementation has to walk lines. These three functions are also compatibility **shims kept
for the existing assertions**: the production path (`handle_notify_msg`) calls `knotify_scan`
once per datagram and never calls `strlen` at all.

⚠ **The first two attempts to close the gap made it worse, both times because I reasoned
instead of measuring.** Recorded so the next person skips the detour:

- Five separate buffer walks (four `knotify_flag` + one `knotify_field`) where the old code
  did one `memcmp`. Replaced with a single pass.
- The single pass came out **slower** (138 ns vs 75). Cause, measured:
  **`memset(48)` costs 67 ns/op; six explicit `store64`s cost 4** — a 16x difference, and
  roughly half the total call cost on a 7-byte datagram. `memset` is a length-generic loop
  with call overhead that loses badly at small fixed sizes. Worth knowing repo-wide.

**On `strlen(52 chars)`, which the same runs flagged at +39% and which this release does not
touch.** Recorded in full because the investigation refuted five plausible explanations and the
sixth is uncontrollable — the next person should not repeat the first five.

Reproducible at calibration parity (131 vs 132), and NOT an artefact of benchmark order: with a
cut-down bench running only the calibration loop and `strlen`, an unmodified worktree measures
**28 ns** and this tree measures **39 ns** on the same box, back to back. Ruled out by direct
experiment:

| hypothesis | test | result |
|---|---|---|
| branch-predictor state | 1M `strlen(7)` calls before `strlen(52)` | 26 vs 26 — refuted |
| code size | 60 dead functions added to the baseline | 28 — refuted |
| string literals / rodata | 5 literals added to the baseline | 27 — refuted |
| a dynamic `strlen` caller | one added to the baseline | 27 — refuted |
| `bench.cyr` layout | dead function inserted before the notify benches | still 39 — refuted |
| benchmark order | strlen-only binary, both trees | 28 vs 39 — **order excluded** |

There is exactly one `strlen` in the link set (`lib/string.cyr:6`), so this is not a duplicate
symbol winning differently. The same machine code runs at 28 in one binary and 39 in another,
and the binary is 14.6 KB larger — leaving **code placement/alignment of strlen's hot loop** as
the remaining class. That is a real microarchitectural effect, not a semantic regression, and it
may flip back on any unrelated future edit.

**No product impact, measured:** kybernet's own boot span is **156 ms against 153 ms at 1.6.1**
(the harness's `KYB_MS`, which exists precisely because microbenchmarks report properties of the
machine and the binary rather than of the code — standing rule 37). Left explained rather than
"fixed", since there is nothing here to fix; if it moves again it should be re-investigated
rather than assumed to be this.

### Fixed — a diagnostic that could abort the entire harness run

`boot-test.sh` runs under `set -euo pipefail`. Its failure-branch diagnostics are
`echo … | grep … | head -N` pipelines, and a grep that matches **nothing** exits 1, which
under `pipefail` + `set -e` **ends the script**. So the first failing assertion whose
diagnostic had nothing to print killed the run then and there — skipping every remaining
assertion, the reactor pass, the edge pass and both auth passes, and reporting one failure
as though it were the only one. That fired for real while adding the assertions above.

Standing rule 38 in a new form: a gate must not be able to suppress a different gate, and a
*diagnostic* must never be able to end the run. 21 of these existed; all are guarded now.

## [1.6.2] — 2026-08-25

**Code that does nothing, and docs that say it does.**
Suite 632 assertions. Harness 45 properties. argonaut import list 13 → 12 modules;
no dep version change (argonaut stays 1.13.3).

### Removed — boot phase 6b was a provable no-op with three defects

`execute_tmpfiles()` and `enum TmpfileType` are gone from `main.cyr`, along with the
phase 6b call site and the `src/tmpfiles.cyr` entry in argonaut's import list.

**It could never have run.** `config_tmpfiles(cfg)` is a getter; there is no
`config_set_tmpfiles` anywhere in argonaut, and the only write to that field in either
tree is `store64(cfg + 56, vec_new())` inside `argonaut_config_default()`
(`argonaut/src/types.cyr:1006`). No `tmpfiles` key was parsed in any kybernet source.
So the loop body had never executed once, in any release.

**And it was wrong three ways if it ever had:**

- `TMP_TOUCH = 2` aliased argonaut's `TMP_DEVICE = 2`. argonaut's enum is *unvalued*, so
  cyrius numbers it 0/1/2, and the only doubly-defined name — `TMP_SYMLINK` — holds the
  same value in both. There was therefore **no `conflicting value` warning to catch it**.
- The touch arm read offset `+16` as `mode`. In argonaut's `TmpfileEntry`
  (`{entry_type@0, path@8, target@16, mode@24, uid@32, gid@40, …}`) that is `target`, a
  `Str` pointer, which was then passed as the mode argument to `sys_open`.
- It passed the boxed `Str` at `+8` straight to `sys_mkdir` as a cstr (standing rule 3).
- A fourth, previously unfiled: the symlink arm discarded `sys_symlink`'s return and
  incremented `created` unconditionally, so a failed symlink counted as a success.

**Why deleted rather than built.** The need is real — `/run` is a fresh tmpfs every
boot, and `aethersafha`, which kybernet starts *by default* in `BOOT_DESKTOP`, binds
sockets under `/run/agnos/{agents,plugins}` and contains no `mkdir`. But kybernet
already ships the mechanism for it: a `"type": "oneshot"` service, wave-ordered,
cgroup-placed, supervised, and covered by six of the nine QEMU fixtures. A service with
no `security` block runs unconfined as root and can `mkdir`/`chown`/`chmod` freely.
Building tmpfiles instead would have put a new root-privileged filesystem-mutation
surface — config-driven, needing a JSON schema, a path validator and a symlink-safe walk
— inside the least recoverable process on the machine, to buy what one config object
already buys. The roadmap item is now "port `agnos-init.sh`'s `setup_directories()` to a
oneshot", with the two real blockers named.

No harness change: phase 6b emitted no `kmsg`, so no marker moves, and standing rule 27
does not apply to a deletion. Its non-applicability is part of why deleting won.

### Fixed — two audit findings that cleared this code for the wrong reason

Both prior audits looked at `execute_tmpfiles` and let it through. Both reached the right
operational verdict — nothing reached a syscall — via reasoning that does not hold, and
both are now retracted in place rather than edited, so the record shows what was believed
and when it was corrected.

- `docs/audit/2026-05-11-audit.md` cleared path injection because "tmpfile paths come
  from `config_tmpfiles()`, also argonaut-validated". Nothing populates that field, and
  the validator argonaut ships (`validate_tmpfile_entries`) has **zero callers in either
  tree** — it describes a function that has never run.
- `docs/audit/2026-08-24-audit.md` listed "tmpfiles Str-as-cstr" among findings "refuted
  against the actual code". The defect was real; what was true is that it was
  unreachable.

**The lesson, recorded because it generalises: "unreachable" and "correct" are not the
same verdict.** Filing the first as the second is what let three defects sit in
`main.cyr` for the lifetime of the function — and "it's validated" is an active
invitation to the next person to wire up the parser.

## [1.6.1] — 2026-08-25

**Gates that could not fail, and the kernel panic the first new one found.**
Suite 608 → 632 assertions. Harness 44 → 45 properties. 55 → 57 benchmarks.
argonaut 1.13.2 → 1.13.3; no other dep change.

⚠ The first cut of this release failed its own new benchmark gate, and the
three benchmark fixes below are the result. They are folded in here rather
than split into a follow-up: a release whose CI went red did not ship, so
there is one 1.6.1 and this is it.

1.6.0 shipped four defects that had survived three releases, and every one of
them survived because a gate could not see it or could not go red. This
release is about that, and it justified itself on the first fixture.

### Fixed — argonaut's watchdog kill path segfaulted PID 1 (argonaut 1.13.3)

Adding a service with a failing health check to the harness produced, on the
very first run:

```
Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b
```

`init_enforce_watchdog` took the **cstr** view of the timed-out service name
and passed it to `proc_table_pid(name)` — but every `proc_table_*` entry point
does `str_data(name)` internally, because they take a **boxed Str**. It loaded
the first eight characters of `"kyb-health"` *as a pointer* and handed that to
`map_get`. Standing rule 3, in the dep.

**Why nothing had ever caught it.** `init_check_watchdog`'s only runtime arm
is health-check driven and `init_enforce_watchdog` is reachable from nowhere
else, so with no `health_check` in any argonaut test or any consumer fixture,
the function had **never executed** — not once, in any release of either repo.
The corollary is worth stating on its own: **with no `health_check` configured
there is no watchdog at all.**

argonaut 1.13.3 fixes it and adds `tests/tcyr/watchdog_kill.tcyr`, which
drives the path with a real proc-table entry and is **verified to fail on the
unfixed source with exit 139 (SIGSEGV)** — it cannot fail an assertion there,
because a wild dereference has no other way to present.

### Fixed — six gates that could not turn the build red

- **The QEMU harness could not fail CI.** `continue-on-error: true`, and an
  unreadable `/dev/kvm` set `skip=1` so every later step no-oped and the job
  went green having executed nothing. It is a hard gate now; a genuinely
  unavailable prerequisite **fails** with a reason instead of passing
  silently (`ALLOW_HARNESS_SKIP=1` to override).
- **28 of the harness assertions never ran in CI.** The job installed
  `qemu-system-x86 cpio` only, so `build-initramfs.sh` dropped all three edge
  and auth fixtures and passes 3, 4a and 4b skipped — including both
  credential formats CLAUDE.md rule 26 says are gated. Now installs
  `cryptsetup-bin` and `busybox-static`.
- **A skip and a pass looked the same.** New `HARNESS_STRICT=1`, which CI
  sets: a missing fixture there means fixture *generation* broke, which is
  exactly the regression class a silent SKIP hides.
- **The bench regression gate was never run by CI at all.** `grep -rn
  bench-history .github/` returned nothing. It could not have been a gate
  before 1.6.0 made it load-tolerant; now it runs with `RUNS=5`, advisory on
  pull requests and enforced on the release path.
- **The aarch64 build silently no-oped** on a toolchain without the backend,
  and `release.yml` then published with no aarch64 artifact — while README
  and CLAUDE.md both say both architectures are release-gated. Both now fail,
  and the release additionally checks the artifact really is an aarch64 ELF.
- **`cyrius test` asserted `0 failed` but not the count**, so a suite that
  silently shrank passed trivially. The floor now comes from CLAUDE.md.

### Fixed — CI's security scan was decoration

`scan "raw system()" '\bsystem\s*\('` passed an ERE pattern to BRE `grep`,
where `\(` **opens a group**. grep exited 2 with "Unmatched ( or \(", stderr
was discarded and the status was swallowed into an `awk` pipe, so `hits` was
always empty and the check always reported clean. It was the helper's only
caller. Verified both ways: the old pattern finds nothing in a file containing
a literal `system(` call; the new one finds it.

### Fixed — `is_mounted` benchmarked the machine, not kybernet

CI reported `is_mounted(/proc): 48 -> 445 ns/op, +641%` while **every other
benchmark in the same run improved** — the runner is simply faster at
syscalls than the box that recorded history, and the calibration normalisation
handled that correctly (`getpid` -42%, `set_no_new_privs` -50%). One
benchmark did not fit, and nothing in kybernet had changed.

`is_mounted` scans the cached `/proc/self/mounts` byte by byte and returns at
the first match, so its cost is *how many bytes of the host's mount table sit
before the target*. A dev box with 27 mounts and a CI runner carrying Docker
and overlay mounts are nowhere near each other.

**1.6.0's calibration loop normalises CPU speed. It cannot normalise how much
data the host hands you.** A benchmark over host-shaped input can therefore
never be regression-gated across machines, and that is a property of the
benchmark, not a threshold to tune.

The benchmark now installs a **fixed 2 KiB synthetic mount table** with
`/proc` placed last, so every run scans the same bytes and takes the worst
case rather than a lucky early hit. Renamed to
`is_mounted(/proc, 2KiB fixed table)` so it is obvious the input is
synthetic. Measured spread across three consecutive local runs: 4075 / 4013 /
4004 ns/op — 1.8 %. It also now asserts the lookup actually matched, since a
benchmark of a *miss* would scan the same bytes and report a plausible number
while measuring the wrong path.

### Changed — the Argon2 benchmark was the same defect, not yet fired

`emerg_verify argon2id (m=8192 t=1)` had not failed, but it is the identical
class and would have eventually: Argon2 is memory-**hard**, so at the m=8192
floor it touches 8 MiB and lands in L3/DRAM, while the calibration loop is a
tight dependent-chain integer loop — pure ALU. The ratio between two machines'
ALU speed and their memory subsystems is not the same number, so the
normalisation cannot hold it.

Replaced with `argon2id_into (m=64 cache-resident)`, which stays in cache and
therefore tracks the calibration. It still exercises H0, the fill schedule,
the finalizer and the arena contract — everything except the DRAM traffic.
Spread across three runs: 757118 / 754295 / 759007 ns/op — 0.6 %. The suite
also got 950 ms faster.

**The production cost is a policy number, not a regression signal.** It lives
in CHANGELOG 1.5.9 with its measurements (m=19456/t=2 → 232 ms, and the
`m*t <= 131072` work cap derived from it). Re-measure it deliberately when the
parameters change rather than inferring it from a gate line.

### Fixed — the harness demanded OpenSSL 3.2 and CI has 3.0

The second thing that failed this release's own new gates, and the same shape
as the first: `build-initramfs.sh` minted the argon2id credential fixture with
`scripts/mkcred.sh`, which drives `openssl kdf ... ARGON2ID`. **ARGON2ID
landed in OpenSSL 3.2 and Ubuntu 24.04 runners ship 3.0.x**, so the fixture
was dropped, the whole argon2id credential pass skipped, and `HARNESS_STRICT=1`
correctly failed the build. The gate was demanding a property the environment
could not supply.

`scripts/mkcred.sh` stays exactly as it is — an operator provisioning a board
has openssl, not a Cyrius toolchain, and that is the right tool for them. But
the *gate* now mints its fixture with **`qemu/mkcred-fixture.cyr`**, which uses
sigil's Argon2id — the same implementation `emergency_auth.cyr` verifies with —
so any machine that can build kybernet can produce it. Verified byte-identical
to OpenSSL 3.6 at these parameters.

⚠ That is deliberately **not** a cross-check, and the file says so: generating
and verifying with one implementation proves they agree with each other, not
that either is right. The independent check stays in `src/test.cyr`, which
carries OpenSSL-generated vectors, so a sigil regression fails the unit suite.

A generator failure is now **fatal** rather than a warning — silently dropping
the fixture is precisely what let this pass go unrun.

Also: `build-initramfs.sh` had been reporting `staged /etc/kybernet/config.json
(2 services, 1.5.0 harness)` while staging nine. Counted now, not hardcoded.

### Fixed — the cgroup teardown sweep raced, and the gate asserted the race

`remove_all_service_cgroups` called `kill_cgroup(nm)` and `remove_service_cgroup(nm)`
on adjacent lines. **`cgroup.kill` is asynchronous**: it sets the kill bit and
returns, and the kernel delivers SIGKILL on its own schedule. So the `rmdir`
could beat SIGKILL to a still-running child, fail `EBUSY`, and leak a cgroup —
or not — depending on scheduling.

The harness asserted the racy outcome as an exact literal,
`removed service cgroups: 8`, with a comment arguing the shortfall was correct
because kyb-orphan's unreaped zombie still held its cgroup. **That reasoning
was wrong.** A zombie does not keep a cgroup populated — the kernel drops the
task from the populated count in `cgroup_exit()`, which runs inside `do_exit()`,
long before anyone calls `wait()`. The only thing that ever produced an 8 was
the race against a still-*running* `sleep`.

Measured on a runner-faithful rebuild (Ubuntu's azure kernel + `busybox-static`),
the literal 8 was not even stable: **70% of idle boots and 100% of contended
boots produced 9**, so the gate failed on correct behaviour depending on machine
speed and load. It also fired locally, mid-session, on an unmodified tree.

`_remove_cgroup_settled` now retries **only `EBUSY`** under a whole-sweep
150 ms budget (a whole-sweep bound, not per-cgroup — this runs on the path to
`sys_reboot`, where the one unacceptable outcome is not arriving), and a
shortfall is now logged rather than passing as a success line. The marker is
`9`, verified deterministic across repeated boots.

⚠ While fixing this: the retry initially did nothing, because the first version
called **`err_code(r)`** where `r` is a tagged `Result` box. `err_code(ret)` is
`0 - ret` and takes a **raw** negative syscall return; `err_code_of(res)` reads
the payload out of a box. Both are in scope, neither is a compile error at the
call site, and the only symptom is that the bug you are fixing appears to
persist. Use `err_code_of` for anything that returns `Result`.

### Fixed — the boot budget was 82% a measurement of the runner's kernel

`WALL_MS` spanned qemu spin-up through shutdown, and the budget comment called
it "the conservative proxy" for kybernet's own work with "~200-400 ms" of
overhead. Measured, the split is nothing like that:

| | qemu + kernel boot | kybernet's own span | total |
|---|---|---|---|
| Arch dev kernel | 630 ms (83%) | 119 ms | 749 ms |
| Ubuntu azure kernel (the CI one) | 2333 ms (82%) | 494 ms | 2827 ms |

So the identical tree "took" 750 ms locally and 2830 ms in CI while running the
same amount of kybernet, and CI compensated by raising `BUDGET_MS` to 8000 —
compensating for the *metric* being wrong rather than for anything being slow.
The next time it fired it would have read as "kybernet got slow".

This is the same defect as `is_mounted` benchmarking the host's mount table,
and it gets the same treatment: **measure the code, not the machine.** The
serial stream is now timestamped host-side and the gate is `KYB_MS`, the span
from `kybernet: starting` to `kybernet: shutdown` — 150 ms locally against a
1200 ms budget. `WALL_MS` is retained only as a loose 20 s liveness ceiling,
and the CI override is gone.

### Fixed — the reactor gate was suppressed by any unrelated failure

The entire `kybernet.harness=loop` pass sat inside `if [ $fail -eq 0 ]`. Pass 1
has ~25 assertions, so **any** one of them failing silently skipped the only
gate that executes a reactor iteration — standing rule 23's whole subject — with
no line in the output admitting it. That is exactly what happened this session:
the cgroup marker failed and took the wakeup ceiling, both deferred-restart
assertions and the health-tick assertion with it. It is a separate boot with its
own log; it now always runs.

### Fixed — eight boots never checked whether PID 1 panicked

Pass 1 and the reactor gate grep for `Attempted to kill init|Kernel panic`. The
four edge boots and four auth boots grepped only for the verity or password
string they cared about, so a PID-1 panic in any of them was invisible unless it
also happened to suppress that one string. Given that this very release found a
SIGSEGV in argonaut's watchdog that panicked PID 1, that is not hypothetical.
`_assert_no_panic` now runs on every captured boot.

### Fixed — gates that assumed tools the runner does not install

Found by reproducing the runner rather than modelling it — downloading the
actual azure kernel, `busybox-static`, `cryptsetup-bin` and `mawk` from the
noble pool and running the scripts against them.

- **`awk '/^\s*\//'` is gawk-only.** `\s` is not POSIX ERE. Same `ldd` input:
  gawk emits the dynamic-loader line, **Ubuntu's mawk emits nothing, exit 0, no
  warning**. Dormant today only because `busybox-static` is static — it would go
  live the day CI installed plain `busybox`, and the symptom would be an
  initramfs whose `/bin/sh` ENOENTs at exec, i.e. seven of nine services failing
  with no diagnostic.
- **`file` was never installed.** The static/dynamic probe branched on it, so an
  empty pipe meant "static" and the libc staging was skipped silently — the same
  symptom by a different route. Now branches on `ldd`, which is in `libc-bin`,
  always present, and exits non-zero on a static binary. Removes the dependency
  and the gawk regex in one edit.
- **`xxd` was never installed either**, and Ubuntu 24.04 split it out of
  `vim-common`. The ELF gates now use `od` (coreutils) and check `e_machine`
  (`0x003E` x86_64 / `0x00B7` aarch64) rather than magic alone or `file`'s
  prose — so a cross-built binary can no longer pass as native, which the old
  4-byte magic check could not catch.
- **`python3-minimal` would have broken the fixture staging**: `json` and
  `pathlib` are not in the minimal subset. Installs `python3`.
- **A missing busybox was a `WARNING` claiming "harness mode unaffected."** Not
  true since 1.5.0 — all nine services exec busybox applets, and the config
  heredoc sat inside the same guard, so no busybox meant no `/etc/kybernet` and
  an abort 200 lines later blaming the *edge* config. Now fatal, at the point of
  cause; the always-true second guard is gone.
- **`bsdcpio` vs `cpio`** meant the dev box and CI built their images with
  different archivers, so a local image and a CI image were never comparable.
  GNU `cpio` everywhere now.

### Fixed — failures that reported the wrong subsystem

- `veritysetup could not run` was the one edge path ignoring `HARNESS_STRICT`.
  It set `SKIP_EDGE=1`, which routed the *auth* block to "no auth fixture" — so
  a broken library closure inside the VM (the Ubuntu-specific failure the
  staging loop exists to prevent) was reported as a missing credential fixture.
- `veritysetup format`'s stderr was discarded, so "produced no root hash" never
  said why.
- The `mkcred-fixture.cyr` build discarded the compiler's diagnostic on a path
  that hard-aborts the whole initramfs build.
- The `sudo mknod` block silently produced either a four-device image (CI,
  passwordless sudo) or a zero-device one (a dev box where sudo prompts). It now
  states which.
- "correct password did not authenticate" was reported as the 1.5.4-1.5.7 brick
  even when the prompt never appeared — a slow VM outrunning `_auth_boot`'s
  fixed 8 s wait looks identical. Now discriminated on whether `Password:` was
  seen.
- **qemu warns and boots when it cannot provide a CPU feature.** `+invtsc`
  unavailable → sakshi's clock init panics with exit 75 before phase 1, and the
  operator gets a wall of "missing marker" lines with nothing pointing at the
  flag. The warning was in the log; nothing looked at it. Now checked first.

### Fixed — release.yml could publish an incomplete release

`ci.yml` hard-fails without an aarch64 backend; **release.yml — the path that
actually ships — only warned**, and the publish step's `files:` glob tolerates a
missing artifact. A toolchain without the backend would have published a release
advertising two architectures and delivering one. Also: an absent CHANGELOG
section wrote *"No changelog entry for $TAG."* into the body and published it;
now a hard error. Plus `fail_on_unmatched_files: true` and `--retry` on the
toolchain installer fetch.

### Fixed — the benchmark runner silently unpinned itself on CI

`nice -n -5` is a **negative** nice value and needs `CAP_SYS_NICE`. `command -v
nice` succeeds regardless, so the runner was built as `nice -n -5 taskset -c 0
cyrius`, the whole invocation failed `EPERM` on an unprivileged runner, and
`_bench_once`'s `||` fell back to bare `cyrius` — **dropping `taskset` too**. On
exactly the machine that needed CPU pinning most, the benchmarks ran unpinned
and nothing said so. Both wrappers are now probed for real and the applied state
is printed.

The suite-shrink error also now names `bench_drop_caps_nonroot` and
`bench_secure_pre_exec_nonroot` when running as root — both self-skip under
root, dropping the count by exactly 2 and producing a "the benchmark suite
SHRANK" error that sends you hunting for a deleted benchmark.

### Fixed — the benchmark gate could not see a benchmark disappear

1.6.1 closed this hole for `cyrius test` and left it open for
`bench-history.sh`, which the roadmap had noted. The comparison loop only
iterates benchmarks that ARE present, so deleting one — or having it
self-skip, which the two non-root privilege benchmarks do under root — removed
it from the gate silently and still reported "no regressions".

The recorded count is now compared against the previous run's. Growth is fine
and noted; a drop fails. **Verified by deleting one benchmark: exit 1,
`the benchmark suite SHRANK — 56 < 57`.**

### Changed — `cyrius lint` is a hard gate

It has an untracked-deferral detector, and that is precisely the thing that
would have flagged 1.6.0's defects — every one of them was described in a
comment nobody tracked. It was advisory "once the standing dead-code warnings
are addressed"; there were none. The real blocker was 24 over-length lines,
all of them 1.5.9's credential vectors. Those are now assembled from parts, so
each assertion reads as the property it tests (`_rec("1", "8191", "1")` is
"one KiB below the memory floor") instead of a 140-character literal. **Tree is
at 0 untracked deferrals and 0 warnings**, and CI fails on either.

### Added — coverage for three things that had none

- **`kyb-health`**, the fixture that found the panic above. Also the first
  execution of 1.5.4's restart-on-threshold path in any gate.
- **`kyb-orphan`**, which backgrounds a child and exits so PID 1 must reap
  something it did not start — `reap_and_log`'s path, distinct from
  argonaut's `init_reap_services`.
- **`src/lib/console_io.cyr`** — `_read_line_fd` and `_u64_str` extracted from
  main.cyr, which `src/test.cyr` does not include, so **none of main's 25
  functions had ever been unit tested**. `_read_line_fd`'s overflow answer is
  now a contract rather than a comment: an over-long line is `-2`, never a
  truncated prefix. (1.6.0 fixed the behaviour; this makes it testable.)
- **Structured logging** had zero coverage. `slog`/`slog2` run on every klog,
  write into a static 1 KiB buffer and hand-roll JSON escaping — a service
  name containing a quote or a control byte would otherwise produce a line no
  parser can read. Also: a failed `slog_init` left `g_log_fd` at 0 and said
  nothing, disabling structured logging for the life of the boot with the
  explanation in the log that was not being written. It now reports on console
  and dmesg and returns the verdict.
- **Credential benchmarks**, on x86_64. 1.5.9 chose its work cap from one-off
  measurements never re-run; `emerg_cred_parse` (1,513 ns/op) and
  `emerg_verify argon2id` at the m=8192 floor (54.7 ms/op) are under the
  regression gate now.

### Removed

`qemu/boot-crash-test.sh` and `qemu/boot-shutdown-test.sh`. Both were
referenced by nothing, both booted with `-m 256M` — which audit rule 8 says
fails `alloc_init`'s mmap outright, so they would have panicked before testing
anything — and both headers described a kybernet without service management.
The one property they uniquely covered, reaping an unmanaged child, is now
`kyb-orphan` in the real harness.

---

## [1.6.0] — 2026-08-25

**The confinement path did not confine, and one of the four ways it failed was
fatal.** Suite 567 → 608 assertions, 0 failures. Harness 42 → 44 properties.
Binary 1,482,272 → 1,483,024 B (+752). No dep change.

Everything here came out of a deliberate sweep of the tree after 1.5.9, looking
for work that had been deferred without being tracked. What it found instead
was mostly shipped, documented, README-advertised behaviour that did not work.

### Fixed — `"seccomp": "basic"` killed every service it was applied to

`seccomp_basic_service()` allowlisted 37 syscalls. **`execve` was not one of
them** — `BS_EXECVE` existed in neither `#ifdef` arm — and the default action
was `SECCOMP_RET_KILL_PROCESS`. A seccomp filter takes effect the instant it is
installed, so the very next syscall after `seccomp_apply` in `kyb_pre_exec` is
argonaut's `execve` of the service binary. Verified by execution, through
kybernet's own code in `kyb_pre_exec`'s order:

```
set_no_new_privs() -> seccomp_apply(seccomp_basic_service()) -> execve("/bin/true")
  => killed by SIGSYS (31)
```

From 1.4.3 to 1.6.0, the documented config key guaranteed the service died
before running one instruction, on both architectures. Nothing caught it
because `grep -rn seccomp qemu/` returned **nothing** — no fixture had ever set
the key, so `seccomp_apply` had never executed in a release gate.

Two changes, both measured rather than reasoned:

**The exec + dynamic-loader set.** `execve`, `access`/`faccessat`,
`newfstatat`, `pread64`, `prlimit64`, `rt_sigaction`, `rt_sigprocmask`, and the
identity reads — found by escalating an allowlist against a real dynamically
linked binary until it ran, not by reading glibc. Per-arch: aarch64 has no
`access` at all, so that one is `#ifdef`-guarded.

**The default action is now `ERRNO(EPERM)`, not `KILL_PROCESS`.** The argument
is empirical: this module's own list ran a glibc `/bin/true` after four
additions and still could not run a busybox applet after **ninety-seven**. A
hand-maintained allowlist is never complete, so an omission must degrade the
service rather than execute it — in a supervisor that would otherwise restart
it into the same wall, with SIGSYS and no diagnostic. systemd's
`SystemCallFilter` defaults to EPERM for the same reason. Measured after:

```
busybox true          -> exit 0
busybox mkdir /tmp/x  -> "Operation not permitted", exit 1, no directory created
```

Still denying; now diagnosable. `seccomp_build_action` keeps the harder
behaviour available for a future `strict` profile.

The filter grew 42 → 56 BPF instructions (+33 %), which is the one honest cost.

### Fixed — Landlock failed OPEN inside a hook documented as fail-closed

`sandbox_apply` answers `Ok(0)` for "applied" and `Ok(1)` for "this kernel has
no Landlock". `kyb_pre_exec` tested only `is_err_result`, so on a pre-5.13
kernel a service carrying an explicit rule list started with **no filesystem
confinement** while the hook reported success — the outcome
`service_sandbox.cyr`'s own header calls "the one outcome worse than not
running it", and what README calls failing closed.

Now fails closed, exiting the child 126. `"landlock_optional": true` is the
deliberate opt-out for a board on an old kernel. Inheriting a refusal is rule
19's complaint; inheriting a **silent loss of policy** is worse, so the default
goes the other way here.

### Fixed — a required boot stage keyed on the wrong signal (standing rule 18)

`_stage_verify_rootfs` failed on `edge_boot_dmverity_supp() == 0`. Rule 18
forbids exactly that: the probe answers whether the kernel can instantiate a dm
*target*, which `veritysetup verify` does not need. 1.5.7 removed that refusal
from `edge_boot.cyr` and the boot stage kept it — so a board with no dm module
saw phase 6c look at the facts and continue, then phase 7 fail a *required*
step and drop to the emergency shell. Two gates, opposite verdicts, one boot.

Now keyed on `edge_boot_verity_ok()` — the real `veritysetup verify` result,
which had zero callers until now. No root device configured is a SKIP.

### Fixed — an unconfigured 3-second boot budget could power the board off

`edge_apply_defaults` cleared three of `EdgeBootConfig`'s **five** fields, so
`max_boot_ms` kept argonaut's 3000 and `pcr_bindings` kept `"7+14"` on every
path — absent block, partial block, and the malformed-block reset. An operator
who never configured a budget inherited a 3-second one, and `veritysetup
verify` hashes the entire rootfs image against it; with `readonly_rootfs` set,
expiry is a poweroff. Rule 19's exact sentence, one field over from where 1.5.7
fixed it. All five are cleared now; 0 means unbounded.

The edge fixture sets `"max_boot_ms": 20000` — the one value that hid it.

### Fixed — a broken config could silently replace a running one

`load_config` returned `argonaut_config_default()` for both "no file" and "file
present and unparseable", and `reload_config` installed the result. A SIGHUP
with a truncated or mistyped `/etc/kybernet/config.json` therefore replaced a
live board's services, boot mode, edge policy and timeouts with defaults. A
reload that cannot fail is a reload that can destroy.

`load_config` now returns **0** for present-but-unusable and callers separate
the cases: at boot the board still comes up on defaults but says so on the
console *and* in dmesg (on an edge deployment that is the difference between
booting verified and booting ordinary); on reload the running config is kept.

Also closed the silent **16 KiB cliff** — `file_read_all` stops at `maxlen` and
returns `maxlen` with no error, so a config that outgrew the buffer came back
as invalid JSON. One byte of headroom now distinguishes a full read from a
truncated one, with a readable refusal.

### Fixed — `"enabled": false` was counted as a boot failure

argonaut's `init_start_service` returns `-1` for a disabled service — the same
value it returns for a real failure — so a deliberately disabled service was
logged `FAILED to start`. A config that disables every service therefore hit
`failed > 0 && started == 0` and **dropped the board to the emergency shell**,
which is a remarkable answer to "I turned my services off". Skipped now, before
the cgroup is even created.

### Fixed — unsafe service names reached the teardown paths

1.4.2's MEDIUM-3 added `cgroup_name_is_safe` at `create_service_cgroup` and
`move_to_cgroup` and left the rest open, so a name refused at `mkdir` was
accepted at `rmdir` and at `cgroup.kill` — the latter SIGKILLs every pid it
reads out of whatever cgroup it lands on. The predicate now guards
`remove_service_cgroup`, `kill_cgroup` and `cgroup_apply_limits`, and — the
primary fix — a service whose name is not a safe cgroup component is **refused
at config load**, whole.

### Added — the fixture whose absence let this ship for three releases

`kyb-seccomp` reports its own `/proc/self/status` from under
`"seccomp": "basic"`, so the gate asserts both halves from inside the confined
child: that the filter was really loaded (`Seccomp: 2`, `Seccomp_filters: 1`)
and that it no longer kills what it confines. It needs no fork because
`sh -c '<simple command>'` execs directly — process creation is deliberately
**not** on the basic allowlist.

Harness 42 → 44 properties.

### Notes

- Tests 567 → 608. The seccomp additions are asserted individually so a future
  trim has to argue with a test, and the `execve` assertion names what its
  absence did.
- **One benchmark regressed, and it is the expected one.**
  `seccomp_basic_service+build` 1707 -> 2260 ns/op (**+32 %**), which is the
  42 -> 56 BPF instruction growth (+33 %) landing almost exactly where
  arithmetic said it would. It runs once per confined service at startup, so
  +553 ns is not a number anything can notice. Three benchmarks improved and
  two moved inside the noise floor; nothing else changed.

### Fixed — the benchmark gate did not work on a machine doing other things

This nearly went out as "could not be evaluated". The gate compared **raw
absolute ns/op** against the previous run, so at load average 24 three
consecutive runs reported **52, then 21, then 51** regressions — on primitives
this release never touched (`strlen(52 chars)` +144 %, `getpid` +70 %,
`memcpy` +40 %). A gate that only passes on an idle box is not a gate; it is a
request to stop working, and asking for one is the wrong answer.

Two mechanisms, neither of which asks anything of the operator:

- **Best of N runs** (`RUNS`, default 3). Contention only ever *adds* time, so
  the minimum across runs is the closest estimate of true cost and is far more
  robust than a mean. This alone took the same loaded machine from 52
  regressions to 1.
- **Normalisation against a calibration loop.** `_calibration (reference loop)`
  in `src/bench.cyr` is fixed integer arithmetic that touches no kybernet code,
  no allocator and no syscall, so its cost moves *only* with machine
  conditions. `calibration_now / calibration_then` is how much slower this box
  is than the one that recorded history, and every comparison is scaled by it.
  A uniformly slower machine now flags nothing.

The runner also pins to one CPU (`taskset`) and raises priority (`nice`) where
those exist — best-effort, no privilege required to try.

Raw ns/op still goes into `benches/history.csv`: the history stays a record of
what was actually measured, and the scale is recomputed from the stored
calibration row on each run.

**Verified to still fail on a real regression**, which is the property that
matters — a gate that tolerates noise is worthless if it also tolerates
defects. With `bench_getpid` deliberately slowed, the gate reported
`getpid: 292 -> 339 ns/op (expected ~294 on this box, +15%)` and **exited 1**.

---

## [1.5.9] — 2026-08-25

**The emergency credential is salted and memory-hard.** Suite 491 → 567
assertions, 0 failures. Binary 1,448,600 → 1,482,272 B (+33,672, +2.3 %).
sigil 3.12.9 → 3.12.10; no other dep change.

The stored credential was a bare unsalted single-round SHA-256 hex digest,
provisioned with `printf 'pw' | sha256sum`. That is fine against a
shoulder-surfer and weak against anyone holding the config file: no salt means
one rainbow table covers every AGNOS board at once, and one SHA-256 round means
a commodity GPU tries billions of candidates a second. It is now Argon2id.

### Added — the `v1` credential record

```
v1$<t>$<m>$<p>$<salt-hex>$<tag-hex>
```

The format is agnostic's (`agnostic/src/auth/crypto.cyr`), adopted unchanged so
the pack has one credential shape rather than two. Its central property is that
**the parameters are stored, not assumed** — a bare salt+tag verified against
compile-time constants means the day anyone raises `m`, every existing
credential stops verifying silently, and the operator sees "wrong password" on
a password that is right.

PHC (`$argon2id$v=19$m=…$b64salt$b64tag`) was considered and passed over. Its
B64 is the standard alphabet with padding stripped, and the stdlib has no codec
for that shape: `bayan_base64_decode` refuses input whose length is not a
multiple of 4, and `bayan_base64url_decode` tolerates the missing padding but
uses the `-_` alphabet. Adopting PHC meant hand-rolling a base64 codec inside
PID 1 to interoperate with tools this project does not use. Hex costs nothing
new — `hex_decode_into` is already linked and is alloc-free.

New `src/lib/emergency_auth.cyr`. Verification runs at phase 6c, before the
event loop, and every bound in the file exists because of that.

### Added — a provisioning story, which did not exist

`scripts/mkcred.sh`. Nothing in either repo had ever told an operator how to
produce `emergency_password_hash`; the only generator in the tree was one line
inside `qemu/build-initramfs.sh`.

**OpenSSL 3.2+ implements RFC 9106 Argon2id, and its output is byte-for-byte
identical to sigil's.** Verified at m=19456/t=2/p=1, salt `4142…4f50`,
password `hunter2`:

```
sigil    8c194cb37afbddc6888ab9984059bc26f05fdc9f19c3fd3a201f83590f80d428
openssl  8c194cb37afbddc6888ab9984059bc26f05fdc9f19c3fd3a201f83590f80d428
```

So provisioning needs no compiled tool — which matters, because kybernet is
PID 1 and has no command line at all (`main()` takes no arguments and `args` is
not even a pinned dependency). Adding an argv-parsing path to the one process
that must never crash, so it could also be a password utility, was the wrong
trade.

That equality is not taken on faith. `src/test.cyr` carries two records
generated by the exact `openssl kdf` invocation the script uses and asserts
kybernet verifies them, so generator and verifier are checked against each
other on every test run — and the QEMU gate boots a fixture whose credential
came from `mkcred.sh` itself.

The script also refuses a password under 12 characters unless `ALLOW_WEAK=1`.
At these parameters an offline attacker manages on the order of 1e4 guesses a
second: years against a passphrase, about five minutes against anything in a
10-million-entry wordlist. The KDF moves the line from "instant" to "years"
only for a password that is not already on a list.

### Added — parameter bounds, and they are REJECTIONS, not clamps

The roadmap asked for a ceiling as well as a floor. Both ends turned out to
matter, and the reject-don't-clamp part is structural:

**The parameters live inside the credential, not in a policy knob.** kybernet
only verifies; the tool generates. Clamping a stored `m=1048576` down to 65536
computes Argon2 over different inputs and derives a *different tag* — so a
correct password fails, permanently, with no diagnostic saying why. Clamping a
verification parameter converts a config typo into a brick.

| bound | value | why sigil's own limit is not enough |
|---|---|---|
| `m_cost` floor | 8192 KiB | sigil enforces `m ≥ 8·p` = **8 KiB** at p=1. That fits inside one GPU streaming multiprocessor's shared memory (~100 KB on an RTX 4090), so an attacker never touches DRAM and the memory-hardness argument evaporates entirely |
| `m_cost` ceiling | 65536 KiB | RFC 9106 §4's second recommended option, exactly. sigil has **no** ceiling |
| `t_cost` | 1..8 | sigil enforces `t ≥ 1` and nothing above |
| `parallelism` | **must be 1** | sigil fills lanes serially, so p>1 gives this defender no speedup while cutting the sequential depth an attacker must reproduce by a factor of p. Strictly worse in both directions |
| `m_cost × t_cost` | ≤ 131072 | **the cap that actually bounds the PID-1 stall.** The static ceilings alone still admit m=65536 × t=8 — an extrapolated 16-26 s on an RPi4-class core, at phase 6c where nothing reaps and nothing services a watchdog |
| salt / tag | ≥ 16 / ≥ 32 bytes | sigil's floors are RFC §3.1's structural 8 and 4. A 4-byte tag is guessable in 2³² tries |

Two concrete hazards the ceiling closes, both found by reading rather than
guessed:

- **The dangerous band is 64 MiB … 2 GiB.** `alloc()` refuses `size >
  ALLOC_MAX` (2 GiB) and `argon2_hash_into` checks `mem == 0`, so the very top
  degrades cleanly. In between, the anonymous mmap *succeeds* — Linux
  overcommits — and Argon2 then faults in every page, because it touches all of
  them. In PID 1, which is unkillable, that is not a dead process; it is
  `Out of memory and no killable processes` → kernel panic.
- **`argon2_mem_bytes` has no overflow check.** `m = 2^54 + 1024` wraps its
  byte count down to 1 MiB, `alloc()` succeeds, and the fill then runs far
  outside the buffer — a wild write inside PID 1 from one config integer.
  `_emerg_parse_bounded` refuses during digit accumulation, so no such value is
  ever constructed. Checking the bound *after* accumulating would let the
  overflow land on a small positive number that passes the ceiling, which is
  how a ceiling becomes decoration.

### Added — load-time validation, the last config key without it

`emergency_password_hash` was the one key `load_config` accepted verbatim:
`_cfg_str` returns whatever string is present, so a truncated or mistyped
credential was accepted at load and surfaced months later as an unexplained
`AUTHENTICATION FAILED` on the one night the shell was needed. Every other
block — `edge`, `limits`, `security`, `health_check` — already had a
`→ 1|0` parser with a readable failure. This one now does too (audit rule 19).

An unusable credential is **dropped**, not kept, because phase 6c branches on
`g_emerg_hash != 0`: dropped, an edge refusal suppresses the root shell
entirely; kept, kybernet would prompt for a password nothing could match and
then halt. Both are closed; only one is honest.

The parameters are logged at boot — never the salt, never the tag — so a typo
shows up in dmesg long before it matters.

### Fixed — SIGHUP silently swapped the emergency credential

`g_emerg_require_auth` / `g_emerg_hash` are assigned as a side effect of
`load_config()`, which `reload_config()` calls. They were not in its documented
"live-applicable scalars" list and no log line mentioned them, so a reload
changed the password the recovery shell would accept and said nothing.
Re-reading it is the right behaviour — rotating a credential should not need a
reboot — but `reload_config`'s own header argues that a reload which "appears
total and is not" is the thing to avoid. Both changes are now named in the log.

### Migration — the legacy digest keeps working, and the gate proves it

A stored 64-hex SHA-256 still authenticates for this release. The two formats
are **provably disjoint**: legacy is exactly 64 characters all drawn from
`[0-9a-fA-F]`, and a `v1` record begins `v1$` — `v` is not a hex digit and `$`
is not either. No string satisfies both predicates, so a `v1` record cannot be
coerced onto the unsalted path, and a malformed `v1` record is `INVALID`, never
a fallback to `LEGACY`.

The legacy arm **delegates to argonaut's `verify_emergency_auth` verbatim**
rather than reimplementing SHA-256. That is the strongest migration guarantee
available: the deprecated path is not "compatible with" the 1.5.8 code, it *is*
the 1.5.8 code.

`qemu/boot-test.sh` grew a second auth fixture rather than replacing the first.
Pass 4 now runs the four brick-regression properties against **both** formats,
and adds three: the legacy boot must name its format as deprecated, the KDF
boot must report its parameters, and neither the salt nor the stored tag may
appear anywhere in the serial log. 35 → 42 properties.

### Dependency — sigil 3.12.10, and the 352 KB that made this affordable

sigil was also the last repo in the pack front still pinning **cyrius 6.5.21**
while kybernet, argonaut, libro, agnostik and agnostic are all on **6.5.35**.
A dep that builds and tests on a different compiler from the consumer linking
it is a gate that proves nothing, so 3.12.10 takes the toolchain to 6.5.35 and
re-validates there: deps resolve clean, the smoke build links, **all 14 distlib
bundles regenerated on the new toolchain**, and the 65-file suite passes with
1,681 assertions and 0 failures.


Linking sigil 3.12.9's argon2 profile cost **+377,048 bytes**, of which
**+352,256** was a single `var SCR[352256]` inside `argon2_hash_into` — a
function-local array over the compiler's per-fn stack budget, which cyrius
promotes to a shared global. `.bss` is not code, so DCE cannot strip it; the
build says so itself:

```
hint: 352256 bytes inside 3142 unreachable fn(s) — DCE NOPs code but keeps .bss
```

sigil 3.12.10 takes that working lane off the **tail of the caller's arena**
instead, widening `argon2_mem_bytes` by `_ARGON2_SCR_LANE` (5,504 bytes). The
same link now costs **+24,784**. Measured, all three:

| build | bytes | `.bss` |
|---|---|---|
| 1.5.8 baseline, no argon2 | 1,448,600 | 121,632 |
| argon2 linked but unreachable, sigil 3.12.9 | 1,825,648 | 474,104 |
| argon2 linked but unreachable, sigil 3.12.10 | 1,473,384 | 121,840 |
| **1.5.9 shipped** — argon2 reachable and called | **1,482,272** | **122,000** |

`.bss` is the number that matters, and the middle two rows are why: the profile
was merely *linked* in both, called in neither, and 3.12.9 still charged
**+352,472 bytes** of it. DCE NOPs an unreachable function's code and keeps its
static arrays, so that cost was unavoidable for any binary that touched the
module. Shipped, with the KDF genuinely reachable, `.bss` is **+352 bytes** over
the 1.5.8 baseline (+368 as shipped). That is the difference between a
memory-hard KDF being affordable in PID 1 and not.

sigil's own suite is green across all 65 test files (1,681 assertions), RFC 9106
official vectors and the OpenSSL cross-check included.

### Fixed — nine defects an adversarial review found in this release's own work

Four independent review lenses attacked the change with probes and fuzzing
before it was cut. The parser survived (400,000 guard-paged random records and
300,000 structure-aware mutants, zero crashes; the arena sized exactly by
`argon2_mem_bytes` and backed onto a `PROT_NONE` page, clean — with the same
test 8 bytes short confirmed to SIGSEGV, so the clean runs mean something).
These did not:

- **An UPPERCASE legacy digest was blessed at load and could never
  authenticate.** `edge_is_hex64_str` accepts `A-F`, so a digest from Windows
  `certutil`, PowerShell `Get-FileHash` or most online hashers classified
  LEGACY and passed the new validation — while argonaut recomputes with
  `hex_encode_str`, which is **lowercase**, and compares byte-exact. The
  verdict was 0 for every possible password, and a failed emergency
  authentication halts PID 1 forever. The 1.5.4–1.5.7 brick through a
  different door, waved through by the very check added to prevent it. Hex is
  case-insensitive, so the credential is *correct* — it is now normalised
  rather than refused, because denying a correct password over letter case is
  exactly the failure mode this release exists to remove.
- **A password longer than the prompt buffer was silently truncated**, then
  verified as a *different* password, denied, and halted. `_read_line_fd`
  returned the truncated prefix instead of an error. Overflow is now `-2` with
  its own message, the buffer is 512 bytes, and `mkcred.sh` refuses to mint a
  password longer than 256 — a credential nobody can type is the same brick as
  one nobody can parse.
- **The interactive read was never actually bounded.** `_read_line_fd` polls
  with `sleep_ms` because the stdlib has no `poll`, but `console_open_rw`
  opens without `O_NONBLOCK` — and a poll loop over a blocking descriptor is
  not a poll loop. A canonical-mode tty parks the first `read` until a line
  arrives, so the 120 s deadline audit rule 22 requires never fired. Present
  since 1.5.8, with a comment asserting a property the code did not have.
  `console_set_nonblock` now wraps the read and clears the flag before the fd
  becomes the shell's stdin.
- **The null-password guard was on one arm only.** The legacy arm reached
  argonaut unguarded, which does `str_data(password_input)` — `load64(0)`,
  a kernel panic. Latent rather than triggerable, and the asymmetry was
  accidental.
- **`scripts/mkcred.sh` had floors but no ceilings on salt and tag.**
  `TAG_BYTES=128` produced a record the script emitted, self-checked and
  blessed, and which kybernet then classified INVALID and dropped — leaving an
  operator who chose a *longer* tag "for safety" with no emergency shell and
  no diagnostic.
- **`read -rsp` strips leading and trailing whitespace; `_read_line_fd` does
  not.** A passphrase with an edge space would be hashed trimmed and typed
  untrimmed — permanent lockout, and `Confirm:` could not catch it because
  both reads trim identically. `IFS= read` on both. The pre-1.5.9 recipe
  (`printf 'pw' | sha256sum`) had no trim, so the provisioning tool would have
  introduced this.
- **A leading-zero cost field made `--check` abandon validation and generate a
  key instead.** bash's `$(( ))` honours a base prefix, so `$((08192))` is a
  fatal "value too great for base" — and `set -e` does *not* stop the script,
  because the failure is inside a `[ … ] || die` list where neither command
  runs. Execution simply fell through into the generate path: `--check` on a
  record kybernet accepts perfectly printed a brand-new unrelated credential
  and exited **0**. All arithmetic is `10#`-prefixed now.
- **A trailing `$` passed `--check` and failed on the board.** With `IFS=$`,
  `read`'s last variable absorbs the remainder and a single trailing separator
  leaves `extra` *unset*, so the seventh-field test never fired — while
  kybernet's `_emerg_field(h, 6)` returns a non-null zero-length field and
  rejects. Separators are counted before splitting now.
- **The salt/tag leak assertion passed vacuously**, and **stale fixtures could
  be gated as fresh.** If the staged config could not be read the harness
  grepped for nothing and printed OK; and losing `veritysetup` between runs
  dropped only the edge cpio, leaving both auth fixtures behind booting the
  *previous* run's init. An untestable secret-leak check is worse than an
  absent one, because it reads as evidence.

### Notes

- **`argon2id_into`, never `argon2id`.** The convenience wrapper allocates
  through `fl_alloc`, whose large path does `store64(blk, 0)` on the raw
  `_fl_mmap` return — and that return is a small negative errno on failure, not
  0. It faults at `store64(-12, 0)` *before* `argon2id`'s own `if (mem == 0)`
  guard can fire, which makes that guard dead code. `alloc()` checks its mmap
  and returns 0, which is why the arena comes from there.
- **Nothing on the PID-1 path draws entropy.** The salt is generated once,
  offline, by the provisioning tool and travels inside the record.
  `random_bytes` blocks until the kernel pool is seeded, and a blocking call at
  phase 6c is audit rule 22's exact failure mode.
- The digest compare goes through the stdlib's `ct_eq_bytes`. argonaut's
  `verify_emergency_auth` reaches for `constant_time_eq_str`, which is
  **libro's** — an undeclared cross-repo dependency the new path does not
  inherit.
- **argonaut is untouched.** kybernet is its only consumer, and leaving
  `src/security.cyr` byte-for-byte alone keeps all 11 `verify_emergency_auth`
  call sites green *and* keeps argonaut off this release's critical path — two
  repos to tag instead of three.

---

## [1.5.8] — 2026-08-25

**The emergency-auth gate did not work at all, and on an edge board it was a
reboot loop.** Suite 477 → 491 assertions, 0 failures. No dep change.

Both v1.5.8 roadmap items — a salted KDF, and suppressing console echo —
were aimed past a defect that made the entire gate non-functional. Finding
it changed what this release is.

### Fixed — no password could ever be entered

`setup_console` closes fds 0/1/2 and opens `/dev/null` O_RDWR first, so it
lands on **fd 0**. That is deliberate and correct: a supervised service must
never block reading a console, and its own header says "stdin → /dev/null".

The password prompt added at 1.5.4 read fd 0. It got EOF on the first call,
every time, and `_read_console_line` reported that as a read failure — which
`drop_to_emergency` treated as a failed authentication and rebooted on. **No
password could ever be entered, correct or not.**

Reproduced in a real PID-1 QEMU boot before anything was changed. The serial
log shows the prompt and the rejection on one line, with nothing typed:

```
Password: kybernet: emergency shell: AUTHENTICATION FAILED — rebooting
```

1.5.7 made it destructive rather than merely broken. Forcing
`require_auth = 1` on an edge refusal meant a board with a hash configured
would refuse the boot, reboot, refuse, reboot — indefinitely, recoverable
only from the bootloader. Configuring a password made an edge board *less*
recoverable, which is the opposite of the intent.

Interactive reads now open their own descriptor, `console_open_rw()` →
`/dev/console` with `O_RDWR | O_NOCTTY`, and close it again. fd 0 keeps
pointing at `/dev/null` for everything services inherit.

`O_NOCTTY` is not defined by the cyrius stdlib. Its value is `1 << 8` = 256
from `asm-generic/fcntl.h`, and x86's `asm/fcntl.h` just includes
asm-generic, so it is arch-uniform — consistent with the `O_CREAT=64` /
`O_EXCL=128` / `O_TRUNC=512` values this toolchain already carries. Without
it, an `O_RDWR` open of a tty by a **session leader** — which PID 1 is —
silently acquires `/dev/console` as its controlling terminal.

### Added — console echo suppression (the roadmap item, now meaningful)

`src/lib/termios.cyr`, written from scratch: the cyrius stdlib has **no
ioctl, no termios and no poll**. Filed upstream as cyrius issue
`2026-08-24-sys-ioctl-wrapper-missing.md`.

The arch news is good, and verified against the installed kernel headers
rather than recalled: `/usr/include/asm/ioctls.h` and `asm/termbits.h` on
x86 both simply `#include <asm-generic/...>`, so x86_64 and aarch64 share
identical ioctl values *and* an identical struct layout. Only the syscall
number differs, and `SYS_IOCTL` is already in both tables (16 / 29) — so the
enum dispatches, standing rule 1 is satisfied without an `#ifdef`, and
unlike `struct epoll_event` (1.4.2 CRITICAL-2) this needs no per-arch
treatment at all.

`TCSETSF` rather than `TCSETS`, so anything typed between the prompt
appearing and echo going off is flushed rather than prefixed onto the
password. `ECHONL` is cleared alongside `ECHO`. Attributes are restored on
**every** exit — success, wrong password, empty input, timeout — because
echo left off hands the operator a shell that shows nothing they type.

Failure to suppress echo is logged and **does not block authentication**.
Refusing a password because the terminal could not be reconfigured would be
a self-inflicted lockout on the one path an operator reaches when the
machine is already broken.

### Fixed — the read is bounded, and a rejection halts

The old read was a single `sys_read`. Once the fd is a real terminal in
canonical mode that blocks until Enter, **indefinitely** — at phase 6c,
before the event loop, where nothing is reaping and nothing services a
watchdog. A board with no operator in front of it would look dead. The read
now has a 120 s deadline, polled with `sleep_ms` because there is no
`poll`/`select` wrapper either.

A failed authentication now **halts instead of rebooting**. Rebooting
re-enters whatever refused the boot, which re-enters this prompt — that is
the loop. A stopped machine with a diagnostic on kmsg can be recovered from
the bootloader; one power-cycling every few seconds cannot. It also removes
an attacker's ability to force an endless reboot cycle by typing anything.

### Fixed — the emergency shell was unusable even after a successful login

Two independent defects, both on the far side of the auth gate, so neither
had ever been reachable to observe:

- The forked shell inherited `stdin` = `/dev/null`, read EOF at its first
  prompt and exited immediately. It now gets the console on 0/1/2.
- It was exec'd with **`envp = 0`** — a completely empty environment.
  argonaut's `emergency_shell_default()` builds HOME, TERM, PATH and SHELL,
  and every one was discarded, so the recovery shell had no PATH (no command
  resolves by name) and no TERM (no line editing). `_emerg_envp` now
  flattens that map, plus `PS1=kybernet-emergency# `.

### Harness — a regression test for a brick

A third fixture (`initramfs-auth.cpio.gz`) with a password configured, and a
gate that **feeds the password over the serial line**: `-serial stdio` (not
`mon:stdio`, which multiplexes the monitor onto the same stream) takes it
from a pipe after the prompt appears. Four assertions:

- the correct password authenticates — this alone fails on every tree from
  1.5.4 to 1.5.7
- the password does **not** appear in the serial log (echo suppression)
- a wrong password is rejected
- a rejection does **not** reboot

Skips cleanly when the edge fixture is absent, since it is built from it.

### Deferred — the salted KDF, with reasons

Moved to v1.5.9 rather than dropped. The investigation turned up three
things that must be resolved first, one of them a fault:

- **`argon2id()` cannot be called from PID 1 as sigil ships it.** It
  allocates through `fl_alloc`, whose large path stores to the raw `mmap`
  return without checking it — so on exhaustion it faults instead of
  returning the error its own `if (mem == 0)` guard is written to expect.
  Reproduced: exit 139. `argon2id_into(mem, ...)` over an `alloc()` arena
  avoids it, since `alloc()` returns 0 cleanly.
- **sigil's argon2 profile costs +377 KB, 352 KB of it `.bss`** that DCE
  cannot strip — one `var SCR[352256]`. Fixable in sigil by taking the
  scratch lane off the tail of the caller-supplied arena; **not** by caching
  it in a global, which is audit rule 8 (a bump-arena pointer in a static)
  and was tried and rejected during this work.
- **There is no provisioning story.** Nothing in either repo tells an
  operator how to produce `emergency_password_hash`. Today it happens to be
  `printf 'pw' | sha256sum`; a salted KDF ends that, so a generator has to
  ship alongside the format.

PBKDF2 was evaluated and rejected: sigil's SHA-256 acceleration is
`#ifdef CYRIUS_ARCH_X86` only, so every ARM edge board runs the software
path — around 164x slower than OpenSSL, which buys roughly 6-9k iterations
in a one-second budget against an attacker doing millions. Argon2's BLAKE2b
has no comparable gap.

### Benchmarks

54 benchmarks, no regressions. Nothing added is on a hot path — the
emergency gate runs at most once, and only on a boot that already failed.

---

## [1.5.7] — 2026-08-25

**Edge boot actually verifies, and stops being a poweroff trap.** Suite
440 → 477 assertions, 0 failures. Requires **argonaut 1.13.2**.

The roadmap said this was blocked on argonaut extending `EdgeBootConfig`
with device paths. It never was — `execute_edge_boot(config, root_device,
hash_device, root_hash, luks_device)` has always taken them as
**parameters**. Meanwhile the gap the roadmap did *not* name was a live
foot-gun, and it is the most important thing in this release.

### Fixed — `"boot_mode": "edge"` was an un-overridable poweroff trap

kybernet parsed **no edge config at all**. `config_edge()` therefore always
returned argonaut's `edge_config_default()`:

```
readonly_rootfs = 1   luks_enabled = 1   tpm_attestation = 1
```

with `verify_boot` defaulting to 1 as well. So writing `"boot_mode":
"edge"` was an unconditional demand for a TPM *and* dm-verity that no
config file could soften — and the refusal path at phase 6c drops to the
emergency shell and then **powers the machine off**. On a headless
TPM-less board that is a poweroff loop.

An `edge` block is now parsed, and **an absent block means detection-only.**
Refusing to boot is a policy an operator opts into, never one they inherit
from a struct default they never saw.

Everything is validated at **load** time — device paths (`/dev/` prefix,
traversal-free, conservative charset), 64-hex root hashes, PCR indices
0-23 — with a loud `klog` + `kmsg` and a fallback to detection-only. A typo
is a config error the operator can read, never a mid-boot poweroff.

### Added — dm-verity integrity verification that actually runs

`veritysetup verify <data> <hash> <root_hash>` walks the hash tree in
**pure userspace**: no device-mapper, no kernel module, no `/dev/mapper`
node. That is why kybernet verifies with `verify` rather than `open`, and
it is what makes this testable in an initramfs where dm is a module nothing
can load.

This is the honest half of the 1.2.0 deferral — "the rootfs image matches
the root hash the operator pinned". Mounting it *through* dm-verity so that
later corruption is caught at read time is the other half, and needs a
device-mapper stack this init cannot assume. That is now filed against
hardware (roadmap v1.5.10), not against a version number.

The dm-verity capability probe no longer causes a refusal. It answers "can
the kernel instantiate a dm target", which `verify` does not need — keying
`readonly_rootfs` to it failed boards that verify perfectly well. The
refusal now keys on the verification **result**.

### Added — PCR baseline comparison, deliberately REPORT-ONLY

`expected_pcrs` is compared against the live reading and reported. It does
**not** refuse, and that is a decision rather than an unfinished edge:

- PCR 7/14 legitimately change on any firmware or kernel update, so
  enforcement turns a routine signed upgrade into a fleet-wide refusal.
- The oracle is `/usr/bin/tpm2_pcrread` — a file living on the very rootfs
  under verification, read through sigil's `exec_capture`, which discards
  the child's wait status and **zero-fills** anything it cannot parse. A
  control that is defeated by replacing a file must not be able to
  permanently brick a board.

That zero-fill is also why an all-zero digest is rejected as a configured
baseline and treated as **UNREADABLE, never MATCH** when read back — an
all-zero baseline would otherwise match a PCR that was never read, i.e.
attestation that can never fail.

### Fixed — an edge refusal opened an unauthenticated root shell

`g_emerg_require_auth` defaults to 0, so a pulled TPM, a missing
`veritysetup` or a corrupted rootfs handed a **console root shell** to
whoever caused it — on a device whose entire purpose is verified boot.
An edge refusal now requires authentication when a password hash is
configured, and when none is configured it does not open a shell at all
(`verify_emergency_auth` fails closed, so offering one would loop the
operator through a password nobody has).

### Added — escape hatches, and the reason `off` is narrow

`kybernet.edge=permissive` runs every check and refuses for none.
`kybernet.edge=off` skips the layer — but **only on a board with no
`root_hash` pinned**; where one is configured it downgrades to permissive.
`/proc/cmdline` is exactly as trustworthy as the bootloader, which is the
surface verified boot exists to protect, so a silent total bypass is the
wrong thing to ship. The board still boots; the verification still runs and
still reaches dmesg.

An operator locked out by a hardware change cannot edit a config file on a
rootfs that is itself what failed to verify, which is why the hatch is on
the cmdline at all — and why the harness exercises both. An escape hatch
that has never been executed is not an escape hatch.

### Fixed — two upstream defects found on the way (argonaut 1.13.2)

- argonaut built every SafeCommand with a **bare binary name**, and
  `execve(2)` does not search `$PATH`. Every `mount` / `veritysetup` /
  `cryptsetup` exec died 127; its whole edge-boot execution path could
  never have succeeded. Unnoticed because no consumer imported the module —
  and found *before* kybernet wired it up, which would have refused boot on
  every edge device.
- `exec_vec_str` waits **unbounded** (uninterruptible under PID 1's blocked
  mask) and **fails OPEN**: it discards `waitpid`'s return and reads a
  `var stbuf[4]` that is **static storage in cyrius, not stack** (verified
  on 6.5.35). A wait that does not land decodes status 0 as exit 0 —
  success. On `veritysetup verify` that is a verification which never ran,
  reported as verified.

kybernet's own `_eb_dmverity_supported` had both problems plus a hardcoded
`/usr/sbin/veritysetup` (wrong on split-usr systems); it now goes through
`run_safe_cmd_timeout` too.

### Changed

`_cmdline_has` moved from `main.cyr` to a new `src/lib/cmdline.cyr`.
`edge_boot.cyr` needs it for the escape hatches, and a `src/lib` module
reaching into `main.cyr` links in the real binary while breaking
`cyrius test src/test.cyr`, which includes only `src/lib`.

### Harness — a real cryptographic round trip

A second initramfs (`initramfs-edge.cpio.gz`) with a real 4 MiB
`veritysetup format` image pair attached as virtio disks — `CONFIG_VIRTIO_BLK`
is builtin, so `/dev/vda` and `/dev/vdb` appear with no modules, no udev
and no losetup. Six assertions: an intact image verifies, a corrupted image
fails and **refuses the boot**, and both escape hatches behave. It SKIPS
cleanly when `veritysetup` is absent on the build host — a missing tool must
never read as a pass. Every gate from 1.5.0-1.5.6 is byte-for-byte
unchanged.


**What it does not cover, stated so the green is not misread:**
`veritysetup open`, the read-only mount, LUKS unlock, and PCR enforcement.
Measured, not assumed — the harness kernel has `CONFIG_BLK_DEV_DM=m`, no
`CONFIG_DM_INIT`, and the initramfs busybox has no `insmod`; in-VM
`veritysetup open` returns "Cannot initialize device-mapper". Putting a
module loader inside PID 1 to make a test pass is scaffolding in the one
process that must never crash.

### `cyrius.lock` carries all five commit pins

The first cut of this release had four. The local gates ran under a
temporary `path = "../argonaut"` override because the 1.13.2 tag did not
exist yet, and a `path` override makes cyrius drop that dep's `commit` line
from the lock — while `cyrius deps --verify` still reports "N verified,
0 failed", because it cannot miss what is not there. Same trap as 1.5.4 and
1.5.5. Regenerated against the real remote tag: **70 deps, 5 commit-pinned**,
and the sibling-free reproduction now passes with a byte-identical binary.

### The edge harness fixture builds on CI

The first cut of the edge gate was written and verified on a dev box with
KVM, no passwordless sudo and no multiarch layout. Three things it could not
surface, all of which broke the Ubuntu runner:

- The edge staging tree is copied with `tar --exclude=./dev` rather than
  `cp -a`. Recreating a character device needs CAP_MKNOD, so `cp -a` of the
  `sudo mknod`-created nodes failed EPERM for the unprivileged runner and,
  under `set -e`, killed the whole build. The nodes are re-made in the edge
  tree with the same best-effort `|| true` pattern the main tree uses.
- Shared libraries are staged at their **original absolute paths**, not
  flattened into `/usr/lib`. There is no `ld.so.cache` in an initramfs, so
  the loader falls back to compiled-in defaults — which on a multiarch
  distro are `/lib/x86_64-linux-gnu` and `/usr/lib/x86_64-linux-gnu`, not
  `/usr/lib`. Flattening worked on Arch and would have produced a silently
  unrunnable `veritysetup` on the Ubuntu runner.
- The fixture image is 1 MiB rather than 4: CI has no bare-metal KVM, and a
  smaller Merkle tree keeps the four extra boots cheap while still being a
  real round trip.

A staged `veritysetup` that cannot start is now detected and **skipped**
rather than failed — kybernet reports "tool unrunnable" as an outcome
distinct from a verification verdict precisely so the gate can tell an
environment problem from a defect. Both paths are exercised: breaking the
library closure deliberately produces a SKIP, not a FAIL, and not a pass.

### Benchmarks

54 benchmarks. Nothing added is on a hot path — the edge layer runs once,
at phase 6c.

The gate flagged `strlen(52 chars)` 27 → 40 ns/op (+48%) on the first run
and passed on the second (40 → 39). This is the **same binary-layout
oscillation diagnosed and bisected at 1.5.5**, not new work: nothing here
touches `strlen` or anything it calls, and the series across releases reads

```
26, 27, 38, 38, 27, 27, 40, 39
```

— two stable attractors ~27 ns and ~39 ns that the tree lands on depending
on where the linker puts the loop. At 1.5.5 this was bisected to a code-SIZE
threshold rather than any single change: reverting either of two unrelated
files moved it back. Absolute cost is 13 ns on a function PID 1 calls a few
hundred times per boot, from logging.

---

## [1.5.6] — 2026-08-25

**aarch64 service spawning was broken in a dependency, and the lock was
missing two commit pins.** No kybernet source change. Requires **argonaut
1.13.1**. 440 assertions, 0 failures.

### Fixed — argonaut's hardcoded x86_64 syscall numbers (upstream)

Found while wiring 1.5.5's pre-exec cgroup placement. argonaut called
`syscall(N, ...)` with literal **x86_64** numbers in paths kybernet uses on
every service spawn and every shutdown — and kybernet builds and ships an
aarch64 binary.

```
syscall(112)  # setsid      x86_64 112, aarch64 157   -> not setsid on ARM
syscall(35)   # nanosleep   x86_64  35, aarch64  35 = unlinkat
syscall(0)    # read        syscall(41) # socket      syscall(87) # unlink
```

So on aarch64 no service argonaut forked ever got its own session, and the
service STOP/poll paths called `unlinkat` where they meant to sleep. This is
exactly the class standing rule 1 exists to prevent, sitting in a dep rather
than in kybernet — the cross-build succeeds either way, which is the whole
problem.

argonaut 1.13.1 fixes it with `src/syscall_compat.cyr`: `#ifdef
CYRIUS_ARCH_*` gated `ag_sys_*` wrappers, plus a switch to the dispatching
stdlib `sys_setsid()`. Pairs verified against the kernel tables before
consuming — clock_gettime 228/113, getsid 124/156, sendto 44/206,
getsockopt 55/209, poll 7 / ppoll 73 (aarch64 has no `poll`).

### Changed — the argonaut import list is 13 modules, and the new one is mandatory

kybernet imports argonaut selectively, so a new module is not picked up
automatically. `types.cyr`, `health.cyr` and `notify.cyr` — all three
imported here — now call `ag_sys_*`, so `src/syscall_compat.cyr` is required
and is listed **first**, mirroring argonaut's own include chain. Omitting it
produces `undefined function 'ag_sys_clock_gettime'`, which links and then
**SIGILLs at runtime** (standing rule 7).

### Fixed — `cyrius.lock` was missing the argonaut and agnostik commit pins

Both the 1.5.4 and 1.5.5 cuts shipped a lock with no `commit` line for the
deps whose local gates had run under a temporary `path = "../<dep>"`
override. `path` makes cyrius skip commit-pin verification, and the lock is
written from disk — so the line is simply absent, and
`cyrius deps --verify` still reports "N verified, 0 failed" because it
cannot miss what is not there.

This cut resolves from the real remote tags with no override:
**70 deps locked, 5 commit-pinned** (sigil, agnostik, libro, argonaut,
patra), 70 verified / 0 failed. Recorded as a manifest rule in CLAUDE.md so
the next dep change follows dep-tag → regenerate lock → verify pins →
consumer-tag.

### Benchmarks

No regressions; five improvements, largest `restart_queue_pop_due_empty`
4 → 3 ns/op. Harness green — 767 ms of a 3000 ms budget, reactor wakeups
24 of a 500 ceiling.

---

## [1.5.5] — 2026-08-25

**Per-service cgroup limits are configured, applied, and proven.** Suite
409 → 440 assertions, 0 failures. Requires **argonaut 1.13.0** and
**agnostik 1.5.1**.

`cgroup_apply_limits`, `cgroup_apply_resource_limits` and
`cgroup_setup_agent` had sat with no production call site since the port.
Wiring them up turned out to need two things the roadmap item did not know
about, either of which alone would have made the feature silently do
nothing.

### Fixed — the limit files did not exist

A cgroup v2 controller's interface files appear in a cgroup **only if its
parent lists that controller in `cgroup.subtree_control`.** Nothing in
kybernet ever wrote it. Verified in the QEMU PID-1 boot before any code was
written:

```
cgroup.controllers     = cpuset cpu io memory hugetlb pids rdma misc dmem
cgroup.subtree_control =                      <- empty, at root AND on the slice
kybernet.slice/kyb-live/memory.max -> No such file or directory
```

Every controller was available; nothing enabled them downward. So a freshly
`mkdir`'d service cgroup held only the core `cgroup.*` files, and every
write `cgroup_apply_limits` would have done returned ENOENT. That is why it
could sit unwired for four releases without anything failing.

`cgroup_enable_controllers()` runs at phase 3a — after the cgroup2 mount,
before any service — and enables memory/pids/cpu at **both** levels: root,
so `kybernet.slice` gets the files, and the slice, so each service does.
Controllers are enabled **one per write**: the kernel parses the buffer
atomically and rejects the whole thing on an unrecognised name, so
`+memory +pids` against a kernel without `pids` would lose `memory` too.
Non-fatal throughout — a kernel with no memory controller should run
services uncapped, not refuse to boot.

This also explains why the 1.5.3 teardown gate never noticed: `cgroup.kill`
is a **core** file, present regardless of subtree_control, so
"removed service cgroups: N" proved directories were created and removed
and nothing about controllers.

### Fixed — `ResourceLimits` is a silent struct collision

The roadmap said to call `cgroup_apply_resource_limits` with
`svc_def_rlimits`. **Doing that literally would have OOM-killed services.**

argonaut defines `struct ResourceLimits { nofile, address_space, nproc,
core }` (32 B). agnostik independently defines a *different* struct with the
*same name* — `{ max_memory, max_cpu_time, max_fds, max_procs, max_disk,
net_bw }` (48 B) — and ships the only `rlim_*` accessors. kybernet links
both. cyrius warns about duplicate fns and duplicate symbols; **duplicate
structs are silent.** A probe on 6.5.35 gives `sizeof(ResourceLimits) == 48`
— agnostik's wins — while `svc_def_rlimits` returns a pointer argonaut
filled to its own layout:

```
rlim_max_memory(r) = load64(r + 0)  -> argonaut's nofile
rlim_max_procs(r)  = load64(r + 24) -> argonaut's core (-1 when unset)
```

A service configured for 1024 open files would have had `memory.max` set to
**1024 bytes** and been OOM-killed on its first page fault.

Limits therefore use agnostik's `cgroup_limits`, which has no twin and whose
five fields are all real cgroup v2 control files, stored on argonaut
1.13.0's separate `cgroup_limits` field (+168). Recorded as standing rule 14
in CLAUDE.md.

### Fixed — the process was placed in its cgroup too late, or never

Placement moved into the child, as step 0 of `kyb_pre_exec`. The parent
cannot do it without a race: argonaut owns fork+exec, so kybernet only
learns the pid after `init_start_service` returns — and for a `simple`
service with a ready_check, that is after the entire readiness poll.

Worse than late. cgroup v2 charges memory on **first touch and does not
migrate charges on move**, so every page the service faulted in before the
move stayed charged to the root cgroup for the life of that memory. And a
**oneshot was never placed at all** — argonaut waits for it inside
`init_start_service` and returns 0, so there was no surviving pid to move.

The child writes the literal `"0"` to `cgroup.procs` — the kernel's "move
the writer" form, so no getpid and no integer formatting. It runs **before**
no_new_privs, capabilities, Landlock and seccomp, because every one of those
can take away the ability to write cgroupfs. The parent creates the cgroup
and writes its limits before calling `init_start_service`.

Placement fails closed only when limits were actually configured: a service
that asked to be capped and would instead run uncapped is a policy
violation. A service with no limits gets best-effort placement — losing its
cgroup costs accounting and the shutdown sweep, not containment.

### Fixed — `cgroup_apply_limits` was fail-fast across independent controllers

It returned on the first error, and the write order is
memory.max → memory.high → cpu.weight → pids.max. On a kernel without the
cpu controller, a service configured for both `cpu_weight` and `pids_max`
got **neither** — cpu.weight returned ENOENT and pids.max was never
attempted. These are independent controllers. Every configured limit is now
attempted and the last failure is returned, so the caller still learns
something did not apply.

### Added — the `limits` config block

```json
{ "name": "svc", "binary": "/bin/svc",
  "limits": { "memory_max": 67108864, "memory_high": 50331648,
              "cpu_weight": 250, "pids_max": 32 } }
```

Same contract as the 1.5.2 `security` block: absent is fine, present but
malformed **rejects the service**. Validated at parse time rather than
discovered at write time — a negative would be formatted as `"-1"` and
rejected by the kernel with EINVAL, silently leaving the service unlimited;
`cpu_weight` outside 1..10000 is EINVAL; `memory_high` above `memory_max`
can never take effect. Plain integers only — no `"64M"` suffixes. `cpu_max`
is deliberately not exposed: the file also takes the literal `max`, and
"quota with an implicit period" is a confusing thing to hand an operator.

### Harness

`kyb-limited` reads its own cgroup back from **inside the service** and the
gate asserts what the kernel accepted, not what kybernet logged:

```
LIMIT-cgroup=/kybernet.slice/kyb-limited     <- a ONESHOT, placed before exec
LIMIT-memmax=67108864   LIMIT-memhigh=50331648
LIMIT-cpuweight=250     LIMIT-pidsmax=32
LIMIT-ctrl=memory pids
LIMIT-unlimited=max                          <- kyb-live, no limits block
```

The oneshot line is the placement proof — it is impossible under the old
post-start create→move. The unlimited control separates "kybernet wrote the
value" from "the file already contained it". cpu.weight and memory.high
together are the regression test for the fail-fast bug: pids.max asserting
alongside cpu.weight means all four writes were attempted.

Every service now gets a cgroup rather than only the long-lived ones, so the
teardown marker moves 2 → 6.

### Benchmarks

54 benchmarks; none added — nothing in this release is on a hot path.
**No regressions** against 1.5.4. The only ≥15% movement in the whole suite
is `cgroup_file (best case, same pair)` 3 → 4 ns/op, one nanosecond.

Worth recording, because the gate did flag something mid-development and the
diagnosis is reusable: an intermediate tree measured
`strlen(52 chars)` at **38 ns/op against a 27 ns baseline (+41%)**, and it
reproduced — clean re-run on an idle machine gave 38 again, and stashing the
1.5.5 source gave back 27. Nothing here touches `strlen` or anything it
calls. Bisecting by file, reverting *either* `cgroup.cyr` *or*
`svc_config.cyr` restored 26–27: a code-size threshold, not a culprit. The
final tree, which adds three further hardening changes, measures 27 again.

The series reads `26, 26, 27, 38, 38, 27`. Sub-30 ns microbenchmarks in this
suite are sensitive to binary layout at the 10 ns scale, and movement is
bidirectional — the same intermediate tree showed `cgroup_file` 5 → 3
(−40%) and `restart_queue_pop_due_empty` 6 → 2 (−67%) alongside the strlen
rise. Treat a single flagged sub-30 ns bench as layout until bisection says
otherwise.

---

## [1.5.4] — 2026-08-25

**The Rust port is complete; `rust-old/` is deleted.** Suite 309 → 409
assertions, 0 failures. Requires **argonaut 1.12.0**.

The 1.5.3 review of `rust-old/` asked whether the port was finished and
found it was not: eight behaviours present in the Rust implementation had
been dropped. Two were security fixes taken on the spot at 1.5.3; the other
six are here, plus the one that review recorded as blocked. With the list
closed, the reference tree is removed — it stays in git history.

### Fixed — deferred restart, the highest-value gap

`src/lib/restart_queue.cyr`. The Rust implementation kept a PendingRestart
queue and a dedicated `TOKEN_RESTART` timerfd: SIGCHLD only *enqueued*, and
the reactor relaunched once the exponential backoff elapsed. kybernet
restarted **synchronously inside `handle_sigchld`**, so a crash-looping
service was relaunched as fast as it could die until `max_restarts` tripped.

The backoff was not merely ignored — it was passed to the wrong parameter:
`init_restart_service(g_init, name, delay)` against
`fn init_restart_service(init, name, stop_timeout_ms)`. Inert rather than
harmful (that parameter is only read while the service is RUNNING/STARTING,
and the SIGCHLD path has already set STOPPED/FAILED), but the delay went
nowhere. Nothing in argonaut read `CrashAction.delay_ms` at all — producers
and struct declarations, zero readers. `TOKEN_RESTART = 4` had sat in
`eventloop.cyr`'s enum since the port with no timer creating it and no
`case 4` in the reactor.

Storage is **static**, not a vec. PID 1 never resets the bump arena, so a
per-crash allocation grows for the life of the system. Dedup is by name
*content*, not pointer, and matters more than it did in Rust: the health
path re-evaluates every tick, so an unconditional push would exhaust the
queue within a minute. `restart_queue_pop_due` scans the **whole** queue —
entries carry different delays (crash backoff, flat 1 s health, 2 s
watchdog), so it is not sorted by `restart_at`, and stopping at the head
would let one long-backoff entry block every shorter one behind it.

Verified in the QEMU harness, not just unit tests. `kyb-crash`
(`/bin/false`) now restarts at ≈2.0 s and then ≈3.0 s — the backoff being
waited on and growing. `qemu/boot-test.sh` gates both markers under
`kybernet.harness=loop`; the boot-only pass shuts down before the reactor
starts, so this is invisible there.

### Fixed — health checks and the watchdog now act

- **Health-check failures were logged forever and never acted on**, which
  defeats the point of configuring a health check. `init_poll_health`
  discards argonaut's threshold verdict, so `handle_health_tick`
  reconstructs it from `health_tracker_count` against `svc_hc_retries` and
  schedules a flat 1 s restart — the Rust delay. Not a crash backoff; it is
  "stop waiting and cycle it".
- **A watchdog kill was a one-way door** — the service was killed and
  stayed dead for the life of the system, which is worse than having no
  watchdog. A 2 s restart is queued for every service
  `init_enforce_watchdog` returns.

### Fixed — `$NOTIFY_SOCKET` was never exported

kybernet bound the notify socket, registered it with epoll and had a
handler ready — but a service discovers that socket through
`$NOTIFY_SOCKET`, and nothing ever set it. The **entire readiness and
watchdog-ping path was unreachable from the service side of the fork.**

This needed a new seam upstream: argonaut assembles the child envp inside
`fork_exec_service`, between fork and exec, where a consumer has none.
argonaut 1.12.0 adds `argonaut_set_extra_env()`; kybernet registers
`NOTIFY_SOCKET=…` immediately after the bind succeeds, mirroring the Rust
implementation's `env::set_var` at the same point.

### Fixed — emergency-shell authentication (`require_auth`)

The 1.5.3 review recorded this as blocked, needing "a password-verify
primitive that does not exist on the Cyrius side." **That was wrong.**
argonaut has shipped `verify_emergency_auth` in `src/security.cyr` for
several releases, and 1.8.6 made it fail closed. kybernet had simply never
imported the module — it is now the 12th argonaut module in the manifest
(no symbol collisions; 10 functions).

`emergency_require_auth` and `emergency_password_hash` are read from
`config.json` and overlaid onto `emergency_shell_default()`, which
hard-codes both off — so without the overlay the gate could never engage
regardless of what an operator configured. A failed password reboots; if
`sys_reboot` returns (CAP_SYS_BOOT dropped, say) the path **hangs rather
than falling through to the shell**. The plaintext buffer is wiped on both
verdicts, since the arena is never reset in a process that can be dumped.

⚠ **Two known weaknesses, stated rather than hidden.** `password_hash` is
an unsalted single-pass SHA-256, so the digest is trivially brute-forced
offline by anyone who can read `config.json`; and PID 1 has no termios
layer here, so the typed password **echoes to the console**. Both are
acceptable against the threat this addresses — a drive-by operator at a
physical console — and both are tracked for v1.5.8.

### Fixed — two smaller port gaps

- **`should_drop_to_emergency` was never consulted in the service wave
  loop**, so a boot where every service failed to start still proceeded to
  the event loop. `start_services` now counts started/failed and checks it.
- **`kill_cgroup`'s per-PID SIGKILL fallback was unreachable** when
  `cgroup.kill` was openable but not writable — Rust checked the write
  result, the port checked only the open.
- `SHUTDOWN_HALT` → `RB_HALT_SYSTEM` is mapped (latent: no caller produces
  HALT today).

### Removed

`rust-old/` — 44 files, 7.9 MB. Deliberately **not** salvaged from it,
recorded here so the decision is not re-litigated: the Rust build and
supply-chain scaffolding (Cargo, Makefile, `deny.toml` — which still
allow-listed agnosys, dropped at 1.3.5 — and codecov.yml); the six rust-old
qemu scripts (none assert anything, and three cargo-build sibling Rust
repos by absolute path; the current harness is far ahead); the fd-0 sanity
assertion in console (invariant by the `open(2)` contract given the three
closes above it); and `KYBERNET_LOG` env-var log levels (PID 1 has no
inherited environment).

### Benchmarks

No regression. 51 → **54 benchmarks**; the restart queue adds three, and
they confirm the static-storage design: `restart_queue_push` **9 ns/op**,
`restart_queue_pop_due` on an empty queue **3 ns/op** — the reactor's
steady state, since the restart tick fires every second on a healthy system
— and `restart_queue_has` against 8 entries **158 ns/op**, the linear
content-compare scan that push dedups through.

---

## [1.5.3] — 2026-08-25

**Lifecycle cleanup and observability.** Suite 296 → 309 assertions, 0
failures; both arches; harness green with two new gates. No dep changes.

Five items from the 2026-08-24 audit that each had a real operational
consequence and no owner. One of the five turned out to be misdiagnosed —
see below.

### Fixed — service cgroups were never removed

`create_service_cgroup` and `move_to_cgroup` were the **only** cgroup calls
with a production call site. `kill_cgroup` and `remove_service_cgroup`
existed and were tested, but nothing outside tests and benches ever called
them, so cgroup directories accumulated for the life of the system and a
`CRASH_GIVE_UP` left a **populated** one behind — the main process had
exited, but anything it forked was still in there and still counted against
the slice.

Now torn down in both places it matters:
- **`CRASH_GIVE_UP`** — the service will not be restarted, so its cgroup is
  killed and removed.
- **Shutdown** — a new `remove_all_service_cgroups()` sweeps argonaut's
  registry after `init_stop_all`. `kill_cgroup` first: "stopped" means the
  tracked PID exited, not that the cgroup is empty, and `rmdir` on a
  non-empty cgroup fails `EBUSY`. Best-effort throughout — a failed `rmdir`
  must not stop the shutdown path reaching `sys_reboot`.

### Fixed — `reload_config` claimed more than it did

SIGHUP did `store64(g_init, new_cfg)` under a comment reading "Re-initialize
argonaut with new config". That overwrites field 0 of `ArgonautInit` and
nothing else — but `argonaut_init_new` **derives** two further fields from
the config at construction: the boot sequence and the service map. Neither
was rebuilt, so a reload left new config values sitting on top of derived
state built from the old config, with no way for an operator to tell.

Rebuilding them is not the fix: the service map holds live runtime state —
PIDs, states, restart counts — for processes that are still running.
Replacing it would orphan every one of them: still executing, no longer
tracked, never reaped. In PID 1 that is far worse than a stale timeout.

So the reload now applies the values that are safe to change while the
system is up (boot/shutdown timeouts, console logging) and **says plainly**
that boot-mode and service-definition changes need a reboot, rather than
appearing total and not being.

### Fixed — edge-boot refusals never reached `dmesg`

Both refusal reasons used `klog`, which reaches stderr and slog. On a
headless board with no console and no writable `/var`, neither survives.
The only `kmsg` line on that path was main.cyr's generic `phase 6c: FATAL
edge-boot prerequisite missing` — the operator learned a refusal happened
but never why.

All four refusal paths now also write to `/dev/kmsg` with the specific
reason (`edge-boot REFUSED: tpm_attestation required, no TPM present`, and
so on), which is what `dmesg` still has after the fact.

### Fixed — the edge-boot budget could not bound anything

`max_boot_ms` was measured **once, after every step it was meant to bound**
— a post-mortem, and warn-only. By the time it noticed, both unbounded
operations had already run: `_eb_dmverity_supported`'s `veritysetup` exec
and `tpm_read_pcr`'s `tpm2_pcrread` exec, each a blocking wait on an
external program with no timeout of its own.

It still cannot interrupt a call already blocked — that needs a timeout
inside sigil's exec path, which is not kybernet's to add. What it can do is
**refuse to start the next expensive step** once the budget is spent, so
`_eb_over_budget` is now checked before each exec-backed step. The terminal
check also stops being advisory: on a device that set a boot budget *and*
requires attestation, a verified boot that ran far past its allowance is a
signal, so that combination now refuses rather than warning.

### Corrected — the "cgroup cache has no production hits" finding was wrong

The audit recorded that `kill_cgroup`, `_cgroup_write_u64` and
`remove_service_cgroup` "bypass" the path cache. They do not: all three go
through `cgroup_file` / `cgroup_path`, which *are* the cached accessors.
The real problem was the one above — those functions had no production call
site at all, so the cache had nothing to serve them. Wiring the teardown in
gives them one; no cache change was needed or made.

### Changed — the harness exercises the cgroup lifecycle

The staged config gains `kyb-live` (`/bin/sleep 30`), the only service in it
that stays **running** — so it is the only one that gets a cgroup at all,
which is correct: a completed oneshot has no surviving process to place. The
harness now asserts `started: kyb-live` and `removed service cgroups: 1`,
covering create → move → kill → rmdir end-to-end in a real PID-1 boot.

That path was previously untested end-to-end: every service in the harness
was a oneshot, so no cgroup was ever created and the new sweep would have
had nothing to remove.

### Tests

- `test_cgroup_teardown` — removal goes through the cached path builder,
  an absent cgroup errors rather than reporting success (the shutdown sweep
  counts on the `Result`), and name validation still guards the teardown
  path so it is not the hole in the 1.4.2 traversal fix.
- `test_reload_config_is_narrow` — live scalars apply, and the boot sequence
  and service map are provably **not** swapped.
- `test_edge_budget_predicate` — unset/negative budgets never trip, a
  generous one does not, an elapsed one does.

### Fixed — two mount options dropped in the Rust→Cyrius port

Found by the `rust-old/` port review done alongside this release (see below).
Both verified against both trees:

- **`/run` was mounted without `mode=0755`.** tmpfs with no `mode=` defaults
  to **01777 — world-writable and sticky** — and `/run` holds the notify
  socket and argonaut's PID files. The Rust implementation passed
  `mode=0755,size=20%`; the port kept the size and dropped the mode, so every
  boot since has come up with a world-writable `/run`. This undercuts
  argonaut 1.8.6's PID-file ownership check (CVE-2018-16888 class) among
  other things.
- **`/dev/pts` was mounted without `gid=5`** (the tty group), so allocated
  ptys got the wrong group owner. Rust passed `gid=5,mode=0620`.

### Reviewed — is the Rust port complete? No.

The question was whether `rust-old/` can be deleted. Every Rust module has a
Cyrius counterpart and Cyrius is a superset almost everywhere — but several
behaviours were dropped in the port and are still missing. **`rust-old/`
should stay until they are closed**; it is the reference implementation for
the restart machinery. Full list in the roadmap under **v1.5.4 — complete the
Rust port**. The largest:

- **Deferred restart is gone.** Rust kept a PendingRestart queue and a
  `TOKEN_RESTART` timerfd; SIGCHLD only enqueued. kybernet restarts
  synchronously, so a crash-looping service is relaunched as fast as it can
  die until `max_restarts` trips. The backoff is not just ignored — it is
  passed as `init_restart_service`'s **`stop_timeout_ms`** argument, and
  nothing in argonaut ever reads `CrashAction.delay_ms` at all.
  `TOKEN_RESTART = 4` remains in the enum with no timer and no `case 4`.
- **Health-check failures never act** — logged forever, never restarted.
- **A watchdog kill is a one-way door** — Rust queued a restart; kybernet
  kills and the service stays dead.
- **`NOTIFY_SOCKET` is never exported**, so no service can discover the notify
  socket and the whole sd_notify path is unreachable from the service side —
  even though `notify_socket_path()`'s comment says it exists for exactly that.

One finding is worth recording for its own sake: the Rust `eventloop` had
`drain_timerfd`, called at the top of both `TOKEN_HEALTH` and
`TOKEN_WATCHDOG`. The port dropped it — and that omission *was* 1.4.2's
CRITICAL-1, the level-triggered timerfd spin that pinned PID 1 at 100 % CPU
and eventually panicked the kernel. It was found and fixed independently at
1.4.2; the port review shows the original had it right.

### Performance

Bench gate: 51 recorded, **0 regressions**. Two entries printed as `noise`
(`classify_signal` 2→3 ns, `event_token+flags` 4→5 ns) — 1 ns moves under
the `MIN_DELTA_NS` floor added at 1.5.1, which is exactly the case that
floor exists for. `sandbox_basic_service` improved 230 → 218 ns (−5%).

---

## [1.5.2] — 2026-08-25

**Per-service security profiles, as config data — and the capability
numbers they depend on were wrong.** Requires **argonaut 1.11.0** and
**agnostik 1.5.0**. Suite 255 → 296 assertions, 0 failures.

1.4.3 delivered the mechanism (argonaut's pre-exec hook + `kyb_pre_exec`)
but no service carried a policy, so the hook was a no-op in practice. This
is where profiles become real. Completes audit HIGH-1's follow-through.

### Fixed — capability numbers were not kernel capability numbers

The security fix in this release, and it was live the moment capability
policy stopped being decorative.

**agnostik and argonaut both define `enum LinuxCapability`, with the same
member names.** kybernet links both, so "last definition wins" silently
decided which numbers the privilege drop used — argonaut's, which were a
13-entry list in an arbitrary order: `CAP_NET_BIND_SERVICE` = 0,
`CAP_SYS_ADMIN` = 1, `CAP_SETUID` = 5. The kernel's are 10, 21 and 7.

`drop_caps_from_set` builds a mask with `1 << cap` and feeds it to
`capset(2)`. So **"keep `CAP_SYS_ADMIN`" retained kernel capability 1 —
`CAP_DAC_OVERRIDE` — and dropped `CAP_SYS_ADMIN`.** Every capability name an
operator could write meant a different capability than they wrote.

agnostik's numbering was wrong too, in its own way: `CAP_MAC_OVERRIDE` (32)
and `CAP_MAC_ADMIN` (33) were **absent entirely**, shifting everything above
31 down by two, and `CAP_AUDIT_READ`/`CAP_AUDIT_CONTROL` were transposed.

Both are corrected upstream (argonaut 1.11.0, agnostik 1.5.0) to the kernel
table with explicit values. Because they now agree, the toolchain no longer
reports a conflicting-value collision on any `CAP_*` symbol — previously a
standing wall of `duplicate symbol ... redefined with conflicting value`
warnings that had been treated as noise for releases. Filed in the
2026-08-24 audit as `cap-ordinal-vs-kernel-number`.

### Added — profiles are data, not code

A profile lives in `/etc/kybernet/config.json`, so changing what a service
may do does not mean rebuilding PID 1:

```json
"security": {
  "no_new_privs": true,
  "capabilities": ["cap_net_bind_service"],
  "landlock":     [{"path": "/usr", "access": "read-exec"}],
  "seccomp":      "basic"
}
```

- **`capabilities` is a KEEP-list.** Present-and-empty means drop
  everything; absent means no capability policy at all. Names are the
  lowercase kernel spelling (`cap_sys_admin`) that `capsh(1)` and
  `capability(7)` use, parsed by agnostik's new `capability_parse`.
- **`landlock`** becomes an agnostik `sandbox_config`; `access` is
  `none` / `read` / `read-write` / `read-exec`.
- **`seccomp` names a profile** rather than carrying a raw syscall list — a
  BPF filter is not something to hand-assemble in a config file, and a wrong
  one is a service that dies on its first `read()`.
- **`no_new_privs` defaults on** for anything that asked to be confined:
  both Landlock and seccomp require it, and it is what stops a setuid binary
  handing the privileges straight back on exec.

**Every malformed profile rejects the service.** An unknown capability name,
an unknown access mode, an unknown seccomp profile, a Landlock rule without
a path — all refuse to start it. Running a service whose confinement could
not be parsed is strictly worse than not running it, and silently ignoring a
capability name is how you come to believe a service is confined when it is
not.

### Added — the harness proves confinement, as root

The staged config gains `kyb-confined`, which carries a real policy (drop
every capability, set `no_new_privs`) and then reports its **own**
`/proc/self/status` to `/dev/console`. `boot-test.sh` asserts:

```
OK: kyb-confined dropped all capabilities (CapEff=0)
OK: kyb-confined has no_new_privs set
```

So the gate checks the policy *took effect in the child*, rather than
trusting that `kyb_pre_exec` was called.

This is also **the privileged validation of `drop_cap_sets()`** the roadmap
carried as an open item. The unit suite runs unprivileged, where every
capability path short-circuits on the euid check and `capset(2)` never
executes; under QEMU kybernet is genuinely PID 1 as root and it does.

Verified the gate can fail: with the capability drop disabled the same boot
reports `CapEff: 000001ffffffffff` — the full root set — and the harness
fails. That value is bits 0–40, which independently confirms the kernel's
41 capabilities and the corrected `CAP_LAST_CAP`.

### Tests

- `test_security_profile_parse` — capabilities land as **kernel** numbers
  (10 for `cap_net_bind_service`, 5 for `cap_kill` — the assertion that
  would have caught the collision), Landlock rules and access mapping, and
  the named seccomp profile.
- `test_security_profile_defaults_and_rejection` — absent block is a strict
  no-op, empty capability list means drop-all, `no_new_privs` defaults on,
  and five malformed-profile shapes each reject the service.
- `test_capability_numbers_are_kernel` — 18 values pinned against the kernel
  table, including the tail agnostik had shifted.
- agnostik `test_v141_capability_numbers.tcyr` — 35 assertions, full
  roundtrip over all 41 members.

### Still open from the roadmap item

The aarch64 seccomp syscall table (eight values from asm-generic that the
cyrius stdlib does not export) remains **unvalidated on real aarch64
hardware** — the harness is x86_64/KVM only. Unchanged from 1.4.2; carried
forward.

---

## [1.5.1] — 2026-08-25

**Boot stages that do something.** Requires **argonaut 1.10.1**. Suite
235 → 255 assertions, 0 failures; both arches clean; harness green and back
under the original 3000 ms budget.

`execute_boot_stage(stage)` was a switch whose eleven arms *and* `default`
all returned 1 — semantically `return 1;`. So `run_boot_stages` always took
the success branch, `init_mark_step_failed` was unreachable, and the
caller's `if (boot_r < 0)` emergency-drop path could never fire. Every
`boot: <stage>` line an operator saw was theatre. 1.4.2 audit MEDIUM.

### Added — three honest answers per stage

`src/lib/boot_stages.cyr` (new). Each stage returns one of:

- **`STAGE_OK`** — the work was performed or verified
- **`STAGE_SKIP`** — this deployment does not perform this stage; argonaut
  records `STEP_SKIPPED`, which `init_is_boot_complete` accepts
- **`STAGE_FAIL`** — it should have worked and did not

`SKIP` is the load-bearing addition. Several stages describe work kybernet
genuinely does not do — it never starts udev; devtmpfs covers `/dev`. The
two options before were to claim `COMPLETE` and lie, or `FAIL` and abort a
healthy boot. Neither is honest, so argonaut 1.10.1 grew a third state.

What each stage now actually checks:

| Stage | Behaviour |
|---|---|
| `MOUNT_FS` | verifies `/proc`, `/sys`, `/dev` are really mounted — the first point that turns a failed required mount into a failed stage (phase 3's Err path only logs) |
| `DEVICE_MGR` | verifies `/dev` is usable (`/dev/console` present), then **SKIP** — kybernet does not run udev |
| `VERIFY_ROOTFS` | **OK** when edge verification applied, **SKIP** when the deployment never asked for it |
| `SECURITY` | verifies the per-service sandbox hook is armed **before any service spawns** — a real ordering check, since a hook registered after the first spawn confines nothing. Probes Landlock support and logs if absent |
| service groups | reports whether that group's services came up; a group with no services in this deployment is **SKIP**, not a failure |
| `BOOT_COMPLETE` | reaching it is its completion |

An unknown stage returns `SKIP` rather than silently passing — argonaut can
add stages.

### Changed — services start when a stage needs them

Service-group stages report whether their services came up, so the services
must have been attempted first. `run_boot_stages` now starts them on demand
via an idempotent `ensure_services_started()`; phase 8 calls the same
wrapper, covering modes whose sequence has no service stage. Previously
those stages were evaluated *before* any service existed — part of why they
all returned 1.

### Changed — harness

The QEMU config moves to `boot_mode: recovery`, whose sequence is the four
early stages plus boot-complete and whose default service set is empty.
Two consequences:

- The stage outcomes are now assertable on a clean happy path. Previously
  `BOOT_MINIMAL`'s required `STAGE_AGENT_RUNTIME` failed for real (daimon's
  binary is not staged in the initramfs), so every harness boot routed
  through the emergency shell — which masks whether stages actually succeed.
- **Budget back to 3000 ms from 6000.** The 6000 existed for daimon's
  10 × 200 ms ready-check retry against a port nothing listens on. Recovery
  mode has no daimon, the retry disappears with it, and boots land at
  **~650 ms** again.

New gates: the `skipped (not applicable)` marker must appear, and
`FATAL: required boot stage failed` must **not** — a check that could not
have fired before 1.5.1, since a stage failure was structurally impossible.

### Changed — the bench gate got a noise floor

`MIN_DELTA_NS` (default 3). `cyrius bench` reports whole nanoseconds, so a
benchmark at 2–5 ns/op moves ≥15% whenever it moves *at all* — one ns on a
3 ns measurement is 33%. Three releases running, the only flagged
regressions were 1–2 ns wobbles on sub-10 ns benchmarks in code the release
never touched (`classify_signal`, `cgroup_file`, `Ok+is_ok`), each of which
came back as an "improvement" the following release. A regression must now
be **both** ≥15% and ≥3 ns absolute; sub-threshold percentage hits print as
`noise` instead. A 15% regression on anything above ~20 ns/op still trips.
A gate that cries wolf gets ignored, which is worse than no gate.

### Upstream — argonaut 1.10.1

`init_mark_step_skipped` (the third state), `init_service_ready` (the
"is this service up" predicate, oneshot-aware), `init_boot_sequence`, and
`config_set_boot_mode`.

### Tests

- `test_boot_stage_results` — each stage's honest answer, including that an
  unknown stage does not pass and that `BOOT_COMPLETE` is not gated on
  service state.
- `test_boot_stage_security_requires_hook` — the security stage **fails**
  with no hook registered and passes with one. This is the ordering
  guarantee, asserted rather than assumed.
- `test_boot_stage_service_groups` — a group whose service has not started
  fails; a completed oneshot satisfies it; an absent group skips.
- `test_required_stage_failure_propagates` — a failed required step blocks
  `init_is_boot_complete`, while a **skipped** one does not. That contrast
  is the whole reason for the third state.

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
