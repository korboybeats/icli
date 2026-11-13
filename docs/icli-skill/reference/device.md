# device

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `device info` | Model, iOS, battery, storage, memory, bootstrap layout | | no | any |
| `device jetsam` | Jetsam bands, jetsam property lists, memory pressure | | usually (without root, `priorities_error` replaces the band list) | any |
| `device brightness get` | Brightness 0–1 | | no | unlocked |
| `device brightness set <value>` | Set brightness (0–1) | | no | unlocked |
| `device volume get` | Volume, active volume and category | `--category Audio/Video` | no | unlocked |
| `device volume set <value>` | Set volume (0–1) | `--category Audio/Video` | no | unlocked |
| `device rotation get` | Orientation name and degrees, rotation lock | | no | unlocked |
| `device rotation set <value>` | `portrait`, `landscape-left`, `upside-down`, `landscape-right` (or 0/90/180/270) | | no | unlocked |
| `device rotation lock get` | Whether orientation lock is on | | no | unlocked |
| `device rotation lock set <on\|off>` | Turn orientation lock on or off | | no | unlocked |
| `device devmode get` | Developer Mode: `enabled`, `armed` (turns on after the next restart), `writable` (the device allows changing it) | | no | any |
| `device devmode enable` | Arm Developer Mode when it is off; returns `already_enabled` and `restart_required`. Does not restart the device | | see notes | any |
| `device passcode status` | Keybag lock state, failed-attempt counter and back-off, and the ledger of rejected passcodes | | no | any |
| `device passcode unlock` | Unlock the keybag with a supplied passcode, read from stdin, a file or the terminal, never from an argument; never retries a passcode rejected before | `--passcode-stdin`, `--passcode-file <path>` (mode 0600), `--dismiss` (root; also dismiss the lock screen), `--check`, `--max-failures 3` | for `--dismiss` | any |
| `device passcode forget --force` | Clear the ledger of rejected passcodes, after the device passcode changes | `--force` required | no | any |
| `device appearance get` | `light` or `dark` | | no | any |
| `device appearance set <light\|dark>` | Switch appearance; waits until the setting reads the new value | | no | any |
| `device accessibility get` | `text_size`, `reduce_motion`, `increase_contrast`, `reduce_transparency` | | no | any |
| `device accessibility set` | Change any of them; waits until they read the new values | `--text-size xs\|s\|m\|l\|xl\|xxl\|xxxl\|ax1…ax5`, `--reduce-motion on\|off`, `--increase-contrast on\|off`, `--reduce-transparency on\|off` | no | any |
| `device low-power get` | Whether Low Power Mode is on (`method: powerd`) | | no | any |
| `device low-power set <on\|off>` | Turn Low Power Mode on or off through powerd, like Control Center; waits up to 3 seconds for its reply, then checks the new state | | no | any |
| `cc list` | Every Control Center toggle with its state; a toggle that cannot be read carries `error` | | yes (tested as root) | any |
| `cc get <toggle>` | One toggle: `state`, `enabled`, and per toggle `level` (flashlight), `mode`/`mode_id`/`modes` (focus), `time_limited` (AirDrop Everyone), `device` (mirroring) | | yes (tested as root) | any |
| `cc set <toggle> <value>` | Set a toggle and read it back; `changed` is false when it already had the value. Toggles: `airplane`, `wifi`, `bluetooth`, `cellular`, `hotspot`, `airdrop` (`off`/`contacts`/`everyone`), `focus` (`on`/`off`/a Focus name), `silent` (`on` means ringer muted; `off` ringer unmuted), `flashlight` (`on`/`off`/level 0–1), `rotation-lock`, `low-power`, `appearance` (`light`/`dark`); `mirroring` is read-only | | yes (tested as root) | any |
| `cc toggle <toggle>` | Flip a toggle; AirDrop flips off↔contacts, focus off↔Do Not Disturb | | yes (tested as root) | any |
| `cc audio list` | Available Audio/Video outputs: `routes: [{name, uid, selected}]`, `selected_uid` | | tested as root | any |
| `cc audio select <route-uid>` | Exact, case-sensitive UID from the list; waits for native selected-state confirmation, returns `changed`, `requested_uid`, `previous_uid` and fresh routes | `--timeout 8` (greater than 0 through 60 seconds) | tested as root | any |
| `device timezone get` | `identifier` (Olson name), `automatic` (Set Automatically), `seconds_from_gmt` | | no | any |
| `device timezone set <identifier>` | Set the time zone to an Olson name such as `Asia/Shanghai` and turn Set Automatically off, as Settings does; running apps and SpringBoard switch at once. Returns `changed` | | no | any |
| `device timezone automatic <on\|off>` | Turn Set Automatically on or off; `on` hands the zone back to timed | | no | any |
| `device network` | Interface addresses | | no | unlocked |
| `device ioreg` | IORegistry dump | `--plane IOService` | no | unlocked |
| `device bootlogo` | Render a screen-sized JPEG 2000 boot logo from a PNG/JPEG mark | `--mark <image>`, `--output <file.jp2>` (both required), `--dark`, `--width`, `--height`, `--mark-points 128` | no | any |
| `device reboot --force` | Full reboot | `--force` required | required | any |
| `device reboot --userspace --force` | Userspace restart (launchd re-exec) | `--force` required | required | any |

Reboot notes:

- SSH usually drops before the JSON arrives, so a disconnect does not prove that the reboot happened. Reconnect and compare `device info` with the values from before.
- After a userspace restart the system and UI processes are new, while the kernel boot time and boot session UUID stay the same. A full reboot changes both.
- A full reboot clears `/tmp`. On semi-untethered custom firmware it can also leave the device without SSH until someone applies the firmware again, so run it only when you are explicitly told to.

Developer Mode notes:

- `devmode get` asks amfid and works as mobile. It matches `sysctl security.mac.amfi.developer_mode_status`. iOS 15 has no Developer Mode: it reports enabled, not armed and not writable without asking amfid, and `devmode enable` answers already enabled.
- `devmode enable` does nothing when Developer Mode is already on or armed. Otherwise it asks amfid to arm it: after the next restart the device asks the user to confirm, and only then is it on. amfid may refuse to arm it without root; the command then fails with `unavailable`. There is no command to turn Developer Mode off.

## lock and unlock

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `lock` | Lock the phone and turn its screen off; a no-op when already locked. Exit 3: input sent, state not confirmed | | no | any |
| `unlock` | Unlock with the passcode saved in this phone's Keychain, with no prompt. After a restart, unlock by hand once first | `--check` (no attempt), `--max-failures 3`, `--store-from-stdin` (provision), `--forget-stored` | required | any |

## location

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `location set <latitude> <longitude>` | Simulate a fixed location for every app, then read it back to confirm | `--altitude 0`, `--horizontal-accuracy 5`, `--vertical-accuracy 5` (-1 = unknown altitude), `--speed`, `--course` (speed and course default to unknown) | no | any |
| `location clear` | Stop simulating | | no | any |
| `location get` | The location CoreLocation reports: coordinates, altitude, accuracies, speed, course, `timestamp`, `age_seconds`, `fresh`, `simulated` | `--timeout 10` | no | any |

Location notes:

- The simulated location stays on after icli exits, for every app and user, until `location clear`. Always clear it when you are done.
- Negative coordinates work without `--`: `icli location set -33.8688 151.2093`. Give a negative altitude as `--altitude=-10`.
- With Location Services turned off, `set` and `get` fail at once with `unavailable` and send nothing to locationd.
- `get` reads as a System Services location bundle, so it needs no permission prompt. `simulated` is CoreLocation's own flag for a software-simulated fix.
- `fresh: false` means no new fix arrived within the timeout and the reading is locationd's last known location. `clear` waits until locationd stops refreshing the simulated fix, but until the next real fix `get` can still return the last simulated location with `fresh: false`.
- A Wi-Fi-only iPad can reject real fixes for about 15 minutes after a simulated location far from the real one. To avoid that, run `location set` with the real coordinates (from `location get` before simulating), then `location clear`.

## notify

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `notify post <name>` | Post a Darwin notification through notifyd, like `notifyutil -p`; `delivered` is whether notifyd delivered it back to icli's own listener | `--state <UInt64>` stores the state first, like `notifyutil -s` | for names notifyd reserves | any |
| `notify get <name>` | A notification's state value, 0 when none was set or nothing holds the name | | no | any |

Notify notes:

- A post reaches every process observing that name, including system daemons. Post only names whose observers you understand.
- notifyd keeps a name's state only while some process is registered for it. `notify post --state` registers only while it runs, so on a name nothing else observes, a later `notify get` reads 0. Names a daemon holds, such as `com.apple.springboard.lockstate`, keep their state.
- notifyd can reserve names for root, such as those under `com.apple.system.`. A post it refuses fails with `unavailable`; on iOS 26 it can instead accept mobile's post and never deliver it, which shows as `delivered: false`. Retry either with `sudo`.

Control Center notes:

- `cc get silent`, `cc set silent on|off` and `cc toggle silent` use native Silent mode state. They preserve Media, Ringtone, Alarm and Siri volumes, verify changes within three seconds, and work in batch/session. Repeated sets report `changed: false`.

- `cc set wifi off` and `cc set airplane on` cut Wi-Fi, so an SSH session over Wi-Fi drops before the answer arrives. Run them from a detached script that restores the state, or over USB.
- `cc set focus off` ends every active Focus, including one a schedule started, like the Control Center button.
- `cc set focus on` turns on Do Not Disturb; the Focus stays on after icli exits.
- `cc set flashlight on` uses the level Control Center last used. The flashlight stays on after icli exits.
- `cc set airdrop everyone` turns itself back to contacts after 10 minutes, as on the device.
- `cc audio select` succeeds only after a native read confirms the exact UID. Missing/disappearing routes return `route_unavailable`, rejection returns `route_rejected`, and unconfirmed acceptance returns `timed_out`; failures exit nonzero. It never writes volume settings, starts playback, invokes Siri or toggles Bluetooth. Native route-change events wake verification where available, with bounded rereads as a fallback. Password/PIN entry is unsupported. Save the original `selected_uid` to restore it after testing.
