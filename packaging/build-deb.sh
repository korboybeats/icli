#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIND="${1:-rootless}"
VERSION=$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleShortVersionString"])' "$ROOT/Resources/Info.plist")
STAGE="$ROOT/.build/deb-$KIND"
BIN="$ROOT/.build/icli"
PLATFORM=iOS
case "$KIND" in
  rootless) ARCH=iphoneos-arm64; PREFIX=/var/jb ;;
  roothide) ARCH=iphoneos-arm64e; PREFIX= ;;
  rootful) ARCH=iphoneos-arm; PREFIX= ;;
  # Procursus's appletvos-arm64 bootstrap is rootful: everything under /.
  tvos) ARCH=appletvos-arm64; PREFIX=; BIN="$ROOT/.build/icli-tvos"; PLATFORM=tvOS ;;
  *) echo "unknown package layout: $KIND" >&2; exit 64 ;;
esac
[ -f "$BIN" ] || { echo "build $(basename "$BIN") first" >&2; exit 66; }
# The probe agent is injected into an app by `icli app launch --probe`, so it
# ships beside the CLI wherever an app can be launched. tvOS has no such
# layout and its package stays the executable alone.
AGENT="$ROOT/.build/icli-probe-agent.dylib"
FLEX="$ROOT/.build/libicli-flex.dylib"
if [ "$PLATFORM" = iOS ]; then
  [ -f "$AGENT" ] || { echo 'build the probe agent first: make agent' >&2; exit 66; }
  [ -f "$FLEX" ] || { echo 'build the private FLEX runtime first: make agent' >&2; exit 66; }
  for name in libicli-flexultra.dylib libicli-reflex.dylib; do
    [ -f "$ROOT/.build/$name" ] || { echo "build $name first: make agent" >&2; exit 66; }
  done
fi
# Sign once in the build. Packaging must preserve the exact same executable.
ENTITLEMENTS=$(ldid -e "$BIN")
[ -n "$ENTITLEMENTS" ] || { echo 'icli has no signed entitlements' >&2; exit 65; }
rm -rf "$STAGE"
STAGED_BIN="$STAGE$PREFIX/usr/bin/icli"
DOC="$STAGE$PREFIX/usr/share/doc/icli"
mkdir -p "$STAGE/DEBIAN" "$STAGE$PREFIX/usr/bin" "$DOC/licenses"
cp "$BIN" "$STAGED_BIN"
chmod 755 "$STAGED_BIN"
if [ "$PLATFORM" = iOS ]; then
  mkdir -p "$STAGE$PREFIX/usr/lib"
  cp "$AGENT" "$STAGE$PREFIX/usr/lib/icli-probe-agent.dylib"
  chmod 755 "$STAGE$PREFIX/usr/lib/icli-probe-agent.dylib"
  mkdir -p "$STAGE$PREFIX/usr/lib/icli"
  cp "$FLEX" "$STAGE$PREFIX/usr/lib/icli/libFLEX.dylib"
  chmod 755 "$STAGE$PREFIX/usr/lib/icli/libFLEX.dylib"
  for name in libicli-flexultra.dylib libicli-reflex.dylib; do
    cp "$ROOT/.build/$name" "$STAGE$PREFIX/usr/lib/icli/$name"
    chmod 755 "$STAGE$PREFIX/usr/lib/icli/$name"
  done
fi
cp "$ROOT/Resources/Licenses/"*.txt "$DOC/licenses/"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/LICENSE" "$DOC/"
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: com.icli.icli
Name: icli
Version: $VERSION
Architecture: $ARCH
Maintainer: icli
Depends: firmware (>= 15.0)
Section: Development
Description: On-device $PLATFORM control CLI
CONTROL
OUTPUT="$ROOT/.build/com.icli.icli_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group -b "$STAGE" "$OUTPUT"
echo "built $OUTPUT"
