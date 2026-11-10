# Entitlements and execution requirements

[Resources/icli.entitlements](../Resources/icli.entitlements) is the authoritative signing profile for the shipped CLI. This inventory covers all 80 keys and their exact configured values. The complete profile has been tested on vphones; individual keys have **not** all been tested by removing them one at a time. Descriptions below explain each capability's intended role, not a claim that every key is necessary on every iOS release. Private capabilities depend on the OS and bootstrap.

When linking **IcliKit**, **IcliSystem** or **IcliLaunch**, entitlements must be granted to the final calling executable or app. [The Swift Package guide](swift-package.md#entitlements-the-host-needs) maps the read-only `IcliSystem` calls onto the keys below and says which of those are verified, and [its IcliLaunch section](swift-package.md#the-iclilaunch-product) does the same for launching. SwiftPM does not apply this file to consumers or sign them. Use your own `application-identifier` and `com.apple.application-identifier`; the `com.korboy.icli` values identify the CLI. Integrate only the feature groups your host needs using its existing signing process. Ordinary provisioning cannot grant this private platform profile.

Entitlements do not make a process root. Package installation/removal, account password changes, reboots, and privileged filesystem/service operations require the appropriate effective UID. No command elevates itself or launches sudo. Keychain, app data, screenshots, and interaction remain subject to the system's actual access decisions; the library does not promise access to protected content.

## Identity and process environment

| Key | CLI value | Intended role |
| --- | --- | --- |
| `platform-application` | `true` | Platform identity used by privileged system service clients; `environmentReport()` checks actual platform status separately. |
| `application-identifier` | `com.korboy.icli` | CLI application identity; replace with the consumer's own identifier. |
| `com.apple.application-identifier` | `com.korboy.icli` | Companion platform application identity; replace with the consumer's own identifier. |
| `com.apple.private.security.no-sandbox` | `true` | CLI process environment for device-wide filesystem and system service operations. |
| `com.apple.private.security.container-required` | `false` | CLI does not require an application container. |
| `com.apple.private.security.no-container` | `true` | Companion container policy for a standalone executable. |
| `com.apple.private.skip-library-validation` | `true` | Bootstrap/private-library loading profile; not itself a library dependency or a guarantee of load permission. |

## Applications and containers

| Key | CLI value | Intended role |
| --- | --- | --- |
| `com.apple.private.security.storage.AppBundles` | `true` | App bundle storage used for inspection and registration. |
| `com.apple.private.security.storage.AppDataContainers` | `true` | App data container inspection. |
| `com.apple.backboardd.launchapplications` | `true` | BackBoard app launch client capability. |
| `com.apple.springboard.launchapplications` | `true` | SpringBoard app launch client capability. |
| `com.apple.frontboard.launchapplications` | `true` | FrontBoard launch/relaunch actions. |
| `com.apple.backboardd.debugapplications` | `true` | Debug options on a launch: `app launch --arg`, `--env`, `--language`, `--locale`. |
| `com.apple.springboard.debugapplications` | `true` | Debug options on a launch: `app launch --arg`, `--env`, `--language`, `--locale`. |
| `com.apple.frontboard.debugapplications` | `true` | Debug options on a launch: `app launch --arg`, `--env`, `--language`, `--locale`. |
| `com.apple.frontboard.shutdown` | `true` | FrontBoard shutdown/relaunch action used by respring. |
| `com.apple.springboard.opensensitiveurl` | `true` | SpringBoard URL opening profile; URL handling still depends on the OS. |
| `com.apple.private.mobileinstall.allowedSPI` | `Browse`, `Lookup`, `Install`, `Uninstall`, `InstallForLaunchServices`, `UninstallForLaunchServices`, `CopyInstalledAppsForLaunchServices` | Allowed MobileInstallation SPI names: discovery, installation/removal, and LaunchServices-specific registration bookkeeping. |
| `com.apple.private.coreservices.canmaplsdatabase` | `true` | LaunchServices database mapping for app/proxy queries. |
| `com.apple.lsapplicationworkspace.rebuildappdatabases` | `true` | Workspace app database maintenance profile. |
| `com.apple.private.coreservices.can-perform-rebuild-registration` | `true` | Registration maintenance/rebuild profile. |
| `com.apple.private.coreservices.lsaw` | `true` | LSApplicationWorkspace operations. |
| `com.apple.private.coreservices.can-register-install-results` | `true` | Register installation results with LaunchServices. |
| `com.apple.private.coreservices.can-send-install-notifications` | `true` | Installation/removal notification capability. |
| `com.apple.private.coreservices.canforcedatabasegc` | `true` | Database cleanup capability retained in the registration profile; no explicit GC command is exposed. |
| `com.apple.private.coreservices.canmapbundleidtouuid` | `true` | Bundle identifier/container mapping capability. |
| `com.apple.private.installcoordinationd.daemon` | `true` | Installation coordination profile retained for app maintenance. |
| `com.apple.private.MobileContainerManager.allowed` | `true` | MobileContainerManager operations associated with app installation/removal. |
| `com.apple.private.MobileContainerManager.delete` | `true` | Container deletion associated with app removal. |
| `com.apple.private.security.container-manager` | `true` | Companion container manager capability. |

## Input, accessibility, display, and clipboard

| Key | CLI value | Intended role |
| --- | --- | --- |
| `com.apple.private.hid.client.event-dispatch` | `true` | Touch, keyboard, and button HID dispatch. |
| `com.apple.private.hid.client.event-monitor` | `true` | HID client profile; independent necessity is unverified. |
| `com.apple.hid.manager.user-access-device` | `true` | HID device client access. |
| `com.apple.private.hid.client.event-filter` | `true` | HID client profile; independent necessity is unverified. |
| `com.apple.backboard.client` | `true` | BackBoard display/input state client. |
| `com.apple.springboard.orientationlock` | `true` | Orientation lock inspection and updates. |
| `com.apple.private.accessibility.inspection` | `true` | AX element inspection and hit testing. |
| `com.apple.accessibility.api` | `true` | Accessibility API client profile. |
| `com.apple.accessibility.physicalinteraction.client` | `true` | Rotation and orientation lock through SpringBoard's accessibility server, which iOS 27 requires. |
| `com.apple.private.accessibility.look-me-up-setup` | `true` | Accessibility client setup profile. |
| `com.apple.private.webkit.pasteboard` | `true` | Pasteboard service client profile for direct CLI clipboard access. |
| `com.apple.private.pasteboard.check-pasteboard` | `true` | Pasteboard service checks. |
| `com.apple.Pasteboard.background-access` | `true` | Clipboard access without a foreground app. |
| `com.apple.Pasteboard.paste-unchecked` | `true` | CLI pasteboard access profile; receiving apps still have their own paste permission behavior. |
| `com.apple.backboard.displaybrightness` | `true` | Brightness access through BackBoard. |
| `com.apple.private.allow-explicit-graphics-priority` | `true` | Graphics client profile used for direct display capture. |
| `com.apple.private.IOSurface.protected-access` | `true` | IOSurface capture profile; protected-content capture is not an acceptance guarantee. |
| `com.apple.QuartzCore.displayable-context` | `true` | QuartzCore display context profile. |
| `com.apple.QuartzCore.global-capture` | `true` | Device display capture client profile. |
| `com.apple.QuartzCore.secure-mode` | `true` | QuartzCore capture profile; no protected-content guarantee. |
| `com.apple.security.iokit-user-client-class` | `IOHIDLibUserClient`, `IOHIDEventServiceFastPathUserClient`, `IOSurfaceRootUserClient`, `IOSurfaceAcceleratorClient`, `IOMobileFramebufferUserClient`, `AppleJPEGDriverUserClient`, `IOHIDUserDevice`, `IOHIDResourceDeviceUserClient` | IOKit client class allowlist: HID input/events, IOSurface/display capture, image acceleration, and HID user devices. `IOHIDResourceDeviceUserClient` is the one `IOHIDUserDeviceCreate` opens for the virtual pointer (`screen click`, `screen scroll`, the `pointer` calls); without it the kernel logs `deny(1) iokit-open-user-client IOHIDResourceDeviceUserClient` and the device is refused. Verified on an iPadOS 26.6.2 vphone, where `com.apple.developer.hid.virtual.device` was not needed. |

OCR uses Vision and the captured image; there is no separate OCR entitlement in this profile. A host's normal UIKit presentation, privacy strings, and user permission flows remain the host's responsibility.

## Services, logs, and system inspection

| Key | CLI value | Intended role |
| --- | --- | --- |
| `com.apple.private.xpc.launchd.per-user-lookup` | `true` | Query services in the foreground user's launchd domain. |
| `com.apple.private.xpc.service-configure` | `true` | Required for service mutations such as start and stop. Declaring it does not grant every launchctl operation; launchd also checks the calling process and its privileges. |
| `com.apple.private.xpc.service-attach` | `true` | Required for kickstart on iOS 27. With service-configure alone launchd returned status 144; adding this key let the same binary kickstart a running test job. |
| `com.apple.private.xpc.launchd.userspace-reboot` | `true` | Userspace reboot request capability; root is also required. |
| `com.apple.private.logging.stream` | `true` | Unified log streaming. |
| `com.apple.diagnosticd.stream` | `true` | Diagnostic service log stream access. |
| `com.apple.private.logging.diagnostic` | `true` | Diagnostic logging client profile. |
| `task_for_pid-allow` | `true` | SpringBoard task access for the root-only `passcode unlock --dismiss` path; process listing still uses sysctl/proc APIs. |
| `com.apple.private.cs.debugger` | `true` | Debugger profile used by Dopamine's hookd. Adding it alone did not resolve the measured task-control denial. |
| `proc_info-allow` | `true` | Process metadata/executable path inspection. |
| `com.apple.system-task-ports` | `true` | System task access for standalone full unlock. Profile follows opainject; individual necessity remains to be isolated on-device. |
| `com.apple.system-task-ports.control` | `true` | Control task access for the temporary SpringBoard execution context. |
| `com.apple.private.thread-set-state` | `true` | Temporary thread state setup and restoration for full unlock. |
| `com.apple.private.kernel.get-kext-info` | `true` | Retained kernel inspection profile; current IORegistry traversal does not expose a kext query API. |
| `com.apple.private.network.statistics` | `true` | Retained network inspection profile; packet capture uses BPF and requires device access/root. |
| `com.apple.private.security.storage.DiagnosticReports.read-write` | `true` | Diagnostic report storage access; crash commands read reports. |
| `com.apple.CommCenter.fine-grained` | `spi`, `data-allowed-write` | CoreTelephony policy query SPI and per-app data-policy write capability. |
| `com.apple.powerd.lowpowermode.allow` | `true` | Connecting to powerd's Low Power Mode service to turn it on or off. Verified on iOS 18.5: without it powerd rejects the connection. |
| `com.apple.timed` | `true` | Sending timed commands, here turning the automatic time zone off before `device timezone set` and on for `device timezone automatic on`. timed checks it for every command it does not let any client send (read from timed in iOS 27.0.1). |
| `com.apple.tzlink.allow` | `true` | Asking tzlinkd to re-point `/var/db/timezone/localtime` for `device timezone set`; tzlinkd refuses a client without it (read from tzlinkd in iOS 27.0.1). |
| `com.apple.private.amfi.developer-mode-control` | `true` | Arming Developer Mode through amfid, as vphoned does. Reading the status does not need it (verified on iOS 18.5); arming was not run on a test device. |

Do not combine the task-control profile with `com.apple.system-task-ports.read`.
On the physical iOS 17.1.1 phone, the latter restricted icli to read access:
control requests for both SpringBoard and icli itself returned Mach 5. With
the same binary, signing tool and executable path, removing only that key
passed the full-unlock preflight, restoring it reproduced the denial, and
removing it again passed. No passcode was submitted in these comparisons.

## Control Center toggles

`icli cc` reaches each toggle through the service Control Center's module
uses. Each key was measured on the iOS 17.1.1 phone: with it the change read
back from a second process and showed in Control Center, without it the
change failed. Cellular data and Personal Hotspot need nothing beyond the
CommCenter and process keys above; the flashlight needs no key.

| Key | CLI value | Intended role |
| --- | --- | --- |
| `com.apple.SystemConfiguration.SCPreferences-write-access` | `com.apple.radios.plist` | Writing Airplane Mode through RadiosPreferences. Without it the setter returns and nothing changes. |
| `com.apple.wifi.manager-access` | `true` | Reading and setting Wi-Fi power through wifid's manager client. wifid keeps a power change only from a caller named SpringBoard, Preferences, mobilewifitool or sharingd, so icli sends it under the name Preferences; from any other name the radio drops for a few seconds and comes back on. |
| `com.apple.bluetooth.system` | `true` | Attaching BluetoothManager to bluetoothd; without it the manager never becomes available. |
| `com.apple.private.airdrop.settings` | `true` | Reading and setting AirDrop receiving through SharingUI's discovery controller. |
| `com.apple.avfoundation.allow-system-wide-context` | `true` | Reading the system screen output context, the source of Control Center's screen mirroring state. |
| `com.apple.private.donotdisturb.mode.assertion.client-identifiers` | `com.apple.donotdisturb.control-center.module` | Taking a Focus assertion as Control Center's module. donotdisturbd keeps an assertion after its process exits only for client identifiers listed with DNDAssertionsPersist in its user-toggles preload bundle; icli's own identifier lost its Focus when icli exited. |
| `com.apple.private.donotdisturb.mode.assertion.user-requested.client-identifiers` | `com.apple.donotdisturb.control-center.module` | Taking and ending user-requested Focus assertions, as Control Center's toggle does. |
| `com.apple.private.donotdisturb.state.request.client-identifiers` | `com.apple.donotdisturb.control-center.module` | Reading whether a Focus is on and which one. |
| `com.apple.private.donotdisturb.settings.request.client-identifiers` | `com.apple.donotdisturb.control-center.module` | Listing the Focus modes `cc set focus <name>` accepts. |

## Privacy permissions

| Key | CLI value | Intended role |
| --- | --- | --- |
| `com.apple.private.tcc.manager` | `true` | Required for `app permission` and `app reset` to read, grant, deny and reset an app's TCC permissions; without it tccd returns no entries and refuses changes (verified on iOS 17.1.1). |

## Location

| Key | CLI value | Intended role |
| --- | --- | --- |
| `com.apple.locationd.simulation` | `true` | Required for `location set` and `location clear`: without it locationd silently ignores `CLSimulationManager` requests, even from root (verified on iOS 18.5). |
| `com.apple.locationd.effective_bundle` | `true` | Required for `location get`: it lets the CLI read as a System Services location bundle, because locationd never authorizes a bare executable (verified on iOS 18.5). |
| `com.apple.locationd.authorizeapplications` | `true` | Required for `app permission` and `app reset` to read and set an app's location authorization through `CLLocationManager`; without it locationd ignores the change (verified on iOS 17.1.1). |

`com.apple.locationd.preauthorized` is not in the profile: on iOS 18.5 it neither authorizes a bare executable nor is needed once the client names a location bundle.

## Keychain

| Key | CLI value | Intended role |
| --- | --- | --- |
| `keychain-access-groups` | `icli.test`, `com.korboy.icli.unlock` | Separate access groups for test credentials and the explicitly provisioned device-local unlock credential. |
| `com.apple.keystore.access-keychain-keys` | `true` | Retained Keychain client capability; independent necessity is unverified. |
| `com.apple.private.security.system-keychain` | `true` | Retained system Keychain capability; acceptance only operates on fixture items in `icli.test`. |

## Keybag

| Key | CLI value | Intended role |
| --- | --- | --- |
| `com.apple.keystore.device` | `true` | `device passcode unlock`: the keystore grants `MKBUnlockDevice` to holders of this key. On iOS 27.0.1 SpringBoard, demod (which imports `MKBUnlockDeviceWithACM`) and sharingd carry it. Reading the lock state and failed-attempt counter (`device passcode status`) is not expected to need it; on macOS an unsigned tool reads them. Verified on a physical iPhone 15 Pro, iOS 17.3.1 with RootHide: with this key, mobile unlocks the keybag with the right passcode, and a wrong one counts as one failed attempt. |

The shipped CLI's access-group entitlement lists only `icli.test`. The library accepts a `group` argument and relies on the host's granted entitlements and system Keychain checks. A consumer's own identity/signing configuration does not automatically grant `icli.test`. Keep real credentials out of the acceptance fixture namespace and logs. This profile and test suite do not certify access to other apps' credentials.

`listKeychainDatabaseMetadata` and `sec keychain database` read only SQLite index metadata from the system Keychain file. Their access is controlled by filesystem permissions, not an additional entitlement. An IcliKit process opens `/var/Keychains/keychain-2.db`; the RootHide bootstrap shell sees it at `/rootfs/var/Keychains/keychain-2.db`. The signed CLI can run with `sudo` when that file is restricted to `_securityd`.

## Verification and scope

`make all` signs the CLI with the authoritative file. `scripts/check-packages.sh` extracts the signed entitlements using `ldid -e`, compares the entire plist with that file, and verifies both iOS DEB layouts contain the same executable and the tvOS DEB the tvOS executable, which is signed with the same file. [The acceptance report](rootless-acceptance.md) identifies the fully tested binary and device. RootHide service inspection has been checked on iOS 18.5; its full privileged acceptance suite remains pending.

`scripts/check-entitlements.py` checks that this inventory includes every key and exact configured value, so additions or changes require a documentation update. A matching inventory is not proof that a platform will grant an entitlement or that an entry is individually required.
