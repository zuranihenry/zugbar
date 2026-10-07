#!/usr/bin/env bash
# Fails unless the Swift compiler is 6.2 or newer (Xcode 26 / macOS 26 SDK).
# Older toolchains build Zugbar without Liquid Glass, which a release must not ship.
set -euo pipefail
version="$(swift --version 2>&1 | grep -oE 'Swift version [0-9]+\.[0-9]+' | head -1 | awk '{print $3}')"
echo "Swift $version"
major="${version%%.*}"; minor="${version#*.}"
if (( major < 6 || (major == 6 && minor < 2) )); then
  echo "error: Swift 6.2+ (Xcode 26) is required for Liquid Glass, found $version" >&2
  exit 1
fi
