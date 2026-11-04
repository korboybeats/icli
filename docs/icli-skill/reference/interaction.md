# Interaction: screen, ui, input, button, clipboard

Coordinates are UI points in the orientation shown on screen (see `icli screen info`). Every command here except `screen shot`, `screen info` and `button wake` exits with code 2 while the device is locked or its screen is off.

## screen

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `screen info` | Width, height, scale, orientation (degrees), `locked`, `screen_off` | | no | any |
| `screen tap <x> <y>` | Tap one point | | no | unlocked |
| `screen double-tap <x> <y>` | Two taps | `--interval 0.1` | no | unlocked |
| `screen long-press <x> <y>` | Press and hold | `--seconds 0.6` | no | unlocked |
| `screen swipe` | Straight swipe | `--from-x --from-y --to-x --to-y` (all required), `--seconds 0.25`, `--steps 20`, `--no-momentum` | no | unlocked |
| `screen scroll-by <up\|down\|left\|right> <points>` | Scroll content an exact distance by touch, with no fling; long distances take several strokes | `--x`, `--y` (a point in the scroll view) | no | unlocked |
| `screen pinch` | Two-finger pinch around X Y | `X Y --from D --to D` (points apart; larger `--to` zooms in), `--angle 0`, `--seconds 0.4`, `--steps 20` | no | unlocked |
| `screen drag` | Press, hold, then move along a path | four endpoint options **or** `--points '<JSON [{x,y},…]>'`, `--hold 0.5`, `--seconds 0.3`, `--steps 20` | no | unlocked |
| `screen touch <down\|move\|up> <x> <y>` | One raw finger event; a gesture can span several calls | `--normalized` | no | unlocked |
| `screen touch-sequence` | Several finger events from one process, with exact timing | `--events '<JSON [{phase,x,y,delay_ms},…]>'` (required), `--normalized` | no | unlocked |
| `screen gesture <name>` | System gesture: `home`, `app-switcher`, `control-center`, `notification-center`, `spotlight` | | no | unlocked (`home`: any) |
| `screen shot` | JPEG screenshot, upright | `--output <path>` (default: temporary file), `--base64`, `--native-resolution`, `--check-prompt` | no | any |
| `screen record` | Record a .mov at the panel's full resolution | `--seconds N` (omit to record until SIGINT, SIGTERM or SIGHUP; up to 3600), `--output <path>`, `--fps 30` (1–60), `--codec hevc\|h264` | no | any |
| `screen ocr` | Vision text recognition of the current screen | `--lang <code>` (repeatable; default zh-Hans and en-US), `--min-confidence 0.3` | no | unlocked |
| `screen describe` | Screenshot (base64), OCR and accessibility elements from one call | | no | unlocked |

- `screen touch` and `touch-sequence` take UI points like `screen tap`. With `--normalized`, x and y are 0–1 in the fixed portrait digitizer space, which differs from the UI in landscape; `screen touch` reports the converted point as `digitizer_x`/`digitizer_y`. The touch state is kept by the system, so `touch down` in one call and `touch up` in a later call make one tap, drag or long press. Always finish with `up`. In `touch-sequence`, `delay_ms` (0–60000, default 0) is the pause after that event; `finger_down` in the result is true when the sequence did not end with `up`.
- `screen shot` has one image pixel per point by default. With `--native-resolution` the result includes `coordinate_scale`, which converts pixels to points.
- In `screen ocr`, `blocks` holds each recognized text with its confidence and point frame. On a device without text recognition the command fails with `unavailable`, as it does on iOS 15 over SSH, where icli has no Metal device for Vision.
- `screen describe` returns `frontmost`, `screen`, `screenshot`, `ocr` and `elements`. Each component can carry its own `error`. If `context_changed` is true, the foreground app changed during the call, so do not combine its parts.

- `screen record` writes `<path>.partial` and renames it when the movie is complete, so a movie at the path is always whole. A stop signal finishes the movie and the command exits 0 with `stopped_by: signal`. `dropped` counts frames the encoder had no room for. Protected content records black.
- `screen gesture home` presses Home, so it closes what is over an app before it leaves the app. `spotlight` needs the Home Screen. `notification-center` shows the Cover Sheet, during which the device reports `locked: true` and most commands exit 2 until `screen gesture home` or `icli unlock` closes it.

## ui (accessibility of what is on screen)

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `ui tree` | Elements with `label`, `identifier`, `value`, `role`, `frame`, `clickable`, `visible` | `--max-elements 250` (1–2000), `--limit N`, `--include-offscreen`, `--clickable-only` | no | unlocked |
| `ui at <x> <y>` | Element at a point | | no | unlocked |
| `ui back` | Tap the screen's back button, or else swipe in from the left edge; `method` says which, and a swipe may do nothing | | no | unlocked |
| `ui prompt` | Whether a prompt only the owner may answer is on screen (`human_required`, `kind`, `source`) | `--source ax\|ocr\|any` (default `any`) | no | any |
| `ui tap [<text>]` | Find an element and tap its centre; refuses ambiguous matches (`error: ambiguous`, with `matches`) | `--identifier <id>`, `--role <role>`, `--match contains\|exact`, `--index N` | no | unlocked |
| `ui fill [<text>]` | Tap a field, empty it, enter new text | same selectors, `--value <text>` (omit to only empty it), `--submit` | no | unlocked |
| `ui scroll-to [<text>]` | Scroll until an element is on screen and report where; stops at the end of the content | same selectors, `--direction down`, `--max-scrolls 10`, `--x`, `--y` | no | unlocked |
| `ui alert <accept\|dismiss>` | Answer the alert on screen, including system permission alerts; refuses passcode, Face ID, Touch ID, Apple Account, Allow Paste, VPN, profile and purchase prompts (`error: human_required`) | `--button <text>` instead of an action | no | unlocked |
| `ui wait [<text>]` | Poll until the element appears | same selectors, `--timeout 10`, `--interval 0.3` | no | unlocked |
| `ui wait-gone [<text>]` | Poll until the element disappears | same as `ui wait` | no | unlocked |

`ui tree` reads what can be reached now (`--scope auto`): the app in front, or the Home Screen or Spotlight, with anything SpringBoard shows over it listed first and marked `scope: system`, and `system_overlay` true. That covers alerts, banners, Control Center and the app switcher. `ui tap` and `ui wait` search the same list, and between equal matches prefer the overlay. `--scope app` and `--scope system` read one side, `system` with the status bar and on the Lock Screen too; `all` reads both. `--source ocr` lists on-screen text instead of the tree, and `--source any` does so when the tree is empty; text has no tap state, so neither takes `--clickable-only`.

Reading the AX tree needs the system's accessibility and automation switches, which are system-wide and stored in the `com.apple.Accessibility` preference domain as `ApplicationAccessibilityEnabled` and `AutomationEnabled`. icli turns on whichever of the two is off before each query and puts both back when the process exits, so the device is left as it was found. A long-running IcliKit host calls `restoreAccessibilitySwitches()` when it stops reading the UI, since a process that is killed never reaches its exit handler. The query that turns them on waits once for the app to load its accessibility bundles, so it is slower than the ones after it. A device whose last icli run was 0.7.1 or earlier may still have them on: `prefs read com.apple.Accessibility ApplicationAccessibilityEnabled` reads the stored value, and `prefs delete` clears it.

Selectors: `<text>` matches an element's label, identifier or value. Matching ignores case and defaults to `contains`. `--identifier` matches an exact identifier or label and takes precedence over `<text>`. One of the two is required. `ui tap` fails with exit 1 when nothing matches.

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
