#!/bin/sh
# Exercise the production native bridge without touching a device.
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -include Tests/AudioControllerFixture.h \
  -framework Foundation \
  -ISources/IcliPrivate/include -ISources/IcliSystemPrivate/include -ISources/IcliLaunchPrivate/include \
  Sources/IcliPrivate/SilentMode.m Tests/SilentMode/main.m -o "$work/silent-mode-tests"
"$work/silent-mode-tests"
