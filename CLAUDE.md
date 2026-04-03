# Kybernet — Claude Code Instructions

## Project Identity

**Kybernet** (Greek: κυβερνήτης, "helmsman") — PID 1 binary for AGNOS. The helmsman that steers the Argo. Uses the argonaut library for service management, boot sequencing, and health checks. Handles the unsafe kernel interactions that argonaut's `forbid(unsafe_code)` cannot.

- **Type**: Binary crate (uses argonaut library)
- **License**: GPL-3.0-only
- **MSRV**: 1.89
- **Version**: SemVer 0.D.M pre-1.0
- **publish**: false (ships via ark, not crates.io)

## Consumers

AGNOS boot (PID 1), systemd delegate mode

## Development Process

### P(-1): Scaffold Hardening (before any new features)

1. Test + benchmark sweep of existing code
2. Cleanliness check: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo audit`, `cargo deny check`
3. Get baseline benchmarks (`./scripts/bench-history.sh`)
4. Initial refactor + audit (performance, memory, security, edge cases)
5. Cleanliness check — must be clean after audit
6. Additional tests/benchmarks from observations
7. Post-audit benchmarks — prove the wins
8. Repeat audit if heavy

### Development Loop (continuous)

1. Work phase — new features, roadmap items, bug fixes
2. Cleanliness check: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo audit`, `cargo deny check`
3. Test + benchmark additions for new code
4. Run benchmarks (`./scripts/bench-history.sh`)
5. Audit phase — review performance, memory, security, throughput, correctness
6. Cleanliness check — must be clean after audit
7. Deeper tests/benchmarks from audit observations
8. Run benchmarks again — prove the wins
9. If audit heavy → return to step 5
10. Documentation — update CHANGELOG, roadmap, docs
11. Return to step 1

### Key Principles

- **Never skip benchmarks.** Numbers don't lie. The CSV history is the proof.
- **Own the stack.** Depend on argonaut and agnosys, not external init libraries.
- **Minimal unsafe.** Every `unsafe` block gets a `// SAFETY:` comment explaining the invariant.
- **No panics.** PID 1 must never panic — propagate errors, log, and degrade gracefully.
- **Boot time is sacred.** Desktop < 3s, Edge < 1s. Measure everything.
- **`tracing` on all operations** — structured logging for audit trail.
- **Test in QEMU** — real kernel, real PID 1 semantics.
- **`#[non_exhaustive]`** on all public enums.
- **`#[must_use]`** on all pure functions.

## DO NOT
- **Do not commit or push** — the user handles all git operations (commit, push, tag)
- **NEVER use `gh` CLI** — use `curl` to GitHub API only
- Do not add unnecessary dependencies — keep it lean
- Do not skip benchmarks before claiming performance improvements
