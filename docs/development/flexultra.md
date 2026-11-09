# Complete FlexUltra port

The `0.11.0+korboy27` implementation adapts the supplied FlexUltra.zip's entire
105-operation catalog: 90 native operations and 15 local/device operations.
The CLI parser and MCP server retain the original 102 tool names and schemas:
101 map to one operation each, and `flexultra_flex` dispatches to flex.status,
flex.show or flex.hide.
`docs/development/flexultra-operation-catalog.json` is generated from the pinned
shared protocol. Usage is documented in `docs/usage/flex.md`.

The archived Agent, Shared, CLI, MCP, Daemon, ObjSee and Reflex/Echo sources are
preserved under `Vendor/FlexUltra`. The separate private FLEX source is under
`Vendor/FLEX`. `scripts/prepare-flexultra.py` produces namespaced derivatives;
no archived original is edited. Dependency license texts are packaged with icli.

Transport is deliberately integrated with icli's existing on-demand Mach attach
and private Unix socket. No resident broker, all-app constructor or reconnect
loop is installed. The original handler callback graph and heap/keychain worker
guards are initialized on the first explicit full-engine request. UI work uses
the handlers' main-thread callbacks; the outer socket worker must not wrap the
whole engine in a main-thread dispatch, which would deadlock heap callbacks.

The original protocol catalog, method marshalling, paging, heap limits, trace
budgets, errors and MCP schemas are reused. The CLI's local operations call the
existing batch executor in process. No subprocess is spawned by icli. Transport
timeouts come from the original shared protocol. App requests are selected and
pinned to the current PID; a per-process UUID is shared by agent discovery,
object handles and expected-generation checks. The CLI and native engine carry
the same content-derived build identifier. An already-loaded older agent is
reported as stale; it is never silently replaced or relaunched.

Target history is bounded to 128 persisted observations, protected with flock.
It differs from the original resident broker: lifecycle changes are recorded
when icli observes them. History failures cannot turn an already-completed
mutation into a reported operation failure. Health and MCP descriptions disclose
that history is observed, rather than continuously monitored.

The complete FLEX and native libraries use ordinary Xcode compilation, with
arm64 and arm64e slices and an iOS 15.0 floor. The Swift runtime uses the supplied
metadata-only inspector with Echo. Live-value/mirror constructors remain
unavailable exactly as in the archive. The pinned Echo declarations trigger an
LLVM ptr/i64 PHI verification failure under Xcode 26.2 with optimization; `-Onone`
compiles successfully. Compiler support imports added to the floor list were
first verified against local iPhoneOS14.5 `.tbd` exports. Imported debug logging
is redirected to the target app's `Documents/icli-flex_debug.log`.

## Validation

Device acceptance uses only `dev.owngoal.icli.ContainerFixture`:

```sh
ICLI_LEASE=<token> python3 scripts/test-full-flexultra-device.py --section all
```

`--section` takes one or more of `core storage ui trace mcp metadata physical
lifecycle realm` (or `all`) and runs them in that order; a failing section is
reported and the rest still run, and the exit status is 1 if any failed. Run
only the sections a change touches; `all` takes about 25 minutes. Each section
verifies all five installed artifact hashes first and retains complete protocol
replies in `.build/full-flex-validation-<section>.json`. Progress (sections
done, failures, last check) is written to `~/.cache/icli-test-status` as one
tab-separated line, for a status line to show.
Sections cover runtime/object/heap operations, storage and experiments, UI,
tracing, MCP and process-generation recovery. Realm's dependency-unavailable
path is tested in the fixture; the `realm` section reads Bark's (me.fin.bark)
own Realm database. FLEX opens a Realm with a blank configuration, schema
version 0, which Realm refuses for any app that set a version (Bark sets 18:
"Provided schema version 0 is less than last set version 18"). The port opens
the app's default file with the app's own configuration and any other file
with the version stored in it, then runs FLEX's queries on that Realm. The
versions are read on every open, never fixed. A default file older than the
app's version is refused instead of opened: the app's configuration carries its
migration block, so opening would migrate and write the file.
Network/log empty results are distinguished from proving captured traffic.

The test fixture is launched with the local Choicy source's verified per-launch
`CHOICY_DENIED_TWEAKS_OVERRIDE=FLEXing:libFLEX` override to prove the packaged
private libraries, rather than the phone's pre-existing injected FLEX library.
No Choicy preferences are changed. Failed assertions in acceptance are examined
against actual protocol schemas and test bounds; no request is blindly retried.

Both iOS package layouts are checked for exact five-executable payloads, hashes,
licenses, root ownership, signed CLI entitlements, architecture, iOS deployment
floor, system-only linked dependencies, no process-launch imports and no linked
JavaScriptCore. tvOS remains outside the device acceptance: this Mac's SDK build
is blocked by the existing IOKit stub transformation and missing `xpc/xpc.h`.
