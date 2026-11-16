# Hidden App Sessions (Parallel)

With the Parallel package (`com.korboy.parallel`, 1.1.0 or later) installed, icli can run apps in hidden sessions: each session owns one installed app and runs it in a scene that is never shown on the screen. Several runners can each drive their own app at the same time, and the person holding the phone keeps using it. Without the package, these commands fail with `parallel_unavailable` (exit 69).

```sh
eval "$(icli parallel create com.example.app --launch --export)"
P="--parallel $ICLI_PARALLEL"
icli ui tree --compact $P
icli ui tap "Continue" $P
icli input type "hello" --submit $P
icli screen shot --output /tmp/app.png $P
icli parallel release $P
```

## Sessions

| Command | What it does |
| --- | --- |
| `icli parallel info` | Whether Parallel is loaded, its version, protocol and session limit |
| `icli parallel list` | All sessions, without tokens |
| `icli parallel create <bundle-id> [--ttl s] [--launch] [--orientation o] [--export]` | Start a session for an installed app. Prints `session` and `token`; with `--launch` also launches the app and prints `generation`. `--export` prints `export ICLI_PARALLEL=… ICLI_PARALLEL_TOKEN=… ICLI_PARALLEL_GENERATION=…` lines for `eval`. |
| `icli parallel launch [--orientation o]` | Launch the app hidden; answers once it has drawn. Any copy of the app already running in the background is terminated first. |
| `icli parallel restart` | Terminate and launch again; the generation increases |
| `icli parallel stop` | Terminate the app; the session stays |
| `icli parallel status` / `renew` | State, pid, size and orientation; both renew the TTL |
| `icli parallel rotate <orientation>` | `portrait`, `landscape-left`, `landscape-right`, `portrait-upside-down` |
| `icli parallel gesture '<frames>'` | Multi-touch: frames of 1–5 `[x,y]` points at 60 frames per second |
| `icli parallel release` | End the session and terminate its app |

A session ends at `release`, when its TTL (default 300 s, 10–3600) passes without a command, or when SpringBoard restarts. At most 3 sessions run at once (`capacity`); an app belongs to one session at a time (`app_in_use`), and an app the person has open cannot be launched in one (`app_in_foreground`). While a session owns an app, opening it on the phone is refused.

## Commands inside a session

Add `--parallel <session>` to:

- `screen tap`, `long-press`, `double-tap`, `swipe`, `pinch`
- `screen shot` (`--output`, `--format`, `--width`, `--native-resolution`, `--base64`; the result also carries the session's `parallel` metadata, including `gpu_content_fresh`)
- `screen ocr`
- `ui tree`, `ui tap` (accessibility tree of the session's app; `--source ax` only)
- `input type`, `input paste`, `input key` (`return`, `enter`, `delete`/`backspace`, `forward-delete`, `tab`, `escape`, `space`, arrows)

The token comes from `--parallel-token` or `ICLI_PARALLEL_TOKEN`, the generation from `--parallel-generation` or `ICLI_PARALLEL_GENERATION`. Commands without `--parallel` act on the physical screen as usual, even when those variables are set.

Coordinates are points in the session app's interface orientation, the same as its screenshot at `--width` equal to its `width`. Every command replies after the app has handled the input and drawn, so a screenshot taken next shows the result.

Differences from the physical screen:

- Text is inserted into the focused field in one piece, as the keyboard inserts it; `--delay-ms` has no effect and `--clear` is refused. `input type` needs a focused field: tap it first, and retry on `no_focused_text_input` while focus moves.
- Swipes and pinches run at 60 frames per second; `--steps` has no effect and `--no-momentum` is refused.
- `--expect`, `ui tap --source ocr`, `screen shot --stdout` and `--check-prompt` are refused.
- Screenshots taken while the screen is off show Metal and video content as of the last time the screen was on (`gpu_content_fresh: false`).

## Generations

Each launch of the app is a new generation. Input, capture, `rotate` and `ui` commands need the current one and are refused with `stale_generation` after `restart`, or after a launch following an app exit, so a command meant for an earlier process never reaches a new one. Update `ICLI_PARALLEL_GENERATION` from the `generation` of `launch` or `restart`.

## Leases

A session's token, not the device lease, authorizes work in it: commands with `--parallel` and `icli parallel` run while another runner holds the lease, and a runner holding the lease does not need a session's token for anything outside it. The physical screen and the session apps do not interfere with each other, and `ui` commands on the physical screen ignore session apps when deciding which app is in front.

## Errors

Broker errors keep Parallel's code in `error`: `user_control` (the person has taken control of the session in the Parallel viewer app; input resumes when they hand it back, capture still works), `stale_generation`, `generation_required`, `unauthorized`, `unknown_session`, `capacity`, `app_in_use`, `app_in_foreground`, `not_running`, `session_busy`, `launch_timeout`, `agent_missing` and others; see Parallel's PROTOCOL.md. Transport failures are `parallel_unavailable` (exit 69), `parallel_disconnected` and `timed_out`. `icli tests` reports whether Parallel is loaded and speaks icli's protocol.
