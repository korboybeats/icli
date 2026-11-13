# Audio Output Validation

The audio-output implementation in commit `036e0b2` was built as a signed arm64/arm64e rootless package and tested on an iPhone 15 Pro Max running iOS 17.1.1. The CLI version was `1.0.0+korboy1`; the tested binary's SHA-256 was `77efe4460f29b9a016459a8e3e9d7ec48f47dc042be8a8777bdae7676dbb1b1b`. The installed executable matched the build and packaged executable. This identifies that focused run, not subsequent builds with changed help or documentation.

| Check | Recorded result |
| --- | --- |
| Discover outputs | Speaker and AirPods listed by native name, dynamic UID and selected state |
| Switch both directions | Speaker ↔ AirPods completed twice; separate native reads confirmed every result |
| Native events | `ActiveAudioRouteDidChange` delivered with the implementation's temporary subscription client |
| Saved volumes | Speaker and AirPods each retained their own volume across both cycles |
| Already selected UID | Returned `changed: false` |
| Missing UID | Returned `route_unavailable` and a nonzero exit without changing the output |
| Existing cc commands | Toggle states matched before and after testing |
| Restoration and cleanup | Original AirPods output and volume restored; testing lease released; device diagnostic helpers removed |

The production native bridge also passed the macOS host tests for exact UID matching, original dictionary identity, asynchronous completion, unavailable notifications, rejection, route disappearance, accepted-but-unconfirmed timeout, invalid data, ambiguous selected state, native exceptions and worker-thread run loops. Tests check that temporary subscription clients are released after each operation.

The reproducible commands are in [Testing and Compatibility](testing.md#audio-route-host-tests). The run's full command/response record, build log and host test output are local artifacts under `.build/audio-route-device-validation.json`, `.build/audio-route-build.log` and `.build/audio-route-host-tests.log`; they are not included in Git. This summary does not claim full current-version acceptance, or validation on other iOS versions, RootHide, tvOS, PIN-protected outputs or different audio hardware.
