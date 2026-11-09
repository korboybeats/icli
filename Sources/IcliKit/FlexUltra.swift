import Darwin
import Foundation
import IcliFlexClient

/// The original FlexUltra command parser and MCP server, with requests sent
/// through icli's own app agent instead of an unauthenticated loopback broker.
public func runFlexUltra(_ arguments: [String], request: @escaping ([String: Any]) -> [String: Any]) -> Int32 {
    activeFlexRequest = request
    defer { activeFlexRequest = nil }
    if arguments.first == "mcp" { return icli_flex_mcp(flexRequestTrampoline) }
    let allocated = (["icli flex"] + arguments).map { strdup($0)! }
    defer { allocated.forEach { free($0) } }
    let pointers: [UnsafePointer<CChar>?] = allocated.map { UnsafePointer($0) }
    return pointers.withUnsafeBufferPointer { icli_flex_cli(Int32(pointers.count), $0.baseAddress, flexRequestTrampoline) }
}

public var flexUltraBuildID: String { String(cString: icli_flex_build_id()) }

private var activeFlexRequest: (([String: Any]) -> [String: Any])?
private func flexRequestTrampoline(_ source: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let source, let request = try? JSONSerialization.jsonObject(with: Data(String(cString: source).utf8)) as? [String: Any],
          let handler = activeFlexRequest else { return nil }
    let reply = jsonSafe(handler(request))
    guard let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) else { return nil }
    return strdup(String(decoding: data, as: UTF8.self))
}

/// Routing state for one CLI/MCP client. App operations and physical input
/// use the existing icli command executor supplied by the executable.
public final class FlexUltraRouter {
    private let execute: ([String]) throws -> [String: Any]
    private var currentOperation = ""
    private var identities: [String: [String: Any]] = [:]
    private let historyDirectory = "/var/mobile/Library/Caches/icli-flex"
    private let catalog: [[String: Any]]

    public init(execute: @escaping ([String]) throws -> [String: Any]) {
        self.execute = execute
        let raw = takeCString(icli_flex_catalog_json()) ?? "[]"
        catalog = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]] ?? []
    }

    public func handle(_ request: [String: Any]) -> [String: Any] {
        let id = request["id"] as? String ?? UUID().uuidString
        let op = request["op"] as? String ?? ""
        currentOperation = op
        do {
            try Lease.check()
            guard catalog.contains(where: { $0["operation"] as? String == op }) else {
                throw FlexFailure("unknown_operation", "Unknown operation: \(op)")
            }
            if op == "targets" {
                let rows = try discover()
                return success(id, ["targets": rows, "expected_agent_build": flexUltraBuildID,
                                    "transport": "icli_unix_socket", "daemon_memory_policy": ["resident_daemon": false]])
            }
            if op == "target.history" { return success(id, try history(request)) }
            if op == "target.resolve" {
                let query = try targetText(request)
                let selected = try select(query, from: discover())
                return success(id, ["query": query, "match_kind": selected.1, "target": selected.0])
            }
            if op.hasPrefix("app.") {
                let argv: [String]
                switch op {
                case "app.list": argv = ["app", "list"]
                case "app.running": argv = ["app", "running"]
                case "app.frontmost": argv = ["app", "frontmost"]
                case "app.launch", "app.kill":
                    guard let bundle = request["bundle_id"] as? String, !bundle.isEmpty else {
                        throw FlexFailure("invalid_arguments", "bundle_id must be a non-empty string")
                    }
                    if op == "app.kill", let force = request["force"], !(force is Bool) {
                        throw FlexFailure("invalid_arguments", "force must be a boolean")
                    }
                    argv = ["app", op == "app.launch" ? "launch" : "kill", bundle]
                        + ((request["force"] as? Bool == true && op == "app.kill") ? ["--force"] : [])
                default: throw FlexFailure("unknown_operation", op)
                }
                return try command(id, argv)
            }
            if op.hasPrefix("input.") {
                let source = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
                guard let encoded = takeCString(icli_flex_input_arguments_json(source)),
                      let parsed = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] else {
                    throw FlexFailure("invalid_arguments", "Cannot decode the input command")
                }
                guard let argv = parsed["argv"] as? [String] else {
                    return ["v": 1, "kind": "response", "id": id, "ok": false, "error": parsed["error"] ?? [:]]
                }
                return try command(id, argv)
            }
            try Envelope.applyLockPolicy(allowWhenLocked: false)
            let selected = try select(try targetText(request), from: discover())
            guard let bundle = selected.0["bundle_id"] as? String else {
                throw FlexFailure("target_not_found", "The target has no application identity")
            }
            let info = try prepareProbeAgent(for: bundle)
            guard info["flexultra_build"] as? String == flexUltraBuildID else {
                throw FlexFailure("stale_agent", "This app has an older icli agent. Relaunch the app once to load the installed version.")
            }
            guard let pid = info["pid"] as? Int, pid == selected.0["pid"] as? Int else {
                throw FlexFailure("target_generation_changed", "The selected process changed before attachment; resolve it again")
            }
            var forwarded = request
            forwarded["id"] = id
            let budget = TimeInterval(icli_flex_receive_timeout(op))
            let answer = try probeAgentSend(["op": "flexultra", "expected_pid": pid, "request": forwarded], for: bundle, timeout: budget)
            var observed = info
            if let generation = answer["generation"] as? String { observed["generation"] = generation }
            if let result = answer["result"] as? [String: Any] {
                if op == "ping" { observed.merge(result) { _, new in new } }
                if op == "target.health", let identity = result["identity"] as? [String: Any] {
                    observed.merge(identity) { _, new in new }
                }
            }
            identities[bundle] = metadata(observed)
            var response = answer
            if answer["ok"] as? Bool != true {
                let detail = answer["error"] as? [String: Any]
                response = fail(id, detail?["code"] as? String ?? answer["error"] as? String ?? "operation_failed",
                                detail?["message"] as? String ?? answer["message"] as? String ?? "The app agent could not complete the request")
                if var error = response["error"] as? [String: Any], let detail {
                    error.merge(detail) { _, original in original }; response["error"] = error
                }
                for (key, value) in answer where key != "error" { response[key] = value }
                response["id"] = id
            }
            do { try record([identities[bundle]!]) }
            catch { response["history_warning"] = error.localizedDescription }
            return response
        } catch let failure as FlexFailure {
            return fail(id, failure.code, failure.message, candidates: failure.candidates)
        } catch let error as IcliError {
            return fail(id, error.payload["error"] as? String ?? error.code, error.payload["message"] as? String ?? error.message)
        } catch {
            return fail(id, "failed", error.localizedDescription)
        }
    }

    private func command(_ id: String, _ argv: [String]) throws -> [String: Any] {
        let report = try execute(argv)
        if report["ok"] as? Bool == true { return success(id, report["result"] ?? [:]) }
        let payload = report["result"] as? [String: Any] ?? [:]
        return fail(id, payload["error"] as? String ?? "command_failed",
                    payload["message"] as? String ?? report["message"] as? String ?? "icli command failed")
    }

    private func success(_ id: String, _ result: Any) -> [String: Any] {
        ["v": 1, "kind": "response", "id": id, "ok": true, "result": result]
    }

    private func fail(_ id: String, _ code: String, _ message: String, candidates: [[String: Any]] = []) -> [String: Any] {
        let encoded = takeCString(icli_flex_error_json(id, code, message, currentOperation)) ?? "{}"
        var response = (try? JSONSerialization.jsonObject(with: Data(encoded.utf8))) as? [String: Any] ?? [:]
        if !candidates.isEmpty, var error = response["error"] as? [String: Any] {
            error["candidates"] = candidates; response["error"] = error
        }
        return response
    }

    private func targetText(_ request: [String: Any]) throws -> String {
        guard request["target"] == nil || request["target"] is String else {
            throw FlexFailure("invalid_arguments", "target must be a PID, bundle ID or process name string")
        }
        return request["target"] as? String ?? ""
    }

    private func select(_ query: String, from rows: [[String: Any]]) throws -> ([String: Any], String) {
        let candidates: [[String: Any]]
        let kind: String
        if query.isEmpty {
            candidates = rows.filter { $0["agent_attached"] as? Bool == true }
            kind = "unique"
        } else if let pid = Int(query), rows.contains(where: { $0["pid"] as? Int == pid }) {
            candidates = rows.filter { $0["pid"] as? Int == pid }; kind = "pid"
        } else if rows.contains(where: { $0["bundle_id"] as? String == query }) {
            candidates = rows.filter { $0["bundle_id"] as? String == query }; kind = "bundle_id"
        } else {
            candidates = rows.filter { $0["process"] as? String == query || $0["name"] as? String == query }; kind = "process"
        }
        guard candidates.count == 1 else {
            throw FlexFailure(candidates.isEmpty ? "target_not_found" : "target_ambiguous",
                              candidates.isEmpty ? "No running application matches '\(query)'" : "Multiple targets match '\(query)'; select an exact PID",
                              candidates: candidates)
        }
        return (candidates[0], kind)
    }

    private func metadata(_ info: [String: Any]) -> [String: Any] {
        let build = info["flexultra_build"] as? String ?? info["agent_build"] as? String ?? ""
        let attached = info["agent_attached"] as? Bool ?? !build.isEmpty
        return ["pid": info["pid"] ?? 0, "bundle_id": info["bundle_id"] ?? "",
                "process": info["process"] ?? info["name"] ?? "", "name": info["name"] ?? "",
                "generation": info["generation"] ?? "", "agent_build": build,
                "expected_agent_build": flexUltraBuildID, "agent_attached": attached,
                "build_status": build.isEmpty ? "not_attached" : (build == flexUltraBuildID ? "current" : "stale"),
                "current_agent": build == flexUltraBuildID, "refresh_recommended": attached && build != flexUltraBuildID,
                "connected_at_unix_ms": info["connected_at_unix_ms"] ?? 0,
                "capabilities": catalog.filter { (($0["flags"] as? Int ?? 0) & 1) != 0 }.compactMap { $0["operation"] as? String }]
    }

    private func discover() throws -> [[String: Any]] {
        var apps = try runningApps()["apps"] as? [[String: Any]] ?? []
        if let pid = processPID(named: SystemShell.processName), !apps.contains(where: { $0["bundle_id"] as? String == SystemShell.bundleID }) {
            apps.append(["bundle_id": SystemShell.bundleID, "name": SystemShell.processName, "pid": Int(pid)])
        }
        let processes = try listProcesses(filter: nil)["processes"] as? [[String: Any]] ?? []
        let cached = (try? withHistory { $0["active"] as? [[String: Any]] ?? [] }) ?? []
        let front = frontmostApp()["bundle_id"] as? String
        var rows: [[String: Any]] = []
        for app in apps {
            guard let bundle = app["bundle_id"] as? String, let pid = app["pid"] as? Int else { continue }
            var raw = app
            if let process = processes.first(where: { $0["pid"] as? Int == pid }) {
                let executable = process["executable"] as? String ?? ""
                raw["process"] = executable.isEmpty ? process["name"] : URL(fileURLWithPath: executable).lastPathComponent
            }
            let remembered = identities[bundle].flatMap { $0["pid"] as? Int == pid ? $0 : nil }
            if let known = remembered ?? cached.first(where: { $0["bundle_id"] as? String == bundle && $0["pid"] as? Int == pid }) {
                raw.merge(known) { _, old in old }
            }
            if let path = try? probeAgentSocketPath(for: bundle),
               let data = try? Data(contentsOf: URL(fileURLWithPath: path + ".info")),
               let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any], marker["pid"] as? Int == pid {
                raw.merge(marker) { _, new in new }
                raw["agent_attached"] = true
                if bundle == front, let ping = try? probeAgentSend(["op": "ping"], for: bundle, timeout: 2) {
                    raw.merge(ping) { _, new in new }
                }
            }
            rows.append(metadata(raw))
        }
        rows.sort { ($0["pid"] as? Int ?? 0) < ($1["pid"] as? Int ?? 0) }
        // Optional bookkeeping must never turn a completed mutation into an error.
        try? record(rows, fullSnapshot: true)
        return rows
    }

    private func withHistory<T>(_ body: (inout [String: Any]) throws -> T) throws -> T {
        try FileManager.default.createDirectory(atPath: historyDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(historyDirectory + "/lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw IcliError.failed("cannot lock FlexUltra target history") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw IcliError.failed("cannot lock FlexUltra target history") }
        defer { flock(fd, LOCK_UN) }
        let path = URL(fileURLWithPath: historyDirectory + "/targets.json")
        var history = ((try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
            ?? ["events": [], "active": [], "started": Date().timeIntervalSince1970 * 1000, "dropped": 0]
        let result = try body(&history)
        try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys]).write(to: path, options: .atomic)
        return result
    }

    private func record(_ rows: [[String: Any]], fullSnapshot: Bool = false) throws {
        try withHistory { history in
            var events = history["events"] as? [[String: Any]] ?? []
            var active = history["active"] as? [[String: Any]] ?? []
            if fullSnapshot {
                let vanished = active.filter { old in
                    !rows.contains { $0["pid"] as? Int == old["pid"] as? Int && $0["agent_attached"] as? Bool == true }
                }
                for old in vanished {
                    var event = old; event["event"] = "disconnected"; event["reason"] = "process_not_observed"
                    event["timestamp_unix_ms"] = Date().timeIntervalSince1970 * 1000
                    events.append(event)
                }
                active.removeAll { old in vanished.contains { $0["pid"] as? Int == old["pid"] as? Int } }
            }
            for row in rows where row["agent_attached"] as? Bool == true {
                guard let bundle = row["bundle_id"] as? String else { continue }
                let old = active.first { $0["bundle_id"] as? String == bundle }
                if old?["pid"] as? Int != row["pid"] as? Int || old?["agent_build"] as? String != row["agent_build"] as? String || old?["generation"] as? String != row["generation"] as? String {
                    var event = row; event["event"] = "connected"; event["timestamp_unix_ms"] = Date().timeIntervalSince1970 * 1000
                    events.append(event)
                }
                active.removeAll { $0["bundle_id"] as? String == bundle }
                active.append(row)
            }
            if events.count > 128 {
                history["dropped"] = (history["dropped"] as? Int ?? 0) + events.count - 128
                events.removeFirst(events.count - 128)
            }
            history["active"] = active; history["events"] = events
        }
    }

    private func history(_ request: [String: Any]) throws -> [String: Any] {
        let query = try targetText(request)
        let count = request["limit"] as? NSNumber ?? 32
        guard count.doubleValue.isFinite, count.doubleValue == Double(count.intValue), (1 ... 128).contains(count.intValue) else {
            throw FlexFailure("invalid_arguments", "limit must be an integer from 1 through 128")
        }
        let current = try discover().filter { matches($0, query) && $0["agent_attached"] as? Bool == true }
        return try withHistory { data in
            let events = (data["events"] as? [[String: Any]] ?? []).filter { matches($0, query) }
            let dropped = data["dropped"] as? Int ?? 0
            let state = query.isEmpty ? "unfiltered" : (current.count > 1 ? "current_ambiguous" :
                (current.count == 1 ? (current[0]["current_agent"] as? Bool == true ? "current" : "stale_current") :
                    (events.isEmpty ? "never_observed" : "recently_disconnected")))
            return ["query": query.isEmpty ? NSNull() : query as Any, "state": state,
                    "source": "icli_observed_agents", "history_capacity": 128, "history_dropped": dropped,
                    "history_truncated": dropped > 0, "daemon_started_at_unix_ms": data["started"] ?? 0,
                    "expected_agent_build": flexUltraBuildID, "retained_match_count": events.count,
                    "reconnect_count_in_retained_history": max(0, events.filter { $0["event"] as? String == "connected" }.count - 1), "limit": count,
                    "current_targets": current, "events": Array(events.reversed().prefix(count.intValue)),
                    "recovery_hint": "resolve_target", "recommended_action": "Resolve the current PID and call target.health; history records agents observed by icli."]
        }
    }

    private func matches(_ info: [String: Any], _ query: String) -> Bool {
        query.isEmpty || info["bundle_id"] as? String == query || info["process"] as? String == query
            || String(info["pid"] as? Int ?? 0) == query
    }
}

private struct FlexFailure: Error {
    let code: String
    let message: String
    var candidates: [[String: Any]] = []
    init(_ code: String, _ message: String, candidates: [[String: Any]] = []) {
        self.code = code; self.message = message; self.candidates = candidates
    }
}
