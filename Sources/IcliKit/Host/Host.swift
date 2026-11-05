import Darwin
import Foundation
import IcliPrivate
import IcliSystem
import Security

public func listRepos() throws -> [String: Any] {
    let dir = JailbreakRoot.current.jbrootPath("/etc/apt/sources.list.d")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    var entries: [String] = []
    for file in files {
        let path = (dir as NSString).appendingPathComponent(file)
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            entries.append(text)
        }
    }
    return ["repos": entries]
}

public func addRepo(_ url: String) throws -> [String: Any] {
    guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme), parsed.host != nil,
          !url.contains(where: \.isWhitespace), parsed.user == nil, parsed.password == nil
    else {
        throw IcliError.failed("Provide an HTTP or HTTPS repository URL without credentials or whitespace.")
    }
    let dir = JailbreakRoot.current.jbrootPath("/etc/apt/sources.list.d")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let file = (dir as NSString).appendingPathComponent("icli.list")
    let line = "deb \(url) ./"
    let existing = FileManager.default.fileExists(atPath: file) ? try String(contentsOfFile: file, encoding: .utf8) : ""
    if existing.split(separator: "\n").contains(Substring(line)) {
        return ["added": false, "url": url]
    }
    let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
    try (existing + separator + line + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    return ["added": true, "url": url]
}

/// `since` is ISO-8601, epoch seconds, or an age such as 30s, 5m or 2h.
public func parseCrashCutoff(_ text: String) throws -> Date {
    if let unit = text.last, let scale = ["s": 1.0, "m": 60.0, "h": 3600.0][String(unit)],
       let amount = Double(text.dropLast()), amount.isFinite, amount >= 0
    {
        return Date(timeIntervalSinceNow: -amount * scale)
    }
    if let seconds = Double(text), seconds.isFinite { return Date(timeIntervalSince1970: seconds) }
    if let date = parseISO8601(text) { return date }
    throw IcliError.failed("since must be ISO-8601, epoch seconds, or an age such as 30s, 5m or 2h: \(text)")
}

/// What a diagnostic report is, from its file name: a spin or hang, a
/// crash, a system diagnostic (jetsam, resource, panic, watchdog…) or another log.
public enum CrashReportKind: String, CaseIterable {
    case crash, spin, log, diagnostic

    private static let diagnosticWords = [
        "_resource", "jetsamevent", "excresource", "panic", "watchdog", "lowbattery", "sirisearchfeedback",
        "applicationnotresponding", "analytics", "sfa-", "proactive_event_tracker", "xp_amp_",
    ]

    public init(fileName: String) {
        let name = fileName.lowercased()
        if name.contains(".spin") || name.contains(".hang") || name.hasPrefix("stacks") || name.contains("_hang") {
            self = .spin
        } else if name.hasSuffix(".ips") || name.contains(".ips.") || name.hasSuffix(".crash") {
            self = Self.diagnosticWords.contains { name.contains($0) } ? .diagnostic : .crash
        } else {
            self = .log
        }
    }
}

/// Without `kind`, every .ips and .crash report; with it, every file of that kind.
public func crashLogs(
    bundleID: String?, since: Date? = nil, kind: CrashReportKind? = nil, limit: Int? = nil,
) throws -> [String: Any] {
    guard limit == nil || limit! > 0 else { throw IcliError.failed("limit must be at least 1") }
    let dirs = [
        "/var/mobile/Library/Logs/CrashReporter",
        "/var/mobile/Library/Logs/DiagnosticReports",
        "/var/mobile/Library/Logs/CrashReporter/Retired",
    ]
    var files: [(String, Date)] = []
    let appName = bundleID.flatMap { try? appInfo($0)["executable"] as? String }
        .map { ($0 as NSString).lastPathComponent }
    for dir in dirs {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for name in names {
            if let kind {
                guard CrashReportKind(fileName: name) == kind else { continue }
            } else {
                guard name.hasSuffix(".ips") || name.hasSuffix(".crash") else { continue }
            }
            if let bundleID, !name.localizedCaseInsensitiveContains(bundleID),
               appName.map({ name.localizedCaseInsensitiveContains($0) }) != true
            {
                continue
            }
            let path = (dir as NSString).appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            // Folders such as Retired and DiagnosticLogs are not reports.
            if kind != nil, attributes?[.type] as? FileAttributeType == .typeDirectory { continue }
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            if let since, modified < since { continue }
            files.append((path, modified))
        }
    }
    let newest = files.sorted { $0.1 > $1.1 }.map(\.0)
    guard let limit, newest.count > limit else { return ["crashes": newest, "count": files.count] }
    // count stays the number found; truncated says the list stops short of it.
    return ["crashes": Array(newest.prefix(limit)), "count": files.count, "truncated": true]
}

/// What a report's bug_type means; anything else is "bug_type <n>".
public func reportTypeName(_ bugType: String) -> String {
    [
        "109": "crash", "309": "crash", "308": "user fault (the process kept running)",
        "298": "jetsam (memory pressure)", "288": "stackshot", "202": "resource (CPU)",
        "145": "resource (disk writes)",
    ][bugType] ?? "bug_type \(bugType)"
}

/// The most a crash report read answers, in bytes.
public let crashReadLimit: ClosedRange<Int> = 1 ... 64 * 1024 * 1024

/// Reads one crash report as UTF-8 text. With `maxBytes`, at most that many
/// bytes are read, cut back to a whole character, and `truncated` says the
/// report goes on; `size` is always the whole file's.
public func readCrashLog(_ path: String, maxBytes: Int? = nil) throws -> [String: Any] {
    if let maxBytes, !crashReadLimit.contains(maxBytes) {
        throw IcliError.failed("max-bytes must be 1–67108864")
    }
    let prefix: FilePrefix
    do {
        prefix = try FilePrefix.read(path, limit: maxBytes)
    } catch let error as FilePrefixError {
        throw IcliError.failed("crash report: \(error.message)")
    }
    let data = prefix.truncated ? FilePrefix.utf8Prefix(prefix.data) : prefix.data
    guard let text = String(data: data, encoding: .utf8) else {
        throw IcliError.failed("crash report is not UTF-8 text")
    }
    return [
        "path": path,
        "content": text,
        "size": prefix.size,
        "bytes": data.count,
        "encoding": "utf8",
        "truncated": prefix.truncated,
    ]
}

private let crashFrameLimit = 40

/// A report's frames with their image names in place of indexes.
private func crashFrames(_ frames: Any?, images: [[String: Any]]) -> [[String: Any]] {
    (frames as? [[String: Any]] ?? []).map { frame in
        var row: [String: Any] = [:]
        if let index = frame["imageIndex"] as? Int, images.indices.contains(index) {
            row["image"] = images[index]["name"] ?? images[index]["path"].map { ($0 as? NSString)?.lastPathComponent as Any }
        }
        row["offset"] = frame["imageOffset"]
        row["symbol"] = frame["symbol"]
        row["symbol_offset"] = frame["symbolLocation"]
        row["file"] = frame["sourceFile"]
        row["line"] = frame["sourceLine"]
        return row
    }
}

/// What a crash report says went wrong. A report is one line of JSON and a body,
/// which is JSON in crashes and most others and plain text in resource reports.
public func summarizeCrashLog(_ path: String) throws -> [String: Any] {
    let report = try readCrashLog(path)
    let content = report["content"] as? String ?? ""
    let split = content.firstIndex(of: "\n") ?? content.endIndex
    let header = (try? JSONSerialization.jsonObject(with: Data(content[..<split].utf8))) as? [String: Any]
    guard let header else { throw IcliError.failed("crash report: the first line is not JSON") }
    let rest = String(content[split...])
    var summary: [String: Any] = [
        "path": path, "size": report["size"] ?? 0,
        "process": header["app_name"] ?? header["name"] ?? NSNull(),
        "bundle_id": header["bundleID"] ?? NSNull(),
        "version": header["app_version"] ?? NSNull(),
        "build": header["build_version"] ?? NSNull(),
        "os": header["os_version"] ?? NSNull(),
        "time": header["timestamp"] ?? NSNull(),
        "incident": header["incident_id"] ?? NSNull(),
        "bug_type": header["bug_type"] ?? NSNull(),
    ]
    if let type = header["bug_type"] as? String { summary["report_type"] = reportTypeName(type) }
    guard let body = (try? JSONSerialization.jsonObject(with: Data(rest.utf8))) as? [String: Any] else {
        summary["body"] = "text"
        summary["excerpt"] = String(rest.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1500))
        return summary
    }
    summary["body"] = "json"
    summary["process"] = header["app_name"] ?? header["name"] ?? body["procName"] ?? NSNull()
    if let time = body["captureTime"] { summary["time"] = time }
    if let info = body["bundleInfo"] as? [String: Any], let id = info["CFBundleIdentifier"] { summary["bundle_id"] = id }
    for (from, to) in [("pid", "pid"), ("exception", "exception"), ("termination", "termination"),
                       ("vmRegionInfo", "vm_region"), ("asi", "application_info")]
    {
        if let value = body[from] { summary[to] = value }
    }
    let images = body["usedImages"] as? [[String: Any]] ?? []
    if let backtrace = body["lastExceptionBacktrace"] {
        summary["last_exception_backtrace"] = Array(crashFrames(backtrace, images: images).prefix(crashFrameLimit))
    }
    let threads = body["threads"] as? [[String: Any]] ?? []
    let index = (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? $0 : nil }
        ?? threads.firstIndex { $0["triggered"] as? Bool == true }
    if let index {
        let frames = crashFrames(threads[index]["frames"], images: images)
        var thread: [String: Any] = ["index": index, "frames": Array(frames.prefix(crashFrameLimit)), "frame_count": frames.count]
        thread["name"] = threads[index]["name"]
        thread["queue"] = threads[index]["queue"]
        summary["crashed_thread"] = thread
    }
    return summary
}

public func dumpKeychain() throws -> [String: Any] {
    try listKeychain(className: nil, service: nil, account: nil, server: nil, group: nil, includeData: false)
}

public func listKeychain(
    className: String?,
    service: String?,
    account: String?,
    server: String?,
    group: String?,
    includeData: Bool,
) throws -> [String: Any] {
    var items: [[String: Any]] = []
    for entry in keychainClasses(className) {
        var query = keychainQuery(entry.secClass, service: service, account: account, server: server, group: group)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        let withData = includeData && entry.passwords
        if withData {
            query[kSecReturnData as String] = true
        }
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess, withData {
            query.removeValue(forKey: kSecReturnData as String)
            result = nil
            status = SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecItemNotFound {
            continue
        }
        try throwIfKeychain(status, action: "query")
        let rows = result as? [[String: Any]] ?? []
        items.append(contentsOf: rows.map { encodeKeychainItem($0, className: entry.name, includeData: withData) })
    }
    return ["items": items, "count": items.count]
}

public func getKeychain(
    className: String,
    service: String?,
    account: String?,
    server: String?,
    group: String?,
) throws -> [String: Any] {
    let listed = try listKeychain(
        className: className,
        service: service,
        account: account,
        server: server,
        group: group,
        includeData: true,
    )
    let items = listed["items"] as? [[String: Any]] ?? []
    if items.isEmpty {
        throw IcliError.failed("keychain item not found")
    }
    return listed
}

public func addKeychain(
    className: String,
    service: String?,
    account: String,
    server: String?,
    label: String?,
    group: String?,
    data: String,
) throws -> [String: Any] {
    var item: [String: Any] = try [
        kSecClass as String: secClass(named: className),
        kSecAttrAccount as String: account,
        kSecValueData as String: Data(data.utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecReturnAttributes as String: true,
        kSecReturnPersistentRef as String: true,
    ]
    if let service, !service.isEmpty {
        item[kSecAttrService as String] = service
    }
    if let server, !server.isEmpty {
        item[kSecAttrServer as String] = server
    }
    if let label, !label.isEmpty {
        item[kSecAttrLabel as String] = label
    }
    if let group, !group.isEmpty {
        item[kSecAttrAccessGroup as String] = group
    }
    var result: CFTypeRef?
    try throwIfKeychain(SecItemAdd(item as CFDictionary, &result), action: "add")
    guard let result else {
        throw IcliError.failed("keychain add did not persist")
    }
    if let dict = result as? [String: Any] {
        var encoded = encodeKeychainItem(dict, className: className, includeData: true)
        encoded["ok"] = true
        encoded["data"] = data
        return encoded
    }
    return [
        "ok": true,
        "class": className,
        "account": account,
        "service": service ?? "",
        "data": data,
    ]
}

public func updateKeychain(
    className: String,
    service: String?,
    account: String,
    server: String?,
    group: String?,
    data: String,
) throws -> [String: Any] {
    let query = try keychainQuery(
        secClass(named: className),
        service: service,
        account: account,
        server: server,
        group: group,
    )
    try throwIfKeychain(
        SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(data.utf8)] as CFDictionary),
        action: "update",
    )
    return try getKeychain(className: className, service: service, account: account, server: server, group: group)
}

public func deleteKeychain(
    className: String,
    service: String?,
    account: String?,
    server: String?,
    group: String?,
) throws -> [String: Any] {
    let query = try keychainQuery(
        secClass(named: className),
        service: service,
        account: account,
        server: server,
        group: group,
    )
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecItemNotFound {
        return ["deleted": false, "message": "keychain item not found"]
    }
    try throwIfKeychain(status, action: "delete")
    return ["deleted": true]
}

private struct KeychainClass {
    let name: String
    let secClass: CFString
    let passwords: Bool
}

private func keychainClasses(_ className: String?) -> [KeychainClass] {
    let all = [
        KeychainClass(name: "generic_password", secClass: kSecClassGenericPassword, passwords: true),
        KeychainClass(name: "internet_password", secClass: kSecClassInternetPassword, passwords: true),
        KeychainClass(name: "certificate", secClass: kSecClassCertificate, passwords: false),
        KeychainClass(name: "key", secClass: kSecClassKey, passwords: false),
        KeychainClass(name: "identity", secClass: kSecClassIdentity, passwords: false),
    ]
    guard let className else { return all }
    guard let wanted = try? secClass(named: className) else { return [] }
    return all.filter { CFEqual($0.secClass, wanted) }
}

private func secClass(named name: String) throws -> CFString {
    switch name {
    case "generic_password", "generic": return kSecClassGenericPassword
    case "internet_password", "internet": return kSecClassInternetPassword
    case "certificate": return kSecClassCertificate
    case "key": return kSecClassKey
    case "identity": return kSecClassIdentity
    default: throw IcliError.failed("unknown keychain class: \(name)")
    }
}

private func keychainQuery(
    _ secClass: CFString,
    service: String?,
    account: String?,
    server: String?,
    group: String?,
) -> [String: Any] {
    var query: [String: Any] = [kSecClass as String: secClass]
    if let service, !service.isEmpty {
        query[kSecAttrService as String] = service
    }
    if let account, !account.isEmpty {
        query[kSecAttrAccount as String] = account
    }
    if let server, !server.isEmpty {
        query[kSecAttrServer as String] = server
    }
    if let group, !group.isEmpty {
        query[kSecAttrAccessGroup as String] = group
    }
    return query
}

private func encodeKeychainItem(_ item: [String: Any], className: String, includeData: Bool) -> [String: Any] {
    var copy: [String: Any] = ["class": className, "source": "security"]
    if let acct = item[kSecAttrAccount as String] {
        copy["account"] = "\(acct)"
    }
    if let svc = item[kSecAttrService as String] {
        copy["service"] = "\(svc)"
    }
    if let label = item[kSecAttrLabel as String] {
        copy["label"] = "\(label)"
    }
    if let server = item[kSecAttrServer as String] {
        copy["server"] = "\(server)"
    }
    if let group = item[kSecAttrAccessGroup as String] {
        copy["group"] = "\(group)"
    }
    if includeData, let data = item[kSecValueData as String] as? Data {
        copy["data"] = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
    }
    return copy
}

private func throwIfKeychain(_ status: OSStatus, action: String) throws {
    if status == errSecSuccess {
        return
    }
    if status == errSecItemNotFound {
        throw IcliError.failed("keychain item not found")
    }
    if status == errSecDuplicateItem {
        throw IcliError.failed("keychain item already exists")
    }
    if status == errSecInteractionNotAllowed {
        throw IcliError.failed("keychain unavailable while device is locked")
    }
    throw IcliError.failed("keychain \(action) status \(status)")
}

public func sslKillswitchStatus() -> [String: Any] {
    let root = JailbreakRoot.current
    let candidates = [
        root.jbrootPath("/Library/MobileSubstrate/DynamicLibraries/SSLKillSwitch2.dylib"),
        root.jbrootPath("/usr/lib/TweakInject/SSLKillSwitch2.dylib"),
    ]
    return ["present": candidates.contains(where: FileManager.default.fileExists)]
}

/// Captures from the interface's BPF device (root) into a pcap file and
/// returns a summary of the first packets. Filters accept
/// `[tcp|udp|icmp] [src|dst] port N [src|dst] host A`, joined with `and`.
public func capturePackets(
    seconds: TimeInterval,
    interface: String = "en0",
    filter: String? = nil,
    output: String? = nil,
) throws -> [String: Any] {
    guard seconds.isFinite, (1 ... 60).contains(seconds) else {
        throw IcliError.failed("Capture duration must be between 1 and 60 seconds.")
    }
    guard !interface.isEmpty, interface.utf8.count <= 15,
          interface.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
    else {
        throw IcliError.failed("Provide a network interface name.")
    }
    let out = output ?? JailbreakRoot.current.scratchDirectory() + "/icli-\(UUID().uuidString).pcap"
    var payload: [String: Any]
    do {
        payload = try decodeBridgeJSON(
            takeCString(icli_capture_packets_json(interface, filter, seconds, out)),
            "capture response",
        )
    } catch {
        try? FileManager.default.removeItem(atPath: out)
        throw error
    }
    payload["seconds"] = seconds
    payload["file_bytes"] = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
    return payload
}
