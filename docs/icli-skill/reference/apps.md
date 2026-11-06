# Apps: app, url, sb

## app

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `app list` | Installed apps with bundle ID, name, version, path and `type` | `--user` (only `type: User`, the user's apps) | no | unlocked |
| `app search <query>` | Apps whose name or bundle ID matches | | no | unlocked |
| `app running` | Live app processes with PIDs, from RunningBoard when available (`source` reports a process-list fallback) | | no | unlocked |
| `app frontmost` | Foreground app bundle ID, `name`, `pid`, with `verified` and `source`; the home screen may report `com.apple.springboard` with `verified: false` | | no | unlocked |
| `app info <bundle-id>` | LaunchServices record: bundle path, executable, version, entitlements | | no | unlocked |
| `app launch <bundle-id or name>` | Launch and wait up to 5 s for the app to be frontmost. Any option here lasts one launch and stops a running app first | `--arg <value>` and `--env NAME=VALUE` (repeatable; write a dash value as `--arg=-Flag`), `--language fr`, `--locale fr_FR`, `--probe` (inject the probe agent, for `probe --app`), `--wait-foreground`, `--timeout 15` (0–60, how long `--wait-foreground` waits) | no | unlocked |
| `app relaunch <bundle-id or name>` | Stop the app, start it, and verify a new process is in front; reports `old_pids`, `pid` and `launched_at` (pass it to `log crashes --since`) | `--timeout 15` | no | unlocked |
| `app open <url>` | Open a URL, optionally in a specific app | `--bundle <bundle-id>` | no | unlocked |
| `app kill <bundle-id>` | SIGTERM the app's processes and wait for them to exit | `--force` required | no | unlocked |
| `app permission get <app>` | Privacy permissions: `granted` or `denied` per name, and `location` as `while_using`, `always` or `denied`; one never asked is absent | | no | any |
| `app permission grant\|deny <app> <names…>` | Set permissions without the system prompt | names: `camera`, `microphone`, `photos`, `photos-add`, `contacts`, `calendar`, `reminders`, `motion`, `bluetooth`, `speech`, `media-library`, `face-id`, `tracking`, `focus`, `nearby`, `siri`, `location` (While Using), `location-always` | no | any |
| `app permission reset <app> [<names…>]` | Back to never asked, so the app's next request shows the prompt again; no names resets them all | | no | any |
| `app reset <app>` | Stop the app, empty Documents, Library, tmp and SystemData in its data container, clear its preferences through cfprefsd, and reset its permissions; keychain items and group containers stay, as when an app is deleted | `--force` required, `--keep-permissions` | no | any |
| `app install <path>` | `.deb` → native package install; `.ipa` → install into the bootstrap and register; `.app` → register | `--container` installs an `.ipa` into its own app container (see below); `--registration user\|system` (default user) | required for .deb and .ipa | unlocked |
| `app uninstall <bundle-id>` | Remove an app that icli installed from an IPA, with its app and data containers for a `--container` install | `--force`; `--package` treats the argument as a Debian package name (needs `--force`) | required | unlocked |
| `app register <path.app>` | `uicache -p`: register one bootstrap or icli-installed bundle with its entitlements, containers and plug-ins, and read the record back; refuses Apple's and other installers' apps | | usually | any |
| `app unregister <path.app>` | Unregister one bundle | `--force` required | usually | any |
| `app refresh` | `uicache -a`: register new, moved, changed or incompletely registered apps, drop stale ones, and skip Apple's and other installers' apps; fails with `refresh_incomplete` when a record still differs | `--directory <dir>` (default: the bootstrap's /Applications) | usually | any |
| `app unregister-dir <dir>` | Unregister every app directly inside a directory | `--force` required | usually | any |
| `app network get <bundle-id>` | Wi-Fi and cellular data policy | | no | any |
| `app network repair <bundle-id>` | Set both policies to always-allow and read them back | | usually | any |
| `app handlers <url-or-scheme>` | Apps that handle a URL or scheme | | no | unlocked |
| `app schemes` | Every registered URL scheme | | no | unlocked |
| `app binary <bundle-id>` | Main executable: path, SDK, minimum OS, encryption, signing error | | no | unlocked |
| `app data <bundle-id>` | Data container path | | no | unlocked |

`<app>` is a bundle ID or an installed app's display name. iOS stops a running app when any of its permissions change, as Settings does, so launch it again afterwards. Location goes through locationd, the others through TCC.

### Container installs

`sudo icli app install <file.ipa> --container` lays the app out like an App Store app: a bundle container under `/var/containers/Bundle/Application/<UUID>/` with an `_icli` marker, a data container, and a LaunchServices registration with its plug-ins and group containers. The output has `bundle_path`, `bundle_container`, `data_container`, `containerized` (sandboxed in the data container), `registration`, `plugins` and `upgraded`.

- icli does not re-sign the app. The IPA must already carry a signature this device runs; custom firmware may run an ad-hoc signed app from the bootstrap but not from an app container, and then `app launch` fails although the install succeeded.
- Installing again upgrades the app in place and keeps its data. Only apps with an `_icli`, `_VPhone`, `_TrollStore` or `_TrollStoreLite` marker are replaced or removed; App Store, system and bootstrap apps with the same bundle ID are refused.
- A failed install removes the containers it created and restores the previous version.
- `app uninstall --force` deletes the bundle container and the data containers of the app and its plug-ins through MobileContainerManager. Group containers, which other apps may share, are kept.

## url

| Command | Purpose | Root | Screen |
| --- | --- | --- | --- |
| `url open <url>` | Open a URL in its registered app; `--check-changed` then waits (frame by frame, `--timeout 5`) and reports `screen_changed` and `changed_ms`, with `screen_changed: false` (not a failure) when nothing changed | no | unlocked |
| `app settings <bundle-id or name>` | Open Settings at the app's own page (permissions, notifications, its settings) and confirm Settings shows it; `error: no_settings_page` when it has none (iOS lists only apps with something to set there). `--timeout 5` | no | unlocked |

### Settings pages

`icli url open 'prefs:root=<page>'` opens these pages, each confirmed on iOS 17.1.1:

| Page | `<page>` | Page | `<page>` |
| --- | --- | --- | --- |
| Wi-Fi | `WIFI` | About | `General&path=About` |
| Bluetooth | `Bluetooth` | Software Update | `General&path=SOFTWARE_UPDATE_LINK` |
| Cellular | `MOBILE_DATA_SETTINGS_ID` | Keyboards | `General&path=Keyboard` |
| Personal Hotspot | `INTERNET_TETHERING` | Tracking | `Privacy&path=USER_TRACKING` |
| Notifications | `NOTIFICATIONS_ID` | Language & Region | `General&path=INTERNATIONAL` |
| Sounds & Haptics | `Sounds` | Date & Time | `General&path=DATE_AND_TIME` |
| Focus | `DO_NOT_DISTURB` | VPN & Device Management | `General&path=ManagedConfigurationList` |
| Screen Time | `SCREEN_TIME` | Privacy & Security | `Privacy` |
| General | `General` | Location Services | `Privacy&path=LOCATION` |
| Display & Brightness | `DISPLAY` | Photos | `Privacy&path=PHOTOS` |
| Accessibility | `ACCESSIBILITY` | Camera | `Privacy&path=CAMERA` |
| Wallpaper | `Wallpaper` | Contacts | `Privacy&path=CONTACTS` |
| Siri & Search | `SIRI` | Calendars | `Privacy&path=CALENDARS` |
| Battery | `BATTERY_USAGE` | Reminders | `Privacy&path=REMINDERS` |
| Motion & Fitness | `Privacy&path=MOTION` | | |

## sb (SpringBoard)

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `sb uicache` | `app refresh` for the bootstrap's /Applications | | usually | any |
| `sb respring` | Restart SpringBoard and wait for the new process | | no | any |
| `sb system-apps get` | Whether non-default system apps are visible | | no | any |
| `sb system-apps set <on\|off>` | Show or hide them; the result says whether a respring is needed | | usually | any |
