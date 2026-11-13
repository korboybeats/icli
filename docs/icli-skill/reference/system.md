# System: svc, prefs, account, env, proc, sec, net, probe, tests, session, status, lease

## Test runs: session, batch, status, lease

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `session` | Keep one icli process open: each JSON line on stdin runs one command and gets one JSON line back | | no | each command's own |
| `batch` | Run a JSON array of commands from stdin in one process, stopping at the first failure; one report with `ok`, `completed`, `failed_step` and each step's `result` (`text` for a `--compact` step), `exit_code`, `elapsed_ms`. A step is an argument list or `{argv, expect, delay_ms, continue_on_error}`; `expect` keys may be dotted (`element.label`) | | no | each command's own |
| `status` | `locked`, `screen_off`, `orientation`, `frontmost`, `keyboard_shown`, `system_overlay` with `overlay` labels, `prompt` (an owner-only prompt's kind or null), `appearance`, `springboard_pid`, `boot_time` | | no | any |
| `lease acquire` | Claim the device; prints `token` | `--owner <name>` (required), `--ttl 600` idle seconds (1–86400), `--force` (take it over) | no | any |
| `lease release` / `lease status` | End the lease, or show `held`, `owner`, `seconds_left`, `mine` | `--force` (release another's) | no | any |
| `lease indicator [on\|off]` | Show or hide the holder's name (`icli: <owner>`) near the bottom of the screen, above the home indicator when present; without an argument, print `indicator` | | no | any |

A session line is an argument list or an object with `argv`, the batch step fields `expect` and `delay_ms`, and an `id` the reply repeats. The first line out is `{"ready":true,"pid":…,"version":…}`. Each reply has `index`, `ok`, `exit_code`, `elapsed_ms`, `result` (or `text`, the lines of a `--compact` step), and `message` or `expect_failed`. A failed command does not end the session; end of input, SIGINT, SIGTERM or SIGHUP does, and a running `screen record` finishes its movie first. Commands get no stdin. `batch`, `session`, `probe`, `tests` and `screen shot --stdout` cannot run in it. Inside a session `app frontmost` took about 3 ms, `ui tree` 10–35 ms and `ui tap` about 150 ms, against about 0.1 s of process start-up and about 0.4 s for a new SSH login per command.

While a lease is held, every icli command without its token fails with exit 75 and `error: leased`, naming the `owner`; `lease` and `status` always run. Pass the token as `ICLI_LEASE=<token>`. Every command carrying the token keeps the lease alive, so hold it for the whole run and release it at the end. It lapses only after `--ttl` seconds with no command carrying the token, so a crashed runner blocks others for at most that long. Acquiring again with the token renews it. While a lease is held, SpringBoard shows `icli: <owner>` just above the home indicator, so pass an `--owner` a person recognizes: `<project>-<task>`, such as `myapp-build`. The label passes touches through and stays out of screenshots, OCR and `ui tree`; it disappears on release or when the lease lapses.

With `ICLI_FAILURE_ARTIFACTS=<dir>` set, a failed command (including a failed batch or session step) writes `<dir>/<time>-<pid>-<command words>/` with `error.json` (the arguments, the error, the app in front, lock state), `screen.jpg` and `tree.json`, and the error gets `artifacts` with that folder. A `leased` refusal writes none. Without the variable nothing is written.

Leases coordinate interactive testing. An authorized installation through the SSH shell (`dpkg -i` or `trollinst`) does not require acquiring or taking over a testing lease. Leave an existing holder's lease intact.

## svc (launchd)

Label commands take the plist's `Label` value without a domain prefix, for example `com.example.service`. Path commands take one or more plist files or directories. Mutating commands need root and the launchd privileges that the custom firmware grants. Without them they fail with `requires root (launchd status …)`. Every svc command also runs while the device is locked.

On RootHide, `bootstrap` and `load` rewrite each plist in place before handing it to launchd, as RootHide's `launchctl` does: the program (`Program` or `ProgramArguments[0]`) and the other paths launchd itself opens get the jbroot in front, `/rootfs/x` becomes the system's `/x`, an earlier `.jbroot-…` is replaced with the current one, and `__Patched` is set. Plists outside the jbroot, a program under `/rootfs/`, and a plist already patched for the current root are left alone. `bootout` and `unload` never rewrite, and rootless and rootful use plists as written. Check a plist with `svc paths` before loading it.

| Command | Purpose | Key flags | Root |
| --- | --- | --- | --- |
| `svc list [<label>]` | All visible services with PID and last exit status, or one service's status; launchd's full list carries no program path, so only the one-label form reports `program` | | no |
| `svc status <label>` | Enabled, loaded, running, PID | | no |
| `svc print <label>` | launchd's full description | | no |
| `svc print-disabled` | Persistent disabled overrides | | no |
| `svc dump` | Every service with its description in one document; refusals go under `errors` | | no |
| `svc paths <paths…>` | Every path launchd reads from each plist (program, directories, standard streams, `WatchPaths`, `QueueDirectories`, path environment variables, `KeepAlive.PathState`, socket and fsevents paths): `written`, `launchd` (as launchd opens it on this bootstrap), `exists`, and a `hint`/`suggested` spelling when only the other side of the jbroot exists. On RootHide also `system_job` and `load_rewrites`. Reads only | | no |
| `svc bootstrap <paths…>` | Load (modern name). On RootHide, rewrites each plist first; the result lists them under `patched` | | required |
| `svc bootout <paths…>` | Unload (modern name) | | required |
| `svc load <paths…>` | Load (legacy name); rewrites on RootHide like `bootstrap` | `--enable` (like `launchctl load -w`) | required |
| `svc unload <paths…>` | Unload (legacy name) | `--disable` (like `launchctl unload -w`) | required |
| `svc enable <label>` / `svc disable <label>` | Persistent override; does not start or stop the service | | required |
| `svc start <label>` / `svc stop <label>` | Request a start or stop; check `svc status` afterwards (KeepAlive can restart it) | | required |
| `svc kickstart <label>` | Spawn the job now (`launchctl kickstart`); a running instance is left alone unless `-k`, which kills it and waits for it to exit so the new process runs the binary on disk now. `pid` is the new process | `-k`/`--kill` (like `launchctl kickstart -k`) | required |
| `svc kill <signal> <label>` | Send a signal (1–31, or a name such as `TERM`) | | required |
| `svc remove <label>` | Remove a loaded service | | required |
| `svc getenv <key>` | Read a launchd environment variable | | no |
| `svc setenv <key> <value>` / `svc unsetenv <key>` | Change it and verify | | required |

## prefs (cfprefsd, like `defaults`)

`<domain>` is a preference domain such as `com.apple.springboard`, or an absolute physical path ending in `.plist`. Every prefs command runs while the device is locked. `--user` picks whose preferences: `mobile` (default, also under sudo; what apps and Settings use), `root`, `current` (the caller) or `any` (`/var/preferences`; writing it needs root).

| Command | Purpose | Key flags | Root |
| --- | --- | --- | --- |
| `prefs read <domain> [<key>]` | One key as `value`, `type`, `exists`, or the whole domain as `values: {key: {value, type}}` and `count` | `--user`, `--app <bundle-id>` (read the app's own preferences file in its data container; the arguments are then only `[<key>]`) | no |
| `prefs write <domain> <key> <value>` | Write through cfprefsd, synchronize, return the value read back | `--type string\|int\|float\|bool\|date\|data\|json`, `--user`, `--notify <darwin-notification>`, `--app <bundle-id>` (the arguments are then `<key> <value>`; `--user` does not apply), `--force` (with `--app`, stop the app if it is running) | no |
| `prefs delete <domain> <key>` | Remove the key and confirm it is gone; `removed` is false if it was not set | `--user`, `--notify`, `--app <bundle-id>`, `--force` (as for `prefs write`) | no |

Types on read are `string`, `int`, `float`, `bool`, `date` (ISO-8601), `data` (Base64), `array` and `dictionary`. On write, `date` takes ISO-8601 or epoch seconds, `data` takes Base64, `json` takes an array or object (no nulls). Put `--` before a negative number: `icli prefs write --type int <domain> <key> -- -7`. cfprefsd writes the plist to disk a few seconds after the command returns. On RootHide, the non-Apple domains of a process running inside the bootstrap are kept in the jbroot (the shell's `/var/mobile/Library/Preferences`), while `com.apple.*` domains use the system's own file.

## account, env, proc

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `account set-password [<user>]` | Set the bootstrap account's password. The password is the first line of stdin, never an argument | user defaults to `mobile` | required | any |
| `env info` | `layout` (`rootless`/`roothide`/`rootful`), `jbroot`, `rootfs_prefix`, `basebin_version`, `euid`, `spawns_processes: false` | | no | any |
| `env basebin` | Installed BaseBin version, optionally compared with a bundled archive | `--bundled <basebin.tar>` | no | any |
| `proc list` | Processes with PID, name, path | `--filter <text>` | no | unlocked |

Example: `printf '%s\n' "$NEWPASS" | sudo icli account set-password mobile`.

## probe

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `probe [-e <src> \| <file> \| -]` | Evaluate a JavaScriptCore script in-process and print one JSON line `{ok, result \| error, output}` | `-e/--eval <src>`; `-` reads stdin | no | any |
| `probe repl` | Interactive shell; `.help` lists what is available, `.exit` leaves; ^C abandons a half-finished statement, and ends icli while one runs | | no | any |
| `probe --app <app> [-e <src> \| <file> \| -]` | Evaluate the script inside that app's process, on its main thread, and print the same JSON line. Loads an agent into the foreground app if needed, without restarting it; omit the script or pass `repl` for a shell | `--check` (is an agent listening, and in which PID), `--timeout 30` (0.1–600, how long the app's main thread may take) | root to attach | unlocked |
| `probe --app <app> --inspect <target>` | Inspect a live window, root-controller, or view at x,y through the bundled FLEX object explorer; returns structured class, property, field and method metadata | `--values` (executes getters), `--limit 100` (1–500 per group), `--offset 0` | root to attach | unlocked |

A script reaches Objective-C classes through `ObjC.use('NSProcessInfo')` / `ObjC.classes.NSProcessInfo` and calls methods by name (`stringWithUTF8String_`, `_privateMethod`, or `obj['setValue:forKey:'](v, k)`); geometry structs cross in both directions as plain objects (`CGPoint` `{x, y}`, `CGSize` `{width, height}`, `CGRect` flat `{x, y, width, height}`, `UIEdgeInsets` `{top, left, bottom, right}`, `NSRange` `{location, length}`), while any other struct, non-null pointers and blocks are refused; a string, number, boolean or date comes back as a JavaScript value and `NSNull` as `null`, anything else as a handle with `$value`, `$class`, `$isClass`. `fs.ls/read/write/stat`, `console.log`/`print`, `sleep(ms)`, and `api(method, params)` (icli capabilities in process: `env.info`, `device.info`, `screen.info`, `svc.list`, `svc.status`, `app.list`, `proc.list`) are the prelude. `--app <app>` runs the script inside an app instead, where its live objects are, loading the agent into the running app when needed (root required); `app launch --probe` can still load it at launch; `--check` only says whether one is listening and never attaches, scripts run on the app's main thread with a `--timeout` (30 s), the app must be **in front** because iOS suspends a backgrounded app's threads and its agent then answers nothing, `api()` is refused there, `repl` supports `--app`, and a crash takes the app rather than icli. Scripts otherwise run **inline** in the icli process — a crash or hang takes icli down, so isolate one by spawning `icli probe` as its own process. There is no `--detach`, no `proc.run` and no `exit()`. A thrown script is `ok: false` with a nonzero exit, not a crash. On a platform without JavaScriptCore the command answers `ok: false` with the error `This platform has no JavaScriptCore`; the binary gains no process-launch import.

## sec

Security.framework Keychain commands use the calling process's access groups (`icli.test` is the default `--group` for writes). The separate `database` command can read protected metadata across groups when the process can read the system Keychain database. It never returns item values or encrypted blobs.

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `sec keychain list` | Matching items (metadata) | `--class generic_password\|internet_password\|certificate\|key\|identity`, `--service`, `--account`, `--server`, `--group` | no | any; Security.framework may deny locked items |
| `sec keychain database` | Protected database metadata, with source and per-table counts | `--class genp\|inet\|cert\|keys` | filesystem access (usually root) | any |
| `sec keychain get` | One item, including its data | same filters (class defaults to generic_password) | no | any; Security.framework enforces access |
| `sec keychain add` | Add an item | `--account` and `--data` required, `--service`, `--server`, `--label`, `--group icli.test` | no | any; Security.framework enforces access |
| `sec keychain update` | Replace an item's data | `--account` and `--data` required | no | any; Security.framework enforces access |
| `sec keychain delete` | Delete matching items | `--force` required | no | any; Security.framework enforces access |
| `sec ssl-killswitch` | Look for SSL Kill Switch files | | no | unlocked |

## net

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `net capture` | BPF packet capture to a pcap file | `--seconds 5`, `--interface en0`, `--filter '[tcp\|udp\|icmp] [src\|dst] port N [src\|dst] host A'` (terms joined with `and`), `--output <file.pcap>` | required (BPF device) | any |

## tests

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `tests` | On-device self-tests: device info, paths, processes, LaunchServices, files, Debian versions, screenshot, accessibility, OCR, a temporary Keychain item | `--expect-layout rootless\|roothide\|rootful` (stops on mismatch), `--registration-fixture <SelfTestFixture.app>` | no | any (screen tests need the device unlocked) |

The report has pass, fail and skip counts plus `complete`. A failed test exits nonzero. The tests do not reboot the device or change its settings.

## flex (complete FlexUltra port)

`icli flex --help` lists all imported commands. Use `--target <bundle-id|PID|process>`;
bring an app forward before its first request. `flex health` attaches the private
agent on demand. `flex heap instances <Class>` searches the full live heap,
including objects outside the UI tree; `flex object …` inspects and mutates returned
handles. `flex ui …`, `runtime …`, `trace …`, storage and experiment commands
retain the original FlexUltra spellings. `flex catalog` lists all 105 operations;
`flex mcp` serves all 102 original MCP tools over stdin/stdout. A process generation
change invalidates handles. `flex network record on|off|status --target <app>`
turns FLEX's HTTP recorder on or off; it is off by default, so history is empty
until then. Swift inspection is metadata only, Realm needs a loaded Realm
runtime, and target history records only agents observed by icli.
See `docs/usage/flex.md` for the complete contract. Existing `probe` remains available.
