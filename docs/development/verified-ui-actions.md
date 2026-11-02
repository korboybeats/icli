# Verified UI Actions

Current follow-up: strict direct activation is implemented with
`--method accessibility` / `method: .accessibility`. See
[direct AX activation](direct-ax-activation.md) for the latest installed hash,
37 engine cases, 10 additional device scenarios, all 12 touch-mode regressions,
and the remaining boundary. The validation section below records the preceding
touch-only stage.

`performVerifiedUIAction(_:)` is the reusable IcliKit operation. CLI parsing
only creates a `VerifiedUIActionRequest` and emits the result's JSON `payload`.

```swift
import IcliKit

let result = performVerifiedUIAction(VerifiedUIActionRequest(
    app: "dev.owngoal.icli.TestHost",
    tapIdentifier: "counter.increment",
    condition: .valueChanged("counter.status"),
    timeout: 10
))
// Inspect result.outcome, dispatchAttempted, sent and evidence.
```

The engine in `Sources/IcliKit/Input/VerifiedAction.swift` uses typed requests,
conditions and outcomes. `VerifiedActionDevice.swift` supplies guarded native
observations and one HID dispatch. `IcliPrivate/VerifiedAction.m` reads PID,
executable and kernel process start time via sysctl/proc_pidpath. Existing unlock,
vault and ordinary tap/wait paths retain their behavior.

The baseline and second snapshot must agree on context and target. Both must
satisfy the expectation's initial state; value baselines must also agree.
The final hit test must identify the same target geometry and attributes.
The final context check precedes the sole dispatch. A dispatch that returns
false or throws is unconfirmed because finger-down may already have occurred.
Post-dispatch queries require the same context and a transition within the
deadline. Errors, ambiguity and context loss never cause another dispatch.

## Repeatable checks

On macOS, run the deterministic engine checks:

```sh
sh scripts/test-verified-ui-actions.sh
```

These execute the production engine with controlled snapshots, monotonic time
and a counted dispatch boundary. They cover transitions, already satisfied
baselines, duplicate/disabled/moving/occluded targets, label aliases, PID changes
and reuse, orientation changes, foreground loss, AX and partial HID failures,
slow/late observations and the no-retry contract. These are simulated race and
failure cases, not claims that those races were reproduced on hardware.

Build and install icli plus the separate TestHost fixture as described in
[testing](testing.md). With the phone unlocked and available, run from WSL:

```sh
python3 scripts/test-verified-ui-actions-device.py
```

The runner uses `ssh-iphone`, changes dedicated TestHost controls and
temporarily goes Home for the foreground-loss case. It reads the app's
independent `state.json` after each action and records command outputs in
`.build/verified-ui-device.json`. A timeout case waits for the fixture's delayed
callback and verifies it was triggered once; it never retries the action. The
failure-capture case reads the saved JPEG bytes and removes that test image.
TestHost's reset invalidates pending delayed callbacks between cases.

Physical tests cover value/appearance/disappearance, duplicate identifiers and
labels, disabled and app-overlay targets, wrong app and label alias refusal,
timeout/slow response, optional JPEG capture and foreground loss after input.
Reports apply to the binary hash and device used; this is not broad iOS/tvOS
compatibility or system-overlay coverage. Usage and outcome limitations are
documented in [interaction](../usage/interaction.md#verified-ui-actions).

## Validation recorded 2026-10-31

Built release arm64 + arm64e on the Mac, signed with the existing entitlements,
and installed the universal executable at `/var/jb/usr/bin/icli`. Build checks
passed: no process-launch imports, no strong imports beyond the iOS 15 floor,
and JavaScriptCore remains loaded at runtime. Installed and local SHA-256:

```text
930214309908657e348707108788da06605170c3d99d34fc04398d8ea95ddc2e
```

Physical device: iPhone16,2, iOS 17.1.1, rootless. Evidence retained locally:

| Check | Result | Evidence under `.build/` |
| --- | --- | --- |
| Universal build and import/floor checks | Pass | `verified-ui-build.log` |
| Deterministic engine scenarios | 33 pass | `verified-ui-engine.log` |
| Physical UI scenarios with independent TestHost oracle | 12 pass | `verified-ui-device.json`, `verified-ui-device.log` |
| Existing unlock policy tests | 18 pass | `verified-ui-unlock-regression.log` |
| Locked action refusal, real vault full unlock, legacy UI tap | Pass | `verified-ui-vault-regression.json` |

The locked request returned `refused`, `dispatch_attempted: false`, `sent: false`
and left the fixture counter at zero. The existing vault wrapper then performed
one real full unlock (`attempted: true`, `ui_unlocked: true`); keybag and ledger
failure counts stayed zero and SpringBoard's PID stayed unchanged. No real wrong
passcode was submitted. A subsequent ordinary `ui tap` incremented the independent
counter once. TestHost was reset afterward and remains installed for repeat runs.

All 27 pre-existing dirty/untracked unlock/vault files checked against their
starting content are preserved. The shared private header only gained the new
process-identity declaration and comment. No commit, push, CI, package refresh
or release was performed.

The first device attempt reached the old executable while upload was still in
progress; the runner now verifies installed/local hashes before testing. A later
foreground-loss fixture could not bring Settings forward, so the final test uses
Home after observing the dispatch in the independent state file. These earlier
outputs remain in `verified-ui-device-pre-final.*`. Final device reports and all
counts above apply to the matching executable hash shown here.
