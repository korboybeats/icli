---
name: icli
description: Command map for icli, the on-device CLI that controls and inspects an iPhone or iPad running custom firmware. Use it when you drive or inspect such a device over SSH: tapping, typing, reading the accessibility tree, screenshots and OCR, launching or installing apps, files, logs, Debian packages, launchd services, reboots and device settings. It maps an intent to the exact `icli` command, with the sudo and screen-state rules for each command.
---

# icli command map

icli runs **on the device**. Run every command in an SSH session on the device, for example `ssh mobile@<device> 'icli device info'`. It prints JSON on stdout. Add `--human` for readable text. To read the screen and decide what to tap, add `--compact` to `ui tree` or `screen ocr`: one line per element, about a sixth of the JSON's size. `icli <group> --help` and `icli <group> <command> --help` list every option.

The tables below mark each command with two properties:

- **Root**: `required` means icli refuses to run without root (use `sudo icli …`). `usually` means the command runs, but the files or launchd domain it changes normally need root. `no` means it works as the mobile user.
- **Screen**: `unlocked` means the command exits with code 2 (`device_locked`) while the device is locked or its screen is off. `any` means it also runs while the device is locked.

Per-group detail: [interaction](reference/interaction.md) (screen, ui, input, button, clipboard), [device](reference/device.md) (device, cc, lock and unlock, location, notify), [apps](reference/apps.md) (app, url, sb), [files and logs](reference/files-logs.md) (fs, log), [packages](reference/packages.md) (pkg), [system](reference/system.md) (svc, prefs, account, env, proc, sec, net, tests, probe, and session, batch, status and lease for test runs).

## Quick index

| I want to… | Command |
| --- | --- |
| Check whether the screen is on and unlocked | `icli screen info` (read `locked`, `screen_off`) |
| Check lock, front app, keyboard, overlay and owner-only prompt in one call | `icli status` (`springboard_pid` and `boot_time` change after a respring or reboot) |
| Wake the screen | `icli button wake` (does not remove a passcode) |
| Lock the phone | `icli lock` |
| Unlock with the saved passcode | `sudo icli unlock` (`--check` tests without unlocking) |
| Find which app is in front | `icli app frontmost` (bundle ID, name, pid) |
| Find an app's bundle ID | `icli app search <name>` or `icli app list` (`--user` for the user's apps only) |
| Launch an app by its name | `icli app launch Settings` (a bundle ID also works; two visible apps with the name are refused) |
| Launch an app once with arguments, environment or a language | `icli app launch <bundle-id> --arg=-Flag --env NAME=VALUE --language fr --locale fr_FR` (stops it first) |
| Launch an app and wait until it is in front | `icli app launch <bundle-id> --wait-foreground` (verified, with `pid`) |
| Restart an app and prove a new process is in front | `icli app relaunch <bundle-id>` (reports `old_pids`, `pid`, `launched_at`) |
| Open a URL or deep link | `icli url open <url>` (add `--check-changed` to learn whether the screen changed) or `icli app open <url> --bundle <bundle-id>` |
| Quit an app | `icli app kill <bundle-id> --force` |
| Grant, deny or reset an app's permissions without the prompt | `icli app permission grant <app> camera location` / `deny` / `reset <app>` (iOS stops the app) |
| Erase an app's data as a fresh install has it | `icli app reset <app> --force` (also resets its permissions unless `--keep-permissions`) |
| List what is on screen, Home Screen and system overlays included | `icli ui tree --compact` (add `--clickable-only`, `--limit N`, `--source any`, `--hierarchy` to indent by nesting) |
| Check whether only the owner can answer what is on screen | `icli ui prompt` (`human_required`, `kind`) |
| Go back a screen | `icli ui back` (`method` says button or edge swipe) |
| Tap a button by its label | `icli ui tap 'Label' --match exact` |
| Tap by accessibility identifier | `icli ui tap --identifier <id>` |
| Tap and wait for what it should show, in one call | `icli ui tap 'Save' --expect 'Saved'` or `--expect-gone 'Loading'` (also `screen tap`, `ui fill`, `ui alert`, `ui back`) |
| Replace a field's text in one call | `icli ui fill 'Label' --value 'text'` (add `--submit` for Return; `--x X --y Y` for a field at a point) |
| Find an element further down a list | `icli ui scroll-to 'Text' --match exact` |
| Answer a permission or app alert | `icli ui alert accept` / `icli ui alert dismiss` |
| Wait for an element to appear or disappear | `icli ui wait 'Text' --timeout 5` / `icli ui wait-gone 'Loading'` |
| Tap or wait for text missing from the accessibility tree | `icli ui tap --source ocr 'Copy'` / `ui wait --source any 'Copy'` |
| Wait for the screen to change and settle instead of sleeping | `icli screen wait --baseline /tmp/before.jpg --changed --stable` |
| Find which element is at a point | `icli ui at <x> <y>` |
| Tap, double-tap or long-press a point | `icli screen tap <x> <y>` / `double-tap` / `long-press --seconds 1` |
| Swipe or scroll | `icli screen swipe --from-x X --from-y Y --to-x X --to-y Y` |
| Scroll an exact distance, with no fling | `icli screen scroll-by down 200` |
| Open Control Center, the app switcher, Spotlight or Notification Center | `icli screen gesture control-center` / `app-switcher` / `spotlight` / `notification-center`; `screen gesture home` closes them |
| Record the screen | `icli screen record --seconds 10 --output /tmp/r.mov` (or no `--seconds` and send SIGTERM) |
| Put the keyboard away | `icli input hide-keyboard` |
| Drag along a path | `icli screen drag --points '[{"x":10,"y":10},{"x":90,"y":40}]'` |
| Type text into the focused field | `icli input paste 'text'` (fast, Unicode) or `icli input type 'text'` |
| Press Return, Tab, arrows, forward delete or a shortcut | `icli input key return` / `icli input key forward-delete` / `icli input key cmd+a` / `icli input key delete --count 5` |
| Press Home, lock the screen, change volume or bring up Siri | `icli button home` / `button power` / `button volume-up` / `button siri` |
| Read or set the clipboard | `icli clipboard get` / `icli clipboard set 'text'` / `clipboard set --image <file>` |
| Save the clipboard image | `icli clipboard get --image-output /tmp/clip.png` |
| Take a screenshot | `icli screen shot --output /tmp/s.jpg`, `--base64`, or `--stdout` (raw JPEG only); `--output /tmp/s.png` or `--format png` for lossless PNG, `--width 300` for a smaller image |
| Read the text on screen | `icli screen ocr --compact` |
| Read the text in one area quickly | `icli screen ocr --region x,y,width,height --fast --lang en-US` |
| Get a screenshot, OCR and elements together | `icli screen describe` |
| Get the model, iOS version, battery and bootstrap layout | `icli device info` |
| Get brightness, volume and orientation | `icli device brightness get` / `volume get` / `rotation get` |
| Simulate the GPS location, then stop | `icli location set 37.3349 -122.009` / `icli location clear` |
| Read the current location | `icli location get` (check `fresh` and `simulated`) |
| Post a Darwin notification or read its state | `icli notify post <name> [--state N]` / `icli notify get <name>` |
| Switch to light or dark mode | `icli device appearance set dark` |
| Read or flip Control Center toggles (Wi-Fi, Bluetooth, Airplane Mode, cellular data, Hotspot, AirDrop, Focus, flashlight) | `sudo icli cc list` / `sudo icli cc set bluetooth off` / `sudo icli cc toggle flashlight` |
| Change the text size, Reduce Motion, Increase Contrast or Reduce Transparency | `icli device accessibility set --text-size xxl --reduce-motion on` |
| Open a Settings page | `icli url open 'prefs:root=General&path=About'` (table in [apps](reference/apps.md)) |
| Open an app's page in Settings (its permissions, notifications) | `icli app settings <bundle-id or name>` |
| Rotate the screen or lock rotation | `icli device rotation set landscape-left` / `rotation lock set on` |
| Read, write or list files | `icli fs read <p>` / `fs write <p> <text>` / `fs ls <dir>` |
| Read or edit a plist | `icli fs plist <p>` / `icli fs plist-set <p> <key> '<json>'` |
| Read or change preferences (like `defaults`) | `icli prefs read <domain> [<key>]` / `prefs write <domain> <key> <value> --type int` / `prefs delete <domain> <key>` |
| Change an app's own container preferences | `icli prefs write --app <bundle-id> --force <key> <value> --type bool` (stops the app) |
| Capture live logs | `icli log syslog --seconds 5 --process <name> --level error` |
| Find and read crash reports | `icli log crashes --bundle-id <id> [--since 5m] [--kind crash\|spin\|diagnostic\|log] [--limit 5]` then `icli log crash <path> --summary`, or `icli log crash --bundle-id <id> --summary` for its newest crash |
| Run several commands in one process with checks | `echo '[["app","frontmost"],{"argv":["ui","wait","Ready"],"expect":{"found":true}}]' \| icli batch` |
| Keep one icli process open and send it commands as you go | `icli session`, then one line per command: `{"id":1,"argv":["ui","tap","OK"]}` (one JSON line back each) |
| Keep other agents' icli commands off the device during a run | `export ICLI_LEASE=$(icli lease acquire --owner ci \| jq -r .token)`, then `icli lease release` |
| Save the screen and element tree whenever a command fails | `export ICLI_FAILURE_ARTIFACTS=/var/tmp/icli-failures` (the error's `artifacts` names the folder) |
| Install a .deb or .ipa | `sudo icli app install /tmp/x.deb` (or `.ipa`) |
| Uninstall an app or package | `sudo icli app uninstall <bundle-id> --force` / `sudo icli pkg remove <pkg>` |
| Inspect a .deb without installing it | `icli pkg info <file.deb>` |
| Check whether a package is installed | `icli pkg status <name>` / `icli pkg list --filter <text>` |
| Refresh the home screen's app icons | `sudo icli sb uicache` or `icli app refresh` |
| Restart SpringBoard | `icli sb respring` |
| Check a launchd service | `icli svc status <label>` / `icli svc print <label>` |
| Start or stop a service | `sudo icli svc start <label>` / `sudo icli svc stop <label>` |
| Restart a service on its new binary | `sudo icli svc kickstart -k <label>` |
| List processes | `icli proc list --filter <text>` |
| Get bootstrap paths (jbroot, layout) | `icli env info` |
| Capture packets | `sudo icli net capture --seconds 5 --filter 'tcp port 443'` |
| Run the self-tests | `icli tests --expect-layout roothide` |
| Run a JavaScript probe in the icli process | `icli probe -e '<source>'` |
| Restart userspace | `sudo icli device reboot --userspace --force` |

## Speed

- **Batch or keep a session open.** Each separate `icli` process costs about 100 ms just to start on an iPhone 15 Pro Max (`icli --version`), and typical commands take 105–140 ms in all (`screen info` 105 ms, `ui tree` 125 ms, `status` 140 ms), plus the SSH connection: about 0.4 s for a new one over Wi-Fi from a PC, under 0.1 s when SSH reuses a shared connection (ControlMaster). Inside `icli session` the start-up is gone: `screen info` takes about 1 ms, `app frontmost` 3 ms, `ui tree` 10–35 ms and `status` 32 ms. For more than a couple of steps, run `icli batch` (a list of commands, each with an optional `expect`) or keep one `ssh … icli session` open.
- **Wait on events, never sleep.** Use `ui tap --expect`/`--expect-gone`, `ui wait`/`wait-gone`, `screen wait --changed --stable` and `app launch --wait-foreground`. Each returns as soon as the condition holds.
- **Check state in one call.** `icli status` replaces separate `screen info`, `app frontmost` and keyboard checks.
- **Find things below the fold with one command.** Use `ui scroll-to` rather than swipe loops. It pages with accessibility when the view supports that (`method: accessibility`), falls back to touch strokes, and returns a point you can tap.
- **Prefer the accessibility tree to OCR.** `--source ax` (the default) is much faster than `ocr`. Use `any` only when the text may be missing from the tree. Trim `ui tree` with `--clickable-only` and `--limit`.
- **Read the screen with `--compact`.** When you read `ui tree` or `screen ocr` to decide what to tap, add `--compact`. It prints one line per element instead of pretty JSON: on the Home Screen `ui tree` drops from 11.6 KB to 1.8 KB, and `screen ocr --fast` from 5.2 KB to 0.8 KB. Tap the `x,y` from a line straight with `screen tap`; it is the element's tap point. Inside `batch` and `session` a `--compact` step answers with its lines in `text` instead of `result`. Use the JSON instead when a script parses the output, or when you need what the lines leave out: a frame's origin (to pick a `--region`, or a `--x/--y` inside a scroll view), sub-point coordinates or raw `traits`. The line format is in [reference/interaction.md](reference/interaction.md).
- **Use `ui perform` for one exact, verified tap** in an automated test. It needs a known identifier and app, and checks the change you expect.
- **Share the device safely.** When other agents may use the same device, hold `icli lease` and export `ICLI_LEASE` in every shell that runs icli.

## Conventions

- **Output**: one JSON object on stdout, with keys sorted, unless `--compact` (`ui tree`, `ui at`, `ui wait`, `ui wait-gone`, `screen ocr`) or `--human` asks for text. On failure the object is `{"error": <code>, "message": <text>}`, where the code is `failed`, `device_locked`, `force_required`, `unavailable`, `missing_dependency`, `command_failed`, or a command's own code such as `timed_out` or `refresh_incomplete`. `icli probe` prints its own line instead, `{"ok": true, "result": <text>}` or `{"ok": false, "error": <message text>}`, both with `output`, and `icli probe repl` is interactive text. Argument errors come from the argument parser as plain text on stderr.
- **Exit codes**: `0` is success. `2` is `device_locked`. `75` is `leased`: another runner holds the device (see `icli lease`). `1` is any other runtime failure. A result or failure that carries a nonzero `status` exits with that status (1–255). Treat any nonzero exit as a failure and read the JSON.
- **Locked device**: see the Screen column. Most interactive and many read commands need the device unlocked with the screen on. When you get exit 2, run `icli button wake`. If `screen info` still shows `locked: true`, a person has to unlock the device.
- **Destructive commands need `--force`**: `app kill`, `app unregister`, `app unregister-dir`, `app uninstall --package`, `fs rm`, `sec keychain delete` and `device reboot` refuse to run without it and return `force_required`.
- **Coordinates** are UI points in the orientation shown on screen. The origin is the top-left corner as the user sees it. `screen info` gives the current `width`, `height` and `orientation`; an iPad in landscape reports a landscape width. Elements from `ui tree` and boxes from `screen ocr` use the same space, so you can pass an element's `x`,`y` (its tap point, which can sit off the frame's centre) straight to `screen tap`.
- **Paths are physical device paths.** On RootHide, the SSH shell, `scp` and bootstrap tools treat the bootstrap root as `/` and reach the real filesystem under `/rootfs`. A file that icli writes to `/tmp/a.jpg` is `/rootfs/tmp/a.jpg` in that shell. A file you `scp` to `/tmp/x.deb` is `<jbroot>/tmp/x.deb` for icli; `icli env info` reports `jbroot`. On rootless, both views agree and the bootstrap lives under `/var/jb`.
- **Not a shell**: icli never spawns processes. There is no command to run arbitrary programs. Use the SSH shell for that.
- **On an Apple TV** (the `icli-tvos` build): there is no touch screen, pointer or clipboard. `screen tap`/`swipe`/`touch`/`click`, `ui tap`, `clipboard`, `rotation set` and `app network` return `unavailable`. Move focus with `icli input hid 12 66`/`67`/`68`/`69` (up, down, left, right), select with `icli input hid 12 65`, and go back with `icli input hid 12 70`. `button home` is the TV button and `button wake` dismisses the screen saver. Finish Setup Assistant before launching apps.

## Workflows

**Launch, wait, tap, verify**

```sh
icli screen info                                  # locked:false, screen_off:false
icli app launch com.example.app                   # returns once the app is in front
icli ui wait 'Sign In' --timeout 10
icli ui tap 'Sign In' --match exact
icli ui wait-gone 'Loading' --timeout 15
icli ui tree --compact --clickable-only          # confirm the new screen
```

To tap and wait in one call, use `ui tap 'Sign In' --expect 'Welcome'`. To verify a visible change the tree does not show, save `screen shot --output /tmp/before.jpg` before the tap and run `screen wait --baseline /tmp/before.jpg --changed --stable` after it. For text the tree does not expose (system sheets, games), add `--source ocr` to `ui tap`/`ui wait`.

If no element matches, look for the label in `ui tree` (text matching is `contains` by default and ignores case). Use `--index N` to pick the N-th match. As a last resort, tap the element's `x`,`y` (its tap point; the `x,y` on its `--compact` line) with `screen tap`.

**Screenshot plus OCR**

```sh
icli screen shot --output /tmp/screen.jpg         # one pixel per point; --native-resolution for full pixels
icli screen ocr --lang en-US                      # blocks with text, confidence and point frames
icli screen describe                              # image (base64), OCR and ui elements from one call
```

To copy a screenshot to your Mac on RootHide: `scp mobile@<device>:/rootfs/tmp/screen.jpg .`. On rootless: `scp mobile@<device>:/tmp/screen.jpg .`.

**Install a .deb or .ipa**

```sh
scp app.ipa mobile@<device>:/tmp/                 # RootHide: icli sees it as <jbroot>/tmp/app.ipa
sudo icli app install /tmp/app.ipa                # use the path as icli sees it
icli app info <bundle-id>
icli app launch <bundle-id>
sudo icli app uninstall <bundle-id> --force
```

`app install` picks the installer from the file extension: `.deb` installs natively, as `pkg install` does, `.ipa` installs into the bootstrap and registers the app, and `.app` registers the bundle. Maintainer scripts are never run; the result lists them in `scripts_not_run`.

**Recover from a stuck state**

`icli button home` returns to the home screen. `icli app kill <id> --force` quits the app. `icli sb respring` restarts SpringBoard. `sudo icli device reboot --userspace --force` restarts userspace; SSH drops, so reconnect and check `device info`. A full reboot (`device reboot --force` without `--userspace`) can leave the device without SSH until the custom firmware is applied again, so use it only when you are told to.
