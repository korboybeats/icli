# Script the Device

`icli probe` runs a JavaScriptCore script in the icli process. A script reaches any Objective-C class through a reflection bridge, reads and writes files, prints, and calls icli's own capabilities through `api()`.

```sh
icli probe -e "ObjC.use('NSProcessInfo').processInfo().processName()"
icli probe -e "api('svc.list').count"
echo "var m = ObjC.use('NSFileManager').defaultManager(); m.fileExistsAtPath_('/')" | icli probe -
icli probe script.js
icli probe repl
icli app launch com.example.app --probe
icli probe --app com.example.app --check
icli probe --app com.example.app -e "ObjC.use('UIApplication').sharedApplication().keyWindow().frame()"
```

A class method, then an instance method on what it returns: `ObjC.use('NSProcessInfo')` (or `ObjC.classes.NSProcessInfo`) gives a class, and a selector becomes a method call with underscores for its colons (`stringWithUTF8String_`) or the selector written out (`obj['setValue:forKey:'](v, k)`); a leading underscore stays part of a private method's name (`_isDeallocating`). A geometry struct is a plain object with one property per field: `CGPoint` and `CGVector` as `{x, y}` / `{dx, dy}`, `CGSize` as `{width, height}`, `CGRect` flat as `{x, y, width, height}`, `UIEdgeInsets` as `{top, left, bottom, right}`, `NSDirectionalEdgeInsets` as `{top, leading, bottom, trailing}` and `NSRange` as `{location, length}`, in both directions, so a frame read from one view goes straight into another's setter. Every field has to be there and be a finite number. Any other struct, a non-null pointer or a block is refused with an error rather than passed, since a bad one would take icli down. A string, number, boolean or date comes back as a JavaScript value, and `NSNull` as `null`; anything else, collections included, comes back as a handle whose `$value` converts it, `$class` names its class and `$isClass` says whether it is one. `fs.ls/read/write/stat` use icli's own file access, `console.log`/`print` and `sleep(ms)` do output and waiting, and `api(method, params)` calls an icli capability in process (`env.info`, `device.info`, `screen.info`, `passcode.status`, `svc.list`, `svc.status`, `app.list`, `proc.list`); `params` is an object, encoded as `JSON.stringify` encodes it.

`-e`, a file, or `-` (stdin) prints one JSON line `{ok, result | error, output}`: stdout carries only that line and everything the script printed is collected into `output`. A thrown script is an answer with `ok: false` and a nonzero exit, not a crash. `repl` (or no argument) opens an interactive shell whose output appears as it happens; `.help` lists what is available and `.exit` leaves. ^C abandons a half-finished statement; while a statement runs, ^C ends icli, since nothing inline could stop it otherwise.

## Inside an App

`--app` runs the script in an app's own process instead of icli's, which is where its live objects are: a `UIView` there is a view on screen with a frame and a superview, not just a class. Bring the app to the front, then use `icli probe --app <app>`. If no agent is listening, icli loads it into the running process without restarting the app. `-e`, a file or stdin answers in the same `{ok, result | error, output}` line. With no script, or `repl`, it opens an interactive shell. `--check` only reports whether an agent is listening, with its PID; it never loads one.

```sh
icli app launch com.example.app --wait-foreground
icli probe --app com.example.app repl
icli probe --app com.example.app -e "ObjC.use('UIApplication').sharedApplication().keyWindow().subviews().count()"
echo "ObjC.use('UIScreen').mainScreen().bounds()" | icli probe --app com.example.app -
```

The agent is `/var/jb/usr/lib/icli-probe-agent.dylib`, loaded on demand using a temporary thread in the existing app. This needs root and a jailbreak that grants task control; a refusal reports an error without restarting the app. `icli app launch <app> --probe` remains available to load it at launch through `DYLD_INSERT_LIBRARIES`. There is no global tweak filter, saved launch setting or resident broker. After an app exits, the next `probe --app` command attaches to its new foreground process again. It binds a Unix socket inside the app's own container, which the sandbox keeps to root and to that app — a loopback port would be reachable by every other app on the device. `--probe` keeps any `DYLD_INSERT_LIBRARIES` the same launch already asked for, and the bootstrap's own loader stays in front of both.

The app has to be **in front**. iOS suspends a backgrounded app, and a suspended process runs no threads, so its agent cannot answer even `--check`; the connection still succeeds, because the kernel accepts it into the listen backlog while the app is frozen, so it reads as a silent agent rather than a refusal. icli says which case it is. Bring the app forward and ask again.

A script runs on the app's **main thread**, as UIKit requires, so it sees a consistent view tree and a setter takes effect where the app would have made it. A main thread that does not answer within `--timeout` (30 s by default) gives an error instead of hanging forever; the script may still run later, which is the app's own business. A script that crashes takes the **app** down, not icli — `icli log crashes` reports it, and the next app launch and probe command start a fresh agent. `api()` reaches icli's own capabilities and is refused inside an app: run that part as a plain `icli probe` and pass what it answers into the script. The remote REPL shares the app's context, including variables from earlier commands. Multiline input, `.help`, `.exit` and Ctrl-C while editing work as in the local shell. Output is collected until each statement returns. Exiting leaves the app and agent running; Ctrl-C during evaluation ends only the client, and the submitted script may still run. Each shell is pinned to its original PID: if the app restarts, a new process refuses its scripts before evaluation. Open a new shell to attach again.

## Inspect a Live Object

```sh
icli probe --app com.example.app --inspect window
icli probe --app com.example.app --inspect root-controller
icli probe --app com.example.app --inspect 215,466 --limit 20
icli probe --app com.example.app --inspect root-controller --values --limit 20
icli probe --app com.example.app --inspect root-controller --offset 20 --limit 20
```

`--inspect` uses the bundled FLEX object explorer. `window` selects the foreground
key window; `root-controller` selects that window's root controller. `x,y` selects
the actual view hit at that screen point, so a point from `ui tree` can inspect a
button directly. A point outside the window returns an error.

The reply is one JSON object `{ok, result, output}` with a **structured object**
in `result`, containing `class`, `address`, `pid`, `bundle_id`, `class_hierarchy`,
`properties`, `ivars`, `methods` and `class_methods`. `runtime_image` names the
actual loaded FLEX library. Every member includes its
name, declaring class and type encoding. Properties also describe their getters
and setters; fields include their offset and size. Addresses identify this
process's objects; they are not accepted as input or durable handles.

Values are omitted by default. `--values` reads property getters and fields through
FLEX, executing app code on the main thread. Exceptions become per-member
`value_error` entries. Strings are bounded; object values are class/address
references instead of recursively walking their contents. A getter can still
block or crash its app, like any other in-app probe.

`--limit` (default 100, maximum 500) and `--offset` apply independently to each
member group. `totals` and `truncated` describe the groups; these are the members
FLEX exposes under the app's FLEX explorer preferences. Method arguments include
Objective-C's implicit receiver and selector. Listing methods does not call them.

If the app already has a compatible FLEX explorer, inspection reuses it.
Otherwise FLEX is loaded **only on the first inspection**, from the private
packaged `usr/lib/icli/libFLEX.dylib`. Ordinary scripts and REPLs do not load it. There is
no added global tweak or background service, and no inspector interface is shown.
An app already carrying an older agent needs one relaunch before it can use
inspection. This command selects UIKit objects; [icli flex](flex.md) exposes
the complete FlexUltra command set, including arbitrary object handles, heap
searches, mutation, tracing and MCP tools.

## Inline, In icli

The script runs **inline**, in the icli process, with icli's memory, file access and entitlements. There is no `--detach`: a script that crashes or hangs takes icli down with it. A caller that needs to survive a bad script spawns `icli probe` as its own process and reads its JSON line. `proc.run` and `exit()` are deliberately not provided: `exit()` would end the caller, and running other programs belongs to the host that spawns `icli probe`, which adds it through its own `api()` handler. On a platform without JavaScriptCore the command answers `ok: false` with the error `This platform has no JavaScriptCore`; icli's binary gains no process-launch import, so `env info` stays `spawns_processes: false`.
