# FLEX object inspection handoff

Implemented in `0.11.0+korboy24`. The new `probe --app <app> --inspect <target>`
operation uses FLEXObjectExplorer for a live window, root controller, or hit-tested
view at a screen point. It returns structured member metadata with bounded pages;
values are opt-in. The usage contract is in `docs/usage/probe.md`.

The agent reuses the existing main-thread request queue and PID check. The queue
now accepts either evaluation or inspection callbacks and retains a late reply
only until its block returns. A timed-out request is not automatically repeated.

The private FLEX runtime is built from the supplied archive's pinned FLEX sources
under `Vendor/FLEX`; all Classes files match the ZIP byte-for-byte. `ARCHIVE.json`
records the archive hash and upstream revision. The original license is preserved
in the vendor tree and in each package's dependency notices. The standard Xcode
compiler builds both architectures; Theos is not a dependency of this build.

The runtime is not linked to icli or its agent. Inspection first checks for an
already-loaded FLEXObjectExplorer, then loads the private runtime if needed.
The reply's `runtime_image` identifies the actual library used, including when
an app already has its own FLEX. No tweak filter or daemon is installed.

## Verified on 2026-11-06

Rootless iPhone 15 Pro Max, iOS 17.1.1:

- Existing FLEX compatibility passed in TestHost PID 2931. Its explorer came
  from the phone's pre-existing `usr/lib/TweakInject/libFLEX.dylib`.
- Isolated ContainerFixture PID 67405 passed 31 inspection checks. An ordinary
  script first reported no FLEXObjectExplorer. Inspection then loaded the
  packaged `usr/lib/icli/libFLEX.dylib`, confirmed by `runtime_image`.
- The returned controller and point-selected button addresses matched those
  obtained independently through the original Objective-C probe bridge.
- Known property/field names, types and values matched TestHost's source and
  independent probe results. Inheritance, pagination, missing targets, invalid
  options, bounded object references and absence of values by default passed.
- Inspection preserved the app PID and counter. The existing remote REPL suite
  passed all 12 checks. A timeout test returned an error, then recovered with
  exactly one execution recorded in the shared context.
- The host probe suite passed 170 checks. Both iOS package layouts passed payload,
  architecture, deployment floor, system dependency, license, ownership, import
  and hash checks. Runtime imports were checked per slice.

Installed hashes matched the selected build artifacts:

```text
icli: 5ab3cddbf39bcda13a55d5a7bf7f36834f42d6743083a9055eaca704083b3b23
agent: 1e2a29a1b2ef15988f42fdc9edc2db28def95d75e4a39bd10a7bd0c3104920ba
FLEX: ad6133daf23735c2a52c4709997ea996d187afb56499471421cb0ce5aa13d48a
```

Reports and full logs are in `.build/object-inspection-*.json` and
`.build/object-inspection-*.log`. Repeat acceptance against the dedicated fixture:

```sh
python3 scripts/test-object-inspection-device.py --app dev.owngoal.icli.ContainerFixture --expect-lazy
```

`--expect-lazy` needs a fresh fixture process without another FLEX injector.
The phone already had FLEXing installed, so an ordinary fresh launch did not
provide that baseline. `_MSSafeMode=1` also prevented this phone from loading the
agent; that was a test setup failure, not evidence of a lazy-load regression.
The successful isolated launch used Choicy's per-launch environment override:

```sh
icli app launch dev.owngoal.icli.ContainerFixture --env CHOICY_DENIED_TWEAKS_OVERRIDE=FLEXing:libFLEX --wait-foreground
```

That override's exact name and colon-separated format were verified from the
local Choicy source (`Shared.h`, `Tweak.c`). It changes only the test launch;
no Choicy preference files were edited. The normal fixture launch is restored
after acceptance.

The FLEX build also introduced five compiler-emitted runtime imports not yet in
icli's floor list. Each was confirmed exported for arm64/arm64e by the local
iPhoneOS14.5 SDK's `libobjc.A.tbd` or `libc++abi.tbd` before adding it to the
existing compiler-runtime section. Import verification remains enabled.

This records the initial UIKit inspection implementation. The subsequent
[complete FlexUltra port](flexultra.md) exposes arbitrary object handles, heap
searches, tracing, mutation commands and the rest of the supplied suite. Other iOS versions, arm64-only hardware and tvOS have not
been device tested for this feature.
