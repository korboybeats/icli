# Apps, Files, and Logs

Use `app list` to find an app's bundle identifier. Replace `example.bundle.id` with an app you installed; file paths refer to the device:

```sh
icli app list
icli app list --user                           # the user's apps only
icli app settings example.bundle.id            # Settings at the app's own page
icli app info example.bundle.id
icli app launch example.bundle.id
icli app launch Settings                # by name, when only one visible app has it
icli fs write /tmp/example.txt 'Hello from icli'
icli fs read /tmp/example.txt
icli fs read /tmp/example.txt --offset 6 --limit 4096 --binary
icli log syslog --seconds 3 --level error
icli log syslog --seconds 10 --subsystem com.example.tweak --message-contains 'loaded' --max-lines 20
icli log crashes --bundle-id example.bundle.id
icli log crash /var/mobile/Library/Logs/CrashReporter/example.ips --max-bytes 65536
icli log crash /var/mobile/Library/Logs/CrashReporter/example.ips --summary
icli log crash --bundle-id example.bundle.id --summary   # that app's newest crash
icli log crashes --kind spin                   # also crash, diagnostic or log
```

`log syslog` filters by process name (`--process`, a case-insensitive substring), `--pid`, `--subsystem` (with its dotted children), `--category` (exact), `--message-contains` (case-sensitive) and minimum `--level` (`all`, `debug`, `info`, `default`, `error`, `fault`). Every filter runs before `--max-lines`, so unrelated lines on a busy device never use up the cap; `truncated` says more lines matched than were kept. `log crash --max-bytes` reads at most that many bytes of a report, cut back to a whole character, and reports `truncated` and the whole file's `size`.

`log crashes --kind` sorts reports by file name: `spin` is a spin or hang report (`.spin`, `.hang`, `_hang`, or a name starting `stacks`); among `.ips` and `.crash` reports, `diagnostic` is a system report whose name contains `jetsamevent`, `excresource`, `_resource`, `panic`, `watchdog`, `lowbattery`, `analytics`, `sfa-`, `xp_amp_`, `sirisearchfeedback`, `applicationnotresponding` or `proactive_event_tracker`, and `crash` is the rest; `log` is any other file. Without `--kind` the list is every `.ips` and `.crash` report, as before. `log crash --bundle-id <id>` reads that app's newest `crash` report. `log crashes --limit N` lists the newest N (`count` stays the total and `truncated` is true). `log crash --summary` names the report's `bug_type` in `report_type`: 109 and 309 crash, 308 user fault (the process kept running), 298 jetsam (memory pressure), 288 stackshot, 202 resource (CPU), 145 resource (disk writes).

`app list --user` keeps the apps LaunchServices types `User`, leaving out system and bootstrap apps. `app settings <app>` opens Settings at the app's own page with `prefs:root=<bundle id>` and confirms the page's title is the app's name; an app with nothing to set there has no page, and the command fails with `no_settings_page`. `url open --check-changed` captures the screen first, then waits frame by frame (up to `--timeout`, default 5 s) for it to change; `screen_changed: false` says the URL showed nothing new.

### Reading Files in Chunks

`fs read --offset <bytes>` starts at that byte position (default 0), and
`--limit <bytes>` caps the returned chunk (default 524288, range 0–67108864).
Negative offsets fail. At or past the end, content is empty and `truncated`
is false. `size` reports the whole file size observed before reading;
`truncated` says more bytes were available beyond the returned chunk.

For repeated reads of an append-only log, use `--binary`, Base64-decode
`content`, and advance the offset by the decoded byte count. Byte boundaries
can split UTF-8 characters; character counts and Base64 string lengths are
not byte offsets. If `size` becomes smaller than the saved offset, reset to 0.
This detects shrinkage, but cannot reliably detect replacement by another
file of the same or greater size. Each command reads one chunk; it does not
keep watching the file.

### Permissions and Fresh Data

```sh
icli app permission get example.bundle.id
icli app permission grant example.bundle.id camera microphone location
icli app permission reset example.bundle.id          # every permission back to never asked
icli app reset example.bundle.id --force              # empty its data container, as a fresh install has it
```

`app permission` sets privacy permissions without the system prompt: TCC services by name, and location through locationd (`location` is While Using, `location-always` Always). A reset returns them to never asked, so the app's next request shows the real prompt. iOS stops a running app when any of its permissions change. `app reset` stops the app, empties Documents, Library, tmp and SystemData in its data container, clears its preferences through cfprefsd so no cached value survives, and resets its permissions unless `--keep-permissions` is given. Keychain items and group containers stay, as they do when an app is deleted.

Upload a package before installing it:

```sh
sudo icli app install /tmp/example.deb
sudo icli app install /tmp/example.ipa
sudo icli app install /tmp/example.ipa --container
```

DEB operations read archives and update the bootstrap's dpkg database directly. IPA installation validates archive paths and app metadata, preserves the app's signature, and requires the bootstrap to support running it. This IPA installation path does not overwrite apps installed outside icli. With `--container`, the app is installed into its own app container under `/var/containers/Bundle/Application`, with a data container, and registered as a System app (`--registration user` for a User app: FrontBoard refuses to launch an ad-hoc signed User app with "No code signature found", while the same app registered as System launches, as TrollStore Lite registers its apps); reinstalling upgrades it in place and `app uninstall --force` removes both containers. A `--container` install re-signs every Mach-O in the app ad-hoc first, as TrollStore Lite does with ldid, but inside icli: app and extension binaries keep their entitlements and get `jb.pmap_cs.custom_trust` = `PMAP_CS_APP_STORE` (Dopamine 2.1.5 and later run them at App Store trust), so decrypted App Store and developer-signed IPAs launch. The signature is the one `codesign -s -` makes (SHA-256 CodeDirectory, XML and DER entitlements). A FairPlay-encrypted main binary is refused. `--keep-signature` installs the app as it is signed, and then the IPA must carry a signature the device accepts. The bootstrap install does not re-sign. Use `icli app uninstall --help` for removal options.

`sudo icli pkg install /tmp/example.deb` installs a local archive and checks architecture and installed dependencies; installing the same version reinstalls it. Package identifiers and repository downloads are not supported. `pkg info`, `pkg extract`, `pkg status`, and `pkg compare` expose metadata, extraction, installed state, and Debian version comparison. `pkg remove` keeps configuration files unless `--purge` is supplied. `pkg repos` and `pkg add-repo` inspect and edit repository source files.

Maintainer scripts and package triggers are not executed. Transactions report skipped scripts in `scripts_not_run` and register installed app bundles through LaunchServices. Packages that require script-driven setup need that setup handled separately; icli is not a complete dpkg or APT replacement.

### Launch Arguments and Environment

`app launch` can pass launch arguments and environment variables, and run an app in another language or region format. They last for that launch and reach a new process only, so a running app is stopped first. Write a value that starts with a dash as `--arg=-Flag`.

```sh
icli app launch example.bundle.id --arg=-FeatureFlag --arg=YES --env API_URL=https://staging.example.com
icli app launch example.bundle.id --language fr --locale fr_FR
icli app launch example.bundle.id --probe        # carry the probe agent, for `icli probe --app`
```

### Verified Launches and Crash Checks

`app launch --wait-foreground` returns only after RunningBoard verifies the app in front, with its `pid`. `app relaunch <bundle-id>` stops the app, launches it, verifies a new process is in front, and reports `old_pids`, `pid` and `launched_at`. Pass `launched_at` to `log crashes --since`, which also takes epoch seconds or an age such as `30s`, `5m` or `2h`.

```sh
icli app relaunch example.bundle.id
icli log crashes --bundle-id example.bundle.id --since 2m
```
