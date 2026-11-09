# Build from Source

Requires macOS with Xcode and its iPhoneOS SDK, Swift, Clang, Make, `ldid`, `dpkg-deb`, and Python 3. Make these tools available on your `PATH`.

```sh
git clone https://github.com/owngoal-dev/icli.git
cd icli
make all CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
make deb-rootless
make deb-roothide
make tvos
./scripts/check-packages.sh
```

Swift Package Manager resolves Argument Parser and the static [ArchiveKit package](https://github.com/Lakr233/libarchive.xcframework) using the versions pinned in `Package.resolved`. Dependency checkouts and binary artifacts stay under `.build/swiftpm-arm64/`, `.build/swiftpm-arm64e/` and the tvOS `.build/swiftpm/`; these package sources are not vendored. FLEX and FlexUltra sources are pinned under `Vendor/`. Separate iOS scratch directories prevent SwiftPM from reusing the other architecture's build description. Use `make resolve` after changing dependency versions.

| Output | Location |
| --- | --- |
| Signed executable | `.build/icli` |
| Signed probe agent | `.build/icli-probe-agent.dylib` |
| Private FLEX runtime | `.build/libicli-flex.dylib` |
| Full FlexUltra native engine | `.build/libicli-flexultra.dylib` |
| Swift metadata runtime | `.build/libicli-reflex.dylib` |
| Rootless package | `.build/com.icli.icli_<version>_iphoneos-arm64.deb` |
| Experimental RootHide package | `.build/com.icli.icli_<version>_iphoneos-arm64e.deb` |
| Signed tvOS executable | `.build/icli-tvos` |
| tvOS package | `.build/com.icli.icli_<version>_appletvos-arm64.deb` |
| Package verification report | `.build/package-verification.json` |

The version comes from `Resources/Info.plist`. `make deb` builds the rootless package. `make agent` builds the probe agent, the dylib `icli app launch --probe` inserts into an app so `icli probe --app` can reach its live objects: its own Mach-O with both slices in one clang invocation, no Swift, linked to Foundation and UIKit, held to the same import rules as the CLI (`scripts/verify-binary.py --platform agent`). Each iOS package carries it at `usr/lib/icli-probe-agent.dylib`; the tvOS package stays the executable alone. Every build checks for forbidden process-launch imports. Package checks repeat that check and verify architecture, deployment target, entitlements, system-only linked libraries, a firmware-only DEB dependency, ownership, and identical executable contents across the two iOS layouts and in the tvOS package. `check-packages.sh` needs both `make all` and `make tvos` first. Import checks detect direct linked calls; runtime acceptance also checks the environment report.

The **DEB Release** GitHub Actions workflow builds both iOS layouts and the tvOS package and publishes the DEBs, `icli-tvos`, `SHA256SUMS`, and `package-verification.json`. It runs for version tags or can be dispatched with an existing tag. CI artifacts have their own hashes and package checks; device acceptance applies to the specific binary recorded in its report. Repository changes use ordinary incremental commits; published version tags remain fixed.

`make` builds arm64 and arm64e iOS slices, combines them in `.build/icli`, and signs the result with `ldid` using the repository's entitlements. The arm64e slice is required to control authenticated thread state for full lock-screen unlock; the arm64 slice retains support for older devices. `make tvos` builds the separate tvOS executable; the AppleTVOS SDK has no IOKit.framework, so `scripts/tvos-iokit-stub.sh` first borrows the iPhoneOS SDK's IOKit headers and stub, retargeted to tvOS, into `.build/tvos-stubs`. It does not require an Apple development certificate. To compile an arm64 slice without signing, use `swift build -c release --triple arm64-apple-ios15.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" --scratch-path .build/swiftpm-arm64 --product icli --force-resolved-versions`.

`make agent` also compiles the pinned FLEX source under `Vendor/FLEX` with the
Xcode compiler for arm64 and arm64e. It uses an incremental Makefile with no
Theos dependency. Each iOS package includes this runtime at
`usr/lib/icli/libFLEX.dylib`; the app agent loads it for `probe --inspect` or explicit `flex` requests.
The CLI does not link it. Runtime import checks use `verify-binary.py --platform
flex`; package checks verify both slices, their iOS 15.0 deployment floor,
system-only dependencies, payload hashes and the included license.

The full FlexUltra port is prepared from the preserved archive sources by
`scripts/prepare-flexultra.py`, run by `make all` and `make agent`. Preparation
writes the generated Objective-C CLI/MCP bridge under `Sources/IcliFlexClient`
and native engine sources under `.build/flexultra-src`. Both use the same
content-derived build identifier; an app carrying an older agent must be
relaunched once after a native update.

`Agent/FlexUltra/Makefile` compiles the complete native handlers and ObjSee.
`Makefile.metadata` builds Echo and the original metadata-only Swift inspector.
The metadata library uses `-Onone` because Xcode 26.2's optimizer rejects the
pinned Echo runtime symbol declarations with a ptr/i64 PHI mismatch at `-O`.
No live Swift values or mirror constructors are exposed. The engine and metadata
libraries are loaded lazily, carry both architectures, and undergo the same
import checks (`--platform engine` / `--platform reflex`). The iOS package has
five executable files; all dependency licenses are shipped beside its notices.
