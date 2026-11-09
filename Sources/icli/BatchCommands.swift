import ArgumentParser
import Foundation
import IcliKit

struct Batch: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Run a JSON list of icli commands in one process, stopping at the first failure.",
        discussion: """
        Reads a JSON array from stdin. A step is an argument list, or an object with:
          argv               the arguments, required
          expect             result fields that must equal these values;
                             a dotted key such as element.label reads nested fields
          delay_ms           pause after the step, 0-60000
          continue_on_error  keep going if this step fails

        echo '[["app","relaunch","com.example"],
               {"argv":["app","frontmost"],"expect":{"bundle_id":"com.example"}},
               ["ui","wait","Ready"]]' | icli batch

        Prints one JSON report: ok, completed, failed_step, and for each step its \
        result (text instead with --compact), exit_code and elapsed_ms. The exit status is the failed step's, 0 when every step passed. A step that crashes \
        ends the whole batch without a report. batch, session, probe, tests and 'screen shot --stdout' \
        cannot be steps.
        """,
    )
    @OptionGroup var output: OutputOptions

    func run() {
        emit(allowWhenLocked: true, output) {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let rows = try? JSONSerialization.jsonObject(with: input) as? [Any], !rows.isEmpty, rows.count <= 1000
            else {
                throw IcliError.failed("stdin must be a JSON array of 1-1000 steps")
            }
            let steps = try rows.enumerated().map { try BatchStep(row: $1, index: $0) }

            var reports: [[String: Any]] = []
            var status: Int32 = 0
            var failed: Int?
            for (index, step) in steps.enumerated() {
                var report = step.execute()
                report["index"] = index
                reports.append(report)
                if report["ok"] as? Bool != true {
                    if failed == nil {
                        failed = index
                        status = report["exit_code"] as? Int32 ?? 1
                        if status == 0 { status = 1 }
                    }
                    if !step.continueOnError { break }
                }
                if step.delay > 0 { Thread.sleep(forTimeInterval: step.delay) }
            }
            var result: [String: Any] = [
                "ok": failed == nil, "count": steps.count, "completed": reports.count, "steps": reports,
                "status": Int(status),
            ]
            if let failed { result["failed_step"] = failed }
            return result
        }
    }
}

struct BatchStep {
    let argv: [String]
    let expect: [String: Any]
    let delay: TimeInterval
    let continueOnError: Bool

    init(row: Any, index: Int) throws {
        let fields = row as? [String: Any] ?? ["argv": row]
        guard let argv = fields["argv"] as? [String], let command = argv.first else {
            throw IcliError.failed("step \(index): needs a non-empty list of string arguments")
        }
        guard !["batch", "session", "probe", "flex", "tests"].contains(command) else {
            throw IcliError.failed("step \(index): \(command) cannot run inside a batch or session")
        }
        // Its JPEG would go to the batch's stdout; refuse it before any step runs.
        guard !(argv.starts(with: ["screen", "shot"]) && argv.contains("--stdout")) else {
            throw IcliError.failed("step \(index): screen shot --stdout cannot run inside a batch or session")
        }
        let known: Set = ["argv", "expect", "delay_ms", "continue_on_error"]
        if let unknown = fields.keys.first(where: { !known.contains($0) }) {
            throw IcliError.failed("step \(index): unknown field \(unknown)")
        }
        guard fields["expect"] == nil || fields["expect"] is [String: Any] else {
            throw IcliError.failed("step \(index): expect must be an object")
        }
        let delayMS = fields["delay_ms"].map { ($0 as? NSNumber)?.doubleValue ?? -1 } ?? 0
        guard (0 ... 60000).contains(delayMS) else {
            throw IcliError.failed("step \(index): delay_ms must be 0-60000")
        }
        self.argv = argv
        expect = fields["expect"] as? [String: Any] ?? [:]
        delay = delayMS / 1000
        continueOnError = fields["continue_on_error"] as? Bool ?? false
    }

    func execute() -> [String: Any] {
        let start = ProcessInfo.processInfo.systemUptime
        Envelope.capturing = true
        Envelope.argv = argv
        Envelope.capturedResult = nil
        Envelope.capturedStatus = 0
        var parseError: String?
        do {
            var command = try Icli.parseAsRoot(argv)
            try command.run()
        } catch {
            // ArgumentParser's route for bad arguments and --help alike.
            parseError = Icli.fullMessage(for: error)
            Envelope.capturedStatus = Icli.exitCode(for: error).rawValue
        }
        Envelope.capturing = false
        Envelope.human = false
        // A --compact step answers with its lines in text; expect still reads the result.
        let compact = Envelope.compact
        Envelope.compact = false
        var report: [String: Any] = ["argv": argv, "elapsed_ms": Int((ProcessInfo.processInfo.systemUptime - start) * 1000)]
        let result = Envelope.capturedResult as? [String: Any]
        var status = Envelope.capturedStatus
        if let parseError { report["message"] = parseError }
        if let result {
            if compact { report["text"] = compactText(result) } else { report["result"] = result }
        }
        if status == 0 {
            let mismatched = expect.keys.sorted().filter { key in
                !valuesEqual(field(key, in: result ?? [:]), expect[key])
            }
            if !mismatched.isEmpty {
                status = 1
                report["expect_failed"] = mismatched
            }
        }
        report["ok"] = status == 0
        report["exit_code"] = status
        return report
    }
}

private func field(_ path: String, in result: [String: Any]) -> Any? {
    var current: Any? = result
    for part in path.split(separator: ".") {
        current = (current as? [String: Any])?[String(part)]
    }
    return current
}

private func valuesEqual(_ actual: Any?, _ expected: Any?) -> Bool {
    guard let actual = actual as? NSObject, let expected = expected as? NSObject else { return false }
    return actual.isEqual(expected)
}
