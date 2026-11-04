# Interaction and Screen Capture

Run these commands on the device or in its SSH session. Unlock the device and keep the screen on before interacting with an app.

## Inspect and Interact

Read the foreground app's accessibility tree, then use its text or identifiers in your commands. Replace the sample identifiers and text below with elements in your app:

```sh
icli app frontmost
icli app running
icli ui tree
icli ui tap --identifier counter.increment
icli ui wait 'Ready element' --timeout 5
icli ui wait-gone 'Loading' --timeout 10
```

`app frontmost` marks a bundle ID `verified: true` only when RunningBoard has one non-widget focal app. A SpringBoard-query fallback is marked `verified: false`; UI commands stop if they cannot verify the target. `app running` reports its `source` as `runningboard` or `processes`.

### Verified UI Actions

`ui perform` checks the intended foreground app, taps one enabled target once,
then observes a requested transition. All identifiers are exact accessibility
identifiers: a label with the same text does not count. Targets and expectation
elements must be unique among the visible AX rows. There is no index override.

```sh
icli ui perform --app dev.owngoal.icli.TestHost \
  --tap-identifier element.toggle --expect-appeared element.ready --timeout 10
icli ui perform --app dev.owngoal.icli.TestHost \
  --tap-identifier element.toggle --expect-disappeared element.ready
icli ui perform --app dev.owngoal.icli.TestHost \
  --tap-identifier counter.increment --expect-value-changed counter.status
```

Supply exactly one expectation. Appeared requires absence before the tap;
disappeared requires presence; value-changed requires one visible element
before and after, with a different AX `value`. A changed label alone does not
count as a changed value. Already satisfied appearance/disappearance conditions
refuse the action instead of treating old UI as success. After the tap it looks
again only once the screen draws a new frame, at most every `--interval`
(default 0.1 s); `trigger` in the result says `frames`, or `poll` where frame
notifications are unavailable and it checks every interval.

For a control that implements accessibility activation, add
`--method accessibility`:

For the TestHost example below, first enable its test handler with
`icli url open icli-test://verified-direct`.

```sh
icli ui perform --app dev.owngoal.icli.TestHost \
  --tap-identifier counter.increment --expect-value-changed counter.status \
  --method accessibility
```

This mode retains the selected remote element and sends its activation action
directly. It never falls back to a coordinate tap, including after a timeout or
an activation error. A moved control cannot redirect this request to a different
control at the old screen position. The default `--method touch` keeps ordinary
tap behavior for controls that do not implement activation. Accessibility support
is app-dependent; a reported capability does not guarantee the handler succeeds.

| Outcome | Exit | Meaning |
| --- | --- | --- |
| `refused` | 1 | No dispatch was attempted. Check `reason`. |
| `verified` | 0 | HID accepted the tap and the transition was observed. |
| `sent_unconfirmed` | 3 | Dispatch was attempted, but its visible result was not verified. |

`dispatch_attempted` is set before entering the dispatch API. With `touch`, `sent`
means both finger events were accepted. With `accessibility`, it means the AX
action returned success; `ax_error` records its native result. The visible result
is checked separately. A partial dispatch failure is unconfirmed, never a safe
refusal. A handler can return failure after changing state. Missing/invalid CLI
arguments fail before the operation.
No outcome causes an automatic retry. After an unconfirmed result, inspect the
app before deciding whether another action is appropriate.

The command checks unlocked/screen-on state even in debug/library hosts,
verified foreground bundle, PID and kernel start time, orientation, dimensions,
target frame/activation point, enabled state and an AX hit test before input.
Truncated or failed AX observations stop verification. Foreground/process or
orientation changes after input leave the result unconfirmed. It does not
launch, unlock, dismiss overlays, move a target into view or select another app.

Results include bounded pre/post expectation rows, a compact UI difference
(up to 20 added and 20 removed rows, text capped at 256 characters), target
geometry and timings. Add `--failure-screenshot /tmp/action.jpg` to save a JPEG
on refusal/unconfirmed input; capture is best effort and may show a changed app.
There is no screenshot or OCR work by default.

`--timeout` is an overall monotonic deadline (0.1–60 seconds), including checks;
`--interval` is the least time between checks while the screen keeps changing
(0.1–5 seconds, default 0.1). Synchronous AX/system calls and optional failure
capture can finish after the deadline; late observations cannot verify success.
There is no background service or work between requests. The AX bridge supplies
snapshots, so this operation takes one after each new displayed frame rather
than relying on accessibility notifications, which apps do not post for every
change.

Checks and taps are separate operations: the GUI can still change between them.
Direct activation preserves the target's identity; it does not freeze the UI.
For example, a late overlay may cover the target while its activation still runs.
AX hit testing is scoped to the intended app and cannot prove absence of every
system overlay. Observations do not establish causality or prove a server-side
transaction. There is no rollback or exactly-once guarantee across crashes.
Point input is unavailable on tvOS. See [validation](../development/verified-ui-actions.md)
for tested behavior and the reusable IcliKit API.
See [direct activation research](../development/direct-ax-activation.md) for
the native behavior and limits tested on the phone.

For coordinate input, read the screen dimensions first. Coordinates are **points** in the orientation shown on screen, including those returned by accessibility and OCR. On an iPad held in landscape, `screen info` reports a landscape width and height:

```sh
icli screen info
icli screen tap 100 245
icli screen swipe --from-x 200 --from-y 600 --to-x 200 --to-y 200
icli screen scroll-by down 200                 # exactly 200 points, no fling
icli screen pinch 200 400 --from 80 --to 240   # zoom in; swap the distances to zoom out
icli screen drag --points '[{"x":54,"y":500},{"x":140,"y":480},{"x":240,"y":500}]'
```

Focus a text field before entering text:

```sh
icli input paste '中文 and emoji 🌱'
icli input key cmd+a
icli input type 'Hello!' --delay-ms 30
```

For input that needs exact control, send one event at a time. A finger that goes down stays down until an `up`, even across separate icli runs. `--normalized` takes 0…1 coordinates in the digitizer's fixed portrait space instead of points. `input hid` sends a raw HID usage: page 7 is the keyboard page, 12 the consumer page.

```sh
icli screen touch down 100 245
icli screen touch move 160 245
icli screen touch up 160 245
icli screen touch-sequence --events '[{"phase":"down","x":100,"y":245,"delay_ms":800},{"phase":"up","x":100,"y":245}]'
icli input hid 7 0xE1 --down
icli input hid 7 4
icli input hid 7 0xE1 --up
```

On an iPad, `screen click` and `screen scroll` use a virtual pointer, as a trackpad does. A click is a pointer click rather than a touch, and a scroll moves the view under the pointer by exactly the deltas given, with no momentum. `--button secondary` opens the context menu under the pointer, and `--hover 0.5` rests the pointer on the point before it clicks, so hover effects show first. `--normalized` takes 0…1 of the interface as it is shown. The pointer exists only while the command runs. iOS on an iPhone uses it only through AssistiveTouch's pointer devices.

```sh
icli screen click 100 245
icli screen click 100 245 --button secondary
icli screen scroll 400 500 --dy 300
```

`input paste` sends Unicode keyboard events; it does not read the clipboard. `input type` sends one grapheme at a time. Use `icli clipboard get` and `icli clipboard set 'shared text'` for clipboard text. `clipboard get` also reports the pasteboard types, change count and any image; `--image-output /tmp/clip.png` saves the image, and `clipboard set --image /tmp/photo.png` copies one. icli reads and writes the system pasteboard without a prompt. When another app later reads that text programmatically, iOS may show its standard paste permission prompt for that app; user-initiated pastes such as `icli input key cmd+v` are not prompted.

## Capture the Screen

```sh
icli screen shot --output /tmp/screen.jpg
icli screen shot --base64
icli screen ocr
icli screen ocr --region 0,100,430,60 --fast --lang en-US
icli screen describe
```

Screenshot paths are on the device. Default screenshots have one image pixel per point. Add `--native-resolution` for native pixel dimensions; the result includes a `coordinate_scale` to relate pixels to points.

`screen describe` uses one capture for its JPEG and OCR results and collects accessibility elements separately. Check its component errors and `context_changed` before combining the results.

`--region x,y,width,height` reads only that rectangle, in points, and reports blocks in screen coordinates. `--fast` uses Vision's fast recognition level, which Apple documents as quicker and less accurate. On an iPhone 15 Pro Max a full read took about 0.5 s, `--fast --lang en-US` about 0.2 s.

OCR uses Apple's Vision framework. If system text recognition is unavailable, the command returns an `unavailable` error; that includes a process with no Metal device, such as one started over SSH on iOS 15, where Vision would otherwise crash. A successful scan with no recognized text returns an empty result.

### Tapping, Filling and Scrolling to Elements

`ui tap` taps only an unmistakable match. An exact match beats a partial one, then an enabled element, then one that can be tapped; an element whose tap point lies inside a better one counts as the same control. If several remain, nothing is tapped and the result is `error: ambiguous` with their `matches`. `--index N` skips this and picks among all matches.

A quick swipe flings: a scroll view keeps moving after the finger lifts, so a 200-point `screen swipe` at the default speed moved Settings about 490 points. `screen scroll-by` and `screen swipe --no-momentum` end with a short slow move, so the scroll view stops when the finger lifts; `--steps` has no effect with `--no-momentum`, and `--seconds` can only lengthen the stroke. `scroll-by` also adds the distance iOS keeps before a scroll view starts moving, and lands within a point or two of the distance asked for, or sooner where the content ends.

`ui scroll-to` pages with accessibility's own scroll action where the view supports it: no touch, no fling, and a page never jumps past content. `method` in the result says whether it paged (`accessibility`) or had to use touch strokes (`touch`). If the element it finds has its tap point clipped by the list's edge or a bar, it scrolls that element into view (`revealed: true`) and reports the corrected point, so a tap there lands. In a view accessibility cannot scroll, each stroke covers 45% of the screen, which can jump past rows in a list shorter than that.

```sh
icli ui fill 'Email' --value 'me@example.com' --submit
icli input paste 'replacement' --clear
icli ui scroll-to 'Developer' --match exact
icli ui alert accept
```

`ui fill` taps the field and waits for the on-screen keyboard before it selects all, deletes and sends the text. `ui scroll-to` fails with `error: not_found` and `reason` `end_of_content` or `max_scrolls`. `ui alert` reads SpringBoard's accessibility tree as well as the app's, because a system alert is not in the app's, then falls back to text recognition. It chooses from a list of allowing or refusing button names, and refuses prompts only the device's owner should answer, with `error: human_required`. A tap made while the alert is still animating in is dropped, so `ui alert` waits for the alert to close. It taps once more when the same alert, with the same button and title, is still there after a second (`attempts: 2`), and fails with `error: alert_open` if it stays.

### Waiting for the Result of an Action

`screen tap`, `ui tap`, `ui fill`, `ui alert` and `ui back` take `--expect <text>`, which waits after the action until an element whose label, identifier or value contains the text is on screen, or `--expect-gone <text>`, which waits until none does. The wait is in the result as `expect`. If it runs out (`--expect-timeout`, default 10 s), the command exits 1 with `error: expect_failed`, and its `action` shows that the action itself ran.

```sh
icli ui tap 'Sign In' --expect 'Welcome'
icli screen tap 200 640 --expect-gone 'Loading' --expect-timeout 20
```

### What Is on Screen

`ui tree` lists what can be reached now: the app in front, or the Home Screen, or Spotlight, with whatever SpringBoard shows over it first. Those elements carry `scope: system`, and `system_overlay` is true; `ui tap` and `ui wait` search the same list and, between equal matches, prefer the overlay. `--scope system` reads SpringBoard alone, including the status bar and the Lock Screen; `--scope app` ignores it.

`ui back` taps the screen's back button, or swipes in from the left edge when it has none. `method` says which, and a swipe does nothing on a screen with nowhere to go back to. `input hide-keyboard` sends the key that toggles the on-screen keyboard only while it is up, and returns once it has gone.

```sh
icli screen gesture control-center
icli ui tree                                   # Control Center first, then the app beneath it
icli screen gesture home                       # closes it; pressed again, leaves the app
icli ui prompt                                 # {"human_required":false}
```

`ui prompt` says whether a passcode, Face ID, Touch ID, Apple Account, Allow Paste, VPN, profile or purchase prompt is on screen: nothing an agent should answer. Some of these belong to processes with no readable tree, so it reads the trees and then the screen's text; `--source ax` skips the text. `screen describe` always carries `prompt`, and `screen shot --check-prompt` adds it to a screenshot.

### Recording the Screen

```sh
icli screen record --seconds 10 --output /tmp/run.mov
icli screen record --output /tmp/run.mov &     # until SIGINT, SIGTERM or SIGHUP
```

Recording draws each frame straight into the hardware encoder's buffers at the panel's full resolution, 30 frames per second by default and up to 60 (`--fps`). `--codec` picks `hevc` (the default) or `h264`. The movie appears at its path only once it is complete, and a stop signal finishes it rather than abandoning it. The result has `frames`, `dropped`, the achieved `fps` and `stopped_by`.

### Text Recognition Selectors

`ui tree`, `ui tap`, `ui wait` and `ui wait-gone` take `--source ax|ocr|any` (default `ax`). `ocr` matches on-screen text found by text recognition, for UI missing from the accessibility tree such as system share sheets; it accepts text only, not `--identifier` or `--role`, and taps the centre of the matched text within its line. `any` tries the tree first and falls back to text recognition when the tree has no match. Results from `ocr` and `any` include `source`. Add `--lang` to change the recognition languages.

```sh
icli ui wait --source ocr Copy --timeout 5
icli ui tap --source any Copy
```

### Waiting for the Screen

`screen wait` compares screenshots, so it sees changes the accessibility tree does not. `--changed` waits until the screen differs from a baseline, `--stable` until it stops changing for `--stable-for` seconds, and both together wait for a change and then for it to settle. A change made before the command starts is invisible to it unless you save a baseline first. `--region x,y,width,height` limits the comparison to a rectangle in points. A timeout exits 1 with `error: timed_out`. It captures again only after the display shows a new frame, at most every `--interval`, so a still screen costs one capture to confirm `--stable-for` and one at the timeout; `trigger` reports `frames`, or `poll` where frame notifications are unavailable and it captures every interval. `ui wait`, `ui wait-gone` and `--expect` pace their checks the same way. A wait that starts while one app is replacing another looks again until the switch is done, instead of failing because the front app is briefly unverified.

```sh
icli screen shot --output /tmp/before.jpg
icli ui tap Continue
icli screen wait --baseline /tmp/before.jpg --changed --stable
```

`screen shot --stdout` writes only the JPEG bytes to stdout, for `ssh phone 'icli screen shot --stdout' > shot.jpg`; errors go to stderr as JSON.

### Batches

`icli batch` reads a JSON array of steps from stdin and runs them in one process, stopping at the first failure. A step is an argument list or an object with `argv`, and optionally `expect` (result fields that must match; dotted keys read nested fields), `delay_ms` and `continue_on_error`. The result lists each step's `result`, `exit_code` and `elapsed_ms`; the exit status is the first failed step's. `batch`, `session`, `probe`, `tests` and `screen shot --stdout` cannot be steps.

```sh
echo '[["app","relaunch","com.example"],
       {"argv":["app","frontmost"],"expect":{"bundle_id":"com.example","verified":true}},
       ["ui","wait","Ready"]]' | icli batch
```

### Sessions

`icli session` keeps one process open for a runner that sends commands as it goes, one JSON line each, and answers each with one JSON line, so no command pays for process start-up or an SSH login. A line is an argument list or an object with `argv`, `expect`, `delay_ms` and an `id` the reply repeats. The first line out is `{"ready":true,...}`. A failed command does not end the session; end of input or SIGINT, SIGTERM or SIGHUP does.

```sh
printf '%s\n' '{"id":1,"argv":["app","frontmost"]}' '["ui","tap","Continue","--expect","Done"]' | icli session
```
