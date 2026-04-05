#!/bin/sh
# Test kybernet — standalone
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CC="${CYRIUS_CC:-${ROOT}/../cyrius/build/cc2}"

if [ ! -x "$CC" ]; then
    echo "ERROR: Cyrius compiler not found" >&2
    exit 1
fi

echo "=== Kybernet Tests ==="
cd "$ROOT"

# Run module tests
cat src/test.cyr | "$CC" > /tmp/kybernet_test 2>/dev/null
chmod +x /tmp/kybernet_test
/tmp/kybernet_test
test_exit=$?

# Build main
cat src/main.cyr | "$CC" > /tmp/kybernet_main 2>/dev/null
if [ $? -eq 0 ]; then
    SZ=$(wc -c < /tmp/kybernet_main)
    echo "  PASS: main builds ($SZ bytes)"
else
    echo "  FAIL: main build error"
    test_exit=1
fi

rm -f /tmp/kybernet_test /tmp/kybernet_main
exit $test_exit
