#!/bin/sh
# Build kybernet — standalone (vendored stdlib in lib/)
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CYRIUS_CC:-${ROOT}/../cyrius/build/cc2}"

if [ ! -x "$CC" ]; then
    echo "ERROR: Cyrius compiler not found at $CC" >&2
    echo "Set CYRIUS_CC or build: cd ../cyrius && sh bootstrap/bootstrap.sh" >&2
    exit 1
fi

mkdir -p "$ROOT/build"

echo "Building kybernet..."
cd "$ROOT"
cat src/main.cyr | "$CC" > build/kybernet
chmod +x build/kybernet
SZ=$(wc -c < build/kybernet)
echo "  -> build/kybernet ($SZ bytes)"
