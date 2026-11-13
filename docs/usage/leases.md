# Concurrent work and interaction leases

A lease protects interaction and shared device state. Without the holder's
`ICLI_LEASE` token, guarded commands fail with exit 75 and `error: leased`.
Background commands run without a token and never renew, acquire or release
the lease, even when called with the holder's token. Guarded holder commands
renew it; for a run that only observes the phone, explicitly renew with
`lease acquire --owner <same-owner> --ttl <seconds>` using the existing token.
The lease expires after its idle time (default 600 seconds) without renewal.

| Runs alongside a lease | Requires its token while held |
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

`lease`, `status` and the owner indicator remain available to other runners.
The indicator label passes touches through and is omitted from icli captures.
