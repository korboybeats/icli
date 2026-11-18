import ArgumentParser
import Foundation
import IcliKit

/// --parallel on the screen and input commands that can act in a Parallel
/// session instead of on the physical screen.
struct ParallelOptions: ParsableArguments {
    @Option(name: .customLong("parallel"), help: ArgumentHelp(
        "Act in this Parallel session (see `icli parallel`) instead of on the screen.",
        discussion: "The session's token and generation come from --parallel-token and --parallel-generation, "
            + "or ICLI_PARALLEL_TOKEN and ICLI_PARALLEL_GENERATION. The device lease does not apply.",
        valueName: "session",
    ))
    var session: String?
    @Option(name: .customLong("parallel-token"), help: "The session's token (default: ICLI_PARALLEL_TOKEN).")
    var token: String?
    @Option(name: .customLong("parallel-generation"), help: "The app process generation the command is meant for (default: ICLI_PARALLEL_GENERATION).")
    var generation: Int?

    var isSet: Bool { session != nil }

    func target() throws -> ParallelTarget {
        guard let target = try ParallelTarget.resolve(session: session, token: token, generation: generation) else {
            throw IcliError.failed("--parallel names no session")
        }
        return target
    }

    /// Runs `body` in the session: its token is the authority, so the device
    /// lease does not apply, and a locked phone does not stop it.
    func run(_ output: OutputOptions, compact: Bool = false, _ body: (ParallelTarget) throws -> [String: Any]) {
        emit(allowWhenLocked: true, requiresLease: false, output, compact: compact) { try body(target()) }
    }

    /// For options a session cannot honor.
    func refuse(_ option: String, when given: Bool) throws {
        if given { throw IcliError.failed("\(option) is not available with --parallel") }
    }
}

struct ParallelCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "parallel",
        abstract: "Hidden app sessions for concurrent runners (needs the Parallel package).",
        discussion: """
        A session owns one installed app and runs it in a scene that is never shown, so \
        several runners can each drive their own app while the phone stays usable. \
        The session's token authorizes it; the device lease does not apply.

          eval "$(icli parallel create com.example.app --launch --export)"
          icli screen tap 200 400 --parallel "$ICLI_PARALLEL"
          icli input type hello --parallel "$ICLI_PARALLEL"
          icli screen shot --output /tmp/app.png --parallel "$ICLI_PARALLEL"
          icli screen ocr --parallel "$ICLI_PARALLEL"
          icli parallel release --parallel "$ICLI_PARALLEL"

        create prints the session, its token and, with --launch, the generation. Input \
        and capture need the generation: after restart, or a launch after the app exited, \
        commands for the old generation are refused with stale_generation. Coordinates are \
        points in the app's interface orientation. A session ends at release, when its TTL \
        passes without a command, or when SpringBoard restarts.
        """,
        subcommands: [Info.self, List.self, Create.self, Launch.self, Restart.self, Stop.self, Status.self,
                      Renew.self, Release.self, Rotate.self, Gesture.self, Attach.self],
    )
}

private let orientationHelp: ArgumentHelp = "portrait, landscape-left, landscape-right or portrait-upside-down; default: what the app prefers for a phone held upright."

extension ParallelCommand {
    struct Info: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Whether Parallel is running, its version and session limit.")
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) {
                var result = try Parallel.request("ping")
                result["client_protocol"] = Parallel.protocolVersion
                return result
            }
        }
    }

    struct List: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "All sessions, without their tokens.")
        @OptionGroup var output: OutputOptions
        func run() {
            emit(allowWhenLocked: true, requiresLease: false, output) { try Parallel.request("list") }
        }
    }

    struct Create: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Start a session that owns an app.")
        @OptionGroup var output: OutputOptions
        @Argument(help: "Bundle ID of an installed app.") var bundleID: String
        @Option(help: "Seconds the session lives without a command, 10–3600.") var ttl: Double = 300
        @Option(help: "Open the app in this Space (virtual screen); default: a new one that closes with its last app.")
        var screen: Int?
        @Flag(help: "Also launch the app hidden and wait until it has drawn.") var launch = false
        @Option(help: orientationHelp) var orientation: String?
        @Flag(help: "Print shell assignments for ICLI_PARALLEL, ICLI_PARALLEL_TOKEN and ICLI_PARALLEL_GENERATION instead of JSON.")
        var export = false
        func run() {
            emitSession(export: export, output) { try create() }
        }

        private func create() throws -> [String: Any] {
            var fields: [String: Any] = ["bundle": bundleID, "ttl": ttl]
            if let screen { fields["screen"] = screen }
            var session = try Parallel.request("create", fields)
            guard launch else { return session }
            let target = try ParallelTarget(session: session["session"] as? String ?? "", token: session["token"] as? String, generation: nil)
            do {
                for (key, value) in try target.lifecycle("launch", orientation: orientation) { session[key] = value }
            } catch {
                _ = try? target.lifecycle("release")
                throw error
            }
            return session
        }
    }

    struct Attach: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Take control of an app the person opened in a Space.",
            discussion: "Prints the session's token (and generation while the app runs). The session has no TTL: it ends when the person closes the app or its Space. `icli parallel list` shows each Space's sessions.",
        )
        @OptionGroup var output: OutputOptions
        @Argument(help: "Session ID from `icli parallel list`.") var session: String
        @Flag(help: "Print shell assignments for ICLI_PARALLEL, ICLI_PARALLEL_TOKEN and ICLI_PARALLEL_GENERATION instead of JSON.")
        var export = false
        func run() { emitSession(export: export, output) { try Parallel.request("attach", ["session": session]) } }
    }

    struct Launch: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Launch the app hidden; replies once it has drawn. Starts a new generation unless it is already running.")
        @OptionGroup var output: OutputOptions
        @OptionGroup var parallel: ParallelOptions
        @Option(help: orientationHelp) var orientation: String?
        func run() { parallel.run(output) { try $0.lifecycle("launch", orientation: orientation) } }
    }

    struct Restart: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Terminate and launch the app again; the generation increases.")
        @OptionGroup var output: OutputOptions
        @OptionGroup var parallel: ParallelOptions
        @Option(help: orientationHelp) var orientation: String?
        func run() { parallel.run(output) { try $0.lifecycle("restart", orientation: orientation) } }
    }

    struct Stop: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Terminate the app; the session remains.")
        @OptionGroup var output: OutputOptions
        @OptionGroup var parallel: ParallelOptions
        func run() { parallel.run(output) { try $0.lifecycle("stop") } }
    }

    struct Status: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "The session's state; renews its TTL.")
        @OptionGroup var output: OutputOptions
        @OptionGroup var parallel: ParallelOptions
        func run() { parallel.run(output) { try $0.lifecycle("status") } }
    }

    struct Renew: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Renew the session's TTL.")
        @OptionGroup var output: OutputOptions
        @OptionGroup var parallel: ParallelOptions
        func run() { parallel.run(output) { try $0.lifecycle("renew") } }
    }

    struct Release: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "End the session and terminate its app.")
        @OptionGroup var output: OutputOptions
        @OptionGroup var parallel: ParallelOptions
        func run() { parallel.run(output) { try $0.lifecycle("release") } }
    }

    struct Rotate: ParsableCommand {
        static var configuration = CommandConfiguration(abstract: "Change the app's interface orientation.")
        @OptionGroup var output: OutputOptions
        @OptionGroup var parallel: ParallelOptions
        @Argument(help: "portrait, landscape-left, landscape-right or portrait-upside-down.") var orientation: String
        func run() { parallel.run(output) { try $0.lifecycle("rotate", orientation: orientation) } }
    }

    struct Gesture: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Multi-touch in the session: frames of 1–5 touch points, 60 frames per second.",
            discussion: "Each frame lists the same number of [x,y] points; the first frame touches down and the last lifts. A pinch:\n\n  icli parallel gesture --parallel S '[[[150,400],[280,500]],[[160,410],[270,490]],[[170,420],[260,480]]]'",
        )
        @OptionGroup var output: OutputOptions
        @OptionGroup var parallel: ParallelOptions
        @Argument(help: "JSON array of frames, 2–1200.") var frames: String
        func run() {
            parallel.run(output) { target in
                guard let list = try? JSONSerialization.jsonObject(with: Data(frames.utf8)) as? [[[Double]]] else {
                    throw IcliError.failed("frames must be a JSON array of frames of [x,y] points")
                }
                return try target.gesture(list)
            }
        }
    }
}

/// Prints a session reply as JSON, or with `export` as shell assignments for eval.
private func emitSession(export: Bool, _ output: OutputOptions, _ body: () throws -> [String: Any]) {
    guard export else {
        emit(allowWhenLocked: true, requiresLease: false, output, body)
        return
    }
    do {
        let result = try body()
        for (name, key) in [("ICLI_PARALLEL", "session"), ("ICLI_PARALLEL_TOKEN", "token"), ("ICLI_PARALLEL_GENERATION", "generation")] {
            if let value = result[key] { print("export \(name)='\(value)'") }
        }
    } catch {
        emit(allowWhenLocked: true, requiresLease: false, output) { throw error }
    }
}
