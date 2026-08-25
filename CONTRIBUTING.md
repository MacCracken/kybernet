# Contributing to Kybernet

Contributions are welcome. All contributions must be licensed under GPL-3.0-only.

## Development

Follow the conventions in [CLAUDE.md](CLAUDE.md) — in particular the standing
audit rules, which encode defects this project has actually shipped and does
not want back.

Before submitting:

```sh
CYRIUS_DCE=1 cyrius build src/main.cyr build/kybernet
cyrius build --aarch64 src/main.cyr build/kybernet-aarch64
cyrius test src/test.cyr
cyrius fmt <changed-file> --check          # NOT `cyrius fmt <f>` — that rewrites in place
cyrius vet src/main.cyr
```

A change that touches `src/` should also run the QEMU harness, which boots
kybernet as real PID 1:

```sh
bash qemu/boot-test.sh
```

It needs KVM. It is the only gate that executes a real boot, a reactor
iteration, and the verified-boot and emergency-auth paths — several defects in
this repo's history were invisible to every other gate.

A version bump additionally runs `bash scripts/bench-history.sh`, which gates
on a ≥15% per-benchmark regression. Sub-30ns benchmarks in this suite move on
binary layout alone; bisect by file before treating one as real.

## Reporting Issues

Open an issue at https://github.com/MacCracken/kybernet/issues
