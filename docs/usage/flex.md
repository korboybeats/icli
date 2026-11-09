# Inspect Running Apps with FlexUltra

`icli flex` provides all 105 operations and all 102 MCP tools from the supplied
FlexUltra archive. It uses icli's on-demand app agent. Run as root on an unlocked
iPhone; first bring the app you want to inspect forward.

```sh
icli app launch com.example.app --wait-foreground
icli flex targets
icli flex health --target com.example.app
icli flex ui key-window --target com.example.app
icli flex heap instances SomeClass --target com.example.app --limit 20
icli flex --help
```

A target is an exact bundle ID, PID, or process name. Ambiguous names return
candidates. A running app can appear with `agent_attached: false`; its first
agent request attaches without restarting it. A process already carrying an
older agent needs one relaunch after an update. SpringBoard can also be selected,
without a respring.

| Commands | What they do |
| --- | --- |
| `targets`, `resolve`, `history`, `ping`, `health`, `info` | Discover targets and check their identity and capabilities |
| `runtime …` | Search classes, images, protocols, methods, properties and ivars |
| `heap …` | Find live instances beyond the UI tree, allocation counts, subclasses, incoming references and reference graphs |
| `object …` | Inspect, read, change and pin objects; invoke supported methods |
| `ui …` | Find and resolve views, activate controls, edit text and values, navigate, scroll, inspect alerts, capture screenshots and compare saved snapshots |
| `defaults …`, `experiment …` | Read/write app preferences and group supported changes for rollback or commit |
| `bookmarks …`, `globals …` | Retain useful objects and access FLEX's global inspectors/actions |
| `network …`, `logs …` | Read recorded network and log history |
| `keychain …`, `database …`, `filesystem …` | Inspect the target app's accessible storage, SQLite and loaded Realm databases |
| `trace …` | Capture bounded method traces through ObjSee; stop tracing when finished |
| `swift inspect …` | Read Swift class metadata, field names and offsets |
| `investigate …` | Combine screen/element evidence, metadata and reference information |
| `app …`, `input …` | Use icli's existing app lifecycle and physical input commands |
| `flex status/show/hide` | Inspect the FLEX runtime or show/hide its graphical explorer |

`icli flex --help` prints every command's exact arguments. `icli flex catalog`
returns the original operation metadata. `icli flex request '<JSON>'` accepts a
raw protocol request, including operations with no dedicated original CLI spelling.

Object IDs have the form `obj_<generation>_<counter>`. Reuse them only while the
same process generation is alive. Pinning keeps an object alive; unpin it when
finished. Use returned stable selectors to find UI objects again after a restart.
`--expected-generation <generation>` refuses a request if the process changed;
requests that fail or time out are never automatically repeated.

The original method-call value format is retained: JSON scalars and supported
geometry structures, or `@obj_<generation>_<counter>` to pass an object handle.
A returned object is usually `result.value.object`; strings, URLs and numbers
are serialized as values. Listing methods does not invoke them. Value inspection
can execute getters; `--no-values` requests metadata only.

Experiments cover the original supported mutations, including object/defaults
and UI text, value and scroll changes. They do not make arbitrary method calls,
physical input, trace operations or global actions reversible.

Tracing rebinds each loaded image's imported `objc_msgSend`, as the original
does, so it records calls made from those images. Calls UIKit makes from the
shared cache, such as a button sending its action, and calls made with
`object call` are not recorded. Measured on iOS 17.1.1: `trace start --pattern
TestController increment:` saw nothing for an activation, a physical tap or
`object call`, while `trace start --method alpha` followed by `ui key-window`
recorded `-[UIWindow alpha]`.

Swift inspection is metadata only. Live Swift values and mirror construction
are disabled in the supplied implementation and remain disabled here. Realm
browsing requires Realm to be loaded by the target app; the app's default Realm
file opens with the app's own configuration, including its schema version. A
file older than the app's schema version is refused rather than migrated; let the
app open it first.
Network/log history contains only what the underlying recorder captured; empty
history is valid.
`health` exposes per-operation support and dependency reasons.

Target history stores up to 128 lifecycle observations in
`/var/mobile/Library/Caches/icli-flex`. It records processes seen when icli runs;
it does not monitor connections continuously. `source: icli_observed_agents`
identifies this behavior. No resident broker or global injection tweak is added.

## MCP

```sh
ssh-iphone '/var/jb/usr/bin/icli flex mcp'
```

The process serves newline-delimited JSON-RPC on stdin/stdout, using the original
`flexultra_*` tool names, schemas and annotations. It supports initialization,
`tools/list` and `tools/call`. The existing icli lease applies to tool requests;
pass its token as `ICLI_LEASE` in the remote environment. MCP cannot be nested in
`icli batch` or `session`, because it owns stdin/stdout.

The original `probe` scripting, interactive REPL and `probe --inspect` commands
remain available and share the same lazily attached agent. The full FlexUltra
engine is loaded only for a `flex` request; ordinary probe scripts do not load it.
