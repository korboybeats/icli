import Darwin
import Foundation
import IcliPrivate
import IcliSystem

func validateBundleID(_ bundleID: String) throws {
    guard bundleID.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{1,200}$", options: .regularExpression) != nil else {
        throw IcliError.failed("invalid app bundle identifier")
    }
}

private func managedAppPath(_ bundleID: String) throws -> String {
    try validateBundleID(bundleID)
    return JailbreakRoot.current.jbrootPath("/Applications/icli-" + bundleID + ".app")
}

private func managedReceipt(_ bundleID: String) -> String {
    JailbreakRoot.current.jbrootPath("/var/lib/icli/apps/" + bundleID + ".json")
}

/// A validated .app bundle on disk: has a bundle identifier, a Mach-O
/// executable and no symlink that leaves the bundle.
struct ValidatedAppBundle {
    let app: String
    let bundleID: String
    let executable: String
}

func validateAppBundle(_ path: String, kind: String = "app") throws -> ValidatedAppBundle {
    let manager = FileManager.default
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: trimmed, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw IcliError.failed("\(kind) bundle is not a directory: \(path)")
    }
    let infoData = try Data(contentsOf: URL(fileURLWithPath: trimmed + "/Info.plist"))
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
          let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
          let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
          !executable.contains("/"), executable != ".", executable != ".."
    else {
        throw IcliError.failed("\(kind) has invalid bundle metadata")
    }
    _ = try machOInfo(at: trimmed + "/" + executable)
    let bundleRoot = URL(fileURLWithPath: trimmed).resolvingSymlinksInPath().path + "/"
    if let entries = manager.enumerator(at: URL(fileURLWithPath: trimmed), includingPropertiesForKeys: [.isSymbolicLinkKey]) {
        for case let item as URL in entries {
            if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
               !item.resolvingSymlinksInPath().path.hasPrefix(bundleRoot)
            {
                throw IcliError.failed("\(kind) bundle contains a symlink outside the app")
            }
        }
    }
    return ValidatedAppBundle(app: trimmed, bundleID: bundleID, executable: executable)
}

/// An IPA extracted into a private staging directory, which the caller
/// removes: exactly one Payload/*.app with a bundle identifier, a Mach-O
/// executable and no symlink that leaves the bundle.
struct StagedIPA {
    let stage: String
    let app: String
    let bundleID: String
    let executable: String
}

func stageIPA(_ path: String) throws -> StagedIPA {
    let manager = FileManager.default
    let stage = JailbreakRoot.current.scratchDirectory() + "/icli-install-" + UUID().uuidString
    try manager.createDirectory(
        atPath: stage,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700],
    )
    do {
        _ = try decodeBridgeJSON(takeCString(icli_extract_ipa_json(path, stage)), "IPA extraction response")
        let payload = stage + "/Payload"
        let bundles = try manager.contentsOfDirectory(atPath: payload).filter { $0.hasSuffix(".app") }
        guard bundles.count == 1 else { throw IcliError.failed("IPA must contain exactly one Payload/*.app") }
        let validated = try validateAppBundle(payload + "/" + bundles[0], kind: "IPA")
        return StagedIPA(stage: stage, app: validated.app, bundleID: validated.bundleID, executable: validated.executable)
    } catch {
        try? manager.removeItem(atPath: stage)
        throw error
    }
}

func installIPA(_ path: String) throws -> [String: Any] {
    guard geteuid() == 0 else {
        throw IcliError.failed("IPA installation requires root; run sudo icli app install <file.ipa>")
    }
    let manager = FileManager.default
    let staged = try stageIPA(path)
    // The stage also holds the previous app during an upgrade, so it stays
    // when that app could not be moved back.
    var keepStage = false
    defer {
        if !keepStage {
            try? manager.removeItem(atPath: staged.stage)
        }
    }
    let (stage, source, bundleID, executable) = (staged.stage, staged.app, staged.bundleID, staged.executable)
    let target = try managedAppPath(bundleID)
    let receipt = managedReceipt(bundleID)
    let installed = try? appInfo(bundleID)
    if installed != nil, !manager.fileExists(atPath: receipt) {
        throw IcliError.failed("an app with this identifier is already installed outside icli")
    }
    let upgrading = manager.fileExists(atPath: target)
    if upgrading, !manager.fileExists(atPath: receipt) {
        throw IcliError.failed("installation path already exists without an icli receipt")
    }
    if upgrading {
        _ = try killApp(bundleID, force: true)
    }
    try manager.createDirectory(
        atPath: (receipt as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true,
    )
    try manager.createDirectory(
        atPath: (target as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true,
    )
    let backup = stage + "/previous.app"
    if upgrading {
        try manager.moveItem(atPath: target, toPath: backup)
    }
    do {
        try manager.moveItem(atPath: source, toPath: target)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target + "/" + executable)
        _ = try registerApp(target)
        try JSONSerialization.data(withJSONObject: ["bundle_id": bundleID, "path": target])
            .write(to: URL(fileURLWithPath: receipt), options: .atomic)
    } catch {
        _ = icli_unregister_app(target)
        try? manager.removeItem(atPath: target)
        if upgrading {
            do {
                try manager.moveItem(atPath: backup, toPath: target)
                _ = try? registerApp(target)
            } catch let restoreError {
                keepStage = true
                throw IcliError.failed(
                    "\(error); the previous app could not be restored (\(restoreError)) and is kept at \(backup)",
                )
            }
        }
        throw error
    }
    return ["installed": bundleID, "bundle_path": target, "method": "bootstrap_app_registration", "upgraded": upgrading]
}

func uninstallManagedApp(_ bundleID: String) throws -> [String: Any]? {
    let target = try managedAppPath(bundleID)
    let receipt = managedReceipt(bundleID)
    let manager = FileManager.default
    guard manager.fileExists(atPath: receipt) else { return nil }
    guard geteuid() == 0 else { throw IcliError.failed("removing an icli-installed IPA requires root") }
    guard let data = manager.contents(atPath: receipt),
          let record = try JSONSerialization.jsonObject(with: data) as? [String: String],
          record["path"] == target, record["bundle_id"] == bundleID
    else {
        throw IcliError.failed("invalid installation receipt")
    }
    _ = try killApp(bundleID, force: true)
    _ = try unregisterApp(target, force: true)
    try manager.removeItem(atPath: target)
    try manager.removeItem(atPath: receipt)
    return ["uninstalled": bundleID, "method": "bootstrap_app_registration"]
}
