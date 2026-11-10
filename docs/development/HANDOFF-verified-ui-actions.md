# icli handoff — 2026-10-31

> Latest lock follow-up: user requested a dedicated lock option. **`icli lock`**
> is built, installed, help-updated and device-tested. It confirms locked and
> screen-off, sends no input when already in that state, and never automatically
> retries. Awake lock screen handling and the saved `icli unlock` regression
> passed, with zero failures and stable SpringBoard PID. Current installed/local
> SHA-256: `ee1e7ee40a282ed6ef46bf6920fc06e871687781f60e14cc3e3ba16e0d802b4d`.
> See [lock validation](lock-command.md). All prior unlock/vault/UI changes and
> the saved phone credential are retained. No commit/push/CI/release.

> Latest native-unlock follow-up: user wants to type only the command in a phone
> terminal, with no passcode entry. **`icli unlock` is implemented, installed and
> provisioned in the phone's Keychain.** Requires a root terminal; no stdin or
> prompt. Dedicated `com.korboy.icli.unlock` group, device-only after-first-unlock item;
> same existing full-unlock engine/ledger/guards, no retry. Windows vault remains
> intact; new `icli-unlock --provision-phone` transfers it securely once. Both
> 12 boundary tests and 18 old policy tests passed. Actual locked/screen-off ->
> `icli unlock` with stdin left open succeeded, zero failures, same SpringBoard
> PID. Current installed/local hash:
> `f602337c51f9548fc7d64c03b60c5c09a5e8026d96fc85db4f8382eda374f955`.
> See [saved-command validation](passcode-unlock.md#saved-command-validation-2026-10-31)
> and [usage](../usage/device-settings.md#unlock-directly-from-the-phone-terminal).
> Earlier no-phone-storage statements are superseded by this explicit request.
> No commit/push/release. RuneLite work remains a plan only.

> Latest direct-activation follow-up: user authorized proceeding with direct AX
> activation research and implementation. Strict opt-in `--method accessibility`
> is installed; default touch behavior is preserved. Current installed/local
> SHA-256 is `566261bec5c7bf52c8a3bc8165bfef28535c24751abeda54c23cc0f489b4c22f`.
> 37 engine cases, 10 direct-mode/reference device scenarios, all 12 existing
> touch-mode scenarios, unsupported/locked direct refusals, touch-detector
> positive control and real vault unlock passed. No coordinate fallback exists
> in direct mode. Ordinary native UIButton activation was unsupported on this
> fixture; a supporting handler was tested with zero touches. Movement could
> not redirect to a decoy; replacement could not reuse the retained reference.
> A late overlay still allowed the original handler to run underneath it.
> See [native evidence and limits](direct-ax-activation.md). Unlock/vault work
> preserved; no commit/push/CI/release. Earlier installed hashes below are history.

> Implementation follow-up, 2026-10-31: the user's subsequent request explicitly
> authorized implementing, building, installing and self-testing Verified UI
> Actions. It is now implemented as `icli ui perform` and the reusable
> `performVerifiedUIAction` API. The universal binary is installed and matches
> SHA-256 `930214309908657e348707108788da06605170c3d99d34fc04398d8ea95ddc2e`.
> Validation: 33 engine cases, 12 physical-device scenarios, 18 existing unlock
> policy cases, locked-action refusal, a real Windows-vault full unlock and a
> legacy UI tap all passed. Unlock/vault source and scripts were preserved;
> the shared header gained only an additive process-identity declaration.
> See [implementation and evidence](verified-ui-actions.md) and
> [usage](../usage/interaction.md#verified-ui-actions). No commit/push/CI/release.
> The research-only authorization and installed hash in the original handoff
> below describe the earlier state and are superseded by this follow-up.

## Start here and authorization

Workspace: `/home/korboy-wsl/Projects/icli-src/icli` (parent cwd sometimes
`/home/korboy-wsl/Projects/icli-src`). HEAD `e295e0f`, version 0.11.0.

The latest substantive task was **research only**: analyze the whole program
and select the single highest-impact next feature. The user explicitly said
not to modify files or begin implementation. Analysis is complete. They then
asked for this handoff. **No implementation of the recommended feature is
authorized yet.** Read the next user prompt before acting; if they merely
ask what's next, explain rather than implementing.

No commits, pushes, CI or releases were performed. There is substantial dirty
and untracked work from the completed unlock project; preserve all of it.
Do not mistake untracked production source or tests for disposable clutter.

## Recommendation delivered: Verified UI Actions

One command should check the intended app/target, send an action once, then
observe a caller-specified visible result and return evidence. This targets
the gap between input dispatch and successful UI behavior. It is a proposed
feature, not an existing capability and not a promise of atomic GUI control.

Illustrative CLI (not implemented):

```sh
icli ui perform --app com.example.editor \
  --tap-identifier document.save \
  --expect-appeared document.saved --timeout 10
```

Proposed behavior:
- Require the intended verified foreground app and interactive device.
- Resolve one enabled target; refuse ambiguous matches by default.
- Recheck app/process identity, orientation and target geometry before input.
- Dispatch once, then observe appeared/disappeared/value-change conditions.
- Distinguish refusal before dispatch, verified result, and sent-but-unconfirmed.
- Never automatically retry a potentially consequential action after timeout.
- Compare pre/post observations: an already-present label does not prove success.
- Return compact UI differences and timings; screenshots are optional evidence.
- Reuse supported notifications where available; bounded polling otherwise.
- Avoid mandatory OCR, image models, permanent services or idle overhead.
- Admit the race between checks and a GUI tap; no exactly-once claim across
  crashes, no rollback claim, no claim UI evidence proves a server transaction.

Why selected: improves most UI automation tasks, rather than adding another
isolated device command. A macro runner or new transport would still leave
callers responsible for ambiguity, timing and outcome verification. Existing
strengths are native device access, JSON output, a self-contained executable,
reusable libraries and broad control/diagnostic commands.

## Verified architecture and code anchors

- `Package.swift`: CLI (`Sources/icli`) -> `IcliKit` -> ObjC `IcliPrivate`;
  Foundation-only `IcliSystem` and `IcliLaunch` are separate reusable products.
  `IcliProbe` supplies in-process JavaScriptCore reflection/scripting. No
  subprocess spawning in the device executable; keep that invariant.
- `Sources/IcliKit/Input/Screen.swift:340`: ElementSelector, defaults to
  contains text and index 0. Identifier matching also accepts an exact label.
- Same file `:385`: selectedElements queries up to 2000, refuses truncation.
- Same file `:393`: tapElement chooses a matching index, dispatches a coordinate
  tap and returns `tapped: true`; it does not verify the resulting UI state.
- Same file `:405`: waitForElement polls an independent presence condition.
- Same file `:281` and `:320`: describeScreen shares image capture with OCR,
  collects AX separately, and flags unverified/changed foreground bundle.
  This does not prove screen consistency within the same app.
- `Sources/IcliPrivate/Accessibility.m:111`: serializes enabled/clickable state,
  activation point, frame, label/value/id and traits. `:210`: hit testing.
  Queries return flat rows, not persistent element handles or a full hierarchy.
- `Sources/IcliKit/Apps/Apps.swift:68`: frontmostPID already requires verified
  foreground identity. Do not suggest that existing UI commands lack all guards.
- `Sources/IcliLaunch/Launch.swift`: lock state, foreground app and launching.
- `Sources/icli/ScreenCommands.swift:326`: UI tree/at/tap/wait/wait-gone CLI.
- `Sources/IcliKit/Probe.swift:90`: default api() methods are deliberately a
  small read-oriented set, not a complete UI action API. Hosts can inject APIs.
- `Sources/IcliKit/Envelope.swift`: CLI lock policy, JSON and exit handling.
  New library operations must enforce their own relevant guards too.
- `Tests/TestHost/main.m`: independent state.json oracle, counter controls,
  delayed label, input, gesture and scrolling fixtures.
- `scripts/acceptance.py:285`: existing AX tests; they separately inspect
  TestHost state after taps. `docs/development/testing.md`: test boundaries.

Suggested architecture if implementation is later authorized: add typed
requests/results/conditions in `Sources/IcliKit/Input/VerifiedAction.swift`,
reuse existing primitives, add CLI under UI, and test with TestHost. Keep the
execution engine out of argument-parsing code. No framework rewrite needed.

Suggested stages:
1. Specify target uniqueness, transition predicates, deadlines and outcome states.
2. Implement one complete identifier tap + visible-result verification path.
3. Test duplicate labels, moving targets, overlays, foreground changes and slow
   responses; independent oracle must show at most one tap per live request.
4. Add bounded evidence and optional failure capture.
5. Validate physical-device behavior, compatibility and resource use; expose
   the same implementation through IcliKit and document unsupported cases.

Moderate implementation complexity; private AX behavior, occlusion and races
are the hard parts, not command syntax. Speed gains are unmeasured. Fewer host
exchanges are plausible; do not invent percentages or performance guarantees.

External primary sources checked for comparison (not claims of novelty):
- https://docs.maestro.dev/maestro-flows/flow-control-and-logic/wait-commands
- https://docs.maestro.dev/reference/commands-available/retry
- https://appium.github.io/appium-xcuitest-driver/latest/settings/
Maestro already has assertions/retries, Appium synchronization controls. The
recommendation is about fit for icli, not claiming competitors lack verification.

## Completed prior project: standalone full unlock and Windows vault

Authoritative detailed findings, implementation reasoning, fault fixes and
commands: `docs/development/standalone-unlock-research.md`. Also read
`docs/development/passcode-unlock.md` and `docs/usage/device-settings.md`.
Avoid rebuilding or redoing this completed work just to start the new chat.

The installed icli uses the supplied passcode directly with SpringBoard's
unlock method. The original upstream MKBUnlockDevice path remains without
`--dismiss`; it unlocked the keybag but left the lock screen visible in tests.
Full unlock is not passcode bypass. It has no helper/service or keypad dependency.
On the tested phone the single-argument selector exists; the four-argument
selector does not. Both branches have synthetic fixture coverage.

Freshest completed audit evidence:
- `.build/full-unlock-audit-validation.json`: real locked/screen-off -> awake,
  unlocked through Windows vault, zero keybag/ledger failures, SpringBoard pid
  46125 unchanged, installed/local SHA-256 match.
- Installed hash: `d934d9047f07a181c2a3d58211db1c74c112676be48fd0fb3472058d3340341a`.
- `.build/full-unlock-failures.json` and `.build/device-audit/failures.json`:
  ten native failure cases each on macOS and owned arm64e phone fixtures.
- `.build/full-unlock-final-regression.log`: 18 policy tests and both selector
  fixtures. Five separate ledger tests also passed.
- `.build/package-verification.json`: both iOS package payloads match installed
  hash, per-architecture signing/import/floor/dependency/ownership checks pass.
- Full build and audit logs under `.build/full-unlock-*.log`.

Do not claim 100% optimal or failure-proof: no performance benchmark, no broad
iOS compatibility proof, SIGKILL/power loss cannot be deferred, a live remote
callee that never returns cannot safely be abandoned. Unexpected callee faults
may retain context for safety; raw owned input is wiped and incomplete cleanup
reported. Further details are already in the research document.

Tested phone: iPhone16,2 (15 Pro Max), iOS17.1.1, rootless Dopamine3.0.12.
No real wrong passcode was used in the audit. Do not write credentials here.

## Windows command launch — most recent implementation change

User typed `icli-unlock` in Windows Command Prompt and got command-not-found.
Fixed by adding `scripts/icli-unlock.cmd` and installing identical content to
`C:\Users\korbo\.local\bin\icli-unlock.cmd`, an existing Windows PATH folder.
It runs `wsl.exe -d Ubuntu --exec /home/korboy-wsl/bin/icli-unlock` with supplied
options and propagates exit status.

WSL `~/bin/icli-unlock` symlinks to `scripts/unlock-from-windows-vault`, which
uses `scripts/windows-unlock.ps1`. Credential is in Windows Credential Manager,
selected only after same-connection device-identity verification; secret travels
through SSH stdin. Never log/read out the vault or store it in argv or files.

Both `cmd.exe /d /c 'icli-unlock --check'` and `cmd.exe /d /c icli-unlock` were
executed successfully. The latter really unlocked the phone (attempted true,
ui_unlocked true, ledger_failures 0, status0). Usage docs were updated.

Cleanup checked: no Mac/phone RPC fixture processes, no temporary fixture
folders, no icli.new, no legacy phone passcode or .arm files. Kept production
source, tests, build evidence, packages and intentional vault credential.
The latest package listing found no installed UnlockHelper package; older
research/usage prose says it was left installed at migration time. Do not
repeat that older snapshot as current or uninstall unrelated software.

## Work rules and practical environment

- User wants autonomous execution, concise plain English and evidence, not
  repeated permission questions or instructions to perform our tests.
- Strictly honor research-only scope until new implementation authorization.
- Never guess actual private API behavior; inspect source/binary or reproduce.
- Preserve dirty work. No commit/push until a fix is confirmed by user; no
  unsolicited CI/release/publishing. No AI attribution in commits.
- No streaming logs or gh run watch. Use one-shot snapshots. Use RTK for noisy
  builds/tests only while preserving real commands/status and full logs.
- No subagents unless explicitly requested or required by applicable instructions.
- Phone SSH is `ssh-iphone`; uploads `scp-iphone`. Never hardcode the IP.
  Phone tools are under `/var/jb/usr/bin` and `/var/jb/bin`.
- Original user AGENTS says stop after install, but for the completed unlock
  work they explicitly overrode this: test it yourself and work autonomously.
  Apply the next task's specific authorization rather than assume global scope.
- Mac: `ssh mac`; build mirror
  `/Users/korboy/Projects/icli-src/icli-update-e295e0f`.
- Existing `scripts/build-install.sh` syncs source, builds universal arm64+arm64e
  on Mac with full logs, copies and installs atomically on phone. Do not run
  during research-only continuation.
- Existing unrelated tvOS SDK/stub/xpc build issues remain; do not chase them
  as part of the proposed UI feature without scope justification.
- Appropriate skills: `diagnose` for reproducing faults, `tweak-development`
  for private iOS/runtime work, `handoff` for handoffs. Read their SKILL.md when
  applying. No need to invoke architecture-refactor skills solely by keyword.
- No global memory was updated. This document is the durable handoff.

## Suggested next-chat prompt

Read `/home/korboy-wsl/Projects/icli-src/icli/docs/development/HANDOFF-verified-ui-actions.md`.
Preserve all existing unlock/vault changes. The proposed next feature is
Verified UI Actions; it has not been implemented or authorized. Continue with
my new instruction, and distinguish existing behavior from the proposal.
