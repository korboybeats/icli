import Darwin
import Foundation
import IcliPrivate

private func orNull(_ value: Any?) -> Any { value ?? NSNull() }

private func bootTime() -> Int? {
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
    return Int(boot.tv_sec)
}

/// Everything a test step checks before it acts, from one call: lock and
/// screen, what is in front, whether the keyboard, an overlay or an owner-only
/// prompt is up, and SpringBoard's PID and the boot time, whose change means
/// a respring or a reboot happened in between.
public func deviceStatus() -> [String: Any] {
    icli_private_init()
    let lock = icli_lock_status()
    let metrics = icli_screen_metrics()
    var result: [String: Any] = [
        "locked": lock.locked, "screen_off": lock.screen_off, "orientation": Int(metrics.orientation),
        "frontmost": frontmostApp(),
    ]
    let shell = try? systemShellPID()
    result["springboard_pid"] = orNull(shell.map { Int($0) })
    result["boot_time"] = orNull(bootTime())
    let style = icli_appearance_get()
    result["appearance"] = orNull(style == 1 ? "light" : style == 2 ? "dark" : nil)
    guard !lock.screen_off else { return result }
    func visible(_ pid: Int32) -> [[String: Any]] {
        ((try? axElements(pid: pid, maxElements: 2000))?["elements"] as? [[String: Any]] ?? [])
            .filter { $0["visible"] as? Bool == true }
    }
    let system = shell.map(visible) ?? []
    var app: [[String: Any]] = []
    if !lock.locked, let front = try? onScreenPID(), front != shell { app = visible(front) }
    let overlay = app.isEmpty ? [] : system.filter { (elementCoordinate($0["y"]) ?? 0) > statusBarBottom }
    result["system_overlay"] = !overlay.isEmpty
    result["overlay"] = overlay.prefix(8).compactMap { ($0["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    result["keyboard_shown"] = app.contains { ($0["traits"] as? Int ?? 0) & 0x20 != 0 }
    result["prompt"] = orNull(promptKind(in: screenText(system + app)))
    return result
}

/// An exclusive claim on the device for one runner, so another agent's input
/// does not land in the middle of its test. Without a lease nothing changes;
/// while one is held, interaction and state-changing commands without its token
/// fail with `leased`. Explicit background commands do not check or renew it.
///
/// A lease is held until its runner releases it. Every guarded command that carries
/// the token keeps it alive, so a run of any length never loses it; only a
/// lease nothing has used for `idle_seconds` lapses, which frees the device
/// after a runner crashed or lost its connection without releasing.
public enum Lease {
    public static let path = "/var/mobile/Library/Caches/com.korboy.icli/lease.json"
    /// While this file exists the lease indicator in SpringBoard stays hidden.
    public static let indicatorOffPath = "/var/mobile/Library/Caches/com.korboy.icli/indicator-off"
    /// Posted after every change to the lease file or the indicator switch;
    /// the lease indicator in SpringBoard reads the file again when it fires.
    static let changedNotification = "com.korboy.icli.lease-changed"

    static func announce() {
        var delivered = false
        _ = icli_notify_post(changedNotification, false, 0, &delivered)
    }
    /// Set by the lease and status commands, which must run whoever holds it.
    public static var exempt = false
    public static let exitStatus = 75
    public static let defaultIdleSeconds = 600.0

    static func current() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let lease = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expires = lease["expires_at"] as? Double, expires > Date().timeIntervalSince1970
        else { return nil }
        return lease
    }

    static var callerToken: String? { ProcessInfo.processInfo.environment["ICLI_LEASE"] }

    static func idleSeconds(_ lease: [String: Any]) -> Double {
        if let idle = lease["idle_seconds"] as? Double { return idle }
        // A lease written before idle_seconds existed lasted its whole TTL.
        return (lease["expires_at"] as? Double ?? 0) - (lease["acquired_at"] as? Double ?? 0)
    }

    static func check() throws {
        guard FileManager.default.fileExists(atPath: path), let lease = current() else { return }
        guard callerToken != lease["token"] as? String else {
            touch(lease)
            return
        }
        throw IcliError.commandFailed(describe(lease).merging([
            "error": "leased", "status": exitStatus,
            "message": "\(lease["owner"] as? String ?? "another runner") holds this device; run with its ICLI_LEASE token or wait until it is released",
        ]) { $1 })
    }

    /// Moves the holder's lease forward to `idle_seconds` from now. Commands
    /// within a second of the last use skip the write.
    static func touch(_ lease: [String: Any]) {
        let now = Date().timeIntervalSince1970
        guard now - (lease["last_used_at"] as? Double ?? lease["acquired_at"] as? Double ?? 0) >= 1 else { return }
        var renewed = lease
        renewed["idle_seconds"] = idleSeconds(lease)
        renewed["last_used_at"] = now
        renewed["expires_at"] = now + idleSeconds(lease)
        try? store(renewed)
    }

    static func store(_ lease: [String: Any]) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700],
        )
        try JSONSerialization.data(withJSONObject: lease).write(to: URL(fileURLWithPath: path), options: .atomic)
        // Root and mobile both run icli, and either must be able to renew or
        // release the lease, so mobile owns the directory and the file, as it
        // does the passcode ledger beside them. The atomic write replaces the
        // file, so its owner is set again on every write.
        if geteuid() == 0 {
            chown(directory, 501, 501)
            chown(path, 501, 501)
        }
        chmod(path, 0o600)
        announce()
    }

    static func describe(_ lease: [String: Any]) -> [String: Any] {
        let expires = lease["expires_at"] as? Double ?? 0
        let acquired = lease["acquired_at"] as? Double ?? 0
        return ["owner": lease["owner"] ?? "", "expires_at": expires,
                "seconds_left": max(0, Int(expires - Date().timeIntervalSince1970)),
                "idle_seconds": idleSeconds(lease),
                "last_used_at": lease["last_used_at"] as? Double ?? acquired,
                "acquired_at": acquired]
    }
}

public func leaseStatus() -> [String: Any] {
    guard let lease = Lease.current() else { return ["held": false] }
    return Lease.describe(lease).merging(["held": true, "mine": Lease.callerToken == lease["token"] as? String]) { $1 }
}

/// `seconds` is how long the lease survives without a command carrying its
/// token; acquiring again with the token renews it and may change that.
public func acquireLease(owner: String, seconds: Double, force: Bool) throws -> [String: Any] {
    guard !owner.isEmpty, owner.count <= 200 else { throw IcliError.failed("owner must be 1–200 characters") }
    guard seconds.isFinite, (1 ... 86400).contains(seconds) else { throw IcliError.failed("ttl must be 1–86400 seconds") }
    let now = Date().timeIntervalSince1970
    var token = UUID().uuidString
    var acquired = now
    if let lease = Lease.current() {
        if Lease.callerToken == lease["token"] as? String {
            token = lease["token"] as? String ?? token
            acquired = lease["acquired_at"] as? Double ?? now
        } else if !force {
            throw IcliError.commandFailed(Lease.describe(lease).merging([
                "error": "leased", "status": Lease.exitStatus,
                "message": "\(lease["owner"] as? String ?? "another runner") holds this device; --force takes it over",
            ]) { $1 })
        }
    }
    let lease: [String: Any] = ["owner": owner, "token": token, "acquired_at": acquired, "last_used_at": now,
                                "idle_seconds": seconds, "expires_at": now + seconds]
    try Lease.store(lease)
    return Lease.describe(lease).merging(["held": true, "token": token]) { $1 }
}

public func releaseLease(force: Bool) throws -> [String: Any] {
    guard let lease = Lease.current() else {
        try? FileManager.default.removeItem(atPath: Lease.path)
        return ["released": false, "held": false]
    }
    guard force || Lease.callerToken == lease["token"] as? String else {
        throw IcliError.commandFailed(Lease.describe(lease).merging([
            "error": "leased", "status": Lease.exitStatus,
            "message": "only the holder's ICLI_LEASE token or --force releases it",
        ]) { $1 })
    }
    try FileManager.default.removeItem(atPath: Lease.path)
    Lease.announce()
    return ["released": true, "held": false, "owner": lease["owner"] ?? ""]
}

/// Whether the lease indicator in SpringBoard shows the holder's name.
public func leaseIndicator() -> [String: Any] {
    ["indicator": FileManager.default.fileExists(atPath: Lease.indicatorOffPath) ? "off" : "on"]
}

public func setLeaseIndicator(_ on: Bool) throws -> [String: Any] {
    let before = leaseIndicator()["indicator"] as? String
    if on {
        if FileManager.default.fileExists(atPath: Lease.indicatorOffPath) {
            try FileManager.default.removeItem(atPath: Lease.indicatorOffPath)
        }
    } else {
        let directory = (Lease.indicatorOffPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700],
        )
        FileManager.default.createFile(atPath: Lease.indicatorOffPath, contents: Data())
        if geteuid() == 0 {
            chown(directory, 501, 501)
            chown(Lease.indicatorOffPath, 501, 501)
        }
    }
    Lease.announce()
    let after = leaseIndicator()
    return after.merging(["changed": before != after["indicator"] as? String]) { $1 }
}

/// What a failed command leaves behind when ICLI_FAILURE_ARTIFACTS names a
/// directory: the screen, the element list, and the error with its context.
func saveFailureArtifacts(directory: String, argv: [String], error: [String: Any]) throws -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss.SSS"
    let words = argv.prefix(3).filter { !$0.hasPrefix("-") }.joined(separator: "-")
    let name = String(words.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.prefix(60))
    let folder = (directory as NSString).appendingPathComponent("\(formatter.string(from: Date()))-\(getpid())-\(name)")
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let lock = icli_lock_status()
    var context: [String: Any] = ["argv": argv, "error": error, "frontmost": frontmostApp(),
                                  "locked": lock.locked, "screen_off": lock.screen_off]
    if !lock.screen_off {
        _ = icli_screenshot_jpeg((folder as NSString).appendingPathComponent("screen.jpg"), 0.8, 0, false)
        do {
            let tree = try uiElements(maxElements: 2000, scope: lock.locked ? .system : .auto)
            let data = try JSONSerialization.data(withJSONObject: jsonSafe(tree), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent("tree.json")))
        } catch {
            context["tree_error"] = (error as? IcliError)?.message ?? error.localizedDescription
        }
    }
    let data = try JSONSerialization.data(withJSONObject: jsonSafe(context), options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent("error.json")))
    return folder
}
