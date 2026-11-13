#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
xcrun --sdk iphoneos clang -arch arm64 -arch arm64e \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" -miphoneos-version-min=15.0 \
  -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
  Tests/SilentMode/native-state.m -o .build/silent-mode-native-state
ldid -SResources/icli.entitlements .build/silent-mode-native-state
