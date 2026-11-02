# Direct accessibility activation

Verified UI Actions has an explicit `--method accessibility` mode, also exposed
as `VerifiedUIActionRequest(..., method: .accessibility)` in IcliKit. The default
remains `.touch`. Direct mode retains the remote AX element, requires a unique
enabled/visible target and advertised activation support, compares its geometry
with the original observation, and checks that the final AX hit is `CFEqual` to
that retained reference. It then sends one raw activation action to that element.
There is no coordinate fallback. The reference is released when the request ends.

An AX error after attempting activation yields `sent_unconfirmed`, with
`dispatch_attempted: true`, `sent: false`, and native `ax_error`. No retry follows:
an app's handler can have performed its action before returning failure. Successful
AX dispatch still requires the caller's visible transition to be observed.

## Binary evidence

Analysis used iOS 17.1.1 build 21B91 cache images for iPhone16,2, extracted with
`ipsw dyld extract --objc --slide` and inspected with IDA. Research artifacts are
under `.build/ax-activation-research/`.

| Image and address | Behavior |
| --- | --- |
| AXRuntime `0x1b8301cac`, `AXElement._performActivate` | Sends action **2010** to its remote element. |
| AXRuntime `0x1b8301bb4`, `AXElement.canPerformActivate` | Reads attribute **2019** for activation capability. |
| AXRuntime `0x1b8301db0`, `AXElement.press` | Attempts activation, but can fall back to system action **5008**, with screen coordinates. |
| AXRuntime `0x1b82f40e4`, `AXUIElement.performAXAction:` | Calls raw `AXUIElementPerformAction`; no touch fallback. |
| UIAccessibility `0x1a284d540`, action handler case 2010 | Calls the selected object's `accessibilityActivate` and returns its result. |

The iOS raw function uses a numeric action argument. IDA initially applied a
macOS public prototype with `CFStringRef`; its generated type was not treated as
ABI evidence. The iOS caller's integer action, handler switch and live probe
establish action 2010. Production resolves the function at runtime with the
matching numeric signature.

Saved evidence includes `client-decompile.txt`, `low-level-decompile.txt`,
`server-decompile.txt`, and `action-handler-disassembly.txt`. Apple documents
[`accessibilityActivate`](https://developer.apple.com/documentation/objectivec/nsobject-swift.class/accessibilityactivate%28%29?language=objc)
as an element handler that reports success or failure; the remote mechanism and
numeric values above were established separately from the device-era binaries.

## Physical tests

`Tests/TestHost/main.m` instruments its counter button's `accessibilityActivate`,
`touchesBegan` and `touchesEnded` into the independent state file. Its optional
direct handler sends the button's action and returns either success, or an
intentional failure after the side effect. Without that handler the instrumented
subclass delegates to UIButton's default implementation. The instrumentation
override can itself affect capability advertisement, so this is not proof that
every unmodified UIButton advertises support.

The separate unmodified `element.toggle` UIButton reported attribute 2019 false;
raw action 2010 returned `-25200` and did not run its callback. Its evidence is
`native-button-probe.json`. The supported instrumented handler instead returned
success, incremented once, recorded one activation call, and recorded no touch
events (`supported-probe.json`).

The dedicated research driver in `Tests/VerifiedUIAction/activation-probe.m`
restricts PID paths to TestHost. It calls raw action 2010, without any HID code.
Its optional stdin barrier allows the host to change the UI **after** the remote
reference was retained and **before** action dispatch. This tests the precise
gap that stale coordinate checks cannot close. The probe's geometry stubs are
restricted by the runner to the tested 430-by-932 portrait fixture; production
uses the existing device geometry functions.

Run the physical checks with the current icli and instrumented TestHost installed,
the phone unlocked, and the signed research driver uploaded as
`/var/jb/usr/bin/icli-ax-activation-probe`:

```sh
python3 scripts/test-direct-ax-activation-device.py
```

The runner records the installed/local binary hash, command output and independent
oracle in `.build/ax-activation-research/device.json`. Checks cover direct success
with zero touches, a declined handler with no fallback, failure after a side
effect with no retry, duplicate/disabled/occluded targets, timeout, and retained
references across movement, late overlay and replacement.

Direct activation solves coordinate redirection for a supporting control. It
does not make the foreground check, overlay check and activation atomic. A newly
covered target may still execute its handler. An app can repurpose the same
object without replacing its identity. No claim is made for universal control
support, all iOS versions, UI causality, or exactly-once execution across crashes.

## Validation recorded 2026-10-31

The universal release arm64 + arm64e executable is installed on the iPhone16,2
running iOS 17.1.1 rootless. Installed and local binary SHA-256 both equal:

```text
566261bec5c7bf52c8a3bc8165bfef28535c24751abeda54c23cc0f489b4c22f
```

- 37 engine cases passed (`engine.log`).
- 10 direct-mode/device-reference scenarios passed (`device.json`, `device.log`).
- All 12 existing touch-mode device scenarios passed again on this binary
  (`../verified-ui-device.json`, relative to the research artifact directory).
- An unmodified native button without advertised support was refused by the
  production direct-mode preflight before dispatch. Locked direct input was
  also refused. The existing vault then performed a real full unlock; keybag and
  ledger failures stayed zero and SpringBoard's PID stayed unchanged.
- A real ordinary tap incremented once and recorded one `touchesBegan` and one
  `touchesEnded`, providing a positive control for the zero-touch direct results
  (`guards-and-vault.json`).

The moved-target probe activated the original once and left the decoy untouched.
The replacement probe returned an AX error and did not activate the replacement.
The late-overlay probe activated the original underneath the overlay, confirming
the remaining UI-state race rather than claiming it was eliminated.

Build/import/deployment-floor checks passed (`build.log`). All 27 pre-existing
dirty/untracked unlock/vault files were checked against their original content;
they remain preserved, with additive declarations in the shared private header.
No commit, push, CI or release was performed. The temporary research driver and
its uploaded fixture DEB were removed from the phone; TestHost remains installed.

The original 12-case report from before direct activation is retained as
`previous-touch-device.json`. The earlier validation hash in
`verified-ui-actions.md` describes the preceding implementation stage.
