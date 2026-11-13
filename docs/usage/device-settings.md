# Location, Power, and Preferences

```sh
icli location set 37.3349 -122.0090
icli location get
icli location clear
icli device low-power set on
icli device appearance set dark
icli device accessibility set --text-size xxl --reduce-motion on
icli device timezone set Asia/Shanghai
icli notify post com.apple.springboard.lockcomplete
icli notify get com.apple.springboard.lockstate
icli device devmode get
icli prefs read com.apple.springboard SBShowBatteryPercentage
icli prefs write example.domain Enabled true --type bool
icli prefs delete example.domain Enabled
```

## Control Center Toggles

```sh
icli cc list
icli cc get focus
icli cc get silent
icli cc set silent on
icli cc set silent off
icli cc toggle silent
icli cc set bluetooth off
icli cc set airdrop everyone
icli cc set focus sleep
icli cc set flashlight 0.5
icli cc toggle hotspot
```

`icli cc` reads and sets the toggles in Control Center: `airplane`, `wifi`, `bluetooth`, `cellular`, `hotspot`, `airdrop`, `focus`, `silent`, `flashlight`, `mirroring` (read-only), and the `rotation-lock`, `low-power` and `appearance` settings that `icli device` also reaches. Each command answers with the state read back after the change, plus `changed`. AirDrop takes `off`, `contacts` or `everyone`; Everyone reverts to contacts after 10 minutes. Focus takes `on` (Do Not Disturb), `off` (ends every active Focus, as the Control Center button does) or a Focus name from `cc get focus`. The flashlight takes `on` (Control Center's last level), `off` or a level from 0 to 1. Changes persist after icli exits and show in Control Center and Settings. Turning Wi-Fi off or Airplane Mode on drops an SSH session that runs over Wi-Fi; run those from a detached script that restores the state. The entitlements each toggle needs are listed in [entitlements](../entitlements.md#control-center-toggles).

`silent on` means Silent mode enabled (ringer muted); `silent off` disables Silent
mode (ringer unmuted). These commands use native services without opening Control
Center, pressing buttons or changing Media, Ringtone, Alarm or Siri volume.
`get` returns `{"toggle":"silent","state":"on","enabled":true}` when muted.
`set` and `toggle` also return `changed`; repeated sets return `changed: false`
without another write. A write succeeds only after the native state reads back
as requested within three seconds. Missing/unknown native state returns
`unavailable`; an unconfirmed change returns `failed` and exits nonzero.
This native path requires iOS 17+ and compatible APIs. Devices with a physical
ringer switch may refuse Control Center client writes; refusal is reported as
a failure. See [native evidence and validation](../development/silent-mode-validation.md).
Reads can run alongside another task's lease; writes require its token while
held. The same commands work as ordinary `batch` and `session` steps.

A simulated location applies to every app and stays on after icli exits, until `location clear`. `notify post` posts a Darwin notification to every observer, optionally storing a `--state` value first; names that notifyd reserves, such as those under `com.apple.system.`, need root. `device devmode enable` asks the system to turn Developer Mode on after the next restart and does nothing when it is already on. `device timezone set` turns Set Automatically off and switches the system time zone; running apps follow at once, and `device timezone automatic on` hands it back to the system. `prefs` commands use mobile's preferences by default, including under `sudo`; `--user root`, `current` or `any` choose another set, and a `.plist` path works as a domain. Writes go through cfprefsd, so running apps see them.

## Audio Output

```sh
icli cc audio list
icli cc audio select '<route-uid>'
icli cc audio select '<route-uid>' --timeout 15
```

Use an exact, case-sensitive UID from `audio list`, which returns
`routes: [{name, uid, selected}]` and `selected_uid` (null if there is no single
selected output). Names can be identical; selection uses only the UID. Outputs
are discovered each time from the system's Audio/Video routes. Commands work
with the screen locked and obey the normal testing lease.

Selection passes the original native route dictionary with an empty password.
It waits up to 8 seconds by default (`--timeout` accepts greater than 0 through
60 seconds), waking on native route-change events when available and rereading
the native state. An accepted request alone is never success. A successful
response includes the fresh route list, `selected_uid`, `requested_uid`,
`previous_uid`, and `changed`. Selecting the already selected UID returns
`changed: false` without sending another request.

Failures exit nonzero: `route_unavailable` means the exact UID is absent or
disappeared, `route_rejected` means the native service refused it, `timed_out`
means acceptance was not confirmed before the deadline, and `unavailable`
means the native route API/state cannot be used. When available, failures
include the last native route list and selected UID. A timed-out request may
still complete later; use `audio list` to check. Password/PIN entry is not
supported by these commands.

These commands do not write volume settings, start playback, invoke Siri or
toggle Bluetooth. iOS applies its existing per-output volume when routes change.
To restore an output after testing, save its `selected_uid` before switching
and select that UID afterward.

## Unlock with a Passcode

To lock the phone and turn off the screen:

```sh
icli lock
```

It checks the resulting locked/screen-off state. If already locked and screen-off,
it returns success without sending input. Otherwise it sends one power-button
action while the screen is on and observes for up to three seconds. Exit 3 means
the action was sent but the requested state was unconfirmed; it does not retry.
An off screen with an unconfirmed lock state is refused without sending input.
The state can still change between the check and the power event. tvOS is
unsupported. `icli button power` remains the raw power-button command.

### Unlock directly from the phone terminal

After one-time provisioning, run this in a **root phone terminal**:

```sh
icli unlock
```

It uses the credential explicitly saved in this phone's Keychain and dismisses
the lock screen. It never reads stdin or prompts for the passcode. The existing
failure budget, rejected-passcode ledger and no-retry policy still apply.

On the configured Windows/WSL workstation, provision from the existing vault
without typing the passcode again:

```sh
icli-unlock --provision-phone
```

This verifies the phone identity on the same SSH connection, then sends the
vault credential through stdin to `icli unlock --store-from-stdin`. Provisioning
saves the credential without making an unlock attempt. Ordinary Windows
`icli-unlock` behavior is unchanged. Once provisioned, the phone command works
without Windows, SSH or a helper process.

The Keychain item uses the separate `com.korboy.icli.unlock` access group, service
`com.korboy.icli.device-passcode`, and `AfterFirstUnlockThisDeviceOnly` accessibility.
It does not synchronize or migrate to another device. After a restart, manually
unlock once before this Keychain item becomes available. Owned input buffers
are wiped; Security/Foundation can retain internal copies outside icli's control.

```sh
icli unlock --check          # access/policy preflight; no unlock attempt
icli unlock --forget-stored  # delete only the saved credential, not the failure ledger
```

Missing or inaccessible storage returns an error immediately, including when
stdin remains open. After changing the phone's passcode, update the Windows
vault and provision the phone again. Explicit stdin/file/hidden-prompt commands
below remain available and do not implicitly save their input.

### Explicit passcode input

For test automation, `device passcode unlock` unlocks the keybag with a passcode you supply. icli never guesses, generates or iterates passcodes, and it refuses an attempt that could lock the device out. See [the design notes](../development/passcode-unlock.md) for the rationale and what is still unverified.

```sh
icli device passcode status
printf '%s\n' "$PASSCODE" | icli device passcode unlock --passcode-stdin
icli device passcode unlock --passcode-file ~/.icli-passcode   # chmod 600
icli device passcode unlock                                    # prompts on a terminal, no echo
icli device passcode unlock --dismiss                          # root; full lock-screen unlock
icli device passcode unlock --passcode-stdin --dismiss         # code supplied through SSH/stdin
icli device passcode unlock --passcode-stdin --check < ~/.icli-passcode
icli device passcode forget --force
```

The passcode never goes in argv. `--passcode-file` refuses a file that is not regular, not owned by you or root, or open to group or others. Nothing reaches the keybag when it is already unlocked, when the same passcode was rejected before, when the larger of icli's recorded failures and the keybag's failed-attempt counter has reached `--max-failures` (default 3, at most 4, so icli never makes the fifth attempt that starts iOS's delays), or while the keybag backs off. Every answer carries `attempts_remaining` and a `hint`.

icli records a salted PBKDF2 digest of each rejected passcode in `/var/mobile/Library/Caches/com.korboy.icli/passcode-ledger.json` (0600), and empties it when an unlock succeeds. After the device passcode changes, a passcode recorded as wrong may now be right: run `forget --force`. The exit status is 0 unlocked, 3 rejected now, 4 rejected before and not retried, 5 refused by a guard, 6 a keybag error that did not count as an attempt.

Without `--dismiss`, unlocking the keybag does not dismiss the lock screen;
`lock_screen` in the answer shows whether it is still up. With `--dismiss`,
icli invokes SpringBoard's unlock method through a temporary execution context
inside SpringBoard. Like UnlockHelper, it uses
`attemptUnlockWithPasscode:mesa:finishUIUnlock:completion:` when available and
otherwise `attemptUnlockWithPasscode:`. It requires
root and a jailbreak that grants control of SpringBoard's task. There is no
installed helper, passcode file, keypad simulation, or subprocess dependency.
The existing ledger and lockout guards run before the request. An unlocked
keybag is insufficient to skip this mode if the lock screen remains.

`--dismiss --check` checks task access and system mappings without executing
code in SpringBoard or sending the passcode. Direct execution was verified on
the physical iOS 17.1.1 test phone. The command verifies the screen is awake and unlocked before
returning `ui_unlocked: true`. It never automatically retries an unlock.

The caller's byte buffer and successfully cleaned-up target request memory are
wiped; Foundation and iOS can make their own temporary copies. This is not a
guarantee that every system-owned copy can be erased. The old UnlockHelper
tweak and its saved passcode file are not used or automatically removed.

## Unattended unlock from Windows/WSL

On this workstation, `icli-unlock` reads the phone's passcode from the current
Windows user's Credential Manager entry and streams it to icli through SSH
stdin. It verifies the phone's UDID on that same connection before executing
the unlock. It does not print the passcode or put it in command arguments.

```sh
icli-unlock          # unlock with the stored credential
icli-unlock --check  # read-only access and policy preflight
icli-unlock --store  # replace the credential using a hidden terminal prompt
icli-unlock --provision-phone  # copy the vault credential into this phone's Keychain
```

The same commands work in Windows Command Prompt and PowerShell on this
workstation. `C:\Users\korbo\.local\bin\icli-unlock.cmd` forwards to the Ubuntu
WSL entry point and preserves its exit status. Its source is
`scripts/icli-unlock.cmd`; the destination folder is already on Windows PATH.

The entry point is `scripts/unlock-from-windows-vault`, with native Windows
credential access in `scripts/windows-unlock.ps1`. `--store` also accepts a
passcode piped through stdin for authorized automation. The credential is
named `Korboy.icli.Passcode/<device UDID>` and persists for the same Windows
user on this computer. It supports unattended Windows unlock and one-time phone
provisioning; native `icli unlock` then reads the phone's Keychain independently.
icli's ordinary stdin and hidden terminal inputs remain available.

The old UnlockHelper passcode and arm files were removed from the connected
phone after migration was verified. The old tweak package remains installed
and is not used by this command.

### App Container Preferences

`prefs read|write|delete --app <bundle-id>` reads and changes the app's own preferences in its data container through cfprefsd, so the result is what the app reads; cfprefsd writes `Library/Preferences/<bundle-id>.plist` a few seconds later. cfprefsd is never restarted: that would drop every process's preference observers, and SpringBoard would then ignore light and dark mode changes until a respring. The app must not be running; `--force` stops it first. `--user` and `--notify` do not apply.

```sh
icli prefs write --app example.bundle.id --force DebugEnabled true --type bool
icli prefs read --app example.bundle.id DebugEnabled
```
