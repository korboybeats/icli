# icli

Control your iPhone from the command line. Tap and swipe, enter text, inspect accessibility elements, capture screenshots, and read on-screen text, with JSON output for scripts and automation.

icli runs on the device itself. Use it in a device terminal or over SSH from your Mac. It requires an arm64 device running iOS 15 or later on custom firmware with a compatible bootstrap. A separate build runs on tvOS 15 or later; see [tvOS](docs/platforms/tvos.md).

The CLI performs device operations in-process using iOS frameworks and a statically linked archive library, without spawning subprocesses or invoking bootstrap tools. App inspection additionally uses the app agent and runtimes shipped in the iOS package. `icli env` reports `spawns_processes: false` and an empty `external_tools_used` object.

For app integration, add this repository as a Swift Package dependency and select **IcliKit**, or the Foundation-only **IcliSystem** (read-only system state) and **IcliLaunch** (bring an app to the front, read the lock state and the frontmost app). See the [Swift Package integration guide](docs/swift-package.md) and the [entitlement inventory](docs/entitlements.md).

## Install

Download a DEB from [GitHub Releases](https://github.com/korboybeats/icli/releases), or [build from source](docs/development/building.md), then choose the package for your bootstrap:

| Bootstrap | Package Architecture | Status |
| --- | --- | --- |
| Rootless (`/var/jb`) | `iphoneos-arm64` | Tested on an iPhone 15 Pro Max (iOS 17.1.1, Dopamine) and the project's rootless vphone |
| RootHide | `iphoneos-arm64e` | Experimental; service inspection verified on iOS 18.5, full acceptance pending |
| tvOS, rootful (`/usr/bin`, Procursus `appletvos-arm64`) | `appletvos-arm64` | Package checks only; not run on a tvOS device |

```sh
sudo dpkg -i /tmp/icli.deb
icli --version
icli device info
```

See [Install](docs/install/install.md) for uploading over USB, rootless paths, and what the package contains.

## Features

- **Touch and keyboard**: Tap, swipe, pinch, press and hold, drag along a path, scroll an exact distance, perform system gestures, enter Unicode text, and send keyboard shortcuts or raw HID events. On an iPad, click and scroll with a virtual pointer.
- **Accessibility**: Read the UI tree, including system UI, find elements by text, identifier, or role, tap a match and verify what it changed, fill text fields, scroll until an element is on screen, answer alerts, go back, and wait for an element to appear or disappear.
- **Screenshots and OCR**: Save JPEG or PNG screenshots, return images as Base64, record the screen to a movie, wait for the screen to change or settle, recognize text, or collect an image, OCR results, and accessibility elements together.
- **Apps**: List, launch, relaunch, inspect, register, unregister, and refresh apps; grant, deny, or reset their privacy permissions, erase their data, and open their Settings page; inspect or repair their network policy. Install and remove local DEB packages and IPA files; an IPA installed with `--container` gets its own app and data containers and is re-signed ad-hoc inside icli, so decrypted App Store apps launch.
- **Files and logs**: Read, write, copy, move, link, and remove files; change permissions and ownership; read and edit property lists; capture live logs and read crash reports.
- **Control Center**: Read and set Airplane Mode, Wi-Fi, Bluetooth, cellular data, Personal Hotspot, AirDrop, Focus and Do Not Disturb, the flashlight and its level, rotation lock, Low Power Mode, and light or dark appearance, and read screen mirroring. `cc audio list` discovers audio outputs; `cc audio select <route-uid>` selects an exact UID and waits for native confirmation. Changes are read back and stay after icli exits.
- **Device controls**: Lock and unlock, keybag unlock with a supplied passcode, brightness, volume, rotation, appearance, accessibility text size and display settings, time zone, hardware buttons, the clipboard, Low Power Mode, Darwin notifications, Developer Mode, simulated location, reboots, and boot logos.
- **System**: Manage launchd services, local DEB packages and repository sources, account passwords, system app visibility, SpringBoard restarts, packet capture, and test Keychain items; read jetsam bands and memory pressure.
- **Preferences**: Read, write, and delete typed preference values like `defaults`.
- **Inspect running apps**: `icli flex` brings FLEX's in-app inspection to the command line (ported from FlexUltra): live objects and the heap, views and view controllers, the app's files, defaults, keychain, SQLite and Realm databases, network history, its log, and method tracing. The agent attaches on demand and remains loaded in the target app until it exits.
- **Scripting**: Run a JavaScriptCore script in-process with `icli probe`, or inside an app with `icli probe --app`, with an Objective-C reflection bridge and icli's own capabilities through `api()`.
- **Automation runs**: Run many commands in one process with `batch` or a line-by-line `session`, read the device state in one call with `status`, and claim the device with a `lease` so other runners cannot interfere with interaction while background file work and inspection continue; while a lease is held, the device shows its owner's name above the home indicator.

## Command Line

Run commands on the device or in its SSH session. Commands return JSON by default; add `--human` for readable output, and `--help` to any command for its options.

```sh
icli ui tree
icli ui tap --identifier counter.increment
icli screen tap 100 245
icli screen shot --output /tmp/screen.jpg
icli app launch example.bundle.id
icli log syslog --seconds 3 --level error
```

| Topic | Guide |
| --- | --- |
| Accessibility, touch, keyboard, pointer, screenshots, OCR | [Interaction and Screen Capture](docs/usage/interaction.md) |
| Apps, packages, files, logs | [Apps, Files, and Logs](docs/usage/apps-files-logs.md) |
| launchd services, registration, reboots | [Services and System Maintenance](docs/usage/services.md) |
| Control Center toggles, audio outputs, location, power, notifications, preferences | [Location, Power, and Preferences](docs/usage/device-settings.md) |
| Full FlexUltra inspection, heap search, mutation, tracing and MCP | [Inspect Running Apps](docs/usage/flex.md) |
| JavaScriptCore scripting with `icli probe` | [Script the Device](docs/usage/probe.md) |
| JSON output, errors, lock state, RootHide paths | [Output and Device State](docs/usage/output.md) |
| tvOS differences | [tvOS](docs/platforms/tvos.md) |

## Development

- [Build from Source](docs/development/building.md): toolchain, `make` targets, package outputs, and release CI.
- [Testing and Compatibility](docs/development/testing.md): on-device self-tests, the acceptance suite, and tvOS acceptance. The last full acceptance report, for 0.3.0 on the rootless vphone, is in the [acceptance report](docs/rootless-acceptance.md); later device checks are listed in [release notes](docs/releases) and the [audio-output validation summary](docs/development/audio-output-validation.md).

## License

icli is available under the [MIT License](LICENSE).

Third-party dependency licenses are listed in [Third-Party Notices](THIRD_PARTY_NOTICES.md). The notices and bundled dependency license texts are included in every DEB package.
