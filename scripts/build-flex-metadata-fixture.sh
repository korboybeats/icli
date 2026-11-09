#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
fixture=.build/FlexMetadataFixture
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos swiftc -target arm64-apple-ios15.0 -sdk "$sdk" -emit-library \
  -module-name IcliFlexAcceptance Tests/FlexUltra/MetadataFixture.swift -o "$fixture"
ldid -S "$fixture"
