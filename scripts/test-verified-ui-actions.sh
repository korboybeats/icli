#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun swiftc -swift-version 5 -warnings-as-errors -module-cache-path "$work/modules" \
  Sources/IcliKit/Input/VerifiedAction.swift Tests/VerifiedUIAction/main.swift -o "$work/verified-ui-tests"
"$work/verified-ui-tests"
