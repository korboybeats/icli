# iOS compatibility audit

Status: investigation in progress. The deployment and package floor is still
iOS 15.0. This document does not certify iOS 14 support or runtime operation on
an untested release.

The source baseline is `d066d06`. The CLI examined for the initial import audit
has SHA-256 `ad5c5e4b3483847557c68a4b85a82930032394105f09858ddff556170abf7be7`.
All findings below are static cache, source, or compiler results. This audit has
not yet built or installed a changed device binary or run device acceptance.
The available physical test target is iOS 17.1.1 only.

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

| Initial inventory | Count |
| --- | ---: |
| Source/header files | 726 |
| C/Objective-C translation units indexed with Clang | 269 |
| Clang failures remaining | 0 |
| Distinct C function references, including project functions | 1,490 |
| Distinct typed Objective-C receiver/selector pairs | 4,912 |
| Explicit selectors | 338 |
| Additional selector candidates from literals | 85 |
| Explicit dynamic class names | 71 |
| Additional class candidates from literals | 56 |
| Explicit dynamic symbol names | 146 |
| Additional symbol candidates from literals | 5 |
| Dynamic lookup sites, including variable arguments | 448 |
| Entitlement keys | 90 |
| Absolute path literals | 140 |
| Distinct strong import names across all shipped slices | 2,009 |

The source scope includes `Sources/`, `Agent/`, the prepared inspection engine,
the bundled FLEX sources, the ObjSee files selected by the agent Makefile, and
the metadata library. The generated inspection sources are indexed after
preparation because the preparation script changes framework and class lookups.
Swift source literals and compiled Swift imports are included; Clang cannot
enumerate Swift call sites. The generated metadata sources beyond the selected
Swift metadata entry point remain a conservative inventory superset.

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
`.build/compatibility/all-versions/<version>/`. The generated `presence.tsv`
and `matrix.json` are research inputs for the reviewed per-command matrix.
They must not be read as command pass/fail results.

## Initial confirmed gaps

The first complete cache searches covered 14.0.1, 17.1.1, and 27.2.1. A sweep
of every supplied release is in progress.

| Area | Static finding | Work required |
| --- | --- | --- |
| CLI loading on 14.0.1 | Eleven existing strong imports have no definition in the cache: nine `AsyncStream` symbols, `_xpc_pipe_interface_routine`, and `kIOMainPortDefault`. | Resolve the older launchd and IOKit paths; verify the final executable imports against the floor cache. |
| Optional Swift async log sequence | A standalone compiler probe targeting 14.0 with an iOS 15 availability annotation emits weak concurrency imports and a weak concurrency library load. | Apply and verify the appropriate availability boundary; keep the callback log interface usable on 14. |
| Location reporting | `sourceInformation.isSimulatedBySoftware` is used without an iOS 15 availability guard. | Establish an older way to report simulation or represent the information as unavailable. |
| Low Power Mode | `_PMLowPowerMode` is absent on 14.0.1. `_CDBatterySaver` is exported by that release's CoreDuet. | Reverse engineer its actual getter/setter signatures and reply behavior. |
| Focus | `DNDModeSelectionService` is absent on 14.0.1; the assertion/state services and the deprecated assertion factory are present. | Verify the older Do Not Disturb mode identity and state properties. |
| Silent mode | The current path is gated to iOS 17; the queried getter/setter are absent on 14.0.1. | Reverse engineer the older control path. |
| Rootful packages | The Makefile, packager, and acceptance runner already have a rootful layout. Package verification currently checks rootless and RootHide only. | Include the rootful artifact and its contents in package verification before changing the firmware dependency. |

The iOS 14.0.1 launchd extracted from the firmware and its libxpc have been
inspected with IDA. The old daemon reads separate `subsystem` and `routine`
dictionary fields; libxpc exposes a four-argument `xpc_pipe_routine_with_flags`
instead of the newer five-argument interface routine. The correct subsystem
mapping for each command is still being checked. No substitute value has been
added to the source.

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
