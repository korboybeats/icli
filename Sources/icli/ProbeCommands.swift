import ArgumentParser
import Darwin
import Foundation
import IcliKit

struct Probe: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Run a JavaScriptCore script in-process: an ObjC bridge, files, and api() into icli.",
        discussion: """
        The script runs inline, in this icli process. There is no --detach: a \
        script that crashes or hangs takes icli down with it. To isolate one, \
        spawn `icli probe` as its own process.

        --app runs the script inside an app instead, where its live objects \
        are: a UIView there is the view on screen, not just a class. The app \
        must be in front. If it has no agent yet, icli loads one into the \
        running app without restarting it. `app launch --probe` is still \
        available for launch-time loading. --check only reports; it never attaches. \
        A script runs on the app's main thread, as UIKit \
        requires, and a crash there takes the app rather than icli. api() \
        belongs to icli's own process and is not available in an app.

        --inspect window, root-controller, or x,y returns a structured report \
        with the object's class, properties, fields and methods. It loads the \
        bundled FLEX runtime only when inspection is requested. --values also \
        reads values, executing property getters in the app. --limit and \
        --offset page each group of members independently.

        Examples:
          icli probe -e "ObjC.use('NSProcessInfo').processInfo().processName()"
          icli probe script.js
          echo "api('svc.list').count" | icli probe -
          icli probe repl
          icli app launch com.example.app --probe
          icli probe --app com.example.app --check
          icli probe --app com.example.app --inspect root-controller
          icli probe --app com.example.app --inspect 215,466 --limit 20
          icli probe --app com.example.app -e "ObjC.use('UIApplication').sharedApplication().keyWindow().$class"

        Evaluation prints one JSON line {ok, result | error, output}: stdout \
        carries only that line, with everything the script printed collected \
        into output. --app answers in the same shape. The interactive REPL \
        (`repl`, or no argument) also works with --app; its output appears \
        when each statement returns. .exit leaves the app running.
        """,
    )

    @Option(name: [.customShort("e"), .customLong("eval")], help: "Evaluate this source instead of a file")
    var eval: String?

    @Argument(help: "A script file, '-' for stdin, or 'repl' for the interactive shell")
    var input: String?

    @Option(
        name: .customLong("app"),
        help: "Run inside this foreground app; load the agent if needed, without restarting it. Bundle ID or display name.")
    var app: String?

    @Flag(help: "With --app, report whether an agent is listening instead of running a script.")
    var check = false

    @Option(help: "Inspect a live object with FLEX: window, root-controller, or x,y in screen points. Needs --app.")
    var inspect: String?

    @Flag(help: "With --inspect, read property and field values too. Property getters execute app code.")
    var values = false

    @Option(help: "With --inspect, maximum entries per member group, 1–500.")
    var limit: Int = 100

    @Option(help: "With --inspect, skip this many entries in each member group.")
    var offset: Int = 0

    @Option(help: "Seconds --app waits for the app's main thread, 0.1–600.")
    var timeout: Double = 30

    func run() throws {
        do { try Envelope.applyLockPolicy(allowWhenLocked: true) }
        catch {
            Envelope.run(allowWhenLocked: true) { throw error }
            return
        }
        if inspect != nil {
            guard app != nil, eval == nil, input == nil, !check else {
                throw ValidationError("--inspect needs --app and cannot be combined with a script, repl or --check")
            }
            guard (1 ... 500).contains(limit), offset >= 0 else {
                throw ValidationError("--inspect needs --limit 1–500 and --offset 0 or greater")
            }
        } else if values || offset != 0 || limit != 100 {
            throw ValidationError("--values, --limit and --offset belong to --inspect")
        }
        if let app {
            runInApp(app)
        }
        guard !check else {
            printProbeLine(["ok": false, "error": "--check reports on an app's agent and needs --app", "output": ""])
            Darwin.exit(1)
        }
        let source: String
        switch (eval, input) {
        case let (eval?, _):
            source = eval
        case (nil, nil), (nil, "repl"?):
            Darwin.exit(runProbeREPL())
        case (nil, "-"?):
            source = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        case let (nil, path?):
            source = readScript(path)
        }
        let result = evaluateProbe(source)
        var line: [String: Any] = ["ok": result.ok, "output": result.output]
        if let error = result.error { line["error"] = error } else { line["result"] = result.result }
        printProbeLine(line)
        Darwin.exit(result.ok ? 0 : 1)
    }

    /// Hand the script to the app's own agent and print what it answers, in
    /// the same line shape an inline evaluation prints. Never returns.
    private func runInApp(_ app: String) -> Never {
        guard timeout.isFinite, (0.1 ... 600).contains(timeout) else {
            printProbeLine(["ok": false, "error": "timeout must be 0.1–600 seconds", "output": ""])
            Darwin.exit(1)
        }
        do {
            let bundleID = try resolveAppName(app)
            if check {
                let answer = try probeAgentSend(["op": "ping"], for: bundleID, timeout: 2)
                printProbeLine(answer)
                Darwin.exit(answer["ok"] as? Bool == true ? 0 : 1)
            }
            if let inspect {
                var request: [String: Any] = ["op": "inspect", "timeout": timeout,
                                              "values": values, "limit": limit, "offset": offset]
                if inspect == "window" || inspect == "root-controller" {
                    request["target"] = inspect
                } else {
                    let coordinates = inspect.split(separator: ",", omittingEmptySubsequences: false)
                    guard coordinates.count == 2, let x = Double(coordinates[0]), let y = Double(coordinates[1]),
                          x.isFinite, y.isFinite else {
                        throw IcliError.failed("--inspect target must be window, root-controller, or x,y in screen points")
                    }
                    request["target"] = "point"
                    request["x"] = x
                    request["y"] = y
                }
                let agent = try prepareProbeAgent(for: bundleID)
                guard agent["object_inspection"] as? Bool == true,
                      let pid = agent["pid"] as? Int, agent["bundle_id"] as? String == bundleID else {
                    throw IcliError.failed("the app's loaded probe agent predates object inspection; relaunch the app once to update it")
                }
                request["expected_pid"] = pid
                let answer = try probeAgentSend(request, for: bundleID, timeout: timeout + 2)
                printProbeLine(answer)
                Darwin.exit(answer["ok"] as? Bool == true ? 0 : 1)
            }
            // Read the script before loading anything into the app: a missing
            // file should not change the target process.
            let source: String?
            switch (eval, input) {
            case let (eval?, _): source = eval
            case (nil, "-"?):
                source = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            case (nil, nil), (nil, "repl"?): source = nil
            case let (nil, path?): source = readScript(path)
            }
            let agent = try prepareProbeAgent(for: bundleID)
            guard agent["ok"] as? Bool == true, let pid = agent["pid"] as? Int,
                  agent["bundle_id"] as? String == bundleID else {
                throw IcliError.failed(agent["error"] as? String ?? "the probe agent did not identify its process")
            }
            if let source {
                let result = evaluateAppProbe(source, bundleID: bundleID, pid: pid, timeout: timeout)
                var line: [String: Any] = ["ok": result.ok, "output": result.output]
                if let error = result.error { line["error"] = error } else { line["result"] = result.result }
                printProbeLine(line)
                Darwin.exit(result.ok ? 0 : 1)
            }
            Darwin.exit(runProbeREPL(banner: "icli probe in \(bundleID), pid \(pid). .help for help; .exit leaves the app running.") {
                evaluateAppProbe($0, bundleID: bundleID, pid: pid, timeout: timeout)
            })
        } catch let error as IcliError {
            printProbeLine(["ok": false, "error": error.payload["message"] as? String ?? error.message, "output": ""])
            Darwin.exit(1)
        } catch {
            printProbeLine(["ok": false, "error": error.localizedDescription, "output": ""])
            Darwin.exit(1)
        }
    }

    /// A script file's contents, or the same one-line answer a script that
    /// threw gets, so a caller that spawned `icli probe` has one shape to read.
    private func readScript(_ path: String) -> String {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            printProbeLine(["ok": false, "error": "cannot read script \(path): \(error.localizedDescription)", "output": ""])
            Darwin.exit(1)
        }
    }

    /// The result as one compact line, so a reader can take stdout as a single
    /// JSON object and the script's own output stays inside `output`.
    private func printProbeLine(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"unencodable"}"#.utf8)
        try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
    }
}
