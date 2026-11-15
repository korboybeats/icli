# iOS compatibility audit

Status: investigation in progress. Version `1.0.0+korboy8` builds and packages
for iOS 14.0. This is a deployment floor, not certification that every command
works on every release. The only physical test target is iOS 17.1.1.

The implemented compatibility fixes include source commits `6b3b934` and
`9120923`. The current CLI has SHA-256
`90428218a82d85aac2216ad0fdf69462787c8ab5773f93f089051f34924f4f6c`.
The six shipped artifacts now have 2,005 distinct strong import names. Every
name has export evidence in all 40 supplied caches, including the added 14.0
cache. Both arm64 and arm64e slices pass binary/package verification for the
rootful, rootless, and RootHide layouts. These are static results; private
protocol behavior, entitlements, layouts, and device operation need separate
qualification. Reboot acceptance is deferred at the user's request.
Phone testing is now paused at the user's request: the current build's run
stopped after 68 passing cases out of 110 planned, with no failed cases.

## Inventory

The complete source index is [compatibility-dependencies.tsv](compatibility-dependencies.tsv).
Names are JSON-escaped so multiline literals remain one record. The index
deliberately retains ordinary output strings and project-owned APIs as well as
system dependencies: an unclassified literal must not silently disappear during
the private-key and protocol review.

The [import index](compatibility-dependencies.imports.tsv) records the actual
strong and weak imports of both architecture slices of each shipped artifact.
The [snapshot summary](compatibility-dependencies.summary.json) contains source
hashes, successful Clang inputs, entitlement values, and artifact hashes.

| Current inventory | Count |
| --- | ---: |
| Source/header files | 726 |
| C/Objective-C translation units indexed with Clang | 269 |
| Clang failures remaining | 0 |
| Distinct C function references, including project functions | 1,502 |
| Distinct typed Objective-C receiver/selector pairs | 4,915 |
| Explicit selectors | 350 |
| Additional selector candidates from literals | 86 |
| Explicit dynamic class names | 74 |
| Additional class candidates from literals | 56 |
| Explicit dynamic symbol names | 146 |
| Additional symbol candidates from literals | 5 |
| Dynamic lookup sites, including variable arguments | 459 |
| Entitlement keys | 90 |
| Absolute path literals | 142 |
| Distinct strong import names across all shipped slices | 2,005 |

The source scope includes `Sources/`, `Agent/`, the prepared inspection engine,
the bundled FLEX sources, the ObjSee files selected by the agent Makefile, and
the metadata library. The generated inspection sources are indexed after
preparation because the preparation script changes framework and class lookups.
Swift source literals and compiled Swift imports are included; Clang cannot
enumerate Swift call sites. The generated metadata sources beyond the selected
Swift metadata entry point remain a conservative inventory superset.
The final source/import snapshot freshly indexes the two changed production
translation units, `Accessibility.m` and `FullUnlock.m`, and retains the other
267 completed Clang inputs after source-hash checks. The two generated
`ICLIFlexBuild.h` headers differ from the preceding snapshot only in their
build-ID literals and exactly match the original AST-input hashes. All other
722 source/header hashes match the preceding qualified snapshot. Every final
artifact/slice import list was read afresh and is unchanged.

The following need semantic review in addition to a name-presence check:

- Preferences domains and keys, dictionary fields, Darwin notifications,
  Mach services, entitlement checks, daemon client identifiers, and paths.
- AX numeric attributes/actions, HID fields and report descriptors, launchd
  routine/domain numbers and message fields, and private logging entry layouts.
- Objective-C receiver ownership, superclass/category methods, return types,
  argument types, and the availability guards protecting each call.
- User-supplied reflection targets and app-owned libraries. Their absence from
  a system cache does not make a system command incompatible.

## Reproducing the evidence

On the build Mac, from the repository:

```sh
python3 scripts/prepare-flexultra.py
python3 scripts/compatibility-inventory.py --ast --ast-vendor --imports \
  --output .build/compatibility/inventory-all.json
```

The import inventory requires the six built iOS artifacts. Copy that JSON to
the research host, which holds the complete caches under `~/re/ios/`, then run:

```sh
python3 scripts/compatibility-inventory.py \
  --from-inventory .build/compatibility/inventory-all.json \
  --export docs/development/compatibility-dependencies.tsv
python3 scripts/compatibility-matrix.py \
  --inventory .build/compatibility/inventory-all.json \
  --output .build/compatibility/all-versions
```

The matrix scanner searches every image in every selected cache using
`ipsw dyld symaddr`. It rejects zero-address and undefined-symbol records,
retains full image paths, and distinguishes exports from other definitions.
Frameworks, plug-ins, and accessibility bundles can share a basename; those
images are put in separate batches so ownership remains unambiguous.
Completed batches are reusable only when their cache identity and query match.
The primary cache is detected from the files, including arm64-only releases.

The first scanner validation compared batch/global results on 86 uniquely named
iOS 27.2.1 images: all 24,012 definitions agreed. The complete extended iOS
14.0.1 batch scan also retained all 105,862 definitions found by the earlier,
narrower global query. These checks validate extraction consistency; neither
establishes private ABI compatibility or device behavior.

Raw per-image definitions and query/cache identities live under
`.build/compatibility/{all-versions,mid-versions,latest-versions,current-floor,supplement,korboy7-supplement}/`.
Each supplemental scan records its image scope explicitly. The report accepts
repeated `--supplement` arguments so newer scoped queries retain the earlier
fallback evidence. A later report root
overrides duplicate versions, so 14.0 uses the updated inventory's full scan.

The committed [presence matrix](ios-compatibility-presence.tsv) has 6,389 rows
and a column for each cached release. Its [evidence summary](ios-compatibility-presence.summary.json)
retains cache identities, query hashes, supplemental scopes, and the per-version
strong-import checks. `E` means an exported definition, `D` another definition,
and `M` a named implementation of that selector on some class. `-` means a
full-cache symbol query did not locate the name; `Q` is limited to the recorded
supplemental image scope; `N` means it was not queried. None of these codes is
a command pass. In particular, stripped Objective-C method names can be absent
from symbol results while their runtime method metadata still exists.

The [receiver-specific method matrix](ios-compatibility-methods.tsv) records
112 selected private receiver/selector pairs across the same 40 caches. These
are reviewed calls used by the compatibility fallbacks and adjacent device,
registration, audio and logging paths. Each resolved cell contains the actual
declaring class and native Objective-C encoding, including superclass methods.
Its [input summary](ios-compatibility-methods.summary.json) retains the raw
metadata, reader and reviewed-source hashes. The selected source files match
the recorded `korboy7` inventory byte for byte; its native method snapshots are
retained rather than relabeled as a fresh scan. This establishes receiver and method encoding for
those rows; it is not exhaustive private-API qualification. In particular,
an `@?` argument alone does not establish the block's callback prototype.

`scripts/compatibility-objc.py` reads cache method metadata directly, handles
the recorded slide/relative-list formats, and retains unparseable encodings.
Separate category lists are not all merged, so `class_unresolved` and
`method_unresolved` never prove absence. Source guards and native caller
inspection establish the fallback decisions described below. To regenerate
the selected matrix after saving each version's metadata:

```sh
python3 scripts/compatibility-methods.py \
  --metadata .build/compatibility/objc-korboy7 \
  --inventory .build/compatibility/inventory-korboy7.json \
  --index docs/development/ios-compatibility-methods.tsv \
  --output docs/development/ios-compatibility-methods.tsv
```

Resolver exports require special handling: go-macho's `TrieExport.Type()`
prints `resolver=0x...` for stub/resolver entries instead of `regular`. This
occurs for 38 required dispatch/lock functions in the 16.7.16 and 17.2 caches.
Treating those as non-exports would incorrectly report missing loader APIs.
The parser also handles combined `regular|weak_def` flags and re-exports.

The exact cached releases are 14.0, 14.0.1, 14.1, 14.2, 14.3, 14.4.2, 14.5.1,
14.6, 14.7.1, 14.8, 15.0.2, 15.1, 15.2.1, 15.3.1, 15.4.1, 15.5, 15.6.1,
16.0.3, 16.1.2, 16.2, 16.3.1, 16.4.1, 16.5.1, 16.6.1, 16.7.16, 17.0.3,
17.1.1, 17.1.2, 17.2, 17.2.1, 17.3.1, 17.4.1, 17.5.1, 17.6.1, 17.7, 18.0,
26.0, 26.6.2, 27.0, and 27.2.1. Intermediate releases are not inferred.

## Confirmed gaps and current behavior

The original iOS 15 binary is rejected by the new floor verifier for exactly
eleven unavailable strong imports. The iOS 14 build removes those loading
requirements; it does not bundle a newer Swift concurrency runtime.

| Area | Static finding | Implemented behavior and limits |
| --- | --- | --- |
| CLI loading | Nine `AsyncStream` imports, `_xpc_pipe_interface_routine`, and `kIOMainPortDefault` are missing on 14. | The async sequence is available from 15; launchd routines resolve dynamically; IOKit uses the documented null default port. All final strong imports are measured against the floor cache. |
| Async logging | iOS 14 has no system concurrency runtime. | Callback logging remains available. The 15+ async sequence and its concurrency load are weak on the 14 build; the package verifier accepts only the specific weak concurrency load. |
| Location | The source-information flag starts at 15. The 14 location structure does not carry the same source-information representation. | `location get` reports `simulated: null` on 14. `set` and `clear` explicitly report that simulation verification is unavailable there, before changing simulation. The inspected native external XPC interfaces expose no simulation-state reader; the technology query filters out the simulated provider. |
| Low Power Mode | `_PMLowPowerMode` is absent through the cached 14.8 release and present from 15.0.2. | CoreDuet's `_CDBatterySaver` supplies the verified older `getPowerMode` and completion-based setter ABI. No iOS 14 device result is claimed. |
| Focus | Mode selection service is absent through cached 14.8. Older state uses `activeModeIdentifiers`. | 14 exposes the verified default Do Not Disturb identity and plural state property. Newer mode selection remains preferred. |
| Rotation | `AXSpringBoardServer.setOrientation:` is missing on cached 14 releases. | Use the native `AXPISystemActionHelper` portrait, upside-down, left and right actions. Factory/action signatures match in all ten 14 caches; native caller and orientation meanings were checked in the 14.0.1 firmware. Newer rotation remains preferred. |
| Foreground processes | The newer application-process predicate is missing on 14. | Use the native `predicateMatchingLaunchServicesProcesses` predicate, whose implementation filters application identities. |
| Silent mode | The selected Celestial getter/setter begin in cached 17.0.3. | Read 14–16 through the native AX request 4020 and require an actual BOOL-valued object reply. Nil, errors and incompatible signatures remain unavailable. Writes on 14–16 remain unavailable; no button-event simulation is substituted. |
| App registration | 14–15 lack the newer containerized registration selector. Its newer return is an object, not BOOL. On 14, application records lack signer identity. | Use the verified BOOL-returning `registerApplicationDictionary:` entry point with the original dictionary. Prefer proxies when records cannot supply signer identity, preserving rootful user-app classification. Modern registration checks its error and reads back the result. Older device behavior is not claimed. |
| App lookup | A cold dynamic lookup can precede loading LaunchServices. | Initialize the workspace before looking up application classes for standalone list/name operations. |
| Process logs | The activity entry layout changes between 14–16, 17–18 and 26–27. | Decode the measured offsets for the actual OS major, copy packed timestamps safely and reject unqualified future layouts. Every supplied cache's native decoder was inspected; see the layout matrix below. |
| Accessibility caller context | Two optional manual client lookups do not resolve in the supplied caches. Resolving the actual native setters and forcing a client identity would overwrite a host's selected context. | Keep native caller detection and the existing automation switches. The device-only production-source probe preserves a deliberately seeded current and outgoing context; a negative control detects the discarded overwrite. |
| Passcode unlock | A private factory or unlock method may exist with an incompatible encoding. | Check factory availability, arity and object return; check passcode, BOOL and completion argument types before preparing the credential or invoking the method. Native method-signature fixtures cover incompatible types, and owned Mac RPC fixtures exercise both supported unlock forms. |
| Rootful packages | The existing packager and acceptance runner already support rootful paths. | All three iOS packages are extracted afresh and checked, including all six binaries and both slices. This is package proof, not checkra1n/unc0ver/Taurine runtime proof. |

The iOS 14.0.1 launchd extracted from the firmware and its libxpc have been
inspected with IDA. Its four-argument pipe routine receives `subsystem` 2 for
702/708 and 3 for the used domain routines. Service/domain printing reads an
`fd`, not the newer shared-memory field. Its final callback sends the reply
before `fflush` and `fclose`, so the fallback drains a pipe concurrently and
waits for EOF. Host tests cover every used routine, reply-before-flush, a
payload exceeding pipe capacity, the output bound, and native errors.

The [process-log layout matrix](ios-compatibility-log-layouts.tsv) records the
native decoder address, extracted-image hash and copied decoder-evidence hash
for every supplied release. Message/timeval offsets are 48/88 on 14–16, 56/96
on 17–18 and 52/92 on 26–27. The 26–27 timestamp is unaligned. The production
reader uses `memcpy`; host fixtures run it with undefined-behavior checking for
each supported major and reject unknown majors, wrong layouts and corrupt
entries. These are static layout and host-reader results, not device log
captures from those releases. Raw decoder copies remain private under
`.build/compatibility/logging-layouts/`.

The [accessibility protocol note](ios-compatibility-accessibility.md) records
native instruction and dispatch-table checks for element attributes, direct
activation and scrolling on 14.0.1 and 27.2.1. In particular, the older service's
5019 dispatch calls `accessibilityIdentifier`; the differently named
`AXElement.identifier` wrapper is not a replacement for it. This endpoint
inspection does not qualify the whole 40-cache numeric protocol surface.
Its [native witness matrix](ios-compatibility-accessibility.tsv) now records
matching common accessor/action argument loads in all 40 caches, four newer
5019 wrapper witnesses and the four scroll mappings in every cache. The
different 16.x helper implementations were inspected separately. Earlier
5019 wrapper cells remain unresolved; the older app-side dispatcher evidence
and the 17.1.1 runtime result are kept separate. These checks do not qualify
every C/MIG field, entitlement gate or app-side handler.

## Verification boundaries

The Mac builds all six universal artifacts at 14.0. Binary verification checks
every strong import, including mangled Swift names, against
`scripts/floor-exports-ios14.json`; public SDK spelling alone is insufficient.
The manifest generator retains cache/query/input hashes and full owner paths.
The external IcliKit, IcliSystem, and IcliLaunch consumers build at iOS 14 and
tvOS 15. tvOS's deployment floor remains 15. The consumer fixtures were updated
to the current API signatures and the established tvOS XPC-header fallback.

The source does not yet have exhaustive per-version qualification of service
entitlements, private dictionary keys, numeric protocols, receiver inheritance,
or method argument/return encodings. Name presence and successful linking do
not close those items. The per-command device results must be assessed from
the matching acceptance report, including failures, unexecuted commands, and
the deferred reboot cases. `ICLI_TEST_ROOT_ONLY=1` skips CLI privilege-demotion
checks and records that scope in the report.

## Current device evidence

The installed iOS 17.1.1 CLI is `1.0.0+korboy8`, SHA-256
`90428218a82d85aac2216ad0fdf69462787c8ab5773f93f089051f34924f4f6c`.
The install driver verified the CLI and all five companion files against the
Mac-built artifacts and retained the package hold. All three iOS package layouts
passed verification again. The final inventory contains 269 successful Clang
inputs, including fresh analysis of both changed production translation units;
its summary records source hashes and the qualified reused inputs. All six
artifact import lists remain identical to the preceding qualified import set.

The current root-only run passed its first 68 non-reboot cases before the user
paused phone testing. There are no failed cases, but 42 planned cases were not
completed. Its report records `completed_run: false`, successful lease release,
and a matching installed binary hash. The runner exited through its cleanup
path, removed both installed test apps and stopped further device interaction.
The runner SHA-256 and complete report hash are retained in the
[command evidence summary](ios-compatibility-commands.summary.json).

The preceding `korboy7` build passed a complete 110/110 non-reboot run. On that
build, eight additional FLEX fixture sections passed all 138 checks: core inspection,
storage, UI, tracing, command dispatch, metadata, physical state and lifecycle.
Storage includes reading an actual fixture heartbeat from the process log;
enabling monitoring alone was not counted as proof of delivery. These reports
belong to the earlier binary and remain under `.build/compatibility/korboy7-flex/`;
they are not counted as current-build passes.
App-owned Realm behavior was not exercised against an unrelated user app.

The [per-command matrix](ios-compatibility-commands.tsv) records positive
execution within passing cases for 107 command leaves on the current binary.
Another 79 leaves are `not_executed`, and `device reboot` is explicitly
`deferred`. The preceding build's complete report remains private under
`.build/compatibility/acceptance-korboy7-nonreboot.json`; it is not combined
with the current binary's report. `case_pass`
applies only to the asserted scenarios: passcode unlock used `--check`, the
empty failure ledger was cleared, audio selection covered the current route
and a missing UID, and FLEX inspected the fixture. Other release columns say
`imports_only`: they qualify whole-process loading, not private command
behavior. The source-gated iOS 14 simulation commands say `unavailable`.
Complete private protocol/entitlement qualification remains open.

The command matrix is reproducible with `scripts/compatibility-commands.py`.
It accepts one or more `--acceptance` reports from the same installed binary,
counts only successful command executions in passing asserted cases, and includes
lease acquisition/release recorded outside the individual test cases. Its
companion summary retains report and runner hashes. `--defer-reboot` marks the
user-deferred reboot command explicitly.

```sh
python3 scripts/compatibility-commands.py \
  --acceptance .build/compatibility/acceptance-korboy8-final.json \
  --defer-reboot
```

With `ICLI_TEST_SAVED_UNLOCK=1`, power and respring acceptance first check the
existing on-device saved credential without authenticating. After locking, the
runner calls `icli unlock` once; it neither provisions a credential nor puts it
in a trace. Without that flag or `ICLI_UNLOCK_WAIT`, those scenarios remain
unexecuted on a passcode device. A busy lease is waited for without taking it
over.

Raw device reports and screenshots stay private under `.build/compatibility/`.
Test fixture apps were removed and the test leases were released.

## Completion gates

The audit remains open until all of the following have current evidence:

1. Review the inventory's variable lookups, private keys, paths, services,
   numeric protocol dependencies, and compiler imports.
2. Publish the per-version matrix for every supplied release, including missing
   and changed items and precise evidence limits.
3. Implement and statically verify replacements or clear unavailable errors for
   every uncovered path; reject incompatible method signatures before calling.
4. Establish the iOS 14 toolchain/runtime boundary and rootful packaging before
   lowering build stamps, package dependencies, and import verification.
5. Build and pass binary/package verification, including both slices and every
   iOS layout. Install using `scripts/build-install.sh`.
6. Run the full acceptance suite with `--lease` on 17.1.1, remove its test apps,
   and record per-command runtime results separately from static results.
7. Commit/push each completed logical step and save the measured findings.

Testing on another OS or physical target requires a separate user decision.
