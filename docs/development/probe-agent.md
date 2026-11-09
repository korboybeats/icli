# App probe attachment and REPL

`icli probe --app <app>` attaches to the foreground app when its socket has
no listener. It uses the temporary-thread transport in `FullUnlock.m` to
load the agent and call its explicit start function. It does not call any
unlock methods or restart the app. An existing listener is reused;
`--check` only reports and never attaches. Script errors and timeouts never
trigger attachment or an automatic repeat of the script.

The agent binds its socket before its start function returns. The client
then verifies the agent's bundle ID and PID. This needs no startup sleep.
The remote REPL uses the existing terminal editor and multiline scanner,
with evaluation delegated to the app. Each request carries the original
PID; the agent refuses a different PID before evaluating any source.

## Discoveries to preserve

- LaunchServices' executable and `proc_pidpath` may spell the same file
  `/var/...` and `/private/var/...`. Compare their `realpath` results.
  The first device attempt refused the unequal spellings before loading
  an agent; normalizing both paths resolved it.
- A `dlsym` function pointer belongs to the target's pointer authentication
  context. Strip it before handing it to the existing RPC transport, which
  signs thread-state PC through the kernel's conversion API.
- Closing or interrupting the client can leave the app evaluating a script.
  Accepted sockets use `SO_NOSIGPIPE` so returning an answer to that closed
  connection cannot terminate the app. Ctrl-C does not cancel the script.
- Output in a remote REPL is collected until each statement returns.
  `.exit` leaves the agent and its JavaScript context alive in the app.
- The app still needs to be foreground and responsive. `--timeout` controls
  script evaluation; it does not make the synchronous attach transport
  cancellable while a target call is executing.

## Device acceptance, 2026-11-06

Built and installed `0.11.0+korboy23` on the rootless iPhone 15 Pro Max,
iOS 17.1.1. Installed executable and agent hashes matched the build:

```text
icli: a3f1493d8e40a50f7a527a027bcd6d25388e488f14bbfe7976de5f8c6f3b5799
agent: 82893003b667ffc08968284221b3767e2ce238596c5a7c6deb1dc7b39ac9a313
```

- ContainerFixture: normal launch PID `42402`, no agent, then on-demand
  attachment and evaluation at the same PID. UIKit geometry was real and
  `NSThread.isMainThread()` returned true.
- Mint Mobile: normal launch PID `65886`, `--check` reported no listener,
  then attachment and all shell checks passed at that same PID.
- Existing `app launch --probe` path passed on ContainerFixture PID `66014`.
  Ordinary relaunch produced PID `66027`; `--check` again found no listener,
  and a new probe attached without another special launch.
- Remote REPL checks covered shared variables, multiline functions, print
  output, thrown errors followed by successful evaluation, `.help`, `.exit`,
  and the no-script shell form. Exiting retained the app and its variables.
- A real terminal test confirmed Ctrl-C abandons unfinished input. A second
  test waited for an app-written marker, interrupted the client during
  evaluation, then released a file barrier: the script finished and the
  agent answered again at the original PID.
- A request carrying PID `42402` after the app had relaunched was refused;
  its proposed variable mutation remained `undefined` in the new process.
- Existing host probe suite: 170 checks, no failures. Existing remote-call
  fixture passed twice, including exact selector, arguments and main-thread
  checks. Binary import verification passed for both CLI slices and agent.

Repeat the device checks with an ordinary foreground test app that has no
agent yet, passing the current device lease token in the local environment:

```sh
python3 scripts/test-probe-agent-device.py --app <bundle-id> --require-attach
```

The script verifies the installed executable hash before testing. It never
quits or restarts the app. Reports and full build/host logs from this run are
under `.build/probe-agent-*.json` and `.build/probe-limits-*.log`.

These results establish behavior on this phone. Attachment on other
jailbreaks, iOS versions, arm64-only hardware and tvOS was not device tested.
