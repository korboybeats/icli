#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$work/modules" \
  Sources/IcliKit/Device/SavedPasscode.swift Tests/SavedPasscode/main.swift -o "$work/saved-passcode-tests"
"$work/saved-passcode-tests"
