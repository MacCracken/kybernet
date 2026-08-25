# Security Policy

## Reporting Vulnerabilities

Kybernet runs as PID 1 with root privileges. Security vulnerabilities are critical.

Report vulnerabilities privately to **security@agnos.dev**. Do not open public issues for security bugs.

We will acknowledge receipt within 48 hours and provide a timeline for a fix.

## Supported Versions

> **Proposed, not yet ratified.** This table reflects current practice rather than a
> published commitment — confirm or change it before treating it as policy.

| Version | Supported |
|---------|-----------|
| 1.5.x   | ✅ Fixes land on the latest patch |
| ≤ 1.4.x | ❌ Upgrade to 1.5.x |

Kybernet has no long-term-support branch. Fixes go to the tip and ship as a new patch
release; there is no backporting.

## Scope

In scope — kybernet is PID 1, so anything here is a root-privilege issue by definition:

- **The boot path** — mount handling, the config parser (`/etc/kybernet/config.json`),
  boot stages, and the service-start path
- **Per-service confinement** (`src/lib/service_sandbox.cyr`) — the pre-exec hook that
  applies cgroup placement, `no_new_privs`, capability drops, Landlock and seccomp
  between fork and exec. It **fails closed**: a policy that cannot be applied aborts the
  child rather than launching the service unconfined
- **Verified boot** (`src/lib/edge_boot.cyr`) — TPM detection, PCR reads, and dm-verity
  integrity verification against an operator-pinned root hash
- **The emergency shell** — the authentication gate, the console handling, and the
  conditions under which a shell is opened at all
- **Privilege dropping** (`src/lib/privdrop.cyr`) — capability set manipulation reaching
  `capset(2)`
- **Cgroup handling** — service isolation, resource limits, and teardown
- **The signal and reaper paths** — anything that can wedge or crash PID 1, since the
  kernel panics if init exits

Out of scope, or handled elsewhere:

- **Dependency vulnerabilities** — report to the owning repo (argonaut, agnostik, libro,
  sigil). Cross-post here if kybernet's use of the dep is what makes it exploitable.
- **The Cyrius toolchain** — report to the cyrius repo.
- **Physical-access attacks that verified boot does not claim to stop.** The emergency
  password hash lives in `config.json` on the rootfs; on a non-edge board that file is
  not integrity-protected, and an attacker who can write it can disable the gate. The
  hash is also an **unsalted SHA-256** — trivially brute-forced offline by anyone who
  can read it. Hardening that is tracked as roadmap v1.5.9. Neither is a vulnerability
  report; both are known and documented.
- **PCR baseline mismatches**, which are reported and deliberately not enforced — a
  firmware or kernel update legitimately changes PCR 7/14, and enforcement would turn a
  routine signed upgrade into a fleet-wide refusal to boot. See the roadmap.

## What a good report looks like

The QEMU harness (`bash qemu/boot-test.sh`) boots kybernet as real PID 1. If a finding
can be demonstrated there — or as a failing assertion in `src/test.cyr` — it is far
faster to confirm and fix. Several defects in this project's history were invisible to
every gate except a real boot.
