# Standalone unlock: verified findings, 2026-10-31

The local implementation is installed and has unlocked the physical iPhone
using a passcode supplied through stdin, then again through Windows Credential
Manager after the old phone passcode and arm files were removed. The second
run returned `attempted: true`, `ui_unlocked: true`, `result: unlocked`,
`lock_state: 0`, `locked: false`, and `screen_off: false`. Failed attempts and
ledger failures remained zero. SpringBoard stayed at pid 46125.

## Scope and device evidence

The user requested UnlockHelper's behavior directly inside icli, without a
separate tweak, helper service, saved phone passcode, or simulated keypad.
They explicitly authorized temporary execution inside SpringBoard and later
instructed the agent to run installation and device tests autonomously.
They also explicitly selected Windows vault storage for unattended unlocks.

The tested phone is an iPhone 15 Pro Max (`iPhone16,2`), iOS 17.1.1, rootless
Dopamine basebin 3.0.12. These results do not establish compatibility with every
iOS release or jailbreak.

| Check | Evidence |
| --- | --- |
| Direct unlock | Started locked with screen off; returned attempted/unlocked/awake, exit 0 |
| Windows vault unlock | Started locked with screen off, after deleting legacy files; same successful result, exit 0 |
| Independent state check | Zero failed attempts, zero ledger failures, unlocked keybag and screen; frontmost app query succeeded |
| SpringBoard continuity | pid 46125 before and after; no new SpringBoard crash report during these tests |
| Caller architectures | `lipo -archs` reported `arm64 arm64e` |
| Installed artifact | Downloaded installed executable through SSH/tar and matched its SHA-256 to the local artifact |
| iOS packages | Both layouts passed architecture, per-slice signing/entitlements, iOS 15 floor, system dependency, ownership and matching-content checks |
| Guard policy | All 18 production-policy tests passed, including signal-scope ordering, unlocked-device preflight and no-retry/budget cases |
| Host RPC | Both selector fixtures passed twice, checking exact arguments, main-thread execution and released request memory |
| Phone RPC | Authenticated four-argument fixture passed twice; one-argument fixture passed twice with the same engine |

Nonsecret result snapshots live under `.build/full-unlock-phone-result.json`,
`.build/vault-unlock-phone-result.json`, `.build/device-rpc/`, and the matching
build/test logs. They contain no supplied device passcode.

The audited installed build's complete lock/unlock/state/hash record is
`.build/full-unlock-audit-validation.json`. Its SHA-256 is
`d934d9047f07a181c2a3d58211db1c74c112676be48fd0fb3472058d3340341a`.
Both iOS packages and the local artifact match that installed hash.

## Actual UnlockHelper selector

The earlier notes incorrectly claimed that the four-argument method had been
observed working on this phone. Runtime inspection inside SpringBoard proved:

- `SBLockScreenManager` and its singleton exist.
- `attemptUnlockWithPasscode:mesa:finishUIUnlock:completion:` is absent.
- `attemptUnlockWithPasscode:` exists and the singleton responds to it.

The old tweak's log recorded `unlock requested`, which is its one-argument
fallback branch; the four-argument branch logs a different message. The
implementation now uses the same preference order as the tweak: use the
four-argument method with `mesa=NO`, `finishUIUnlock=YES`, `completion=nil` if
available, otherwise use the one-argument method. Both execute on SpringBoard's
main thread through NSInvocation. No fallback is guessed from the OS version.

## Task-access denial

The initial profile returned Mach 5 for SpringBoard control and even for its
own task, while read access succeeded. A same-binary, same-signing-tool,
same-path comparison isolated `com.apple.system-task-ports.read`:

1. Removing only that key passed preflight.
2. Restoring it reproduced `self=5, read=0`, exit 6.
3. Removing it again passed, exit 0.

The production profile omits the read-only key and the entitlement checker
rejects that conflict. Adding the debugger entitlement alone did not fix it.
The existing `--check` early return also skipped backend access on an already
unlocked phone; two regression cases failed before that fix and passed after.

## Authenticated thread state

An arm64 driver against an owned arm64e fixture reproduced
`thread_set_state: KERN_PROTECTION_FAILURE (2)`. Apple's iOS 17 XNU source
explicitly rejects a JOP-disabled caller setting state on a JOP-enabled target.
The iOS executable therefore contains arm64 and arm64e slices, preserving
older-device support while selecting an authenticated caller on this phone.

The engine uses `thread_convert_thread_state` to translate between caller and
target signing keys. It neither shares target keys nor launches a subprocess.
Exception replies also preserve that exception's random PC/LR diversifier;
omitting it crashed the disposable fixture on restoration. Original return
addresses retain their IB-signed form, and other restored LR values are made
user-signed so the kernel does not substitute the faulting call's LR.

Direct extraction of the pthread's task-local Mach right failed on the phone.
The engine obtains the created pthread's unique id with `pthread_threadid_np`,
then selects its control right from `task_threads` by that id. No pthread/TSD
layout or private struct offsets are assumed.

Only a verified receive-only Mach trap at a waiting thread may be redirected.
The original receive arguments are restored and its `svc #0x80` is restarted;
replaying a send or resuming a canceled receive as completed is forbidden.
An owned temporary pthread constructs the request and exits during cleanup.
Request bytes are wiped and its allocation is released after confirmed exit.
Foundation and iOS may retain their own temporary copies; complete erasure of
system-owned memory is not claimed.

## Windows vault and migration

`scripts/unlock-from-windows-vault` invokes `scripts/windows-unlock.ps1`.
`~/bin/icli-unlock` points to the shell entry point on this workstation.
The credential is a generic Windows Credential Manager entry named
`Korboy.icli.Passcode/<device UDID>`, under the current Windows user, with
local-machine persistence. Only this entry is read; unrelated credentials
are not enumerated.

The native credential buffer is converted to UTF-8 in memory and written to
SSH stdin. The passcode is absent from subprocess arguments, output, project
files, and phone files. The tool checks device identity before selecting the
entry and again on the very SSH connection that executes icli. It never
retries an unlock. Managed byte buffers and owned native buffers are cleared.
The Windows account remains the access boundary for the stored credential.

An identity handshake completes before the credential is read or sent. A
negative test supplied a mismatched device id and a nonexistent credential
name: it returned the identity refusal, proving that even credential lookup
was skipped. The final real vault-backed cycle then succeeded with this
handshake and the final installed artifact.

The legacy `/var/mobile/Library/Preferences/com.korboy.unlockhelper.passcode`
and `.arm` files were deleted only after the direct replacement succeeded.
Their absence was checked before the vault-backed unlock. The old tweak
package was not uninstalled or resprung, and no notification to it was used.

## Failure-path audit

The focused audit reproduced these faults before fixing them:

- A data read from the protected return page was mistaken for a completed
  call. Completion now requires the faulting instruction pointer itself to
  equal that page, after kernel thread-state translation.
- Raw request bytes survived an unexpected callee fault. Cleanup now erases
  the owned raw buffer even when further target execution is unsafe.
- A failed request-region deallocation still allowed a clean success report.
  The failure now produces an explicit incomplete-cleanup result.
- Target termination during an active call left the client waiting forever.
  A temporary dead-name notification now ends that wait, preserves any
  pre-existing observer, and balances the notification's extra reference.
- SIGINT, SIGHUP and SIGTERM delivered on another thread could terminate the
  client before cleanup. Process-wide dispositions now defer them until
  target cleanup, input wiping and ledger persistence are finished. The
  previous dispositions are then restored and pending signals re-raised.
- Failure to restore an existing exception handler was silently ignored.
  Exact masks are restored without a blanket clearing step; one idempotent
  restoration retry tolerates a transient failure. Persistent failure is
  reported as incomplete cleanup, and the unlock call is never retried.

Ten native cases pass on macOS and against disposable arm64e phone fixtures:
data access to the return page, secret wiping after a callee fault, failed
deallocation, target death before replying, transient and persistent handler
restoration failure, target death during the unlock, and each of the three
deferred signals. All use synthetic input, never a wrong real passcode.
Reports are `.build/full-unlock-failures.json` and
`.build/device-audit/failures.json`. Both selector fixtures, 18 policy tests
and five ledger tests also pass. Signal tests use an explicit pipe handshake
to deliver on an unblocked background thread while the fixture is inside
its unlock method; no timing delay stands in for that condition.

After these changes the universal executable was rebuilt, signed and installed.
Vault preflight made no attempt; a subsequent real cycle started with the
phone locked and screen off, then returned attempted/unlocked/awake. Keybag
and ledger failed-attempt counts remained zero, and SpringBoard stayed at pid
46125. The installed executable, local artifact and both verified iOS package
payloads share the audited hash above.

The reply-death experiment returned kernel success while consuming the dead
receiver's send-once reply right on both platforms. It was not a reproduced
send failure. Defined recoverable send failures release pseudo-received
reply rights following Apple's `mach_msg_server` contract. Test readers
require an explicit PASS result as well as exit zero.

A live callee that never returns still cannot be safely abandoned: the client
must retain its reply channel until return or target-thread death. An
unexpected callee fault can leave locks held, so uncertain cleanup does not
run more target code or free a potentially live stack; it wipes the owned raw
input and reports the retained context. SIGKILL and power loss cannot be
deferred, and complete erasure of system-owned string copies is not proven.
This audit establishes the cases above, not universal failure immunity or
measured optimal performance.

## Reproduction and remaining platform boundary

- Host RPC: `python3 scripts/test-full-unlock-rpc.py` and
  `ICLI_RPC_SIMPLE_UNLOCK=1 python3 scripts/test-full-unlock-rpc.py`.
- Phone RPC: build/sign the existing C fixture and driver for arm64e/iOS;
  use `scripts/test-full-unlock-rpc-device.py --target <fixture> --driver <driver>`.
  The script runs only against the fixture it launches and uses synthetic input.
- Host failure cases: `python3 scripts/test-full-unlock-failures.py`.
- Phone failure cases: build/sign the quiet fixture and `fault-driver.m` for
  arm64e/iOS; run `scripts/test-full-unlock-failures-device.py --target <fixture>
  --driver <fault-driver>` from this workstation.
- Phone preflight: `icli-unlock --check` (no unlock attempt).
- Full unlock: `icli-unlock` from this workstation, or icli's existing protected
  stdin/TTY inputs with `device passcode unlock --dismiss`.

Full unlock was tested only on the physical phone above. A broader tvOS build
attempt hit existing SDK/setup issues in the IOKit stub and missing `xpc/xpc.h`;
those unrelated sources were not changed. iOS package verification checks each
signed architecture independently rather than treating the universal file as
a thin arm64 executable.

Original tweak source: `~/Projects/tweaks/UnlockHelper/Tweak.x`.
Kernel contract: Apple's `xnu-10002.41.9/osfmk/arm64/status.c` and
`osfmk/kern/exception.c`; thread conversion is defined in
`osfmk/kern/thread_act.c`.
