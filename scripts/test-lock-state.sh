#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Build the pure lock-source resolver with its test. Works on Linux and macOS.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"${CC:-clang}" -std=c11 -Wall -Wextra -Werror -ISources/IcliLaunchPrivate/include \
  Sources/IcliLaunchPrivate/LockResolve.c Tests/LockState/main.c -o "$work/lock-state-tests"
"$work/lock-state-tests"
