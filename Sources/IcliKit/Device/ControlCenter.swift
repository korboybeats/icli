import Foundation
import IcliPrivate
import IcliSystem

/// The Control Center toggles `icli cc` reads and sets, in Control Center's
/// order. low-power, rotation-lock and appearance are the `device` settings
/// of the same names.
public let controlCenterToggles = [
    "airplane", "wifi", "bluetooth", "cellular", "hotspot", "airdrop", "focus",
    "flashlight", "mirroring", "rotation-lock", "low-power", "appearance",
]

private let toggleAliases = [
    "airplane-mode": "airplane", "wi-fi": "wifi", "bt": "bluetooth", "cellular-data": "cellular",
    "data": "cellular", "personal-hotspot": "hotspot", "dnd": "focus", "do-not-disturb": "focus",
    "torch": "flashlight", "screen-mirroring": "mirroring", "rotation": "rotation-lock",
    "orientation-lock": "rotation-lock", "low-power-mode": "low-power", "dark-mode": "appearance",
]

private func toggleName(_ name: String) throws -> String {
    let key = name.lowercased()
    if controlCenterToggles.contains(key) { return key }
    if let alias = toggleAliases[key] { return alias }
    throw IcliError.failed("unknown toggle \(name); expected one of: \(controlCenterToggles.joined(separator: ", "))")
}

/// Every toggle with its state. A toggle that cannot be read carries `error`
/// instead of failing the list.
public func controlCenterList() -> [String: Any] {
    let toggles: [[String: Any]] = controlCenterToggles.map { name in
        do {
            var state = try controlCenterGet(name)
            state.removeValue(forKey: "modes")
            return state
        } catch let error as IcliError {
            return ["toggle": name, "error": error.message]
        } catch {
            return ["toggle": name, "error": "\(error)"]
        }
    }
    return ["toggles": toggles]
}

public func controlCenterGet(_ name: String) throws -> [String: Any] {
    let toggle = try toggleName(name)
    var result: [String: Any]
    switch toggle {
    case "airplane": result = onOff(try read(icli_cc_airplane_get(), "Airplane Mode"))
    case "wifi": result = onOff(try read(icli_cc_wifi_get(), "Wi-Fi"))
    case "bluetooth": result = onOff(try read(icli_cc_bluetooth_get(), "Bluetooth"))
    case "cellular": result = onOff(try read(icli_cc_cellular_get(), "Cellular data"))
    case "hotspot": result = try hotspotState()
    case "airdrop": result = try airdropState()
    case "focus": result = try focusState()
    case "flashlight": result = try flashlightState()
    case "mirroring": result = try mirroringState()
    case "rotation-lock":
        try requireControlCenter()
        result = onOff(rotationInfo()["locked"] as? Bool == true ? 1 : 0)
    case "low-power": result = onOff(try lowPowerMode()["enabled"] as? Bool == true ? 1 : 0)
    default:
        let style = try appearance()["appearance"] as? String ?? "light"
        result = ["state": style, "enabled": style == "dark"]
    }
    result["toggle"] = toggle
    return result
}

/// Sets a toggle and answers with the state read back afterwards. `changed`
/// is false when the toggle already had the value; nothing is sent then.
public func controlCenterSet(_ name: String, _ value: String) throws -> [String: Any] {
    let toggle = try toggleName(name)
    let before = try controlCenterGet(toggle)
    switch toggle {
    case "airplane", "wifi", "bluetooth", "cellular", "hotspot":
        let enabled = try parseOnOff(value)
        if before["enabled"] as? Bool != enabled { try applyRadio(toggle, enabled) }
    case "airdrop":
        let mode = try airdropMode(value)
        if before["state"] as? String != airdropNames[mode] {
            try check(icli_cc_airdrop_set(Int32(mode)), "AirDrop", seconds: 5)
        }
    case "focus": try setFocus(value, before: before)
    case "flashlight":
        let level = try flashlightLevel(value)
        if abs((before["level"] as? Double ?? -1) - level) >= 0.005 {
            try check(icli_cc_flashlight_set(level), "The flashlight", seconds: 3)
        }
    case "mirroring":
        throw IcliError.failed("mirroring is read-only: start or stop it from Control Center or the AirPlay device")
    case "rotation-lock":
        let locked = try parseOnOff(value)
        if before["enabled"] as? Bool != locked { _ = try setRotationLock(locked) }
    case "low-power":
        let enabled = try parseOnOff(value)
        if before["enabled"] as? Bool != enabled { _ = try setLowPowerMode(enabled) }
    default:
        let style = value.lowercased()
        if before["state"] as? String != style { _ = try setAppearance(style) }
    }
    var after = try controlCenterGet(toggle)
    after["changed"] = !sameState(before, after)
    return after
}

/// Flips a toggle: on to off and back, AirDrop between off and Contacts Only
/// (Everyone counts as on), Focus between off and Do Not Disturb, appearance
/// between light and dark.
public func controlCenterToggle(_ name: String) throws -> [String: Any] {
    let toggle = try toggleName(name)
    let before = try controlCenterGet(toggle)
    let enabled = before["enabled"] as? Bool == true
    switch toggle {
    case "airdrop": return try controlCenterSet(toggle, enabled ? "off" : "contacts")
    case "appearance": return try controlCenterSet(toggle, enabled ? "light" : "dark")
    default: return try controlCenterSet(toggle, enabled ? "off" : "on")
    }
}

// MARK: Shared

private func requireControlCenter() throws {
    #if os(tvOS)
    throw IcliError.unavailable("tvOS has no Control Center toggles.")
    #endif
}

private func onOff(_ value: Int32) -> [String: Any] {
    ["state": value == 1 ? "on" : "off", "enabled": value == 1]
}

private func read(_ value: Int32, _ what: String) throws -> Int32 {
    try requireControlCenter()
    guard value >= 0 else {
        throw IcliError.unavailable("\(what) cannot be read on this device; see docs/entitlements.md for the entitlement it needs.")
    }
    return value
}

private func check(_ status: Int32, _ what: String, seconds: Int) throws {
    switch status {
    case 0: return
    case -1: throw IcliError.unavailable("\(what) cannot be changed on this device; see docs/entitlements.md for the entitlement it needs.")
    case -2: throw IcliError.failed("\(what) did not change within \(seconds) seconds.")
    default: throw IcliError.failed("\(what) refused the change.")
    }
}

private func applyRadio(_ toggle: String, _ enabled: Bool) throws {
    switch toggle {
    case "airplane": try check(icli_cc_airplane_set(enabled), "Airplane Mode", seconds: 5)
    case "wifi": try check(icli_cc_wifi_set(enabled), "Wi-Fi", seconds: 8)
    case "bluetooth": try check(icli_cc_bluetooth_set(enabled), "Bluetooth", seconds: 5)
    case "cellular": try check(icli_cc_cellular_set(enabled), "Cellular data", seconds: 5)
    default: try check(icli_cc_hotspot_set(enabled), "Personal Hotspot", seconds: 5)
    }
}

private func sameState(_ before: [String: Any], _ after: [String: Any]) -> Bool {
    for key in ["state", "mode_id", "level"] {
        let a = before[key].map { "\($0)" }
        let b = after[key].map { "\($0)" }
        if a != b { return false }
    }
    return true
}

// MARK: Personal Hotspot

private func hotspotState() throws -> [String: Any] {
    try requireControlCenter()
    let state = icli_cc_hotspot_state()
    guard state >= 0 else { throw IcliError.unavailable("Personal Hotspot's service is unavailable on this device.") }
    var result = onOff(state == 1023 ? 1 : 0)
    if state < 1022 {
        result["state"] = "unavailable"
        result["available"] = false
    }
    return result
}

// MARK: AirDrop

private let airdropNames = ["off", "contacts", "everyone"]

private func airdropMode(_ value: String) throws -> Int {
    switch value.lowercased() {
    case "off", "receiving-off", "0": return 0
    case "contacts", "contacts-only", "1": return 1
    case "everyone", "2": return 2
    default: throw IcliError.failed("airdrop takes off, contacts or everyone")
    }
}

private func airdropState() throws -> [String: Any] {
    let mode = Int(try read(icli_cc_airdrop_get(), "AirDrop"))
    var result: [String: Any] = ["state": mode < airdropNames.count ? airdropNames[mode] : "\(mode)", "enabled": mode != 0]
    if mode == 2 { result["time_limited"] = icli_cc_airdrop_time_limited() }
    return result
}

// MARK: Flashlight

/// Control Center's four flashlight steps, as SpringBoard keeps the last one
/// in its FlashlightLevel preference (1–4, 3 when unset).
private let flashlightSteps = [0.25, 0.5, 0.85, 1.0]

private func flashlightState() throws -> [String: Any] {
    try requireControlCenter()
    let level = icli_cc_flashlight_level()
    guard level >= 0 else { throw IcliError.unavailable("This device has no flashlight service.") }
    let rounded = (level * 100).rounded() / 100
    var result = onOff(rounded > 0 ? 1 : 0)
    result["level"] = rounded
    if icli_cc_flashlight_overheated() { result["overheated"] = true }
    return result
}

private func flashlightLevel(_ value: String) throws -> Double {
    switch value.lowercased() {
    case "off", "false": return 0
    case "on", "true":
        let user: CFString = geteuid() == 501 ? kCFPreferencesCurrentUser : "mobile" as CFString
        let saved = CFPreferencesCopyValue("FlashlightLevel" as CFString, "com.apple.springboard" as CFString, user, kCFPreferencesAnyHost)
        let step = (saved as? Int).flatMap { (1...4).contains($0) ? $0 : nil } ?? 3
        return flashlightSteps[step - 1]
    default:
        guard let level = Double(value), (0...1).contains(level) else {
            throw IcliError.failed("flashlight takes on, off or a level from 0 to 1")
        }
        return level
    }
}

// MARK: Focus

private func focusState() throws -> [String: Any] {
    try requireControlCenter()
    var focus = try decodeBridgeJSON(takeCString(icli_cc_focus_json()), "Focus state")
    if let error = focus["error"] as? String { throw IcliError.unavailable(error) }
    let active = focus["active"] as? Bool == true
    focus.removeValue(forKey: "active")
    focus["state"] = active ? "on" : "off"
    focus["enabled"] = active
    return focus
}

private let defaultFocusMode = "com.apple.donotdisturb.mode.default"

private func setFocus(_ value: String, before: [String: Any]) throws {
    let wanted = value.lowercased()
    var mode: String?
    if wanted == "on" || wanted == "true" {
        mode = defaultFocusMode
    } else if wanted != "off" && wanted != "false" {
        let modes = before["modes"] as? [[String: Any]] ?? []
        let match = modes.first { ($0["id"] as? String)?.lowercased() == wanted }
            ?? modes.first { ($0["name"] as? String)?.lowercased() == wanted }
            ?? modes.first { ($0["id"] as? String)?.lowercased().split(separator: ".").contains { $0.hasPrefix(wanted) } == true }
        guard let id = match?["id"] as? String else {
            let names = modes.compactMap { $0["name"] as? String }.joined(separator: ", ")
            throw IcliError.failed("focus takes on, off or a Focus name: \(names)")
        }
        mode = id
    }
    let isOn = before["enabled"] as? Bool == true
    if let mode, isOn, before["mode_id"] as? String == mode { return }
    if mode == nil, !isOn { return }
    var message: UnsafeMutablePointer<CChar>?
    let status = mode.map { icli_cc_focus_set($0, &message) } ?? icli_cc_focus_set(nil, &message)
    if status == -3 { throw IcliError.failed(takeCString(message) ?? "The Focus service refused the change.") }
    try check(status, "Focus", seconds: 3)
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while true {
        let now = try focusState()
        let done = mode.map { now["mode_id"] as? String == $0 } ?? (now["enabled"] as? Bool == false)
        if done { return }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw IcliError.failed("Focus did not change within 3 seconds.")
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

// MARK: Screen mirroring

private func mirroringState() throws -> [String: Any] {
    try requireControlCenter()
    var mirroring = try decodeBridgeJSON(takeCString(icli_cc_mirroring_json()), "mirroring state")
    if let error = mirroring["error"] as? String { throw IcliError.unavailable(error) }
    let on = mirroring.removeValue(forKey: "mirroring") as? Bool == true
    mirroring["state"] = on ? "on" : "off"
    mirroring["enabled"] = on
    return mirroring
}
