# Native lock command

`icli lock` calls IcliKit's `lockDevice()` and is allowed while locked. It uses
the existing HID power-button operation once when the observed screen is on,
then checks the existing SpringBoard lock/blanking status for up to three
seconds. Success requires both `locked: true` and `screen_off: true`.

An already locked and blanked device returns success with `requested: false`
and `already_locked: true`. An off screen with an unconfirmed lock state is
refused without input. A sent request whose result is unconfirmed returns
status/exit 3 and the final observed state. There is no automatic retry. tvOS
returns unavailable. The checks and power event are separate, so a concurrent
screen-state change can still affect the event; the result is always verified
before reporting success. No cross-process atomicity is claimed.

The existing raw `icli button power` and saved-credential `icli unlock` commands
retain their behavior. No unlock policy, Keychain credential, entitlements or
failure ledger were changed for this feature.

## Validation, 2026-10-31

Built and installed the release arm64 + arm64e executable. Import/deployment-floor
checks passed. Installed/local SHA-256:
`ee1e7ee40a282ed6ef46bf6920fc06e871687781f60e14cc3e3ba16e0d802b4d`.
`icli --help` registration and the installed `icli lock --help` describe the new
command and its result. Code anchors: `Sources/IcliKit/Device/Lock.swift` and
`Sources/icli/LockCommands.swift`.

On rootless iPhone16,2 / iOS 17.1.1:

- Unlocked/screen-on -> `icli lock` confirmed locked/screen-off.
- A separate `device passcode status` query confirmed both states.
- Repeating `icli lock` sent no input and the phone stayed locked/screen-off.
- Waking the lock screen, then running `icli lock`, blanked it again.
- `icli unlock` then performed a full unlock from the existing phone Keychain
  credential, with zero keybag/ledger failures and unchanged SpringBoard PID.

Evidence: `.build/lock-command/build.log` and `device.json`. Tests left the phone
awake/unlocked. No commit, push, CI or release was performed. Other iOS versions,
devices, no-passcode behavior and concurrent GUI changes were not device-tested.
