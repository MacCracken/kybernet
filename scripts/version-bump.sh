#!/usr/bin/env bash
# version-bump.sh — Update VERSION file and Cargo.toml version.
# Usage: ./scripts/version-bump.sh 0.2.0

set -euo pipefail

VERSION="${1:?Usage: version-bump.sh <version>}"

echo -n "$VERSION" > VERSION
sed -i "s/^version = \".*\"/version = \"$VERSION\"/" Cargo.toml

echo "Bumped to $VERSION"
echo "  VERSION: $(cat VERSION)"
echo "  Cargo.toml: $(grep '^version' Cargo.toml)"
