#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
  -ISources/IcliSystemPrivate/include -framework Foundation \
  Tests/LaunchdLegacy/main.m -o "$work/launchd-legacy-tests"
"$work/launchd-legacy-tests"
