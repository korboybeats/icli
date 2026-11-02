#!/bin/bash
# Builds the rootless .deb on the Mac and installs it with dpkg, so dpkg owns
# the installed binary and its version (Resources/Info.plist).
set -euo pipefail
cd "$(dirname "$0")/.."
MAC_DIR=/Users/korboy/Projects/icli-src/icli-update-e295e0f
VERSION=$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleShortVersionString"])' Resources/Info.plist)
DEB="com.icli.icli_${VERSION}_iphoneos-arm64.deb"
git diff --check
rsync -a --delete --exclude=.git --exclude=.build ./ "mac:$MAC_DIR/"
# The linker embeds Info.plist with -sectcreate, which SwiftPM does not track:
# drop the linked products so a version change always relinks.
ssh mac "zsh -l -c 'cd $MAC_DIR && rm -f .build/swiftpm-*/*/*/icli && rtk err --shell bash \"set -o pipefail; make deb-rootless CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= 2>&1 | tee .build/automation-build.log\"'"
scp "mac:$MAC_DIR/.build/icli" .build/icli
scp "mac:$MAC_DIR/.build/$DEB" ".build/$DEB"
scp "mac:$MAC_DIR/.build/automation-build.log" .build/
scp-iphone ".build/$DEB" "/var/mobile/Documents/Downloads/$DEB"
ssh-iphone "/var/jb/usr/bin/dpkg -i /var/mobile/Documents/Downloads/$DEB && /var/jb/usr/bin/rm -f /var/mobile/Documents/Downloads/$DEB"
# dpkg -i clears a hold; without one, the next upstream release replaces this build.
ssh-iphone "/var/jb/usr/bin/apt-mark hold com.icli.icli"
ssh-iphone "/var/jb/usr/bin/apt-mark showhold" | grep -qx com.icli.icli || { echo "com.icli.icli is not on hold" >&2; exit 1; }
installed=$(ssh-iphone '/var/jb/usr/bin/icli --version; /var/jb/usr/bin/dpkg-query -W -f="\${Version}\n" com.icli.icli; /var/jb/usr/bin/sha256sum /var/jb/usr/bin/icli')
echo "$installed"
local_sha=$(sha256sum .build/icli | cut -d' ' -f1)
[ "$(sed -n 1p <<<"$installed")" = "$VERSION" ] || { echo "icli --version is not $VERSION" >&2; exit 1; }
[ "$(sed -n 2p <<<"$installed")" = "$VERSION" ] || { echo "dpkg does not list $VERSION" >&2; exit 1; }
[ "$(sed -n 3p <<<"$installed" | cut -d' ' -f1)" = "$local_sha" ] || { echo "installed binary differs from .build/icli" >&2; exit 1; }
