# Kybernet Roadmap

Forward work only. What shipped is in [CHANGELOG.md](../../CHANGELOG.md), and what is true
right now, gate counts included, is in [state.md](state.md).

**Current release: 1.12.0** (cyrius 6.7.18, argonaut 1.20.0, libro 2.11.3, agnostik 2.0.0,
sigil 3.13.15).

**Every open item has a target release.** The order is the dependency order: a later release
may assume everything above it. An item whose start depends on something outside these repos
is in [Gated](#gated), names its gate, and gets a number when the gate opens. A new item goes
under a release or under Gated, never in a list of its own. A finished item is deleted, and
a finished release's section goes with it. A version is for code: docs and roadmap changes
never take one, and a comment-only item ships with a release that has code in it.

**Open: 12** (`grep -c '^- \[ \]'` against this file).

---

## Release plan

| Release | Theme | Items | Waits on |
|---|---|---:|---|
| [Gated](#gated) | Unnumbered until the gate opens | 12 | hardware, a consumer, a design, or a dep's release |

**Every release:** the full release gates in CLAUDE.md, including the benchmark gate, then the
sibling-free reproduction.

**A cyrius pin move** has no number until one is wanted, because 6.7.18 is the latest release.
It ships as its own patch, or with whatever release is next. The bench gate's A/B cannot span
a pin change, so a flag on that run stays red until someone explains it (standing rule 6). Scan for the changes that alter
what already-compiling code computes, diff the DCE list knowing it cannot see a
compiler-emitted call, and replay `ci.yml` in the runner's image (CHANGELOG [1.8.0], [1.8.1]).

---

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

**Gate: agnosticos defining their accounts.**

- [ ] **postgres, redis and ifran still run as root.** 1.12.0 moved the four AGNOS services argonaut
      starts by default off root, with ids agnosticos already defines. These three have no AGNOS
      account, and postgres refuses to run as root at all. Each needs a fixed uid and gid in
      agnosticos, its data directory in agnos-init's layout, and the ids in argonaut's
      `default_services`, checked by `test_agnos_identity_contract`.

**Gate: an argonaut tag with agnos-init in BOOT_MINIMAL.**

- [ ] **The console shell on a minimal board.** Nothing owns the terminal: since agnoshi 2.1.2 a
      session started with `/dev/null` on stdin and stdout (standing rule 20) opens `/dev/console`
      itself, with `O_NOCTTY`, and agnos-init (unreleased, after 1.12.0) grants the console to
      group 1000 so agnoshi's uid can open it. argonaut 1.20.0 runs agnos-init in BOOT_DESKTOP
      only; argonaut's unreleased tree adds it to BOOT_MINIMAL, with the minimal agnoshi depending
      on it. When that is tagged: move the argonaut pin, and boot a BOOT_MINIMAL board to an
      agnoshi prompt on its console as uid 1000.

**Gate: a device manager, or a decision that kybernet listens for uevents.**

- [ ] **A device that appears after boot stays root-only.** agnos-init grants `/dev/fb0` and
      `/dev/input/event*` to their groups once, as a oneshot, so a keyboard plugged in later is
      `root:root 0600` and aethersafha cannot open it. Following hotplug is udev's job, and
      kybernet runs no udev.

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
