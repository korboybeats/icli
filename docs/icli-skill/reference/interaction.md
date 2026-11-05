# Interaction: screen, ui, input, button, clipboard

Coordinates are UI points in the orientation shown on screen (see `icli screen info`). Every command here except `screen shot`, `screen info` and `button wake` exits with code 2 while the device is locked or its screen is off.

## screen

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `screen info` | Width, height, scale, orientation (degrees), `locked`, `screen_off` | | no | any |
| `screen tap <x> <y>` | Tap one point | `--expect`, `--expect-gone` (see below) | no | unlocked |
| `screen double-tap <x> <y>` | Two taps | `--interval 0.1` | no | unlocked |
| `screen long-press <x> <y>` | Press and hold | `--seconds 0.6` | no | unlocked |
| `screen swipe` | Straight swipe | `--from-x --from-y --to-x --to-y` (all required), `--seconds 0.25`, `--steps 20`, `--no-momentum` | no | unlocked |
| `screen scroll-by <up\|down\|left\|right> <points>` | Scroll content an exact distance by touch, with no fling; long distances take several strokes | `--x`, `--y` (a point in the scroll view) | no | unlocked |
| `screen click <x> <y>` | Click with a virtual pointer, as a trackpad does on an iPad; an iPhone uses the pointer only through AssistiveTouch's pointer devices | `--button`, `--count`, `--hold`, `--hover`, `--normalized` | no | unlocked |
| `screen scroll <x> <y>` | Scroll the view under a virtual pointer by exact deltas, no momentum (iPad; on an iPhone with iOS 17.1.1 it moved nothing, so use `scroll-by`) | `--dx`, `--dy` (positive `dy` moves toward the end of the content), `--seconds`, `--steps`, `--normalized` | no | unlocked |
| `screen pinch` | Two-finger pinch around X Y | `X Y --from D --to D` (points apart; larger `--to` zooms in), `--angle 0`, `--seconds 0.4`, `--steps 20` | no | unlocked |
| `screen drag` | Press, hold, then move along a path | four endpoint options **or** `--points '<JSON [{x,y},…]>'`, `--hold 0.5`, `--seconds 0.3`, `--steps 20` | no | unlocked |
| `screen touch <down\|move\|up> <x> <y>` | One raw finger event; a gesture can span several calls | `--normalized` | no | unlocked |
| `screen touch-sequence` | Several finger events from one process, with exact timing | `--events '<JSON [{phase,x,y,delay_ms},…]>'` (required), `--normalized` | no | unlocked |
| `screen gesture <name>` | System gesture: `home`, `app-switcher`, `control-center`, `notification-center`, `spotlight` | | no | unlocked (`home`: any) |
| `screen shot` | JPEG screenshot, upright | `--output <path>` (default: temporary file), `--stdout` (raw JPEG on stdout only; errors still JSON on stderr), `--base64`, `--native-resolution`, `--check-prompt` | no | any |
| `screen record` | Record a .mov at the panel's full resolution | `--seconds N` (omit to record until SIGINT, SIGTERM or SIGHUP; up to 3600), `--output <path>`, `--fps 30` (1–60), `--codec hevc\|h264` | no | any |
| `screen ocr` | Vision text recognition of the current screen | `--lang <code>` (repeatable; default zh-Hans and en-US), `--min-confidence 0.3`, `--region x,y,width,height` (points; only that rectangle), `--fast` (quicker, less accurate) | no | unlocked |
| `screen describe` | Screenshot (base64), OCR and accessibility elements from one call | | no | unlocked |
| `screen wait` | Wait until the pixels change from a baseline, settle, or both; sees what the tree does not. Save the baseline with `screen shot --output` before the action | `--changed`, `--stable` (give one or both), `--baseline <jpeg>` (default: the screen when it starts), `--stable-for 0.5`, `--region x,y,w,h`, `--threshold 0.001`, `--timeout 10` (0–60; exits 1 with `timed_out`), `--interval 0.05` | no | unlocked |

- `screen touch` and `touch-sequence` take UI points like `screen tap`. With `--normalized`, x and y are 0–1 in the fixed portrait digitizer space, which differs from the UI in landscape; `screen touch` reports the converted point as `digitizer_x`/`digitizer_y`. The touch state is kept by the system, so `touch down` in one call and `touch up` in a later call make one tap, drag or long press. Always finish with `up`. In `touch-sequence`, `delay_ms` (0–60000, default 0) is the pause after that event; `finger_down` in the result is true when the sequence did not end with `up`.
- `screen shot` has one image pixel per point by default. With `--native-resolution` the result includes `coordinate_scale`, which converts pixels to points.
- In `screen ocr`, `blocks` holds each recognized text with its confidence and point frame, in screen coordinates also with `--region`. On an iPhone 15 Pro Max the whole screen took about 0.5 s, `--fast --lang en-US` about 0.2 s, and a 40-point strip about 0.35 s, or 0.2 s with `--fast`. On a device without text recognition the command fails with `unavailable`, as it does on iOS 15 over SSH, where icli has no Metal device for Vision.
- `screen describe` returns `frontmost`, `screen`, `screenshot`, `ocr` and `elements`. Each component can carry its own `error`. If `context_changed` is true, the foreground app changed during the call, so do not combine its parts.

- `screen record` writes `<path>.partial` and renames it when the movie is complete, so a movie at the path is always whole. A stop signal finishes the movie and the command exits 0 with `stopped_by: signal`. `dropped` counts frames the encoder had no room for. Protected content records black.
- `screen gesture home` presses Home, so it closes what is over an app before it leaves the app. `spotlight` needs the Home Screen. `notification-center` shows the Cover Sheet, during which the device reports `locked: true` and most commands exit 2 until `screen gesture home` or `icli unlock` closes it.

## ui (accessibility of what is on screen)

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `ui tree` | Elements with `label`, `identifier`, `value`, `role`, `frame`, `clickable`, `visible` | `--scope auto\|app\|system\|all` (auto: the front app or Home Screen, or whatever covers it, such as an alert or Control Center; system: SpringBoard with the status bar, also reads the Lock Screen and runs while locked), `--source ax\|ocr\|any`, `--lang` (OCR, default zh-Hans and en-US), `--max-elements 250` (1–2000), `--limit N`, `--include-offscreen`, `--clickable-only` | no | unlocked (`--scope system`: any) |
| `ui at <x> <y>` | Element at a point | | no | unlocked |
| `ui back` | Tap the screen's back button, or else swipe in from the left edge; `method` says which, and a swipe may do nothing | `--expect`, `--expect-gone` | no | unlocked |
| `ui prompt` | Whether a prompt only the owner may answer is on screen (`human_required`, `kind`, `source`) | `--source ax\|ocr\|any` (default `any`) | no | any |
| `ui tap [<text>]` | Find an element and tap its centre; refuses ambiguous matches (`error: ambiguous`, with `matches`) | `--identifier <id>`, `--role <role>`, `--match contains\|exact`, `--index N`, `--source ax\|ocr\|any`, `--lang`, `--expect`, `--expect-gone` | no | unlocked |
| `ui perform` | Tap one element once, by exact identifier, in a verified foreground app, and confirm the change you expect | `--app` and `--tap-identifier` (both required), `--expect-appeared`, `--expect-disappeared`, `--expect-value-changed`, `--method touch\|accessibility`, `--timeout 10`, `--interval 0.1`, `--failure-screenshot <path>` | no | unlocked |
| `ui fill [<text>]` | Tap a field, empty it, enter new text | same selectors, `--value <text>` (omit to only empty it), `--submit`, `--expect`, `--expect-gone` | no | unlocked |
| `ui scroll-to [<text>]` | Scroll until an element is on screen and report where, with accessibility paging (`method: accessibility`) where the view supports it, or else touch strokes; the point reported is tappable; stops at the end of the content | same selectors, `--direction down`, `--max-scrolls 10`, `--x`, `--y` | no | unlocked |
| `ui alert <accept\|dismiss>` | Answer the alert on screen, including system permission alerts, and wait until it has closed; refuses passcode, Face ID, Touch ID, Apple Account, Allow Paste, VPN, profile and purchase prompts (`error: human_required`) | `--button <text>` instead of an action, `--expect`, `--expect-gone` | no | unlocked |
| `ui wait [<text>]` | Wait until the element appears | same selectors, `--timeout 10`, `--interval 0.1` | no | unlocked |
| `ui wait-gone [<text>]` | Wait until the element disappears | same as `ui wait` | no | unlocked |

`ui tree` reads what can be reached now (`--scope auto`): the app in front, or the Home Screen or Spotlight, with anything SpringBoard shows over it listed first and marked `scope: system`, and `system_overlay` true. That covers alerts, banners, Control Center and the app switcher. `ui tap` and `ui wait` search the same list, and between equal matches prefer the overlay. `--scope app` and `--scope system` read one side, `system` with the status bar and on the Lock Screen too; `all` reads both. `--source ocr` lists on-screen text instead of the tree, and `--source any` does so when the tree is empty; text has no tap state, so neither takes `--clickable-only`.

Reading the AX tree needs the system's accessibility and automation switches, which are system-wide and stored in the `com.apple.Accessibility` preference domain as `ApplicationAccessibilityEnabled` and `AutomationEnabled`. icli turns on whichever of the two is off before each query and puts both back when the process exits, so the device is left as it was found. A long-running IcliKit host calls `restoreAccessibilitySwitches()` when it stops reading the UI, since a process that is killed never reaches its exit handler. The query that turns them on waits once for the app to load its accessibility bundles, so it is slower than the ones after it. A device whose last icli run was 0.7.1 or earlier may still have them on: `prefs read com.apple.Accessibility ApplicationAccessibilityEnabled` reads the stored value, and `prefs delete` clears it.

Selectors: `<text>` matches an element's label, identifier or value. Matching ignores case and defaults to `contains`. `--identifier` matches an exact identifier or label and takes precedence over `<text>`. One of the two is required. `ui tap` fails with exit 1 when nothing matches.

`--expect <text>` waits after the action until an element whose label, identifier or value contains the text is on screen, and adds that wait to the result as `expect`; `--expect-gone <text>` waits until none does. Give one of them. `--expect-timeout` is 0–60 seconds (default 10). A wait that runs out exits 1 with `error: expect_failed`, and its `action` shows that the action itself ran. Waits check again only after the screen draws a new frame, at most every 0.1 s (`--interval` for `ui wait`), and not at all while the screen holds still; results carry `trigger: frames`, or `trigger: poll` where frame notifications are unavailable and the wait checks every interval instead. A wait that starts during an app switch waits it out.

A tap that lands while an alert is still animating in is dropped, so `ui alert` checks that the alert closed. If the same alert, with the same button and title, is still there a second later, it taps once more, and `attempts` reports 2. An alert still open after that fails with `error: alert_open`. When the alert was found by text recognition, there is no second tap.

## input (to the focused text field)

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `input paste <text>` | Send the whole string as Unicode key events. Does not touch the clipboard | `--clear`, `--submit` | no | unlocked |
| `input hide-keyboard` | Put the software keyboard away and wait until it has gone; does nothing when it is not up (`was_shown`) | | no | unlocked |
| `input type <text>` | Send one grapheme at a time | `--delay-ms 30`, `--clear`, `--submit` | no | unlocked |
| `input key <name>` | One key or chord | | no | unlocked |
| `input hid <page> <usage>` | Raw HID usage: press (down, 100 ms, up), or only one edge | `--down`, `--up` | no | unlocked |

`input hid` takes decimal or `0x` hex, both 1–0xFFFF. Page 7 is the keyboard (`7 4` is `a`, `7 0xE1` is left shift) and page 12 (`0x0C`) is consumer controls (`0x0C 0xE9` volume up, `0x0C 0xEA` volume down). A key sent with `--down` stays down across calls until the matching `--up`, so `input hid 7 0xE1 --down`, `input hid 7 5`, `input hid 7 0xE1 --up` types `B`.

Key names: `return`/`enter`, `delete`/`backspace`, `tab`, `escape`, `space`, `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, and the letters `a`–`z`. Modifiers are joined with `+`: `cmd`/`command`, `ctrl`/`control`, `shift`, `alt`/`option`. Examples: `cmd+a`, `cmd+v`, `shift+tab`.

## button

| Command | Purpose | Root | Screen |
| --- | --- | --- | --- |
| `button home` | Home button: go to the home screen | no | unlocked |
| `button power` | Side button: turns the screen off (locks) | no | unlocked |
| `button wake` | Turn the screen on and, without a passcode, dismiss the lock screen; does not enter a passcode; does nothing when already awake and unlocked | no | any |
| `button volume-up` / `button volume-down` | Hardware volume event, with a fallback to the audio controller | no | unlocked |
| `button mute` | Toggle mute of the active audio category | no | unlocked |

After `button power`, only lock-exempt commands work until `button wake`. If the device has a passcode, `button wake` stops at the lit lock screen and a person has to unlock it. The result reports `locked` and `screen_off` as observed after the wake.

## clipboard

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `clipboard get` | Text (`""` when there is none), `change_count`, `types`, `items`, `has_text`, `has_image`, and `image` (`width`, `height` in pixels, `scale`) when it holds an image | `--image-output <file.png>` also writes the image as PNG and adds `image_path`, `image_bytes`; fails when there is no image | no | unlocked |
| `clipboard set <text>` | Replace the clipboard with text and read it back | | no | unlocked |
| `clipboard set --image <file>` | Replace the clipboard with a PNG, JPEG or HEIC image and check its pixel size | | no | unlocked |

Both `set` forms return the new `get` output; `change_count` rises with every change. Paths are physical: on RootHide, `/tmp/x.png` for icli is `/rootfs/tmp/x.png` in the shell.
