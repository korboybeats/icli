# iOS compatibility audit

Status: investigation in progress. Version `1.0.0+korboy6` builds and packages
for iOS 14.0. This is a deployment floor, not certification that every command
works on every release. The only physical test target is iOS 17.1.1.

The source baseline is `d066d06`. The CLI examined for the initial import audit
has SHA-256 `ad5c5e4b3483847557c68a4b85a82930032394105f09858ddff556170abf7be7`.
The six shipped artifacts now have 2,005 distinct strong import names. Every
name has export evidence in all 40 supplied caches, including the added 14.0
cache. Both arm64 and arm64e slices pass binary/package verification for the
rootful, rootless, and RootHide layouts. These are static results; private
protocol behavior, entitlements, layouts, and device operation need separate
qualification. Reboot acceptance is deferred at the user's request.

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
| Distinct C function references, including project functions | 1,498 |
| Distinct typed Objective-C receiver/selector pairs | 4,914 |
| Explicit selectors | 341 |
| Additional selector candidates from literals | 85 |
| Explicit dynamic class names | 72 |
| Additional class candidates from literals | 56 |
| Explicit dynamic symbol names | 148 |
| Additional symbol candidates from literals | 5 |
| Dynamic lookup sites, including variable arguments | 456 |
| Entitlement keys | 90 |
| Absolute path literals | 141 |
| Distinct strong import names across all shipped slices | 2,005 |

The source scope includes `Sources/`, `Agent/`, the prepared inspection engine,
the bundled FLEX sources, the ObjSee files selected by the agent Makefile, and
the metadata library. The generated inspection sources are indexed after
preparation because the preparation script changes framework and class lookups.
Swift source literals and compiled Swift imports are included; Clang cannot
enumerate Swift call sites. The generated metadata sources beyond the selected
Swift metadata entry point remain a conservative inventory superset.
The final source/import snapshot retains the original AST input hashes. Only
the two generated `ICLIFlexBuild.h` build-ID string literals changed after
those 269 completed Clang inputs; their exact diffs were checked separately.

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
`.build/compatibility/{all-versions,mid-versions,latest-versions,current-floor,supplement}/`.
The supplemental scan records its image scope explicitly. A later report root
overrides duplicate versions, so 14.0 uses the updated inventory's full scan.

The committed [presence matrix](ios-compatibility-presence.tsv) has 6,376 rows
and a column for each cached release. Its [evidence summary](ios-compatibility-presence.summary.json)
retains cache identities, query hashes, supplemental scopes, and the per-version
strong-import checks. `E` means an exported definition, `D` another definition,
and `M` a named implementation of that selector on some class. `-` means a
full-cache symbol query did not locate the name; `Q` is limited to the recorded
supplemental image scope; `N` means it was not queried. None of these codes is
a command pass. In particular, stripped Objective-C method names can be absent
from symbol results while their runtime method metadata still exists.

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
| Location | The source-information flag starts at 15. The 14 location structure does not carry the same source-information representation. | `location get` reports `simulated: null` on 14. `set` and `clear` explicitly report that simulation verification is unavailable there, before changing simulation. An older verification replacement remains unresolved. |
| Low Power Mode | `_PMLowPowerMode` is absent through the cached 14.8 release and present from 15.0.2. | CoreDuet's `_CDBatterySaver` supplies the verified older `getPowerMode` and completion-based setter ABI. No iOS 14 device result is claimed. |
| Focus | Mode selection service is absent through cached 14.8. Older state uses `activeModeIdentifiers`. | 14 exposes the verified default Do Not Disturb identity and plural state property. Newer mode selection remains preferred. |
| Silent mode | The selected getter/setter have named implementations from cached 17.0.3 onward. | Older systems remain explicitly unavailable. The 14 Control Center module calls its injected system agent, not Celestial's AVSystemController; a standalone replacement has not been established. |
| App registration | 14 lacks the newer containerized registration selector. | Use its verified BOOL-returning `registerApplicationDictionary:` entry point with the original dictionary. The newer interface remains preferred. Older runtime registration/plugin behavior still needs qualification. |
| Rootful packages | The existing packager and acceptance runner already support rootful paths. | All three iOS packages are extracted afresh and checked, including all six binaries and both slices. This is package proof, not checkra1n/unc0ver/Taurine runtime proof. |

The iOS 14.0.1 launchd extracted from the firmware and its libxpc have been
inspected with IDA. Its four-argument pipe routine receives `subsystem` 2 for
702/708 and 3 for the used domain routines. Service/domain printing reads an
`fd`, not the newer shared-memory field. Its final callback sends the reply
before `fflush` and `fclose`, so the fallback drains a pipe concurrently and
waits for EOF. Host tests cover every used routine, reply-before-flush, a
payload exceeding pipe capacity, the output bound, and native errors.

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

The installed iOS 17.1.1 CLI is `1.0.0+korboy6`, SHA-256
`2e7d3ff388acf9f8d629b7393d29a28d1cf1ec294a1f8945723f3dbc819dd816`.
The install driver verified the CLI and all five companion files against the
Mac-built artifacts and retained the package hold.

The first root-only non-reboot run completed 106 cases: 105 passed. Siri was
activated, but its cleanup assertion failed after a fixed 1.5-second delay.
A separate reproduction observed dismissal after 3.725 seconds. Replacing the
fixed delay with `ui wait-gone` passed the targeted Siri rerun on the same
binary. This is a broad run plus a targeted rerun, not a single clean full run.

The [per-command matrix](ios-compatibility-commands.tsv) records positive
execution within passing cases for 174 of 187 command leaves. The remaining
13 entries are explicitly `not_executed`; reboot is deferred, and several
others need dedicated scenarios or improved trace coverage. `case_pass`
applies only to the asserted scenarios. Other release columns say
`imports_only`: they qualify whole-process loading, not private command
behavior. The source-gated iOS 14 simulation commands say `unavailable`.
Complete private protocol/entitlement qualification remains open.

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
