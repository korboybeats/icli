# Native Silent Mode

`cc get silent`, `cc set silent on|off` and `cc toggle silent` use the
standalone AVSystemController client. `on` means ringer muted. They do not
write category volumes or use Control Center UI, buttons, Siri, Frida or an
injected SpringBoard setter. The implementation is limited to iOS 17+ and
checks method signatures at runtime; absent or incompatible APIs fail closed.
tvOS reports unavailable.

## Native evidence

IDA analysis used the iOS 17.1.1 arm64e cache at
`/home/korboy-wsl/mac-files/dsc-17.1.1/dyld_shared_cache_arm64e`.
MediaExperience UUID is `D4237346-F8C0-3642-8B9A-E553BAD2510C`; the reused
analysis input and a fresh extraction from this cache have the same UUID.
Raw analysis snapshots are in `.build/silent-research/ida-native-evidence.json`.
Addresses below are unslid and apply to that build only.

| Evidence | Address | Verified behavior |
| --- | --- | --- |
| `AVSystemController getSilentMode:error:` | `0x19959aa24` | Returns BOOL success, writes a one-byte BOOL through argument 1 and an NSError through argument 2. Reads the native SilentModeEnabled property. True means Silent mode enabled. |
| `AVSystemController(InternalUse) errorWithCode:description:` | `0x19959b430` | Creates NSError even for OSStatus zero; a non-null error alone is not failure. |
| `AVSystemController setSilentMode:untilTime:reason:clientType:` | `0x19959a7d0` | Returns BOOL; arguments are BOOL, object date, object reason, unsigned 32-bit client type. Translates the service's zero OSStatus to YES. |
| `MXSessionManager(Utilities) getSilentModeClientTypeAsString:` | `0x199621150` | Table at `0x1def15d58`: 0 Default, 1 Springboard, **2 ControlCenter**, 3 FocusMode, 4 Accessibility, 5 Gesture, 6 Shortcuts, 7 Settings. |
| `MXSystemController(InternalUse) setAttributeForKeyInternal:andValue:` | `0x1994efab4` | Reads `com.apple.private.mediaexperience.setsilentmode.allow` through SecTaskCopyValueForEntitlement. The implementation adds that exact Boolean entitlement. |
| `MXSystemController setSilentMode:untilTime:reason:clientType:` | `0x199551bc8` | Rejects missing entitlement or client type >= 8. On devices with a physical ringer switch, accepts only Springboard or Accessibility clients. icli uses ControlCenter and reports refusal on those devices rather than impersonating those clients. |
| `MXSessionManager updateSilentModeState:untilTime:withReason:forClientType:updateForStartup:` | `0x1995725d8` | Saves Silent mode and its reason/client/timer, updates ringer state and publishes notifications; does not set category volumes. |
| `SBRingerControl` native AVSC operation block | `0x1d3293180` | Calls the same AVSystemController setter with nil untilTime, reason and unsigned client type. Sound feedback is a separate SBRingerControl operation, which icli does not invoke. |
| `AFDeviceRingerSwitchObserver state` | `0x1a07ee604` | 0 if inactive; nonzero `com.apple.springboard.ringerstate` maps to 1, zero maps to 2. Name table at `0x1df51d5b0`: **0 unspecified, 1 tone, 2 silent**. Used as an independent test oracle, not as a guessed Boolean. |

Native acceptance is checked separately from completion. After an accepted
setter call, icli services the calling thread's run loop and rereads the
native getter until the requested state is reached or three seconds pass.
It also checks the final Swift response against the request. Repeated sets
send no write. There is no background polling or persistent subscription.

The read-only device oracle also uses `AXSpringBoardServer isRingerMuted`
(`0x1920c8a10`), whose BOOL result is decoded by `AXServer
sendSimpleMessageWithResult:` (`0x1920d91f0`). Request 4020 is handled by
`_AXSpringBoardServerInstance _isRingerMuted:` (`0x207c6a60c`);
`AXSpringBoardServerHelper isRingerMutedWithServerInstance:` (`0x207c4f998`)
reads SBRingerControl on its main access queue. The helper checks the live ABI
and compares both directions with the AF enum. It does not inject code into
SpringBoard. Its volume reads check the native success flag, so an unsupported
category cannot silently become a zero baseline. Analysis is retained in
`.build/silent-research/ida-ax-oracle.json`.

## Tests

On macOS, `rtk test ./scripts/test-silent-mode.sh` compiles the production
bridge with a fake native client. It covers both directions, idempotence,
run-loop callback completion, missing/incompatible signatures, getter errors
including the zero-code NSError success case, exceptions, rejected setters,
state becoming unavailable and accepted requests that never reach the target.
The timeout case must fail after the bounded native rereads.

## Physical phone result

Passed on the rootless iPhone 15 Pro Max (`iPhone16,2`), iOS 17.1.1,
on 2026-11-12 (America/Denver). The previous task released its lease before
icli acquired `icli-silent-mode`; installation and tests ran only afterward.
The package was installed normally with dpkg and remains held against upgrades.
All six installed Mach-O hashes matched the local build artifacts.

- CLI SHA-256: `aef001cf7406450d220fbd7715c81687f639b2103ca0a023055a1473375275b2`.
- Getter encoding: `B32@0:8^B16^@24` (BOOL return, BOOL out, NSError out).
- Setter encoding: `B40@0:8B16@20@28I36` (BOOL return, BOOL, date, reason, unsigned 32-bit client type).
- AF observer encoding: `q16@0:8`; its actual states were 1 when unmuted and 2 when muted.
- Independent SpringBoard getter encoding: `B16@0:8`.
- Both signed CLI slices carry the verified setter entitlement.

The report contains 61 command/helper records and 17 native verification
snapshots. `get`, `list`, `on`, `off`, both toggle directions, repeated
idempotent sets, batch expectations and a persistent session passed. Native
AF/SpringBoard state and all four volume baselines were checked after each
normal/session transition and after the batch. A background get succeeded
without a lease token; normal setters, toggles and a guarded session step were
refused with exit 75 before changing state.

| Native category | Before | After |
| --- | --- | --- |
| Audio/Video (Media) | 37.75% | 37.75% |
| Ringtone | 20% | 20% |
| Alarm | 20% | 20% |
| Siri | 50% | 50% |

The exact floats are in the report. Every native volume read returned success;
no baseline was inferred from a failed getter. No volume-restoration setters
were needed. Original Silent mode was **on** and was restored to on, confirmed
by the CLI, AF observer and SpringBoard getter. No playback, UI actions,
SpringBoard injection or prohibited sound tests ran. FLEQ, AUnit and its crash
recorder were not modified.

Evidence: `.build/silent-mode-build.log`, `.build/silent-mode-host-tests.log`,
`.build/silent-mode-artifacts.json`, and `.build/silent-mode-device/` containing
`device-validation.json`, `device-info.json`, `installed-sha256.txt`,
`install.log`, `device-test.log` and `cleanup.json`. Temporary uploaded package,
helper, test script, reports and the task's token file were removed from the
phone after evidence retrieval. The task's lease was released and `held: false`
was confirmed. IDA database leases and the SSH shell were also closed.

This qualifies the recorded binary on this phone. Other devices and iOS
versions have not been physically tested by this check.
