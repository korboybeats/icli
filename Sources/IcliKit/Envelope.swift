import Darwin
import Foundation
import IcliPrivate

// The read-only system library and the launch library are part of IcliKit's
// own API: a consumer that links IcliKit gets every IcliSystem and IcliLaunch
// function without a second import.
@_exported import IcliLaunch
@_exported import IcliSystem

public enum Envelope {
    public static var human = false
    /// One line per element instead of JSON; see compactText. Wins over human.
    public static var compact = false
    public static var warning: String?

    /// While true, the next result and exit status are kept for a batch
    /// instead of being printed or ending the process.
    public static var capturing = false
    public static var capturedResult: Any?
    public static var capturedStatus: Int32 = 0
    /// The command being run, for failure artifacts; a batch or session step sets its own.
    public static var argv = Array(CommandLine.arguments.dropFirst())
    private static var savingArtifacts = false

    public static func applyLockPolicy(allowWhenLocked: Bool, requiresLease: Bool = true) throws {
        warning = nil
        if Lease.exempt {
            Lease.exempt = false
        } else if requiresLease {
            try Lease.check()
        }
        icli_private_init()
        let status = icli_lock_status()
        guard status.locked || status.screen_off else { return }
        #if DEBUG
            let message = "device is locked or screen is off; debug build allowing execution"
            warning = message
            FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
        #else
            if !allowWhenLocked {
                throw IcliError.locked
            }
        #endif
    }

    public static func printJSON(_ value: Any) {
        if capturing {
            capturedResult = value
            return
        }
        let payload: Any
        if let warning, var dict = value as? [String: Any] {
            dict["warning"] = warning
            payload = dict
        } else {
            payload = value
        }
        if compact, let dict = payload as? [String: Any] {
            fputs(compactText(dict), stdout)
            return
        }
        if human, let dict = payload as? [String: Any] {
            fputs(humanText(dict), stdout)
            return
        }
        // JSONSerialization raises an Objective-C exception, which `try?`
        // cannot catch, for a NaN or a non-JSON type, so check first.
        let encodable = JSONSerialization.isValidJSONObject(payload) ? payload : jsonSafe(payload)
        let data = JSONSerialization.isValidJSONObject(encodable)
            ? (try? JSONSerialization.data(withJSONObject: encodable, options: [.prettyPrinted, .sortedKeys]))
            : nil
        // The throwing write: the legacy write(_:) raises on EPIPE or EBADF.
        try? FileHandle.standardOutput.write(
            contentsOf: (data ?? Data("{\"error\":\"failed\",\"message\":\"unencodable\"}".utf8)) + Data("\n".utf8),
        )
    }

    public static func run(allowWhenLocked: Bool = false, requiresLease: Bool = true, _ body: () throws -> [String: Any]) {
        do {
            try applyLockPolicy(allowWhenLocked: allowWhenLocked, requiresLease: requiresLease)
            let result = try body()
            printJSON(result)
            if let status = result["status"] as? Int, status != 0 {
                finish(exitCode(status))
            }
        } catch let error as IcliError {
            printJSON(withArtifacts(error, requiresLease: requiresLease))
            if case .locked = error {
                finish(2)
            } else if case let .commandFailed(result) = error {
                finish(exitCode(result["status"] as? Int ?? 1))
            } else {
                finish(1)
            }
        } catch {
            printJSON(withArtifacts(IcliError.failed(error.localizedDescription), requiresLease: requiresLease))
            finish(1)
        }
    }

    /// The error's payload, with where its artifacts went when
    /// ICLI_FAILURE_ARTIFACTS asks for them. A held lease is not the device's
    /// failure, so it leaves none.
    private static func withArtifacts(_ error: IcliError, requiresLease: Bool) -> [String: Any] {
        var payload = error.payload
        guard requiresLease, let directory = ProcessInfo.processInfo.environment["ICLI_FAILURE_ARTIFACTS"], !directory.isEmpty,
              !savingArtifacts, payload["error"] as? String != "leased"
        else { return payload }
        savingArtifacts = true
        defer { savingArtifacts = false }
        do {
            payload["artifacts"] = try saveFailureArtifacts(directory: directory, argv: argv, error: payload)
        } catch {
            payload["artifacts_error"] = error.localizedDescription
        }
        return payload
    }

    private static func finish(_ status: Int32) {
        if capturing {
            capturedStatus = status
        } else {
            Darwin.exit(status)
        }
    }

    private static func exitCode(_ status: Int) -> Int32 {
        Int32(min(max(status, 1), 255))
    }
}

private func humanText(_ dict: [String: Any], indent: String = "") -> String {
    dict.keys.sorted().map { key in
        let value = dict[key]!
        if let nested = value as? [String: Any] {
            return "\(indent)\(key):\n" + humanText(nested, indent: indent + "  ")
        }
        if let array = value as? [[String: Any]] {
            return "\(indent)\(key): (\(array.count))\n" + array.enumerated().map { i, item in
                "\(indent)  [\(i)]\n" + humanText(item, indent: indent + "    ")
            }.joined()
        }
        return "\(indent)\(key): \(value)\n"
    }.joined()
}
