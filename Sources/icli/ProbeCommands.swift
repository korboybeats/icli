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
        has to have been started with `icli app launch <app> --probe`, which \
        injects the agent for that launch; nothing listens in an app launched \
        any other way. A script runs on the app's main thread, as UIKit \
        requires, and a crash there takes the app rather than icli. api() \
        belongs to icli's own process and is not available in an app.

        Examples:
          icli probe -e "ObjC.use('NSProcessInfo').processInfo().processName()"
          icli probe script.js
          echo "api('svc.list').count" | icli probe -
          icli probe repl
          icli app launch com.example.app --probe
          icli probe --app com.example.app --check
          icli probe --app com.example.app -e "ObjC.use('UIApplication').sharedApplication().keyWindow().$class"

        Evaluation prints one JSON line {ok, result | error, output}: stdout \
        carries only that line, with everything the script printed collected \
        into output. --app answers in the same shape. The interactive REPL \
        (`repl`, or no argument) writes its output live instead, and runs only \
        in icli's own process.
        """,
    )

    @Option(name: [.customShort("e"), .customLong("eval")], help: "Evaluate this source instead of a file")
    var eval: String?

    @Argument(help: "A script file, '-' for stdin, or 'repl' for the interactive shell")
    var input: String?

    @Option(
        name: .customLong("app"),
        help: "Run the script inside this app's process, through the agent 'app launch --probe' injected. Bundle ID or display name.")
    var app: String?

    @Flag(help: "With --app, report whether an agent is listening instead of running a script.")
    var check = false

    @Option(help: "Seconds --app waits for the app's main thread, 0.1–600.")
    var timeout: Double = 30

    func run() throws {
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
        var request: [String: Any]
        if check {
            request = ["op": "ping"]
        } else {
            let source: String
            switch (eval, input) {
            case let (eval?, _):
                source = eval
            case (nil, "-"?):
                source = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            case (nil, nil), (nil, "repl"?):
                // The REPL reads this process's own terminal and shares one
                // context with it; an app's agent is reached one request at a
                // time, so there is nothing for `repl` to attach to yet.
                printProbeLine(["ok": false, "error": "--app has no REPL; pass -e, a script file or '-'", "output": ""])
                Darwin.exit(1)
            case let (nil, path?):
                source = readScript(path)
            }
            request = ["op": "evaluate", "source": source, "timeout": timeout]
        }
        do {
            let bundleID = try resolveAppName(app)
            // A ping is answered on the agent's own serving thread, so it
            // does not wait on --timeout: an agent that cannot answer one
            // promptly is in a suspended app, and waiting changes nothing. An
            // evaluation is given two seconds past the agent's own deadline,
            // so its timeout is the one that reports.
            let answer = try probeAgentSend(request, for: bundleID, timeout: check ? 2 : timeout + 2)
            printProbeLine(answer)
            Darwin.exit(answer["ok"] as? Bool == true ? 0 : 1)
        } catch let error as IcliError {
            printProbeLine(["ok": false, "error": error.message, "output": ""])
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
