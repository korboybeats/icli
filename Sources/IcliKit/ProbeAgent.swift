import Darwin
import Foundation
import IcliPrivate
import IcliSystem

// `icli probe --app` is `icli probe` run somewhere else: the agent dylib holds
// the same engine and bridge inside the target app, and this file is the half
// that talks to it. One request object per line, one answer per line, in the
// shape `icli probe` already answers in, so a caller reads one contract either
// way.
//
// The agent listens on a Unix socket inside the app's own container. A
// loopback port would work too, and be reachable by every other app on the
// device; the container is reachable by root and by the app alone, so the
// sandbox does the access control and there is no secret to hand out. Nothing
// listens until `probe --app` or `app launch --probe` asks for it.

/// What `DYLD_INSERT_LIBRARIES` points at: the agent beside the CLI in
/// whichever bootstrap layout is installed.
public func probeAgentDylibPath() -> String {
    JailbreakRoot.current.jbrootPath("/usr/lib/icli-probe-agent.dylib")
}

/// The socket an app's agent binds, inside that app's own container.
///
/// A sockaddr_un path is 103 characters, and a data container is already 76 of
/// them, so the name is short and the `/private` prefix LaunchServices reports
/// is dropped — the same file by a shorter path. An app with no data container
/// of its own, which a system app can be, binds under its home instead, named
/// for its bundle so two cannot collide.
public func probeAgentSocketPath(for bundleID: String) throws -> String {
    if bundleID == SystemShell.bundleID { return "/var/mobile/tmp/icli-probe-\(bundleID).sock" }
    let info = try appInfo(bundleID)
    let container = (info["data_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let path: String
    if let container {
        let short = container.hasPrefix("/private/") ? String(container.dropFirst("/private".count)) : container
        path = "\(short)/tmp/icli-probe.sock"
    } else {
        path = "/var/mobile/tmp/icli-probe-\(bundleID).sock"
    }
    let limit = MemoryLayout<sockaddr_un>.size - MemoryLayout<UInt8>.size * 2
    guard path.utf8.count < limit else {
        throw IcliError.failed("the probe socket path for \(bundleID) is \(path.utf8.count) characters, over the \(limit - 1) a Unix socket takes")
    }
    return path
}

/// `environment` with the agent added, for `app launch --probe`. A
/// DYLD_INSERT_LIBRARIES the caller asked for keeps its own entries: dyld
/// loads the whole colon-separated list, and the bootstrap prepends its own
/// loader to it either way.
public func environmentWithProbeAgent(_ environment: [String], bundleID: String) throws -> [String] {
    let dylib = probeAgentDylibPath()
    guard access(dylib, R_OK) == 0 else {
        throw IcliError.failed("the probe agent is not installed at \(dylib)")
    }
    var result: [String] = []
    var inserted = false
    for pair in environment {
        guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
            throw IcliError.failed("environment must be NAME=VALUE: \(pair)")
        }
        let name = String(pair[..<separator])
        let value = String(pair[pair.index(after: separator)...])
        if name == "DYLD_INSERT_LIBRARIES" {
            result.append("\(name)=\(value.isEmpty ? dylib : "\(value):\(dylib)")")
            inserted = true
        } else if name == "ICLI_PROBE_SOCKET" {
            throw IcliError.failed("ICLI_PROBE_SOCKET belongs to --probe; pass one or the other")
        } else {
            result.append(pair)
        }
    }
    if !inserted { result.append("DYLD_INSERT_LIBRARIES=\(dylib)") }
    result.append("ICLI_PROBE_SOCKET=\(try probeAgentSocketPath(for: bundleID))")
    return result
}

/// Reuse an existing agent, or load it into the foreground app without
/// relaunching it. Only a missing/refused socket permits attachment: a timed
/// out or failed evaluation is never retried. --check does not call this.
public func prepareProbeAgent(for bundleID: String) throws -> [String: Any] {
    do {
        return try probeAgentSend(["op": "ping"], for: bundleID, timeout: 2)
    } catch let IcliError.commandFailed(report) where report["error"] as? String == "probe_agent_missing" {
        let front = frontmostApp()
        let pid: Int
        let executable: String
        if bundleID == SystemShell.bundleID, let shellPID = processPID(named: SystemShell.processName),
           let rows = try listProcesses(filter: SystemShell.processName)["processes"] as? [[String: Any]],
           let process = rows.first(where: { $0["pid"] as? Int == Int(shellPID) }),
           let path = process["executable"] as? String, !path.isEmpty {
            pid = Int(shellPID)
            executable = path
        } else {
            guard front["bundle_id"] as? String == bundleID, front["verified"] as? Bool == true,
                  let foregroundPID = front["pid"] as? Int, foregroundPID > 1 else {
                throw IcliError.failed("bring \(bundleID) to the front with 'icli app launch \(bundleID)' before probing it")
            }
            let info = try appInfo(bundleID)
            guard let path = info["executable"] as? String, !path.isEmpty else {
                throw IcliError.failed("cannot identify the executable for \(bundleID)")
            }
            pid = foregroundPID
            executable = path
        }
        let dylib = probeAgentDylibPath()
        guard access(dylib, R_OK) == 0 else { throw IcliError.missing(dylib) }
        let socketPath = try probeAgentSocketPath(for: bundleID)
        _ = try decodeBridgeJSON(
            takeCString(icli_probe_attach_json(Int32(pid), executable, dylib, socketPath)), "probe attachment")
        let answer = try probeAgentSend(["op": "ping", "expected_pid": pid], for: bundleID, timeout: 2)
        guard answer["ok"] as? Bool == true, answer["pid"] as? Int == pid,
              answer["bundle_id"] as? String == bundleID else {
            throw IcliError.failed("the app changed while attaching; no script was sent")
        }
        return answer
    }
}

/// Evaluate only in the process the caller connected to. A REPL must never
/// silently start using a new process after an app restart.
public func evaluateAppProbe(_ source: String, bundleID: String, pid: Int, timeout: TimeInterval) -> ProbeResult {
    do {
        let answer = try probeAgentSend(
            ["op": "evaluate", "source": source, "timeout": timeout, "expected_pid": pid],
            for: bundleID, timeout: timeout + 2)
        return ProbeResult(
            result: answer["result"] as? String,
            error: answer["ok"] as? Bool == true ? nil : (answer["error"] as? String ?? "invalid probe answer"),
            output: answer["output"] as? String ?? "")
    } catch let error as IcliError {
        return ProbeResult(result: nil, error: error.payload["message"] as? String ?? error.message, output: "")
    } catch {
        return ProbeResult(result: nil, error: error.localizedDescription, output: "")
    }
}

/// Send one request to an app's agent and return its answer, waiting at most
/// `timeout` for it.
///
/// A request the agent answers from its own serving thread needs only as long
/// as the socket; one it hands to the app's main thread should be given longer
/// than the agent's own deadline, so a read that gave up first does not report
/// a silent agent where the agent was about to say what went wrong.
public func probeAgentSend(
    _ request: [String: Any], for bundleID: String, timeout: TimeInterval,
) throws -> [String: Any] {
    let path = try probeAgentSocketPath(for: bundleID)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw IcliError.failed("cannot make a socket: \(errorText(errno))") }
    defer { close(descriptor) }
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, size) }
    }
    guard connected == 0 else {
        let reason = errno
        if reason == ENOENT || reason == ECONNREFUSED {
            throw IcliError.commandFailed([
                "error": "probe_agent_missing", "status": 1,
                "message": "no probe agent is listening for \(bundleID); run 'icli probe --app \(bundleID)' to attach, or 'icli app launch \(bundleID) --probe'",
            ])
        }
        throw IcliError.failed("cannot reach the probe agent for \(bundleID): \(errorText(reason))")
    }

    var limit = timeval(tv_sec: Int(timeout.rounded(.up)), tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

    var line = try JSONSerialization.data(withJSONObject: request)
    line.append(0x0A)
    try writeAll(descriptor, line)
    let answer = try readLine(descriptor, bundleID: bundleID)
    guard let object = try JSONSerialization.jsonObject(with: answer) as? [String: Any] else {
        throw IcliError.failed("the probe agent for \(bundleID) did not answer with a JSON object")
    }
    return object
}

private func writeAll(_ descriptor: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
            let written = write(descriptor, raw.baseAddress!.advanced(by: sent), raw.count - sent)
            if written <= 0 {
                if written < 0, errno == EINTR { continue }
                throw IcliError.failed("the probe agent stopped reading: \(errorText(errno))")
            }
            sent += written
        }
    }
}

/// One newline-terminated answer. An agent that closed without one is an app
/// that went away mid-script, which a crash does.
private func readLine(_ descriptor: Int32, bundleID: String) throws -> Data {
    var answer = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0 {
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw IcliError.failed("the probe agent for \(bundleID) did not answer in time\(suspendedHint(bundleID))")
            }
            throw IcliError.failed("cannot read from the probe agent: \(errorText(errno))")
        }
        if count == 0 {
            guard !answer.isEmpty else {
                throw IcliError.failed(
                    "the probe agent for \(bundleID) closed without answering; the app may have crashed, which 'icli log crashes' reports")
            }
            return answer
        }
        if let newline = buffer[..<count].firstIndex(of: 0x0A) {
            answer.append(contentsOf: buffer[..<newline])
            return answer
        }
        answer.append(contentsOf: buffer[..<count])
    }
}

private func errorText(_ code: Int32) -> String {
    String(cString: strerror(code))
}

/// Why a listening agent can go quiet: iOS suspends a backgrounded app, and a
/// suspended process runs no threads at all, so the agent cannot answer even a
/// ping. The connection still succeeds, since the kernel takes it into the
/// listen backlog without the app running, which is what makes this look like
/// a hang rather than a refusal.
private func suspendedHint(_ bundleID: String) -> String {
    let frontmost = frontmostApp()
    guard frontmost["bundle_id"] as? String != bundleID else { return "" }
    return "; it is not the app in front, and iOS suspends a backgrounded app's threads. "
        + "Bring it forward with 'icli app launch \(bundleID)' and ask again"
}
