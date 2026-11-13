# Install

Both iOS packages contain the same universal arm64/arm64e executable. The architecture label identifies the bootstrap layout. The tvOS package holds the tvOS executable, which each release also publishes on its own as `icli-tvos` for a tvOS system without a bootstrap or `dpkg`. iOS 15 is the minimum deployment target; [Testing and Compatibility](../development/testing.md) separates historical full acceptance from later focused checks, including [audio-output validation](../development/audio-output-validation.md).

For the initial DEB installation below, use the bootstrap's `dpkg` and an account with permission to install packages. To connect over USB, you also need an SSH server on the device and `iproxy` on your Mac. These are installation and connection tools; icli does not invoke them.

In one Mac terminal, start USB forwarding and leave it running:

```sh
iproxy 2333 22
```

In another Mac terminal, upload the package from the repository directory and connect. Replace the version and account details as needed:

```sh
version=$(python3 -c 'import plistlib; print(plistlib.load(open("Resources/Info.plist", "rb"))["CFBundleShortVersionString"])')
scp -P 2333 ".build/com.korboy.icli_${version}_iphoneos-arm64.deb" mobile@127.0.0.1:/tmp/icli.deb
ssh -p 2333 mobile@127.0.0.1
```

Then run on the device:

```sh
sudo dpkg -i /tmp/icli.deb
icli --version
icli device info
```

On rootless installations, the command is `/var/jb/usr/bin/icli`. Use that full path if your shell cannot find it. For SSH over the network, use your device's address and port instead of USB forwarding.

The iOS DEB installs the CLI, the on-demand app probe agent and its inspection runtimes, a SpringBoard lease-indicator tweak, and license notices. The app agent attaches when requested and remains loaded in that app; updating it can require relaunching the app. The lease indicator becomes active after a respring. The tvOS package contains the standalone CLI and notices. The executable is signed with the [documented entitlements](../entitlements.md) in `Resources/icli.entitlements`, so clipboard, brightness, and rotation commands run directly without launching an app or changing the foreground app.
