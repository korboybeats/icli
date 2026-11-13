#!/bin/sh
# Compile the actual native bridge with a fake AVSystemController on macOS.
set -eu
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wl,-export_dynamic \
  -framework Foundation -framework CoreFoundation \
  -ISources/IcliPrivate/include -ISources/IcliSystemPrivate/include -ISources/IcliLaunchPrivate/include \
  Sources/IcliPrivate/AudioRoutes.m Tests/AudioRoutes/main.m -o "$work/audio-route-tests"
"$work/audio-route-tests"
