#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed '/^import IcliPrivate$/d; /^import IcliSystem$/d' \
  Sources/IcliKit/Device/Passcode.swift > "$work/Passcode.swift"
xcrun swiftc -swift-version 5 -module-cache-path "$work/modules" \
  Tests/PasscodeUnlock/main.swift "$work/Passcode.swift" \
  Sources/IcliKit/Device/PasscodeLedger.swift -o "$work/passcode-unlock-tests"
"$work/passcode-unlock-tests" "$work/ledgers"
