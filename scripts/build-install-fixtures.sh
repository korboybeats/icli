#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
case "${1:-rootless}" in
  rootless) ARCH=iphoneos-arm64 ;;
  roothide) ARCH=iphoneos-arm64e ;;
  *) echo "unknown package layout: $1" >&2; exit 64 ;;
esac
root="$PWD/.build/install-fixtures"
app="$root/Payload/IcliInstallFixture.app"
# stamp BUNDLE IDENTIFIER NAME ENTITLEMENTS_OUT [--container]: gives a TestHost
# copy its own identity. A container fixture drops the TestHost's entitlements.
stamp() {
  python3 - "$@" <<'PY'
import plistlib, sys
from pathlib import Path
bundle, identifier, name, entitlements = sys.argv[1:5]
container = sys.argv[5:] == ['--container']
info = plistlib.loads(Path('Tests/TestHost/Info.plist').read_bytes())
info.pop('CFBundleURLTypes', None)
info['CFBundleIdentifier'] = identifier
info['CFBundleDisplayName'] = name
(Path(bundle) / 'Info.plist').write_bytes(plistlib.dumps(info))
ent = {'get-task-allow': True} if container else plistlib.loads(Path('Tests/TestHost/entitlements.plist').read_bytes())
ent['application-identifier'] = identifier
Path(entitlements).write_bytes(plistlib.dumps(ent))
PY
}
mkdir -p "$app" "$root/deb/DEBIAN" "$root/deb/var/mobile/Library/Caches/icli-install-test"
for version in 1 2; do
  xcrun clang -target arm64-apple-ios15.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
    -Wall -Wextra -Werror -DICLI_DAEMON_VERSION="$version" Tests/LaunchdKickstart/main.c \
    -o "$root/kickstart-daemon-$version"
  ldid -S "$root/kickstart-daemon-$version"
done
cp .build/testhost-app/IcliTestHost "$app/IcliTestHost"
stamp "$app" dev.owngoal.icli.InstallFixture 'icli Install Fixture' "$root/entitlements.plist"
ldid -S"$root/entitlements.plist" "$app"
# A separate identity keeps on-device self-tests away from install acceptance.
selftest="$root/SelfTestFixture.app"
mkdir -p "$selftest"
cp "$app/IcliTestHost" "$selftest/IcliTestHost"
stamp "$selftest" dev.owngoal.icli.SelfTestFixture 'icli Self-Test Fixture' "$root/selftest-entitlements.plist"
ldid -S"$root/selftest-entitlements.plist" "$selftest/IcliTestHost"
ldid -S"$root/selftest-entitlements.plist" "$selftest"
(cd "$root" && rm -f icli-install-fixture.ipa && zip -qr icli-install-fixture.ipa Payload)
# An App Store-shaped app for container installs: sandboxed in its data
# container, without the TestHost's platform and no-sandbox entitlements.
container="$root/container/Payload/IcliContainerFixture.app"
rm -rf "$root/container"
mkdir -p "$container"
cp "$app/IcliTestHost" "$container/IcliTestHost"
stamp "$container" dev.owngoal.icli.ContainerFixture 'icli Container Fixture' "$root/container-entitlements.plist" --container
extension_plist() {
  python3 - "$@" <<'PY'
import plistlib, sys
from pathlib import Path
bundle, identifier, executable = sys.argv[1:]
(Path(bundle) / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': identifier,
    'CFBundleExecutable': executable,
    'CFBundleName': executable,
    'CFBundlePackageType': 'XPC!',
    'CFBundleVersion': '1',
    'CFBundleShortVersionString': '1.0',
    'CFBundleSupportedPlatforms': ['iPhoneOS'],
    'MinimumOSVersion': '15.0',
    'NSExtension': {
        'NSExtensionPointIdentifier': 'com.apple.networkextension.packet-tunnel',
        'NSExtensionPrincipalClass': 'NSObject',
    },
}))
PY
}
# A plug-in, so a container install shows whether LaunchServices registered
# it. Nothing configures the tunnel, so the extension is never launched.
# Signing the app below signs it too, with the app's entitlements.
extension="$container/PlugIns/IcliContainerFixtureTunnel.appex"
mkdir -p "$extension"
cp "$app/IcliTestHost" "$extension/IcliContainerFixtureTunnel"
extension_plist "$extension" dev.owngoal.icli.ContainerFixture.Tunnel IcliContainerFixtureTunnel
ldid -S"$root/container-entitlements.plist" "$container"
(cd "$root/container" && rm -f ../icli-container-fixture.ipa && zip -qr ../icli-container-fixture.ipa Payload)
# An unsandboxed app with a no-container plug-in, as Filza has: LaunchServices
# reports the plug-in as containerized whatever was registered.
uncontained="$root/uncontained-plugin/IcliUncontainedFixture.app"
rm -rf "$root/uncontained-plugin"
mkdir -p "$uncontained/PlugIns/IcliUncontainedTunnel.appex"
cp "$app/IcliTestHost" "$uncontained/IcliTestHost"
stamp "$uncontained" dev.owngoal.icli.UncontainedFixture 'icli Uncontained Fixture' "$root/uncontained-entitlements.plist"
cp "$app/IcliTestHost" "$uncontained/PlugIns/IcliUncontainedTunnel.appex/IcliUncontainedTunnel"
extension_plist "$uncontained/PlugIns/IcliUncontainedTunnel.appex" dev.owngoal.icli.UncontainedFixture.Tunnel IcliUncontainedTunnel
ldid -S"$root/uncontained-entitlements.plist" "$uncontained"
cat > "$root/deb/DEBIAN/control" <<CONTROL
Package: dev.owngoal.icli.installtest
Name: icli install acceptance fixture
Version: 1.0
Architecture: $ARCH
Maintainer: OwnGoal
Description: Removable data-only installation fixture
CONTROL
printf 'icli installation verified\n' > "$root/deb/var/mobile/Library/Caches/icli-install-test/marker.txt"
dpkg-deb --root-owner-group -b "$root/deb" "$root/icli-install-fixture.deb"
