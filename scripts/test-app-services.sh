#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter \
  -ISources/IcliPrivate/include -ISources/IcliSystemPrivate/include -ISources/IcliLaunchPrivate/include \
  -framework Foundation Tests/AppServices/main.m Sources/IcliLaunchPrivate/LockResolve.c \
  -o "$work/app-service-tests"
for mode in legacy modern missing-predicate cold-installed cold-name parallel-hidden parallel-visible; do
  "$work/app-service-tests" "$mode"
done
