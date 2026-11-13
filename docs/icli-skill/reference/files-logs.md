# Files and logs: fs, log

All paths are physical device paths. On RootHide, the SSH shell's `/` is the bootstrap root. See the RootHide note in [SKILL.md](../SKILL.md).

## fs

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `fs ls <path>` | Directory entries with name, path, directory and symlink flags, size, modified time | | no | unlocked |
| `fs read <path>` | File content as UTF-8, or as Base64 when the content is binary | `--binary` (always Base64), `--limit <bytes>` (default 524288, max 64 MiB), `--offset <bytes>` (start byte, default 0; past the end returns empty content); `truncated` is reported | no | unlocked |
| `fs write <path> <content>` | Write a file, creating parent directories | `--encoding utf8\|base64` | no | unlocked |
| `fs find <root> <pattern>` | Recursive search for relative paths containing `<pattern>` (ignores case, at most 500 results) | | no | unlocked |
| `fs plist <path>` | Property list as JSON | | no | unlocked |
| `fs plist-set <path> <key> [<json-value>]` | Set one top-level key to a JSON value, or remove it | `--remove` | no | any |
| `fs mkdir <path>` | Create a directory, including parents | `--mode 755` | no | any |
| `fs rm <path>` | Remove a file or directory | `--force` required, `--recursive` | no | any |
| `fs link <target> <link>` | Create a symbolic link | `--replace` | no | any |
| `fs chmod <path> <mode>` | Set octal permissions | | no | any |
| `fs chown <path> <owner>` | Set `uid:gid`, as numbers or names | | usually | any |
| `fs copy <src> <dst>` | Copy a file or directory | | no | any |
| `fs move <src> <dst>` | Move or rename | | no | any |

"Root: no" means icli does not demand root. The file's own permissions still apply, so use `sudo` for system locations.

For incremental `fs read` calls, pass `--binary` and advance `--offset` by the
Base64-decoded byte count, not the text length. Offsets are nonnegative bytes;
an offset at or beyond EOF returns empty content with `truncated: false`.
`size` remains the whole file size observed before reading, and `truncated`
reports bytes beyond the returned chunk. Reset the offset to 0 if `size`
shrinks below it; this does not reliably detect a replacement file of the
same or greater size. See [chunked reads](../../usage/apps-files-logs.md#reading-files-in-chunks).

## log

| Command | Purpose | Key flags | Root | Screen |
| --- | --- | --- | --- | --- |
| `log syslog` | Capture the live unified log for a period; filters apply before the line cap | `--seconds 3` (0.1–60), `--process <name>`, `--pid <n>`, `--subsystem <id>` (and dotted children), `--category <name>`, `--message-contains <text>`, `--level all\|debug\|info\|default\|error\|fault`, `--max-lines 500` (1–5000) | no | any |
| `log crashes` | List crash report paths, newest first | `--bundle-id <id>`, `--since <ISO-8601, epoch, or 30s/5m/2h>`, `--limit N` (newest N; `count` stays the total, `truncated` true), `--kind crash\|spin\|diagnostic\|log` (by file name: spins and hangs; jetsam, resource, panic, watchdog and similar system reports; anything else; default: every .ips and .crash) | no | unlocked |
| `log crash <path>` | Read one crash report (or, with `--bundle-id <id>` instead of a path, that app's newest crash); `--summary` gives `report_type` (crash, user fault, jetsam, stackshot, resource (CPU) or resource (disk writes), from `bug_type`), the process, exception, termination and the crashed thread's first 40 frames | `--summary`, `--max-bytes <n>` (1–67108864) | no | unlocked |
