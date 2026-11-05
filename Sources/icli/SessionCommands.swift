import ArgumentParser
import Darwin
import Foundation
import IcliKit
import IcliPrivate

struct Session: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Run icli commands one JSON line at a time in one process, for a runner that keeps it open.",
        discussion: """
        Each command skips process start-up and a new SSH connection, about 120 ms on an iPhone 15 Pro Max.
        A line is an argument list, or an object with argv and the batch step fields expect, delay_ms,
        plus id, which the reply repeats. Each line gets one line back, as in a batch report:
        ok, exit_code, elapsed_ms, result, and message or expect_failed. A step run with --compact
        answers with its lines in text instead of result; expect still checks the result.

          {"id":1,"argv":["ui","tap","Continue"]}
          {"id":1,"ok":true,"exit_code":0,"elapsed_ms":182,"result":{...}}

        The first line out is {"ready":true,...}. The session ends at end of input or on SIGINT, SIGTERM or
        SIGHUP, and leaves the accessibility switches as it found them. Commands see no standard input.
        batch, session, probe, tests and 'screen shot --stdout' cannot be steps.
        """,
    )

    func run() {
        // Steps must not read the commands meant for the session.
        let commands = dup(STDIN_FILENO)
        let empty = open("/dev/null", O_RDONLY)
        if empty >= 0 { dup2(empty, STDIN_FILENO); close(empty) }
        guard commands >= 0, let stream = fdopen(commands, "r") else {
            writeLine(["ready": false, "error": "failed", "message": "standard input is unavailable"])
            Darwin.exit(1)
        }
        icli_session_exit_on_signals()
        writeLine(["ready": true, "pid": Int(getpid()),
                   "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"])
        var buffer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        var index = 0
        defer { free(buffer) }
        while getline(&buffer, &capacity, stream) > 0, let buffer {
            let line = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            var report: [String: Any]
            var id: Any?
            do {
                guard var row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
                    throw IcliError.failed("each line must be JSON: an argument list or an object with argv")
                }
                if var fields = row as? [String: Any] {
                    id = fields.removeValue(forKey: "id")
                    row = fields
                }
                let step = try BatchStep(row: row, index: index)
                // A recording takes the stop signals over and finishes its movie first.
                icli_session_defer_signals(step.argv.starts(with: ["screen", "record"]))
                report = step.execute()
                icli_session_exit_on_signals()
                icli_session_defer_signals(false)
                if step.delay > 0 { Thread.sleep(forTimeInterval: step.delay) }
            } catch {
                let message = (error as? IcliError)?.message ?? error.localizedDescription
                report = ["ok": false, "exit_code": 64, "message": message]
            }
            report["index"] = index
            if let id { report["id"] = id }
            writeLine(report)
            index += 1
        }
    }
}

private func writeLine(_ value: [String: Any]) {
    let safe = JSONSerialization.isValidJSONObject(value) ? value : jsonSafe(value)
    let data = (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]))
        ?? Data("{\"ok\":false,\"message\":\"unencodable\"}".utf8)
    try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8))
}

struct Status: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Lock state, the app in front, keyboard, overlay and owner-only prompt, in one call.",
        discussion: "springboard_pid and boot_time change after a respring or a reboot, so a runner that compares them between steps knows its test was disturbed.",
    )
    @OptionGroup var output: OutputOptions
    func run() {
        Lease.exempt = true
        emit(allowWhenLocked: true, output) { deviceStatus() }
    }
}

struct LeaseCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "lease",
        abstract: "Claim the device for one runner, so other agents' commands are refused instead of landing mid-test.",
        discussion: """
        While a lease is held, every icli command run without its token fails with error leased and exit status 75; \
        lease and status still run. Pass the token as ICLI_LEASE=<token>. A lease ends when released or when its \
        time runs out.

          export ICLI_LEASE=$(icli lease acquire --owner ci --ttl 900 | jq -r .token)
        """,
        subcommands: [Acquire.self, Release.self, StatusCommand.self],
    )

    struct Acquire: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Option(help: "Who holds it, shown to anyone refused.") var owner: String
        @Option(help: "Seconds it lasts, 1–86400; acquiring again with the token renews it.") var ttl: Double = 900
        @Flag(help: "Take it over from another holder.") var force = false
        func run() {
            Lease.exempt = true
            emit(allowWhenLocked: true, output) { try acquireLease(owner: owner, seconds: ttl, force: force) }
        }
    }

    struct Release: ParsableCommand {
        @OptionGroup var output: OutputOptions
        @Flag(help: "Release another holder's lease.") var force = false
        func run() {
            Lease.exempt = true
            emit(allowWhenLocked: true, output) { try releaseLease(force: force) }
        }
    }

    struct StatusCommand: ParsableCommand {
        static var configuration = CommandConfiguration(commandName: "status")
        @OptionGroup var output: OutputOptions
        func run() {
            Lease.exempt = true
            emit(allowWhenLocked: true, output) { leaseStatus() }
        }
    }
}

/// Waits after an action until an element appears or goes, so a test needs no sleep.
struct ExpectOptions: ParsableArguments {
    @Option(help: "Afterwards, wait until an element whose label, identifier or value contains this text is on screen.")
    var expect: String?
    @Option(help: "Afterwards, wait until no element contains this text.") var expectGone: String?
    @Option(help: "Seconds to wait for --expect or --expect-gone, 0–60.") var expectTimeout: Double = 10

    func validate() throws {
        guard expect == nil || expectGone == nil else { throw ValidationError("give --expect or --expect-gone, not both") }
        guard expectTimeout.isFinite, (0 ... 60).contains(expectTimeout) else {
            throw ValidationError("--expect-timeout must be 0–60 seconds")
        }
    }

    func after(_ action: () throws -> [String: Any]) throws -> [String: Any] {
        try expectAfter(action(), appear: expect, gone: expectGone, timeout: expectTimeout)
    }
}
