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

A simulated location applies to every app and stays on after icli exits, until `location clear`. `notify post` posts a Darwin notification to every observer, optionally storing a `--state` value first; names that notifyd reserves, such as those under `com.apple.system.`, need root. `device devmode enable` asks the system to turn Developer Mode on after the next restart and does nothing when it is already on. `device timezone set` turns Set Automatically off and switches the system time zone; running apps follow at once, and `device timezone automatic on` hands it back to the system. `prefs` commands use mobile's preferences by default, including under `sudo`; `--user root`, `current` or `any` choose another set, and a `.plist` path works as a domain. Writes go through cfprefsd, so running apps see them.

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

The Keychain item uses the separate `com.icli.unlock` access group, service
`com.icli.device-passcode`, and `AfterFirstUnlockThisDeviceOnly` accessibility.
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

icli records a salted PBKDF2 digest of each rejected passcode in `/var/mobile/Library/Caches/com.icli.icli/passcode-ledger.json` (0600), and empties it when an unlock succeeds. After the device passcode changes, a passcode recorded as wrong may now be right: run `forget --force`. The exit status is 0 unlocked, 3 rejected now, 4 rejected before and not retried, 5 refused by a guard, 6 a keybag error that did not count as an attempt.

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

`prefs read|write|delete --app <bundle-id>` edits the app's own preferences file, `Library/Preferences/<bundle-id>.plist` in its data container, keeping the container's owner, then restarts cfprefsd so the app reads the new value. The app must not be running; `--force` stops it first. `--user` and `--notify` do not apply.

```sh
icli prefs write --app example.bundle.id --force DebugEnabled true --type bool
icli prefs read --app example.bundle.id DebugEnabled
```
