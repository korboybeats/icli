# Output and Device State

Commands return JSON on standard output by default. Add `--human` for interactive reading. `ui tree`, `ui at`, `ui wait`, `ui wait-gone` and `screen ocr` also take `--compact`, one line per element (see [Compact Output](interaction.md#compact-output)). Runtime failures return an `error` code and a `message` and exit nonzero. `icli probe` is the exception: it prints its own line `{ok, result | error, output}`, where `error` is the script's error message, and `probe repl` is interactive text. Help, version output, and argument errors are handled separately by the argument parser.

`device info` reports `jailbreak.layout` and `jailbreak.jbroot` as JSON `null` when no bootstrap is detected. A root at `/` is reported as `rootful` only when the root filesystem is mounted read-write. RootHide and rootless retain their discovered bootstrap paths. A process that is not part of the bootstrap, such as a host of the Swift package on the system volume, finds `/var/jb`, or else the one RootHide root (`.jbroot-<16 hex digits>`) in `/var/containers/Bundle/Application`; `jailbreak.source` is then `filesystem fallback` or `filesystem .jbroot`.

The former `shell` command was removed in 0.3.0. Use the filesystem and system command groups for operations implemented by icli.

Most commands reject execution while the device is locked or the screen is off. Device and screen information, screenshots, `button wake`, and live logs remain available. `button wake` wakes the screen and, without a passcode, dismisses the lock screen; it does not enter a passcode, and it does nothing when the device is already awake and unlocked. On tvOS, which has no lock screen, it also dismisses the screen saver, and `app frontmost` reports the screen saver, `com.apple.IdleScreen`, while it runs.

Audio buttons try hardware events first and fall back to the system audio controller when needed. Their JSON reports the method and resulting state. `button mute` toggles the active audio category's mute state; physical ringer-switch behavior has not been verified.

## Test Runs

`icli status` returns lock and screen state, the app in front, whether the keyboard, a SpringBoard overlay or an owner-only prompt is up, and `springboard_pid` and `boot_time`. A runner that compares the last two between steps knows another agent resprang or rebooted the device under it.

A lease blocks interaction and shared-state changes by other runners. Background file work and inspection run without its token and do not renew it. Guarded commands need `ICLI_LEASE=<token>` and renew the holder’s idle time; background-only observers must renew explicitly. `lease` and `status` remain available. See [command policy and concurrent work](leases.md).

Leases coordinate interactive testing. Install an authorized build through the SSH shell (`dpkg -i` or `trollinst`) without acquiring or taking over an existing testing lease.

`ICLI_FAILURE_ARTIFACTS=<dir>` makes every failed command save `error.json`, `screen.jpg` and `tree.json` in a new folder under `<dir>`, named in the error's `artifacts`.

## Paths on RootHide

icli reads and writes real filesystem paths. On RootHide, the bootstrap's shell, `scp`, and other tools treat `/` as the bootstrap root and reach the real filesystem under `/rootfs`. A file that icli writes to `/tmp/screen.jpg` therefore appears in the shell as `/rootfs/tmp/screen.jpg`. To pass a file from the shell to icli, prefix its path with the `jbroot` value that `icli env` reports.
