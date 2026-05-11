#!/usr/bin/env bash
# version-bump.sh — Update the VERSION file (cyrius.cyml pulls
# package.version from VERSION via ${file:VERSION}, so there's
# nothing else to touch here).
# Usage: ./scripts/version-bump.sh 1.1.1

set -euo pipefail

VERSION="${1:?Usage: version-bump.sh <version>}"
echo -n "$VERSION" > VERSION
echo "Bumped to $VERSION"
echo "  VERSION: $(cat VERSION)"
echo "  cyrius.cyml: package.version = \${file:VERSION} (auto)"
