# Concurrent work and interaction leases

A lease coordinates automated interaction and shared device state. Commands
with terminal input always run, including when output is redirected. You can
use `icli cc set silent on` directly in your phone's terminal while an agent
holds a lease.

For piped input, scripts or SSH without a terminal, use the global override:

```sh
icli --ignore-lease cc set silent on
```

The override applies to the whole command, including batch/session steps,
probe API calls and Flex requests. A flag on one batch/session step affects
only that step, including when parsing or execution fails. Terminal input is
detected before a session redirects its input internally. Bypassed commands
do not acquire, renew, release or take over the current lease. Device-lock,
permission and destructive-action checks still apply. The override allows
commands to interrupt a runner's test.

Without terminal input or `--ignore-lease`, guarded commands without the
holder's `ICLI_LEASE` token fail with exit 75 and `error: leased`.
Background commands run without a token and never renew, acquire or release
the lease, even when called with the holder's token. Guarded holder commands
renew it; for a run that only observes the phone, explicitly renew with
`lease acquire --owner <same-owner> --ttl <seconds>` using the existing token.
The lease expires after its idle time (default 600 seconds) without renewal.

| Runs alongside a lease | Automated commands requiring its token or the override |
| --- | --- |
| All `fs` operations; logs and crash reports | Touch, typing, buttons, navigation, clipboard and accessibility UI queries |
| App lists, search, running/frontmost, info, handlers, schemes, binary/data paths, network/permission reads | App launch, stop, reset, install/uninstall, registration, permissions/network changes and URLs |
| Package info, extraction, status, comparison, lists, repos/add-repo and tweaks | Package install/removal, SpringBoard changes and account changes |
| Device info/jetsam, boot-logo rendering, settings getters, network/IORegistry reads | Settings changes, lock/unlock, reboot and simulated location operations |
| Service lists/status/print/dump/paths/getenv; preference reads; notify get; packet capture | Service/environment mutations, preference writes/deletes and notify post |
| Screen info, screenshots (including `--stdout`), OCR, recording and screenshot waits | `screen describe` (uses accessibility), arbitrary `probe` scripts, `flex` operations and full self-tests |
| Keychain list/database metadata and SSL killswitch status; passcode status | Keychain value retrieval/mutations and passcode changes |

Batch and session apply each command's own policy. A background batch starts
without the token; a guarded step still fails with 75 before doing its work.
New commands require the lease unless explicitly marked as background in
source. Background failures do not collect screenshot/accessibility failure
artifacts, so unrelated file work cannot trigger UI inspection. Device-lock
checks, file permissions and `--force` requirements are unchanged. File work
can still conflict when tasks edit the same files; the lease is not a file lock.

Parallel sessions ([Hidden App Sessions](parallel.md)) are authorized by their
own tokens instead: `icli parallel` and commands given `--parallel` run without
the lease and never acquire, renew or release it, and runners in different
sessions do not block each other or the lease holder.

`lease`, `status` and the owner indicator remain available to other runners.
The indicator label passes touches through and is omitted from icli captures.
