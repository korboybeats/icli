import Foundation
import IcliPrivate

/// Privacy permissions by the names people use, and the TCC service each is.
private let tccServices: [String: String] = [
    "camera": "kTCCServiceCamera", "microphone": "kTCCServiceMicrophone", "photos": "kTCCServicePhotos",
    "photos-add": "kTCCServicePhotosAdd", "contacts": "kTCCServiceAddressBook", "calendar": "kTCCServiceCalendar",
    "reminders": "kTCCServiceReminders", "motion": "kTCCServiceMotion", "bluetooth": "kTCCServiceBluetoothAlways",
    "speech": "kTCCServiceSpeechRecognition", "media-library": "kTCCServiceMediaLibrary", "face-id": "kTCCServiceFaceID",
    "tracking": "kTCCServiceUserTracking", "focus": "kTCCServiceFocusStatus", "nearby": "kTCCServiceNearbyInteraction",
    "siri": "kTCCServiceSiri",
]

/// Location is locationd's, not TCC's: these are CLAuthorizationStatus values.
private let locationStates = [0: "not_determined", 2: "denied", 3: "always", 4: "while_using"]

public let permissionNames = (tccServices.keys + ["location", "location-always"]).sorted()

private func bundlePath(_ app: [String: Any], _ bundleID: String) throws -> String {
    guard let path = app["bundle_path"] as? String, !path.isEmpty else {
        throw IcliError.failed("\(bundleID) has no bundle on disk")
    }
    return path
}

public func appPermissions(_ bundleID: String) throws -> [String: Any] {
    let app = try appInfo(bundleID)
    let reply = try decodeBridgeJSON(takeCString(icli_permissions_json(try bundlePath(app, bundleID))), "TCC response")
    if let error = reply["error"] as? String { throw IcliError.unavailable(error) }
    let names = Dictionary(tccServices.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    var permissions: [String: Any] = [:]
    for entry in reply["entries"] as? [[String: Any]] ?? [] {
        guard let service = entry["service"] as? String else { continue }
        permissions[names[service] ?? service] = entry["granted"] as? Bool == true ? "granted" : "denied"
    }
    let location = icli_location_authorization_get(bundleID)
    if location > 0 { permissions["location"] = locationStates[Int(location)] ?? "status_\(location)" }
    return ["app": bundleID, "permissions": permissions]
}

/// Grants, denies or resets permissions without the system prompt. A reset
/// returns them to never asked, so the app's next request prompts again.
public func setAppPermissions(_ bundleID: String, _ requested: [String], action: String) throws -> [String: Any] {
    guard ["grant", "deny", "reset"].contains(action) else { throw IcliError.failed("action must be grant, deny or reset") }
    let all = requested.isEmpty || requested == ["all"]
    guard action == "reset" || !all else { throw IcliError.failed("name the permissions to \(action): \(permissionNames.joined(separator: ", "))") }
    let names = all ? permissionNames.filter { $0 != "location-always" } : requested
    if let unknown = names.first(where: { !permissionNames.contains($0) }) {
        throw IcliError.failed("unknown permission \(unknown); use \(permissionNames.joined(separator: ", "))")
    }
    let app = try appInfo(bundleID)
    let path = try bundlePath(app, bundleID)
    let unavailable = "This device refused the permission change."
    if all {
        guard icli_tcc_reset("kTCCServiceAll", bundleID) else { throw IcliError.unavailable(unavailable) }
    }
    for name in names {
        if name == "location" || name == "location-always" {
            let status: Int32 = action == "reset" ? 0 : action == "deny" ? 2 : name == "location" ? 4 : 3
            guard icli_location_authorization_set(bundleID, status) else { throw IcliError.unavailable(unavailable) }
            continue
        }
        if all { continue }
        let service = tccServices[name]!
        let done = action == "reset" ? icli_tcc_reset(service, bundleID) : icli_tcc_set(service, path, action == "grant")
        guard done else { throw IcliError.unavailable(unavailable) }
    }
    var result = try appPermissions(bundleID)
    result["changed"] = all ? ["all"] : names
    result["action"] = action
    return result
}

/// Empties an app's data container as a fresh install has it, after stopping
/// the app, and by default resets its permissions. Keychain items survive, as
/// they survive deleting the app.
public func resetApp(_ bundleID: String, force: Bool, keepPermissions: Bool) throws -> [String: Any] {
    guard force else { throw IcliError.forceRequired("erase \(bundleID)'s data") }
    let app = try appInfo(bundleID)
    guard let container = app["data_path"] as? String, !container.isEmpty,
          FileManager.default.fileExists(atPath: container)
    else {
        throw IcliError.failed("\(bundleID) has no data container")
    }
    let stopped = try appIsRunning(app)
    if stopped { _ = try killApp(bundleID, force: true) }
    let manager = FileManager.default
    let owner = try manager.attributesOfItem(atPath: container)
    let ownership: [FileAttributeKey: Any] = [
        .ownerAccountID: owner[.ownerAccountID] as Any, .groupOwnerAccountID: owner[.groupOwnerAccountID] as Any,
    ]
    // cfprefsd holds the app's preferences in its cache too, and would hand
    // them back from there, so every domain is emptied through it first.
    let preferences = (container as NSString).appendingPathComponent("Library/Preferences")
    let files = (try? manager.contentsOfDirectory(atPath: preferences)) ?? []
    let domains = Set(files.filter { $0.hasSuffix(".plist") }.map { String($0.dropLast(6)) } + [bundleID])
    var cleared = 0
    for domain in domains.sorted() {
        for key in containerPreferences(domain, container: container).keys {
            try setContainerPreference(key, nil, domain: domain, container: container)
            cleared += 1
        }
    }
    // The container manager's metadata sits at the top and must stay.
    var removed = 0
    for top in ["Documents", "Library", "tmp", "SystemData"] {
        let directory = (container as NSString).appendingPathComponent(top)
        guard let children = try? manager.contentsOfDirectory(atPath: directory) else { continue }
        for child in children {
            try manager.removeItem(atPath: (directory as NSString).appendingPathComponent(child))
            removed += 1
        }
    }
    for path in ["Library/Caches", "Library/Preferences"] {
        let full = (container as NSString).appendingPathComponent(path)
        if manager.fileExists(atPath: (full as NSString).deletingLastPathComponent), !manager.fileExists(atPath: full) {
            try manager.createDirectory(atPath: full, withIntermediateDirectories: false)
            try manager.setAttributes(ownership, ofItemAtPath: full)
        }
    }
    var result: [String: Any] = [
        "reset": bundleID, "container": container, "removed": removed, "stopped_app": stopped,
        "preferences_cleared": cleared, "permissions_reset": !keepPermissions,
    ]
    if !keepPermissions { result["permissions"] = try setAppPermissions(bundleID, [], action: "reset")["permissions"] }
    return result
}
